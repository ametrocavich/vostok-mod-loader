## Metro Mod Loader -- community mod loader for Road to Vostok (Godot 4.6+).
## Loads .vmz/.pck archives from <game>/mods/ via a pre-game config window.
## Two-pass architecture: mounts archives at file-scope, optionally restarts to
## prepend mod autoloads before the game's own autoloads via [autoload_prepend].
extends Node

const MODLOADER_VERSION := "2.3.1"
const MODLOADER_RES_PATH := "res://modloader.gd"
const MOD_DIR := "mods"
const TMP_DIR := "user://vmz_mount_cache"
const UI_CONFIG_PATH := "user://mod_config.cfg"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const PASS_STATE_PATH := "user://mod_pass_state.cfg"
const HEARTBEAT_PATH := "user://modloader_heartbeat.txt"
const SAFE_MODE_FILE := "modloader_safe_mode"
const MAX_RESTART_COUNT := 2

const HOOK_PACK_DIR := "user://modloader_hooks"
const HOOK_PACK_ZIP := "user://modloader_hooks/framework_pack.zip"
const HOOK_PACK_MOUNT_BASE := "res://modloader_hooks"
const VANILLA_CACHE_DIR := "user://modloader_hooks/vanilla"
const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_DOWNLOAD_URL_TEMPLATE := "https://api.modworkshop.net/mods/%s/download"
const MODWORKSHOP_BATCH_SIZE := 100
const API_CHECK_TIMEOUT := 15.0
const API_DOWNLOAD_TIMEOUT := 30.0

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]

# Scripts the script-swap doesn't handle. Same list as RTVModLib's skip_list.
const RTV_SKIP_LIST: Array[String] = [
	"TreeRenderer.gd",     # @tool script, editor only
	"MuzzleFlash.gd",      # 50ms flash effect -- swap overhead breaks timing
	"Hit.gd",              # per-shot instantiated -- swap overhead degrades effects
	"ParticleInstance.gd", # GPUParticles3D -- property restore corrupts draw_passes
	"Message.gd",          # await-based lifecycle -- swap kills the coroutine
	"Mine.gd",             # queue_free after detonation -- swap breaks timing
	"Explosion.gd",        # await + @onready -- swap kills coroutine and particles
]

# Resource scripts serialized to user:// -- wrapping breaks save files.
# ResourceSaver embeds the script path; saves would become mod-dependent.
const RTV_RESOURCE_SERIALIZED_SKIP: Array[String] = [
	"CharacterSave.gd", "ContainerSave.gd", "FurnitureSave.gd",
	"ItemSave.gd", "Preferences.gd", "ShelterSave.gd",
	"SlotData.gd", "SwitchSave.gd", "TraderSave.gd",
	"Validator.gd", "WorldSave.gd",
]

# Resource scripts loaded from res:// only -- no hook point needed.
# Mods should hook the call sites instead of wrapping the data class.
const RTV_RESOURCE_DATA_SKIP: Array[String] = [
	"AIWeaponData.gd", "AttachmentData.gd", "AudioEvent.gd", "AudioLibrary.gd",
	"CasetteData.gd", "CatData.gd", "EventData.gd", "Events.gd",
	"FishingData.gd", "FurnitureData.gd", "GrenadeData.gd",
	"InstrumentData.gd", "ItemData.gd", "KnifeData.gd", "LootTable.gd",
	"RecipeData.gd", "Recipes.gd",
	"SpawnerChunkData.gd", "SpawnerData.gd", "SpawnerSceneData.gd",
	"SpineData.gd", "TaskData.gd", "TrackData.gd",
	"TraderData.gd", "WeaponData.gd",
]

# Engine lifecycle methods are always void; codegen uses this list to pick
# the void template regardless of return-type detection.
const RTV_ENGINE_VOID_METHODS: Array[String] = [
	"_ready", "_process", "_physics_process", "_input",
	"_unhandled_input", "_unhandled_key_input",
	"_enter_tree", "_exit_tree", "_notification",
]

# mod_id of RTVModLib.vmz. When it's enabled we back off so we don't
# double-swap the same scripts.
const RTV_MODLIB_MOD_ID := "rtv-mod-lib"

var _mods_dir: String = ""
var _developer_mode := false
var _has_loaded := false
var _last_mod_txt_status := "none"
var _database_replaced_by := ""

var _ui_mod_entries: Array[Dictionary] = []
var _pending_autoloads: Array[Dictionary] = []
var _report_lines: Array[String] = []
var _loaded_mod_ids: Dictionary = {}
var _registered_autoload_names: Dictionary = {}
var _override_registry: Dictionary = {}
var _mod_script_analysis: Dictionary = {}
var _archive_file_sets: Dictionary = {}

# Hook registry. Hook names are "<scriptname>-<methodname>[-pre|-post|-callback]",
# lowercase. A bare name (no suffix) is a replace hook (first-wins).
signal frameworks_ready
var _hooks: Dictionary = {}              # hook_name -> Array of {callback, priority, id}
var _next_id: int = 1
var _skip_super: bool = false
var _seq: int = 0
var _caller: Node = null                 # public: source node of the current dispatch
var _is_ready: bool = false              # public: true once frameworks_ready has emitted
# Step C re-entry guard: Set of hook_base currently executing a dispatch
# wrapper. When a rewritten mod script's wrapper fires, then its body calls
# super() into vanilla's wrapper, the vanilla wrapper sees the base already
# active and skips dispatch (just runs its body). Prevents double-fire when
# rewritten subclass scripts chain into rewritten vanilla.
var _wrapper_active: Dictionary = {}

# Runtime script-swap state.
var _hook_swap_map: Dictionary = {}      # res_path -> framework GDScript
var _original_scripts: Dictionary = {}   # res_path -> vanilla script ref (UID identity)
var _vanilla_id_to_path: Dictionary = {} # script.get_instance_id() -> res_path
var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _node_swap_connected := false
var _swap_count: int = 0
var _rtv_modlib_registered := false      # true if Engine.set_meta("RTVModLib", ...) was us
var _defer_to_tetra_modlib := false      # true if tetra's mod is loaded -- we stand down
var _ready_is_coroutine_by_path: Dictionary = {}  # res_path -> bool. Sync (false) means
                                                  # _deferred_swap pre-sets _rtv_ready_done
                                                  # so super() doesn't re-run vanilla _ready.

# Script overrides
var _pending_script_overrides: Array[Dictionary] = []  # {vanilla_path, mod_script_path, mod_name, priority}
var _applied_script_overrides: Dictionary = {}         # vanilla_path -> true

var _re_take_over: RegEx
var _re_extends: RegEx
var _re_extends_classname: RegEx
var _re_class_name: RegEx
var _re_func: RegEx
var _re_preload: RegEx
var _re_filename_priority: RegEx

# Mounts previous session's archives at file-scope (before _ready) so autoloads
# that load after ModLoader can resolve their res:// paths.
# Returns a dict keyed by the archive path as it appears in pass state -- used
# by _process_mod_candidate to skip redundant re-mounts that would clobber our
# own overlay overrides applied at static init (e.g. hook pack for mod scripts).
var _filescope_mounted: Dictionary = _mount_previous_session()

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")

	# PRE-INIT cache snapshot: at class-level static init, before we do ANY
	# work (including hook pack mount), which of the known-pinned scripts
	# are already compiled in Godot's ResourceCache? If YES here, something
	# compiled them before ModLoader's class even loaded -- autoload_prepend
	# won't help because ModLoader can't run any earlier in the current
	# architecture. If NO here, they're compiled by game autoloads/scenes
	# that run AFTER our static init, meaning there IS a window to preempt.
	var pinned_probes: Array[String] = [
		"res://Scripts/Camera.gd", "res://Scripts/WeaponRig.gd",
		"res://Scripts/Bed.gd", "res://Scripts/Hitbox.gd", "res://Scripts/Pickup.gd",
		"res://Scripts/Cat.gd", "res://Scripts/CatBox.gd", "res://Scripts/CatFeeder.gd",
		"res://Scripts/Fish.gd", "res://Scripts/Lure.gd", "res://Scripts/FishingRig.gd",
		"res://Scripts/Grenade.gd", "res://Scripts/GrenadeRig.gd",
		"res://Scripts/KnifeRig.gd", "res://Scripts/Noise.gd", "res://Scripts/Recoil.gd",
		"res://Scripts/Optic.gd", "res://Scripts/Laser.gd", "res://Scripts/PIP.gd",
		"res://Scripts/Impulse.gd", "res://Scripts/Instrument.gd",
		"res://Scripts/Television.gd", "res://Scripts/Sway.gd", "res://Scripts/Tilt.gd",
		"res://Scripts/Handling.gd", "res://Scripts/Furniture.gd",
		"res://Scripts/AudioInstance2D.gd", "res://Scripts/AudioInstance3D.gd",
		"res://Scripts/LootContainer.gd", "res://Scripts/Grid.gd", "res://Scripts/UIPosition.gd",
		# Autoload-like (expected to be cached at static init):
		"res://Scripts/Database.gd", "res://Scripts/GameData.gd",
		"res://Scripts/Settings.gd", "res://Scripts/Menu.gd", "res://Scripts/Loader.gd",
		"res://Scripts/Inputs.gd", "res://Scripts/Simulation.gd",
		"res://Scripts/Mode.gd", "res://Scripts/Profiler.gd",
		# Controls (known-working via inline -- should NOT be cached):
		"res://Scripts/Controller.gd", "res://Scripts/Door.gd", "res://Scripts/Trader.gd",
	]
	var pre_cached_count := 0
	var pre_cached_tokenized: PackedStringArray = []
	var pre_cached_source: PackedStringArray = []
	var pre_notloaded: PackedStringArray = []
	for path in pinned_probes:
		if ResourceLoader.has_cached(path):
			pre_cached_count += 1
			var s := load(path) as GDScript
			if s != null and s.source_code.length() > 0:
				pre_cached_source.append(path.get_file())
			else:
				pre_cached_tokenized.append(path.get_file())
		else:
			pre_notloaded.append(path.get_file())
	log_lines.append("[FileScope] PRE-INIT cache: %d/%d probes already cached at static init" \
			% [pre_cached_count, pinned_probes.size()])
	if pre_cached_tokenized.size() > 0:
		log_lines.append("[FileScope]   tokenized (PCK-compiled already): " + ", ".join(pre_cached_tokenized))
	if pre_cached_source.size() > 0:
		log_lines.append("[FileScope]   source-loaded (our take_over_path from prev session): " + ", ".join(pre_cached_source))
	if pre_notloaded.size() > 0:
		log_lines.append("[FileScope]   NOT YET LOADED (preempt window open): " + ", ".join(pre_notloaded))

	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		_write_filescope_log(log_lines)
		return mounted
	# Wipe stale state from a different modloader version (format may have changed).
	# Also reset override.cfg -- prior version may have written [autoload_prepend]
	# entries for mods that are no longer enabled, causing Godot to fail loading
	# their scripts before modloader's _ready even runs.
	var saved_ver: String = cfg.get_value("state", "modloader_version", "")
	if saved_ver != MODLOADER_VERSION:
		log_lines.append("[FileScope] Version mismatch: saved=%s current=%s -- wiping" % [saved_ver, MODLOADER_VERSION])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_static_reset_override_cfg(log_lines)
		_write_filescope_log(log_lines)
		return mounted
	# Detect game updates -- exe mtime change means vanilla scripts may have changed.
	var saved_exe_mtime: int = cfg.get_value("state", "exe_mtime", 0)
	if saved_exe_mtime != 0:
		var current_exe_mtime := FileAccess.get_modified_time(OS.get_executable_path())
		if current_exe_mtime != saved_exe_mtime:
			log_lines.append("[FileScope] Game exe mtime changed -- wiping hook cache")
			# Game updated -- wipe hook cache so Pass 1 regenerates from fresh vanilla.
			_static_wipe_hook_cache()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_static_reset_override_cfg(log_lines)
			_write_filescope_log(log_lines)
			return mounted
	var paths: PackedStringArray = cfg.get_value("state", "archive_paths", PackedStringArray())
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		_write_filescope_log(log_lines)
		return mounted

	log_lines.append("[FileScope] %d archive path(s) in pass state" % paths.size())

	# Were any archives deleted since last session?
	var any_missing := false
	var any_stale := false
	for path in paths:
		var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
				else ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		# VMZ source gone -- check if the zip cache survived.
		if abs_path.get_extension().to_lower() == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			var cached := cache_dir.path_join(abs_path.get_file().get_basename() + ".zip")
			if FileAccess.file_exists(cached):
				log_lines.append("[FileScope]   STALE (vmz gone, cache ok): " + abs_path)
				any_stale = true
				continue
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true

	if any_missing:
		log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
		# Archive gone, no cache. Wipe override.cfg autoload sections so the next
		# boot is clean, but preserve any non-autoload settings ([display], etc.).
		var exe_dir := OS.get_executable_path().get_base_dir()
		var cfg_path := exe_dir.path_join("override.cfg")
		var preserved := _read_preserved_cfg_sections(cfg_path)
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		if f:
			f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
			f.close()
		var state_path := ProjectSettings.globalize_path(PASS_STATE_PATH)
		if FileAccess.file_exists(state_path):
			DirAccess.remove_absolute(state_path)
		_write_filescope_log(log_lines)
		return mounted

	if any_stale:
		# Source gone but cache works -- invalidate hash so Pass 1 rewrites state.
		cfg.set_value("state", "mods_hash", "")
		cfg.save(PASS_STATE_PATH)

	for path in paths:
		if ProjectSettings.load_resource_pack(path):
			var remaps := _static_resolve_remaps(path)
			log_lines.append("[FileScope]   MOUNTED: " + path
					+ (" (%d remaps)" % remaps if remaps > 0 else ""))
			mounted[path] = true
		elif path.get_extension().to_lower() == "vmz":
			var zip_path := _static_vmz_to_zip(path)
			if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
				var remaps := _static_resolve_remaps(zip_path)
				log_lines.append("[FileScope]   MOUNTED (vmz->zip): " + path
						+ (" (%d remaps)" % remaps if remaps > 0 else ""))
				mounted[path] = true
			else:
				log_lines.append("[FileScope]   MOUNT FAILED (vmz): " + path + " zip_path=" + zip_path)
		else:
			log_lines.append("[FileScope]   MOUNT FAILED: " + path)

	# Step D: mount the hook pack (Scripts/<Name>.gd + .gd.remap + empty
	# .gdc for each rewritten vanilla) at static init -- BEFORE any game
	# autoload compiles a class_name script. This is the only way to
	# rewire scripts Godot pre-compiles during class_cache population
	# (Camera, WeaponRig in the current mod set); source_code+reload and
	# CACHE_MODE_IGNORE+take_over_path both fail after class_cache pins
	# a compiled reference. Must mount AFTER mod archives so our
	# Scripts/*.gd entries win via replace_files=true.
	#
	# First-ever session: no pass_state entry, skip. Pass 1 will generate
	# and activate this session -- Camera/WeaponRig fall back to PCK
	# bytecode that first run. Second session onward: pre-mount works.
	# Fallback to HOOK_PACK_ZIP constant if pass_state lost the key
	# (e.g. after a version-mismatch wipe). The zip survives on disk.
	var hook_pack: String = cfg.get_value("state", "hook_pack_path", "") as String
	if hook_pack == "":
		var fallback_abs := ProjectSettings.globalize_path(HOOK_PACK_ZIP)
		if FileAccess.file_exists(fallback_abs):
			hook_pack = HOOK_PACK_ZIP
			log_lines.append("[FileScope] HOOK PACK path missing from pass_state -- using fallback: " + HOOK_PACK_ZIP)
	if hook_pack != "":
		var hook_abs: String = hook_pack if not hook_pack.begins_with("user://") \
				else ProjectSettings.globalize_path(hook_pack)
		if FileAccess.file_exists(hook_abs):
			if ProjectSettings.load_resource_pack(hook_abs, true):
				log_lines.append("[FileScope] HOOK PACK mounted at static init: " + hook_pack)
				# CRITICAL: mounting alone isn't enough. Godot pre-compiles
				# class_name scripts referenced by the initial scene graph
				# (Camera, WeaponRig) BEFORE ModLoader._ready. Once they land
				# in ScriptServer.class_cache as PCK-bytecode, no runtime
				# rewire works. Force a fresh source-compile of every
				# rewritten script RIGHT NOW while we're still at static
				# init -- before game autoloads run, before any scene
				# instantiates. take_over_path claims the canonical path
				# in the cache so downstream load()s return our version.
				var hzr := ZIPReader.new()
				if hzr.open(hook_abs) == OK:
					var preloaded := 0
					var preload_failed := 0
					for f: String in hzr.get_files():
						# Only force-compile vanilla Scripts/ entries.
						# CACHE_MODE_IGNORE runs GDScript's strict reload parser
						# on anything we preload. Vanilla scripts need that --
						# we're preempting the PCK's .gdc compile. Mod scripts
						# at <ModDir>/<Name>.gd are loaded lazily when the mod's
						# autoload does load() -- lenient first-compile lets
						# them through even if the mod's source has quirks
						# (undeclared vars, missing identifiers) that strict
						# reload rejects. We just need them mounted; the pack
						# mount via load_resource_pack already serves them.
						if not f.begins_with("Scripts/") or not f.ends_with(".gd"):
							continue
						var rpath := "res://" + f
						var scr := ResourceLoader.load(rpath, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
						if scr == null or scr.source_code.is_empty():
							preload_failed += 1
							continue
						scr.take_over_path(rpath)
						preloaded += 1
					hzr.close()
					log_lines.append("[FileScope] HOOK PACK preloaded %d script(s) at static init (%d failed)" \
							% [preloaded, preload_failed])
			else:
				log_lines.append("[FileScope] HOOK PACK mount FAILED: " + hook_pack)
		else:
			log_lines.append("[FileScope] HOOK PACK path in pass_state but file missing: " + hook_abs)

	# TEST HOOK: mount the test pack here (static-init, before any autoload
	# runs) so VFS serves our rewritten scripts to the FIRST compilation.
	# Mount it AFTER mod archives so our entries win via replace_files=true.
	var test_pack_path := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
	if FileAccess.file_exists(test_pack_path):
		if ProjectSettings.load_resource_pack(test_pack_path, true):
			log_lines.append("[FileScope] TEST: mounted test_pack_precedence.zip at static init")
		else:
			log_lines.append("[FileScope] TEST: FAILED to mount test_pack_precedence.zip")

	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % mounted.size())
	_write_filescope_log(log_lines)
	return mounted

static func _write_filescope_log(lines: PackedStringArray) -> void:
	for line in lines:
		print(line)
	var f := FileAccess.open("user://modloader_filescope.log", FileAccess.WRITE)
	if f:
		for line in lines:
			f.store_line(line)
		f.close()

# Reset override.cfg to a clean state -- just [autoload] ModLoader + any
# preserved non-autoload sections. Used when pass state is wiped so stale
# [autoload_prepend] entries from prior launches don't crash the next boot
# by referencing scripts whose archive isn't file-scope-mounted.
static func _static_reset_override_cfg(log_lines: PackedStringArray) -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var cfg_path := exe_dir.path_join("override.cfg")
	if not FileAccess.file_exists(cfg_path):
		return
	var preserved := _read_preserved_cfg_sections(cfg_path)
	var f := FileAccess.open(cfg_path, FileAccess.WRITE)
	if f == null:
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (read-only?)")
		return
	f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
	f.close()
	log_lines.append("[FileScope] override.cfg reset to clean [autoload_prepend] state")

static func _static_wipe_hook_cache() -> void:
	# Wipe every Framework*.gd we previously generated (cheap to regenerate).
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if DirAccess.dir_exists_absolute(pack_dir):
		var pdir := DirAccess.open(pack_dir)
		if pdir != null:
			pdir.list_dir_begin()
			while true:
				var pname := pdir.get_next()
				if pname == "":
					break
				if pname.begins_with("Framework") and pname.ends_with(".gd"):
					DirAccess.remove_absolute(pack_dir.path_join(pname))
			pdir.list_dir_end()
	var cache_dir := ProjectSettings.globalize_path(VANILLA_CACHE_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		var full := cache_dir.path_join(file_name)
		if dir.current_is_dir():
			# Shallow -- vanilla cache is only Scripts/*.gd (one level deep)
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		file_name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(cache_dir)

static func _static_vmz_to_zip(vmz_path: String) -> String:
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		DirAccess.make_dir_recursive_absolute(cache_dir)
	var zip_name := vmz_path.get_file().get_basename() + ".zip"
	var zip_path := cache_dir.path_join(zip_name)
	if FileAccess.file_exists(zip_path):
		# Re-extract if source is newer than cache (mod was updated in-place).
		var src_time := FileAccess.get_modified_time(vmz_path)
		var zip_time := FileAccess.get_modified_time(zip_path)
		if src_time <= zip_time:
			return zip_path
	var src := FileAccess.open(vmz_path, FileAccess.READ)
	if src == null:
		return ""
	var dst := FileAccess.open(zip_path, FileAccess.WRITE)
	if dst == null:
		src.close()
		return ""
	while src.get_position() < src.get_length():
		dst.store_buffer(src.get_buffer(65536))
	src.close()
	dst.close()
	return zip_path

# Entry point

func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	await get_tree().process_frame
	_compile_regex()
	# Hook _load_all_mods completion to mount our test pack AFTER mod re-mounts.
	# (Test pack mounted before _run_pass_2 gets overwritten when load_all_mods
	# re-mounts ImmersiveXP.vmz with replace_files=true.)
	var is_pass_2 := "--modloader-restart" in OS.get_cmdline_user_args()
	if _load_test_pack_flag() and not is_pass_2:
		_test_pack_precedence()
		_log_info("[TEST-REMAP] test complete (Pass 1, before restart)")
	if is_pass_2:
		await _run_pass_2()
	else:
		await _run_pass_1()
	# Deferred verify: by now all autoloads have run. Check what IXP took over.
	if _load_test_pack_flag():
		await get_tree().create_timer(1.0).timeout
		_test_post_autoload_verify()

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

# Pass 1: Normal launch -- show UI, configure, optionally restart

func _run_pass_1() -> void:
	_log_info("Metro Mod Loader v" + MODLOADER_VERSION)
	_check_crash_recovery()
	_check_safe_mode()
	_compile_regex()
	_build_class_name_lookup()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_clean_stale_cache()
	_load_ui_config()
	await show_mod_ui()
	_save_ui_config()

	load_all_mods()
	_apply_script_overrides()  # apply [script_overrides] before hook generation

	var sections := _build_autoload_sections()
	var archive_paths := _collect_enabled_archive_paths()

	var new_hash := _compute_state_hash(archive_paths, sections.prepend)
	var old_hash := ""
	var state_cfg := ConfigFile.new()
	if state_cfg.load(PASS_STATE_PATH) == OK:
		old_hash = state_cfg.get_value("state", "mods_hash", "")

	if new_hash == old_hash and not new_hash.is_empty():
		_log_info("Mod state unchanged -- skipping restart")
		await _finish_with_existing_mounts()
		return

	# Note: do NOT generate framework wrappers here. If we restart, the work is
	# wasted. Pass 2 will generate after archives are mounted + class lookup
	# rebuilt. Single-pass paths (_finish_single_pass, _finish_with_existing_mounts)
	# generate before activating hooks.

	if archive_paths.size() > 0:
		_log_info("Preparing two-pass restart -- %d archive(s)" % archive_paths.size())
		if sections.prepend.size() > 0:
			_log_info("  %d early autoload(s) in [autoload_prepend]" % sections.prepend.size())
		_write_heartbeat()
		var err := _write_override_cfg(sections.prepend)
		if err != OK:
			_log_critical("Failed to write override.cfg (error %d) -- single-pass fallback" % err)
			await _finish_single_pass()
			return
		if _write_pass_state(archive_paths, new_hash) != OK:
			await _finish_single_pass()
			return
		var restart_args := Array(OS.get_cmdline_args())
		restart_args.append_array(["--", "--modloader-restart"])
		OS.set_restart_on_exit(true, restart_args)
		get_tree().quit()
		return

	# No archives enabled. Clean up stale two-pass state if present.
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_restore_clean_override_cfg()
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR)):
		_static_wipe_hook_cache()
		_log_info("[Hooks] Cleaned up unused hook artifacts")
	await _finish_single_pass()

func _finish_with_existing_mounts() -> void:
	# Register meta + generate the framework pack BEFORE mod autoloads run so
	# Engine.get_meta("RTVModLib") is live by the time they call .hook().
	# Script overrides were already applied in _run_pass_1() before the hash
	# check; no need to re-apply from pass state.
	_detect_tetra_modlib()
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	# take_over_path runs AFTER mod autoloads have registered their hooks.
	_activate_hooked_scripts()
	_connect_node_swap()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

func _finish_single_pass() -> void:
	_detect_tetra_modlib()
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_activate_hooked_scripts()
	_connect_node_swap()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

# Pass 2: Post-restart -- archives already mounted at file-scope

func _run_pass_2() -> void:
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _filescope_mounted.size())
	# Restore script overrides from pass state and apply before hooks.
	var _pass_cfg := ConfigFile.new()
	if _pass_cfg.load(PASS_STATE_PATH) == OK:
		var saved_overrides: Array = _pass_cfg.get_value("state", "script_overrides", [])
		for entry in saved_overrides:
			if entry is Dictionary and entry.has("vanilla_path") and entry.has("mod_script_path"):
				_pending_script_overrides.append(entry)
			else:
				_log_warning("[Overrides] Malformed entry in pass state -- skipped")
	_apply_script_overrides()
	_clear_restart_counter()
	_compile_regex()
	_build_class_name_lookup()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_load_ui_config()

	load_all_mods("Pass 2")
	_detect_tetra_modlib()
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	# After load_all_mods re-mounts mod archives (wiping our IXP/Controller
	# override), remount the already-generated test pack to re-apply.
	# NOTE: Godot dedupes load_resource_pack by path, so mounting the same
	# filename twice is a no-op. Copy to a different filename each time.
	if _load_test_pack_flag():
		var src_abs := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
		var reapply_abs := ProjectSettings.globalize_path("user://test_pack_reapply_" \
				+ str(Time.get_ticks_msec()) + ".zip")
		if FileAccess.file_exists(src_abs):
			var src := FileAccess.open(src_abs, FileAccess.READ)
			var dst := FileAccess.open(reapply_abs, FileAccess.WRITE)
			if src and dst:
				dst.store_buffer(src.get_buffer(src.get_length()))
				src.close()
				dst.close()
				if ProjectSettings.load_resource_pack(reapply_abs, true):
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
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])

	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_activate_hooked_scripts()
	_connect_node_swap()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_extends_classname = RegEx.new()
	_re_extends_classname.compile('(?m)^extends\\s+([A-Z]\\w+)\\s*$')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	_re_func = RegEx.new()
	_re_func.compile('(?m)^(?:static\\s+)?func\\s+(\\w+)\\s*\\(')
	_re_preload = RegEx.new()
	_re_preload.compile('preload\\s*\\(\\s*"(res://[^"]+)"\\s*\\)')
	# VostokMods compat: "100-ModName.vmz" encodes priority in the filename.
	_re_filename_priority = RegEx.new()
	_re_filename_priority.compile('^(-?\\d+)-(.*)')

# Mod metadata collection (no mounting)

func collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	_log_info("Scanning mods dir: " + _mods_dir)
	DirAccess.make_dir_recursive_absolute(_mods_dir)
	var dir := DirAccess.open(_mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: " + _mods_dir
				+ " (error " + str(DirAccess.get_open_error()) + ")")
		return entries
	var seen: Dictionary = {}
	var skipped_files: Array[String] = []
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if dir.current_is_dir():
			if _developer_mode and not entry_name.begins_with("."):
				if not seen.has(entry_name):
					seen[entry_name] = true
					entries.append(_build_folder_entry(_mods_dir, entry_name))
			continue
		var ext := entry_name.get_extension().to_lower()
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.pck)")
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s):")
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_info("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	var full_path := mods_dir.path_join(file_name)
	if ext == "pck":
		_last_mod_txt_status = "pck"
	var cfg: ConfigFile = read_mod_config(full_path) if ext != "pck" else null
	var entry := _entry_from_config(cfg, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry)
	return entry

func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
	var mod_name := file_name
	var mod_id   := file_name
	var priority := 0

	# VostokMods compat: parse "100-ModName.vmz" filename priority prefix.
	# The prefix is stripped from mod_name/mod_id defaults and used as fallback priority.
	var base_name := file_name.get_basename()  # strip extension
	var filename_priority := 0
	var has_filename_priority := false
	if _re_filename_priority:
		var m := _re_filename_priority.search(base_name)
		if m:
			filename_priority = int(m.get_string(1))
			base_name = m.get_string(2)
			has_filename_priority = true
			mod_name = base_name
			mod_id   = base_name

	if cfg:
		mod_name = str(cfg.get_value("mod", "name", mod_name))
		mod_id   = str(cfg.get_value("mod", "id",   mod_id))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		elif has_filename_priority:
			priority = filename_priority
	elif has_filename_priority:
		priority = filename_priority
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)
	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id,
		"priority": priority, "enabled": true,
		"cfg": cfg, "mod_txt_status": _last_mod_txt_status,
	}
	if ext == "zip":
		entry["enabled"] = false
	return entry

func _build_entry_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "zip":
		warnings.append("Rename this file from .zip to .vmz to use it")
		return warnings
	if ext == "pck" or ext == "folder":
		return warnings
	var status: String = entry.get("mod_txt_status", "none")
	if status == "none":
		warnings.append("Invalid mod -- may not work correctly. Try re-downloading.")
	elif status == "parse_error":
		warnings.append("Invalid mod -- may not work correctly. Try re-downloading.")
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- packaged incorrectly. Try re-downloading.")
	return warnings

# Config persistence

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for entry in _ui_mod_entries:
		var fn: String = entry["file_name"]
		entry["enabled"] = bool(cfg.get_value("enabled", fn, true))
		if entry["ext"] == "zip":
			entry["enabled"] = false
		if cfg.has_section_key("priority", fn):
			entry["priority"] = int(str(cfg.get_value("priority", fn)))

func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	# Load existing to preserve any custom [settings] keys (e.g. test flags).
	cfg.load(UI_CONFIG_PATH)
	# Clear mod-specific sections so removed mods don't linger.
	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")
	for entry in _ui_mod_entries:
		var fn: String = entry["file_name"]
		cfg.set_value("enabled", fn, entry["enabled"])
		cfg.set_value("priority", fn, entry["priority"])
	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.save(UI_CONFIG_PATH)

# UI

func show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	win.size = Vector2i(960, 640)
	win.min_size = Vector2i(640, 420)
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()

	# Kill the default Godot gray on the Window itself (embedded_border is the
	# stylebox that paints the window's own background area).
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = Color(0.0, 0.0, 0.0)
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Solid dark background so Godot's default gray theme doesn't show through.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	bg_s.border_color = Color(1.0, 1.0, 1.0)
	bg_s.border_width_top    = 1
	bg_s.border_width_bottom = 1
	bg_s.border_width_left   = 1
	bg_s.border_width_right  = 1
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = make_dark_theme()
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	# Bottom bar: instructions + launch button
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Developer Mode: verbose logging, conflict report, and loose folder loading."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.45, 0.45, 0.45)
	bottom.add_child(hint)

	var launch_btn := Button.new()
	launch_btn.text = "  Launch Game  "
	launch_btn.custom_minimum_size = Vector2(130, 36)
	var ls_n := StyleBoxFlat.new()
	ls_n.bg_color = Color(0.05, 0.05, 0.05)
	ls_n.border_color = Color(0.28, 0.28, 0.28)
	ls_n.border_width_top = 1; ls_n.border_width_bottom = 1
	ls_n.border_width_left = 1; ls_n.border_width_right = 1
	ls_n.content_margin_left = 10; ls_n.content_margin_right = 10
	launch_btn.add_theme_stylebox_override("normal", ls_n)
	var ls_h := ls_n.duplicate()
	ls_h.bg_color = Color(0.10, 0.10, 0.10)
	ls_h.border_color = Color(0.55, 0.55, 0.55)
	launch_btn.add_theme_stylebox_override("hover", ls_h)
	var ls_p := ls_n.duplicate()
	ls_p.bg_color = Color(0.03, 0.03, 0.03)
	launch_btn.add_theme_stylebox_override("pressed", ls_p)
	launch_btn.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	launch_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	bottom.add_child(launch_btn)

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = "Mods"
	tabs.add_child(mods_tab)

	var updates_tab := build_updates_tab()
	updates_tab.name = "Updates"
	tabs.add_child(updates_tab)

	await launch_btn.pressed
	win.queue_free()

func make_dark_theme() -> Theme:
	var t := Theme.new()

	const C_PANEL := Color(0.04, 0.04, 0.04)
	const C_BTN   := Color(0.07, 0.07, 0.07)
	const C_BORD  := Color(0.18, 0.18, 0.18)
	const C_HI    := Color(0.90, 0.90, 0.90)
	const C_TEXT  := Color(0.84, 0.84, 0.84)
	const C_DIM   := Color(0.42, 0.42, 0.42)

	# -- Button ----------------------------------------------------------------
	var bn := StyleBoxFlat.new()
	bn.bg_color = C_BTN
	bn.border_color = C_BORD
	bn.border_width_top = 1; bn.border_width_bottom = 1
	bn.border_width_left = 1; bn.border_width_right = 1
	bn.content_margin_left = 8; bn.content_margin_right = 8
	bn.content_margin_top = 3; bn.content_margin_bottom = 3
	var bh := bn.duplicate()
	bh.bg_color = Color(0.10, 0.10, 0.10); bh.border_color = C_HI
	var bp := bn.duplicate(); bp.bg_color = Color(0.03, 0.03, 0.03)
	var bd := bn.duplicate()
	bd.bg_color = Color(0.04, 0.04, 0.04); bd.border_color = Color(0.12, 0.12, 0.12)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", StyleBoxEmpty.new())
	t.set_color("font_color",          "Button", C_TEXT)
	t.set_color("font_hover_color",    "Button", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color",  "Button", C_TEXT)
	t.set_color("font_disabled_color", "Button", C_DIM)

	# -- CheckBox (font only -- box glyph needs texture to restyle) -------------
	t.set_color("font_color",       "CheckBox", C_TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1.0, 1.0, 1.0))

	# -- Label -----------------------------------------------------------------
	t.set_color("font_color", "Label", C_TEXT)

	# -- Panel / PanelContainer ------------------------------------------------
	var ps := StyleBoxFlat.new(); ps.bg_color = C_PANEL
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# -- TabContainer ----------------------------------------------------------
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = C_PANEL
	ts.border_color = C_BORD
	ts.border_width_top = 1; ts.border_width_left = 1; ts.border_width_right = 1
	ts.border_width_bottom = 0
	ts.content_margin_left = 12; ts.content_margin_right = 12
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := ts.duplicate()      # unselected tab
	tu.bg_color = Color(0.02, 0.02, 0.02)
	tu.border_color = Color(0.12, 0.12, 0.12)
	tu.border_width_bottom = 1
	var tc_panel := StyleBoxFlat.new(); tc_panel.bg_color = C_PANEL
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", C_HI)
	t.set_color("font_unselected_color", "TabContainer", C_DIM)
	t.set_color("font_hovered_color",    "TabContainer", C_TEXT)

	# -- HSeparator ------------------------------------------------------------
	var sep := StyleBoxFlat.new(); sep.bg_color = Color(0.14, 0.14, 0.14)
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	# -- LineEdit (SpinBox uses this internally) --------------------------------
	var le := StyleBoxFlat.new()
	le.bg_color = Color(0.04, 0.04, 0.04)
	le.border_color = C_BORD
	le.border_width_top = 1; le.border_width_bottom = 1
	le.border_width_left = 1; le.border_width_right = 1
	le.content_margin_left = 6; le.content_margin_right = 6
	le.content_margin_top = 3; le.content_margin_bottom = 3
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le.duplicate())
	t.set_color("font_color", "LineEdit", C_TEXT)

	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	return t

func build_mods_tab(tabs: TabContainer) -> Control:
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open Mods Folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer Mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", 11)
	dev_check.modulate = Color(0.45, 0.45, 0.45)
	toolbar.add_child(dev_check)

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		var old := tabs.get_node("Mods")
		var idx := old.get_index()
		tabs.remove_child(old)
		old.queue_free()
		var new_tab := build_mods_tab(tabs)
		new_tab.name = "Mods"
		tabs.add_child(new_tab)
		tabs.move_child(new_tab, idx)
		tabs.current_tab = idx
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: mod list --------------------------------------------------------

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(list)

	# -- Right: live load order preview ----------------------------------------

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load Order"
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	# Dark panel behind the load order list for visual separation.
	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.09, 0.09, 0.09)
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	# Rebuilds the right-side order list from current entry state.
	var refresh_order := func():
		for child in order_list.get_children():
			child.queue_free()
		var sorted := _ui_mod_entries.filter(func(e): return e["enabled"])
		sorted.sort_custom(_compare_load_order)
		if sorted.is_empty():
			var lbl := Label.new()
			lbl.text = "(none enabled)"
			lbl.modulate = Color(0.5, 0.5, 0.5)
			order_list.add_child(lbl)
			return
		for i in sorted.size():
			var e: Dictionary = sorted[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.modulate = Color(0.80, 0.80, 0.80)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			order_list.add_child(lbl)

	# -- Column headers --------------------------------------------------------

	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	var h_name := Label.new()
	h_name.text = "Mod"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "Load Order"
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.5, 0.5, 0.5)
		empty.add_theme_font_size_override("font_size", 12)
		list.add_child(empty)

	for entry in _ui_mod_entries:
		var row := HBoxContainer.new()
		list.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 30
		row.add_child(check)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.modulate = Color(0.58, 0.82, 0.38) if entry["enabled"] else Color(0.5, 0.5, 0.5)
		name_col.add_child(name_lbl)

		if entry["ext"] == "folder":
			var dev_lbl := Label.new()
			dev_lbl.text = "[dev folder]"
			dev_lbl.modulate = Color(0.9, 0.3, 0.3)
			dev_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(dev_lbl)
		for warn_text: String in entry.get("warnings", []):
			var warn := Label.new()
			warn.text = warn_text
			warn.modulate = Color(1.0, 0.6, 0.2)
			warn.add_theme_font_size_override("font_size", 11)
			name_col.add_child(warn)

		if entry["ext"] == "zip":
			check.disabled = true

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		if entry["ext"] == "zip":
			spin.editable = false
		row.add_child(spin)

		list.add_child(HSeparator.new())

		# Capture entry by reference (Dictionaries are reference types in GDScript)
		var e := entry
		var nlbl := name_lbl
		check.toggled.connect(func(on: bool):
			e["enabled"] = on
			nlbl.modulate = Color(0.58, 0.82, 0.38) if on else Color(0.5, 0.5, 0.5)
			refresh_order.call()
		)
		spin.value_changed.connect(func(val: float):
			e["priority"] = int(val)
			refresh_order.call()
		)

	refresh_order.call()
	return outer

func build_updates_tab() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 6)
	margin.add_child(container)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var check_btn := Button.new()
	check_btn.text = "Check for Updates"
	toolbar.add_child(check_btn)

	container.add_child(HSeparator.new())

	# Column headers
	var header_row := HBoxContainer.new()
	container.add_child(header_row)

	var h_mod := Label.new()
	h_mod.text = "Mod"
	h_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_mod)

	var h_ver := Label.new()
	h_ver.text = "Version"
	h_ver.custom_minimum_size.x = 90
	header_row.add_child(h_ver)

	var h_status := Label.new()
	h_status.text = "Status"
	h_status.custom_minimum_size.x = 160
	header_row.add_child(h_status)

	var h_action := Label.new()
	h_action.text = "Action"
	h_action.custom_minimum_size.x = 90
	header_row.add_child(h_action)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, mw_id, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var mw_id := 0
		if cfg.has_section_key("updates", "modworkshop"):
			mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

		var row := HBoxContainer.new()
		list.add_child(row)

		# Name column: mod name + last-modified date sub-label.
		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_col.add_child(name_lbl)

		var mtime := FileAccess.get_modified_time(entry["full_path"])
		if mtime > 0:
			var dt := Time.get_datetime_dict_from_unix_time(mtime)
			var date_str := "%04d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
			var mod_lbl := Label.new()
			mod_lbl.text = "modified " + date_str
			mod_lbl.add_theme_font_size_override("font_size", 11)
			mod_lbl.modulate = Color(0.5, 0.5, 0.5)
			name_col.add_child(mod_lbl)

		var ver_lbl := Label.new()
		ver_lbl.text = "v" + version if version != "" else "--"
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		status_lbl.text = "no update info" if mw_id == 0 or version == "" else "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width. Use modulate.a to
		# hide it visually without collapsing its layout slot.
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if mw_id > 0 and version != "":
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "mw_id": mw_id,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"],
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods with update information found.\nAdd [updates] modworkshop=<id> and version=<x.y.z> to mod.txt to enable this."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	# -- Activity log ----------------------------------------------------------

	container.add_child(HSeparator.new())

	var log_hdr := Label.new()
	log_hdr.text = "Activity"
	log_hdr.add_theme_font_size_override("font_size", 11)
	log_hdr.modulate = Color(0.65, 0.65, 0.65)
	container.add_child(log_hdr)

	var log_bg := PanelContainer.new()
	log_bg.custom_minimum_size.y = 72
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = Color(0.09, 0.09, 0.09)
	log_style.content_margin_left = 6
	log_style.content_margin_right = 6
	log_style.content_margin_top = 4
	log_style.content_margin_bottom = 4
	log_bg.add_theme_stylebox_override("panel", log_style)
	container.add_child(log_bg)

	var log_scroll := ScrollContainer.new()
	log_bg.add_child(log_scroll)

	var log_list := VBoxContainer.new()
	log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_list)

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var lbl := Label.new()
		lbl.text = "[" + t + "] " + msg
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.modulate = Color(0.8, 0.8, 0.8)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_list.add_child(lbl)
		log_scroll.scroll_vertical = 999999

	check_btn.pressed.connect(func():
		check_btn.disabled = true
		check_btn.text = "Checking..."
		for fn in status_info:
			var info: Dictionary = status_info[fn]
			(info["label"] as Label).text = "checking..."
			(info["label"] as Label).modulate = Color(1.0, 1.0, 1.0)
			var btn: Button = info["dl_btn"]
			btn.modulate.a = 0.0
			btn.disabled = true
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.text = "Download"
		await check_updates_for_ui(status_info, add_log, check_btn)
		check_btn.disabled = false
		check_btn.text = "Check for Updates"
	)

	return margin

func check_updates_for_ui(status_info: Dictionary, add_log: Callable, check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		return

	var latest := await fetch_latest_modworkshop_versions(ids)

	if not is_instance_valid(check_btn):
		return

	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var dl_btn: Button = info["dl_btn"]
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			lbl.text = "no data"
			lbl.modulate = Color(1.0, 1.0, 1.0)
			continue

		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			lbl.text = "up to date"
			lbl.modulate = Color(0.6, 0.6, 0.6)
		else:
			# Server has a newer version.
			lbl.text = "update: v" + str(latest_v)
			lbl.modulate = Color(0.90, 0.90, 0.90)
			dl_btn.modulate.a = 1.0
			dl_btn.disabled = false
			dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			var full_path: String = info["full_path"]
			var mw_id: int = info["mw_id"]
			var mod_name: String = info["mod_name"]
			var new_ver: String = str(latest_v)
			# Disconnect previous connections so repeated checks don't stack callbacks.
			for c in dl_btn.pressed.get_connections():
				dl_btn.pressed.disconnect(c["callable"])
			dl_btn.pressed.connect(func():
				dl_btn.disabled = true
				dl_btn.text = "Downloading..."
				lbl.text = "downloading..."
				check_btn.disabled = true
				var ok := await download_and_replace_mod(full_path, mw_id)
				if not is_instance_valid(check_btn):
					return
				if not is_instance_valid(dl_btn):
					return
				check_btn.disabled = false
				if ok:
					lbl.text = "updated -- restart to apply"
					lbl.modulate = Color(0.80, 0.80, 0.80)
					dl_btn.modulate.a = 0.0
					dl_btn.disabled = true
					dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
					dl_btn.text = "Download"
					# Update cached version so next Check won't re-flag this mod.
					info["version"] = new_ver
					(info["ver_lbl"] as Label).text = "v" + new_ver
					add_log.call(mod_name + " -- updated to v" + new_ver + ". Restart game to apply.")
				else:
					lbl.text = "download failed"
					lbl.modulate = Color(1.0, 0.4, 0.4)
					dl_btn.disabled = false
					dl_btn.text = "Retry"
					add_log.call(mod_name + " -- download failed.")
			)

# Main load loop

func load_all_mods(pass_label: String = "") -> void:
	_pending_autoloads.clear()
	_loaded_mod_ids.clear()
	_registered_autoload_names.clear()
	_override_registry.clear()
	_report_lines.clear()
	_database_replaced_by = ""
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_hooks.clear()
	_pending_script_overrides.clear()
	_applied_script_overrides.clear()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)

	if candidates.is_empty():
		_log_info("No mods enabled.")
		return

	# Warn about duplicate mod names -- likely a packaging mistake or fork.
	# The sort is still deterministic (file_name tiebreaker), but users should know.
	for i in range(1, candidates.size()):
		if (candidates[i]["mod_name"] as String).to_lower() \
				== (candidates[i - 1]["mod_name"] as String).to_lower():
			_log_warning("Duplicate mod name '" + candidates[i]["mod_name"]
					+ "' -- archives '" + candidates[i - 1]["file_name"]
					+ "' and '" + candidates[i]["file_name"]
					+ "'. Load order tie broken by archive filename.")

	var header := "=== Load Order" + (" (" + pass_label + ")" if pass_label != "" else "") + " ==="
	_log_info(header)
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		_log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"]
				+ " [priority=" + str(c["priority"]) + "]")
	_log_info("=" .repeat(header.length()))

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)

func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	var full_path: String = c["full_path"]
	var ext:       String = c["ext"]
	var mod_name:  String = c["mod_name"]
	var mod_id:    String = c["mod_id"]
	var cfg               = c["cfg"]

	_log_info("--- [" + str(load_index + 1) + "] " + mod_name + " (" + file_name + ")")

	if ext == "zip":
		_log_warning("Skipping .zip file: " + file_name + " -- rename to .vmz to use")
		return

	if ext != "pck" and _loaded_mod_ids.has(mod_id):
		_log_warning("Duplicate mod id '" + mod_id + "' -- skipped: " + file_name)
		return

	var mount_path := full_path
	if ext == "folder":
		mount_path = zip_folder_to_temp(full_path)
		if mount_path == "":
			_log_critical("Failed to zip folder: " + file_name)
			return

	# If this archive was already file-scope-mounted at static init, skip the
	# redundant re-mount. ProjectSettings.load_resource_pack with
	# replace_files=true (default in _try_mount_pack) would otherwise clobber
	# any overlay pack we mounted AFTER this archive -- e.g. an inline-hooks
	# overlay whose entries overlap with this mod's archive paths.
	if _filescope_mounted.has(full_path):
		_log_info("  File-scope mount active -- skipping re-mount")
		_log_debug("  Mount path: " + mount_path)
	elif not _try_mount_pack(mount_path):
		_log_critical("Failed to mount: " + file_name + " (path: " + mount_path + ")")
		return
	else:
		_log_info("  Mounted OK")
		_log_debug("  Mount path: " + mount_path)

	if ext != "pck":
		var scan_path := mount_path if ext == "folder" else full_path
		scan_and_register_archive_claims(scan_path, mod_name, file_name, load_index)

	if ext == "pck" or cfg == null:
		if cfg == null and ext != "pck":
			var status: String = c.get("mod_txt_status", "none")
			if status.begins_with("nested:"):
				_log_warning("  Invalid mod -- packaged incorrectly (nested mod.txt at " + status.substr(7) + ")")
			elif status == "parse_error":
				_log_warning("  Invalid mod -- mod.txt failed to parse")
			else:
				_log_warning("  No mod.txt -- autoloads skipped")
		return

	_loaded_mod_ids[mod_id] = true

	# [hooks] is optional -- all class_name methods are pre-wrapped.
	if cfg != null and cfg.has_section("hooks"):
		for key in cfg.get_section_keys("hooks"):
			var script_path := str(key)
			var methods_str := str(cfg.get_value("hooks", key))
			for method_name in methods_str.split(","):
				method_name = method_name.strip_edges()
				if method_name.is_empty():
					continue
				_log_info("  Hook hint: %s :: %s [%s]" % [script_path, method_name, mod_name])

	# [script_overrides] -- full script replacements that chain via extends.
	if cfg != null and cfg.has_section("script_overrides"):
		for key in cfg.get_section_keys("script_overrides"):
			var vanilla_path := str(key).strip_edges()
			var mod_script_path := str(cfg.get_value("script_overrides", key)).strip_edges()
			if vanilla_path.is_empty() or mod_script_path.is_empty():
				_log_warning("  Empty script_overrides entry -- skipped")
				continue
			_pending_script_overrides.append({
				"vanilla_path": vanilla_path,
				"mod_script_path": mod_script_path,
				"mod_name": mod_name,
				"priority": c.get("priority", 0),
			})
			_log_info("  Script override: %s -> %s" % [vanilla_path, mod_script_path])

	if cfg == null or not cfg.has_section("autoload"):
		return

	var keys: PackedStringArray = cfg.get_section_keys("autoload")
	for key in keys:
		var autoload_name := str(key)
		var raw_path := str(cfg.get_value("autoload", key)).lstrip("*").strip_edges()
		var is_early := raw_path.begins_with("!")
		if is_early:
			raw_path = raw_path.lstrip("!")
		var res_path := raw_path

		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' -- skipped")
			continue

		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' -- skipped")
			continue
		_registered_autoload_names[autoload_name] = true

		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
			_log_critical("  Autoload path not found in archive: " + res_path)
			_log_critical("    Declared in mod.txt but missing from: " + file_name)
			# Log similar paths to help mod authors diagnose typos / case mismatches.
			var similar: Array[String] = []
			var target_file := res_path.get_file().to_lower()
			for p: String in _archive_file_sets[file_name]:
				if p.get_file().to_lower() == target_file:
					similar.append(p)
			if similar.size() > 0:
				_log_critical("    Similar paths in archive: " + ", ".join(similar))
			continue

		_pending_autoloads.append({
			"mod_name": mod_name, "name": autoload_name, "path": res_path,
			"is_early": is_early,
		})
		var early_tag := " [EARLY]" if is_early else ""
		_log_info("  Autoload queued: " + autoload_name + " -> " + res_path + early_tag)
		_register_claim(res_path, mod_name, file_name, load_index)

# Logging

func _log_info(msg: String) -> void:
	var line := "[ModLoader][Info] " + msg
	print(line)
	_report_lines.append(line)

func _log_warning(msg: String) -> void:
	var line := "[ModLoader][Warning] " + msg
	push_warning(line)
	_report_lines.append(line)

func _log_critical(msg: String) -> void:
	var line := "[ModLoader][Critical] " + msg
	push_error(line)
	_report_lines.append(line)

func _log_debug(msg: String) -> void:
	if not _developer_mode:
		return
	var line := "[ModLoader][Debug] " + msg
	print(line)
	_report_lines.append(line)

# Override registry

func _register_claim(res_path: String, mod_name: String, archive: String,
		load_index: int) -> void:
	if not _override_registry.has(res_path):
		_override_registry[res_path] = []
	for existing in _override_registry[res_path]:
		if existing["mod_name"] == mod_name and existing["archive"] == archive:
			return
	_override_registry[res_path].append({
		"mod_name": mod_name, "archive": archive, "load_index": load_index,
	})

func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	# Filename tiebreaker for stable sort.
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

# Apply [script_overrides] entries via take_over_path.  Each override is a mod
# script that extends the vanilla script.  Processing in priority order (lowest
# first) means each subsequent override's extends resolves to the previous one,
# forming a natural chain: ModB -> ModA -> vanilla.
func _apply_script_overrides() -> void:
	if _pending_script_overrides.is_empty():
		return
	# Sort by priority (lowest first, highest last wins take_over_path).
	_pending_script_overrides.sort_custom(func(a, b): return a["priority"] < b["priority"])
	var applied := 0
	for entry in _pending_script_overrides:
		var vanilla_path: String = entry["vanilla_path"]
		var mod_path: String = entry["mod_script_path"]
		var mod_name: String = entry["mod_name"]

		# Read source and compile fresh so extends resolves to current occupant
		# of the vanilla path (which may be a previous mod's override).
		var src_script := load(mod_path) as GDScript
		if src_script == null:
			_log_critical("[Overrides] Failed to load: %s [%s]" % [mod_path, mod_name])
			continue
		var source := src_script.source_code
		if source.is_empty():
			_log_critical("[Overrides] Empty source: %s [%s]" % [mod_path, mod_name])
			continue

		var new_script := GDScript.new()
		new_script.source_code = source
		var err := new_script.reload()
		if err != OK:
			_log_critical("[Overrides] Compile failed for %s (error %d) [%s]" % [mod_path, err, mod_name])
			continue
		new_script.take_over_path(vanilla_path)
		_applied_script_overrides[vanilla_path] = true
		applied += 1
		_log_info("[Overrides] Applied: %s -> %s [%s]" % [vanilla_path, mod_path, mod_name])
	if applied > 0:
		_log_info("[Overrides] Applied %d script override(s)" % applied)

# --- RTVModLib runtime (port of Main.gd) ------------------------------------
# Mods opt in via mod.txt:
#     [rtvmodlib]
#     needs=["LootContainer","Trader"]    # array literal
#     needs=LootContainer,Trader           # or comma string
# Only requested frameworks get take_over_path'd. Matches RTVModLib's
# per-script opt-in instead of wrapping every game script.

# If RTVModLib.vmz is loaded, we stand down -- both of us doing take_over_path
# + node_added would double-swap every instance.
func _detect_tetra_modlib() -> void:
	_defer_to_tetra_modlib = false
	for entry in _ui_mod_entries:
		if not entry.get("enabled", false):
			continue
		if str(entry.get("mod_id", "")) == RTV_MODLIB_MOD_ID:
			_defer_to_tetra_modlib = true
			_log_info("[RTVModLib] tetra's '%s' mod detected -- modloader will not register its own RTVModLib meta" \
					% RTV_MODLIB_MOD_ID)
			return

func _register_rtv_modlib_meta() -> void:
	if _defer_to_tetra_modlib:
		return
	if Engine.has_meta("RTVModLib"):
		_log_warning("[RTVModLib] Engine.meta 'RTVModLib' already set -- not overwriting")
		return
	Engine.set_meta("RTVModLib", self)
	_rtv_modlib_registered = true
	_log_info("[RTVModLib] modloader registered as Engine.meta('RTVModLib')")

# Mods that await Engine.get_meta("RTVModLib").frameworks_ready block until
# we fire this. No-op when deferring to tetra -- his RTVLib.gd emits its own.
func _emit_frameworks_ready() -> void:
	if _defer_to_tetra_modlib:
		return
	if not _rtv_modlib_registered:
		return
	_is_ready = true
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")

# Collect [rtvmodlib] needs= values across all enabled mods.
# Keys are lowercased framework names ("lootcontainer").
func _collect_needed_from_mods() -> Dictionary:
	var needed: Dictionary = {}
	for entry in _ui_mod_entries:
		if not entry.get("enabled", false):
			continue
		var cfg = entry.get("cfg", null)
		if cfg == null:
			continue
		if not cfg.has_section_key("rtvmodlib", "needs"):
			continue
		var raw = cfg.get_value("rtvmodlib", "needs", null)
		var names: Array = []
		if raw is Array or raw is PackedStringArray:
			for v in raw:
				names.append(str(v))
		elif raw is String:
			for part in (raw as String).split(","):
				var trimmed := (part as String).strip_edges()
				if trimmed != "":
					names.append(trimmed)
		else:
			_log_warning("[RTVModLib] mod '%s' has malformed [rtvmodlib] needs -- ignored" \
					% str(entry.get("mod_name", "?")))
			continue
		for n in names:
			needed[(n as String).to_lower()] = true
	return needed

func _activate_hooked_scripts() -> void:
	if _defer_to_tetra_modlib:
		_log_info("[Hooks] Deferred to tetra's RTVModLib mod -- skipping activation")
		return

	var needed := _collect_needed_from_mods()
	if needed.is_empty():
		_log_info("[Hooks] No mod declared [rtvmodlib] needs -- nothing to activate")
		return

	var activated := 0
	for key in needed.keys():
		var vanilla_path := _resolve_framework_vanilla_path(key)
		if vanilla_path == "":
			_log_warning("[RTVModLib] requested framework '%s' has no vanilla script -- skipped" % key)
			continue
		# Load via the mounted pack (res://) rather than user://. GDScript's
		# extends-chain resolution for class_name parents misbehaves for user://
		# scripts in 4.6.
		var framework_file := HOOK_PACK_MOUNT_BASE.path_join("Framework" + vanilla_path.get_file())
		if not ResourceLoader.exists(framework_file):
			_log_warning("[RTVModLib] Framework not in pack for '%s' at %s -- skipped" % [key, framework_file])
			continue
		if _register_override(framework_file, vanilla_path):
			activated += 1

	if activated > 0:
		_log_info("[RTVModLib] activated %d framework override(s)" % activated)

# Case-insensitive filename match. class_name map covers most; fall back to
# Scripts/ enumeration for non-class_name frameworks (Audio, Cables, etc.).
func _resolve_framework_vanilla_path(key_lower: String) -> String:
	for cn: String in _class_name_to_path:
		var path: String = _class_name_to_path[cn]
		if path.get_file().get_basename().to_lower() == key_lower:
			return path
	for fname in DirAccess.get_files_at("res://Scripts/"):
		if not fname.ends_with(".gd"):
			continue
		if fname.get_basename().to_lower() == key_lower:
			return "res://Scripts/" + fname
	return ""

# class_name scripts can't be take_over_path'd safely: Resource::set_path
# doesn't clear global_name, so ScriptServer ends up with the moved script's
# class_name colliding with the evicted original (corrupts the class, see
# WeaponRig crash). For those we swap via node_added only -- ClassName.new()
# call sites aren't hookable this way.
func _register_override(framework_path: String, expected_vanilla_path: String) -> bool:
	var script: Script = load(framework_path)
	if script == null:
		_log_critical("[RTVModLib] Failed to load %s" % framework_path)
		return false
	(script as GDScript).reload()
	var parent_script := script.get_base_script() as Script
	if parent_script == null:
		_log_critical("[RTVModLib] No parent script for %s" % framework_path)
		return false
	var original_path := parent_script.resource_path
	if original_path == "":
		_log_critical("[RTVModLib] Empty parent path for %s" % framework_path)
		return false
	if expected_vanilla_path != "" and original_path != expected_vanilla_path:
		_log_warning("[RTVModLib] Parent path mismatch for %s (got %s, expected %s)" \
				% [framework_path, original_path, expected_vanilla_path])
	_original_scripts[original_path] = parent_script
	# Index evicted ancestors by instance_id so node_added can still identify
	# UID-loaded nodes whose resource_path went empty after take_over_path.
	_vanilla_id_to_path[parent_script.get_instance_id()] = original_path
	var base := parent_script.get_base_script() as GDScript
	while base != null:
		if base.resource_path == "":
			var bid := base.get_instance_id()
			if not _vanilla_id_to_path.has(bid):
				_vanilla_id_to_path[bid] = original_path
		base = base.get_base_script() as GDScript

	# class_name guard (tetra's fix for WeaponRig crash).
	var global_name: StringName = parent_script.get_global_name()
	if global_name == &"" or String(global_name) == "":
		script.take_over_path(original_path)
		_log_info("[RTVModLib] registered override (take_over_path): %s -> %s" \
				% [framework_path, original_path])
	else:
		_log_info("[RTVModLib] registered override (node_added only): %s -> %s (class_name: %s)" \
				% [framework_path, original_path, global_name])
	_hook_swap_map[original_path] = script
	return true

func _connect_node_swap() -> void:
	if _defer_to_tetra_modlib:
		return
	if _node_swap_connected:
		return
	if _hook_swap_map.is_empty():
		return
	get_tree().node_added.connect(_on_node_added)
	_node_swap_connected = true
	_log_info("[RTVModLib] node_added connected -- tracking %d script(s)" % _hook_swap_map.size())

func _on_node_added(node: Node) -> void:
	var node_script = node.get_script()
	if node_script == null:
		return
	var path: String = node_script.resource_path
	if path == "":
		# UID-loaded scripts lose resource_path. Identify by vanilla identity.
		for original_path in _original_scripts:
			if node_script == _original_scripts[original_path]:
				path = original_path
				break
		if path == "":
			var sid: int = node_script.get_instance_id()
			if _vanilla_id_to_path.has(sid):
				path = _vanilla_id_to_path[sid]
			else:
				return

	if not _hook_swap_map.has(path):
		return
	var framework_script = _hook_swap_map[path]
	if node_script != framework_script:
		call_deferred("_deferred_swap", node, framework_script, path)

# Swap a vanilla-script node to its framework wrapper: snapshot props,
# set_script, restore, then fire _ready so the wrapper dispatches.
#
# Pre-set _rtv_ready_done depends on whether vanilla _ready is async:
#  - Sync _ready (Pickup, Controller, etc): pre-set true, super() is skipped,
#    only post hooks fire. Re-running sync _ready can clobber state mutated
#    by the caller after the original _ready returned (e.g. Pickup._ready
#    calls Freeze, then the drop logic calls Unfreeze; re-running _ready
#    re-Freezes and the item floats).
#  - Async _ready (Trader): leave false. set_script kills the coroutine on
#    the old instance, so post-await code never runs. Letting super() re-run
#    vanilla _ready on the new instance gets it to completion. Pre-await
#    statements re-run, idempotent for tested cases (timer.start /
#    animations.play / @onready assignments).
func _deferred_swap(node: Node, framework_script: Script, path: String) -> void:
	if not is_instance_valid(node):
		return
	if node.get_script() == framework_script:
		return

	# Skip nulls: typed @export node refs can become stale after set_script
	# tears down the instance, and writing a stale ref into a freshly-
	# initialized typed slot corrupts memory.
	var saved_props := {}
	for prop in node.get_property_list():
		var pname: String = prop["name"]
		if pname == "script" or pname == "":
			continue
		var val = node.get(pname)
		if val != null:
			saved_props[pname] = val

	node.set_script(framework_script)

	for pname in saved_props:
		var current = node.get(pname)
		if current != saved_props[pname]:
			node.set(pname, saved_props[pname])

	# Direct _ready() instead of NOTIFICATION_READY: notification re-resolves
	# @onready, which crashes on missing child nodes (per RTVModLib).
	if node.is_inside_tree() and node.has_method("_ready"):
		if _ready_is_coroutine_by_path.has(path) \
				and not _ready_is_coroutine_by_path[path]:
			node.set("_rtv_ready_done", true)
		node._ready()

	_swap_count += 1
	if _swap_count <= 50:
		_log_info("[RTVModLib] Runtime swapped %s on %s" % [path.get_file(), node.name])

# --- Hook API (port of tetra's RTVLib.gd) -----------------------------------
# Mods call these via Engine.get_meta("RTVModLib").

## Register a hook. Returns a hook ID for removal, or -1 if rejected.
## hook_name examples:
##   "interface-open-pre"       - runs before original (stackable)
##   "interface-open-post"      - runs after original (stackable)
##   "interface-open-callback"  - deferred after original (stackable)
##   "interface-open"           - REPLACE the original (first-wins, only one allowed)
## callback: Callable to invoke
## priority: lower = runs first (default 100). Ignored for replace hooks.
func hook(hook_name: String, callback: Callable, priority: int = 100) -> int:
	var is_replace := not (hook_name.ends_with("-pre") \
			or hook_name.ends_with("-post") \
			or hook_name.ends_with("-callback"))
	if is_replace and _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0:
		var owner_id: int = (_hooks[hook_name] as Array)[0]["id"]
		push_warning("RTVModLib: replace hook '" + hook_name \
				+ "' already owned (id=" + str(owner_id) + "), registration rejected")
		return -1
	if not _hooks.has(hook_name):
		_hooks[hook_name] = []
	var entry := { "callback": callback, "priority": priority, "id": _next_id }
	(_hooks[hook_name] as Array).append(entry)
	(_hooks[hook_name] as Array).sort_custom(func(a, b): return a["priority"] < b["priority"])
	var id := _next_id
	_next_id += 1
	return id

## Remove a hook by ID.
func unhook(hook_id: int) -> void:
	for hook_name in _hooks:
		var arr: Array = _hooks[hook_name]
		for i in range(arr.size() - 1, -1, -1):
			if arr[i]["id"] == hook_id:
				arr.remove_at(i)
				return

## Any hooks registered at this name?
func has_hooks(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

## Is a replace hook registered at this bare name (no -pre/-post/-callback)?
func has_replace(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

## ID of the current replace owner, or -1 if none. Lets a mod detect a
## pre-existing replace and fall back to pre/post rather than getting rejected.
func get_replace_owner(hook_name: String) -> int:
	if not _hooks.has(hook_name) or (_hooks[hook_name] as Array).size() == 0:
		return -1
	return (_hooks[hook_name] as Array)[0]["id"]

## From inside a replace hook: prevent super() from running on return.
func skip_super() -> void:
	_skip_super = true

## Monotonic dispatch counter, for tests + debug logging.
func seq() -> int:
	return _seq

# Internal dispatch -- called from the generated framework wrappers.

func _dispatch(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	for entry in _hooks[hook_name]:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.callv(args)

func _dispatch_deferred(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	for entry in _hooks[hook_name]:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.bindv(args).call_deferred()

func _get_hooks(hook_name: String) -> Array:
	if not _hooks.has(hook_name):
		return []
	var callbacks := []
	for entry in _hooks[hook_name]:
		callbacks.append(entry["callback"])
	return callbacks

func _build_class_name_lookup() -> void:
	_class_name_to_path.clear()
	var cache := ConfigFile.new()
	var load_err := cache.load("res://.godot/global_script_class_cache.cfg")
	if load_err == OK:
		var class_list: Array = cache.get_value("", "list", [])
		var skipped := 0
		for entry in class_list:
			var cn: String = str(entry.get("class", ""))
			var path: String = str(entry.get("path", ""))
			if cn != "" and path != "":
				_class_name_to_path[cn] = path
			else:
				skipped += 1
		if _class_name_to_path.size() < 10:
			# A mounted mod (e.g., MCM) may shadow the game's cache with its own
			# 1-entry version.  Fall back to the hardcoded map.
			_log_warning("Class cache has only %d entries (raw=%d) -- mod shadowing detected, using hardcoded fallback" \
					% [_class_name_to_path.size(), class_list.size()])
			_class_name_to_path = _get_hardcoded_class_map()
		else:
			_log_info("Loaded %d class_name mappings from game cache" % _class_name_to_path.size())
	else:
		_log_warning("Could not load global_script_class_cache.cfg -- using hardcoded fallback")
		_class_name_to_path = _get_hardcoded_class_map()

func _get_hardcoded_class_map() -> Dictionary:
	return {
		"AIWeaponData": "res://Scripts/AIWeaponData.gd",
		"Area": "res://Scripts/Area.gd",
		"AttachmentData": "res://Scripts/AttachmentData.gd",
		"AudioEvent": "res://Scripts/AudioEvent.gd",
		"AudioLibrary": "res://Scripts/AudioLibrary.gd",
		"Camera": "res://Scripts/Camera.gd",
		"CasetteData": "res://Scripts/CasetteData.gd",
		"CatData": "res://Scripts/CatData.gd",
		"CharacterSave": "res://Scripts/CharacterSave.gd",
		"ContainerSave": "res://Scripts/ContainerSave.gd",
		"Controller": "res://Scripts/Controller.gd",
		"Door": "res://Scripts/Door.gd",
		"EventData": "res://Scripts/EventData.gd",
		"Events": "res://Scripts/Events.gd",
		"Fish": "res://Scripts/Fish.gd",
		"FishingData": "res://Scripts/FishingData.gd",
		"Flash": "res://Scripts/MuzzleFlash.gd",
		"Furniture": "res://Scripts/Furniture.gd",
		"FurnitureSave": "res://Scripts/FurnitureSave.gd",
		"GameData": "res://Scripts/GameData.gd",
		"Grenade": "res://Scripts/Grenade.gd",
		"GrenadeData": "res://Scripts/GrenadeData.gd",
		"Grid": "res://Scripts/Grid.gd",
		"Hitbox": "res://Scripts/Hitbox.gd",
		"Inspect": "res://Scripts/Inspect.gd",
		"InstrumentData": "res://Scripts/InstrumentData.gd",
		"Item": "res://Scripts/Item.gd",
		"ItemData": "res://Scripts/ItemData.gd",
		"ItemSave": "res://Scripts/ItemSave.gd",
		"Knife": "res://Scripts/KnifeRig.gd",
		"KnifeData": "res://Scripts/KnifeData.gd",
		"LootContainer": "res://Scripts/LootContainer.gd",
		"LootTable": "res://Scripts/LootTable.gd",
		"Lure": "res://Scripts/Lure.gd",
		"Mine": "res://Scripts/Mine.gd",
		"Pickup": "res://Scripts/Pickup.gd",
		"Preferences": "res://Scripts/Preferences.gd",
		"RecipeData": "res://Scripts/RecipeData.gd",
		"Recipes": "res://Scripts/Recipes.gd",
		"Settings": "res://Scripts/Settings.gd",
		"ShelterSave": "res://Scripts/ShelterSave.gd",
		"Slot": "res://Scripts/Slot.gd",
		"SlotData": "res://Scripts/SlotData.gd",
		"SpawnerChunkData": "res://Scripts/SpawnerChunkData.gd",
		"SpawnerData": "res://Scripts/SpawnerData.gd",
		"SpawnerSceneData": "res://Scripts/SpawnerSceneData.gd",
		"SpineData": "res://Scripts/SpineData.gd",
		"Surface": "res://Scripts/Surface.gd",
		"SwitchSave": "res://Scripts/SwitchSave.gd",
		"TaskData": "res://Scripts/TaskData.gd",
		"TrackData": "res://Scripts/TrackData.gd",
		"Trader": "res://Scripts/Trader.gd",
		"TraderData": "res://Scripts/TraderData.gd",
		"TraderSave": "res://Scripts/TraderSave.gd",
		"Validator": "res://Scripts/Validator.gd",
		"WeaponData": "res://Scripts/WeaponData.gd",
		"WeaponRig": "res://Scripts/WeaponRig.gd",
		"WorldSave": "res://Scripts/WorldSave.gd",
	}

# --- GDSC Binary Token Detokenizer -------------------------------------------
# Reconstructs GDScript source from Godot's binary-tokenized .gdc format (GDSC).
# Used when the game exports with binary tokenization and load().source_code is
# empty.  Called for all class_name scripts during hook pack generation.
# Supports TOKENIZER_VERSION 100 (Godot 4.0-4.4) and 101 (Godot 4.5-4.6).

const _GDSC_MAGIC := "GDSC"
const _GDSC_TOKEN_BITS := 8
const _GDSC_TOKEN_MASK := (1 << (_GDSC_TOKEN_BITS - 1)) - 1  # 0x7F
const _GDSC_TOKEN_BYTE_MASK := 0x80

# Token type indices -- Godot 4.5-4.6 / TOKENIZER_VERSION 101.
# 0=EMPTY 1=ANNOTATION 2=IDENTIFIER 3=LITERAL
# 4-9: < <= > >= == !=   10-15: and or not && || !
# 16-21: & | ~ ^ << >>   22-27: + - * ** / %
# 28-39: = += -= *= **= /= %= <<= >>= &= |= ^=
# 40-50: if elif else for while break continue pass return match when
# 51-72: as assert await breakpoint class class_name const enum extends func
#        in is namespace preload self signal static super trait var void yield
# 73-78: [ ] { } ( )   79-87: , ; . .. ... : $ -> _
# 88-90: NEWLINE INDENT DEDENT   91-94: PI TAU INF NAN   99: EOF
#
# Raw int keys are used in dictionaries below because Godot does not allow
# enum references in const dictionary initializers.
const _TOKEN_TEXT := {
	4: "<", 5: "<=", 6: ">", 7: ">=", 8: "==", 9: "!=",
	10: "and", 11: "or", 12: "not", 13: "&&", 14: "||", 15: "!",
	16: "&", 17: "|", 18: "~", 19: "^", 20: "<<", 21: ">>",
	22: "+", 23: "-", 24: "*", 25: "**", 26: "/", 27: "%",
	28: "=", 29: "+=", 30: "-=", 31: "*=", 32: "**=", 33: "/=",
	34: "%=", 35: "<<=", 36: ">>=", 37: "&=", 38: "|=", 39: "^=",
	40: "if", 41: "elif", 42: "else", 43: "for", 44: "while",
	45: "break", 46: "continue", 47: "pass", 48: "return", 49: "match", 50: "when",
	51: "as", 52: "assert", 53: "await", 54: "breakpoint", 55: "class",
	56: "class_name", 57: "const", 58: "enum", 59: "extends", 60: "func",
	61: "in", 62: "is", 63: "namespace", 64: "preload", 65: "self",
	66: "signal", 67: "static", 68: "super", 69: "trait", 70: "var",
	71: "void", 72: "yield",
	73: "[", 74: "]", 75: "{", 76: "}", 77: "(", 78: ")",
	79: ",", 80: ";", 81: ".", 82: "..", 83: "...",
	84: ":", 85: "$", 86: "->", 87: "_",
	91: "PI", 92: "TAU", 93: "INF", 94: "NAN",
	96: "`", 97: "?",
}

# Tokens that want a space BEFORE them (binary operators, keywords after exprs).
const _SPACE_BEFORE := {
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,      # < <= > >= == !=
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1,         # and or not && ||
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,          # & | ^ << >>
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,  # + - * ** / %
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,  # = += -= *= **= /=
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,  # %= <<= >>= &= |= ^=
	40: 1, 42: 1, 51: 1, 61: 1, 62: 1,          # if else as in is
	86: 1,                                        # ->
}

# Tokens that want a space AFTER them.
const _SPACE_AFTER := {
	79: 1, 80: 1, 86: 1,                          # , ; ->
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,          # < <= > >= == !=
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1, 15: 1,    # and or not && || !
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,            # & | ^ << >>
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,    # + - * ** / %
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,    # = += -= *= **= /=
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,    # %= <<= >>= &= |= ^=
	84: 1,                                          # :
	1: 1,                                           # @ annotations
	# All keywords (40-72) need space after:
	40: 1, 41: 1, 42: 1, 43: 1, 44: 1,            # if elif else for while
	45: 1, 46: 1, 47: 1, 48: 1, 49: 1, 50: 1,    # break continue pass return match when
	51: 1, 52: 1, 53: 1, 54: 1, 55: 1,            # as assert await breakpoint class
	56: 1, 57: 1, 58: 1, 59: 1, 60: 1,            # class_name const enum extends func
	61: 1, 62: 1, 63: 1, 64: 1, 65: 1,            # in is namespace preload self
	66: 1, 67: 1, 68: 1, 69: 1, 70: 1,            # signal static super trait var
	71: 1, 72: 1,                                   # void yield
}

func _detokenize_script(script_path: String) -> String:
	# Try multiple methods to read raw bytes -- FileAccess on res:// can fail for
	# PCK-embedded files depending on the container format (RSCC, encryption, etc.).
	var raw := PackedByteArray()

	# Method 1: FileAccess.open() on res:// path directly.
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f:
		raw = f.get_buffer(f.get_length())
		f.close()

	# Method 2: Try the globalized path.
	if raw.is_empty():
		var glob_path := ProjectSettings.globalize_path(script_path)
		f = FileAccess.open(glob_path, FileAccess.READ)
		if f:
			raw = f.get_buffer(f.get_length())
			f.close()

	# Method 3: Try loading as a generic Resource and check if it has raw data.
	# (GDScript objects loaded from tokenized files don't expose raw bytes, but
	# we can try get_file_as_bytes with .gdc extension in case Godot mapped it.)
	if raw.is_empty():
		var gdc_path := script_path.replace(".gd", ".gdc")
		raw = FileAccess.get_file_as_bytes(gdc_path)

	if raw.is_empty():
		_log_warning("[Detokenize] Cannot read bytes from: %s (tried res://, globalized, .gdc)" % script_path)
		return ""

	# -- Header (12 bytes) --
	if raw.size() < 12:
		return ""
	var magic := raw.slice(0, 4).get_string_from_ascii()
	if magic != _GDSC_MAGIC:
		# Not a GDSC file -- might be plain text that load() failed on for another reason.
		var text := raw.get_string_from_utf8()
		if not text.is_empty() and (text.begins_with("extends") or text.begins_with("class_name") or text.begins_with("@")):
			return text
		_log_warning("[Detokenize] Not a GDSC file: " + script_path)
		return ""

	var version := raw.decode_u32(4)
	if version != 100 and version != 101:
		_log_critical("[Detokenize] Unsupported GDSC version %d in %s (expected 100 or 101)" % [version, script_path])
		return ""

	var decompressed_size := raw.decode_u32(8)
	var buf: PackedByteArray
	if decompressed_size == 0:
		buf = raw.slice(12)
	else:
		var compressed := raw.slice(12)
		buf = compressed.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)
		if buf.is_empty():
			_log_critical("[Detokenize] ZSTD decompression failed for: " + script_path)
			return ""

	# -- Metadata --
	var meta_size := 20 if version == 100 else 16  # v100 has 4-byte padding
	if buf.size() < meta_size:
		return ""
	var ident_count: int = buf.decode_u32(0)
	var const_count: int = buf.decode_u32(4)
	var line_count: int  = buf.decode_u32(8)
	var token_count: int
	if version == 100:
		token_count = buf.decode_u32(16)
	else:
		token_count = buf.decode_u32(12)

	var offset := meta_size

	# -- Identifiers (XOR 0xb6 encoded UTF-32) --
	var identifiers: Array[String] = []
	for _i in ident_count:
		if offset + 4 > buf.size():
			break
		var str_len: int = buf.decode_u32(offset)
		offset += 4
		var s := ""
		for _j in str_len:
			if offset + 4 > buf.size():
				break
			var b0: int = buf[offset] ^ 0xb6
			var b1: int = buf[offset + 1] ^ 0xb6
			var b2: int = buf[offset + 2] ^ 0xb6
			var b3: int = buf[offset + 3] ^ 0xb6
			var code_point: int = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
			if code_point > 0:
				s += String.chr(code_point)
			offset += 4
		identifiers.append(s)

	# -- Constants (Variant-encoded, sequential) --
	var constants: Array = []
	for _i in const_count:
		if offset + 4 > buf.size():
			break
		# Decode next Variant from the stream.  We round-trip through
		# var_to_bytes() to determine consumed size since bytes_to_var()
		# doesn't report how many bytes it read.
		var remaining := buf.slice(offset)
		var val = bytes_to_var(remaining)
		constants.append(val)
		# Advance offset by the encoded size.
		var encoded := var_to_bytes(val)
		offset += encoded.size()

	# -- Line/column maps --
	var line_map := {}  # token_index -> line
	var col_map := {}   # token_index -> column
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var line_val: int = buf.decode_u32(offset + 4)
		line_map[tok_idx] = line_val
		offset += 8
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var col_val: int = buf.decode_u32(offset + 4)
		col_map[tok_idx] = col_val
		offset += 8

	# -- Token stream --
	var tokens: Array = []  # Array of [type: int, data_index: int]
	for _i in token_count:
		if offset >= buf.size():
			break
		var token_len := 8 if (buf[offset] & _GDSC_TOKEN_BYTE_MASK) else 5
		if offset + token_len > buf.size():
			break
		var raw_type: int = buf.decode_u32(offset)
		var tk_type: int = raw_type & _GDSC_TOKEN_MASK
		var data_idx: int = raw_type >> _GDSC_TOKEN_BITS
		tokens.append([tk_type, data_idx])
		offset += token_len

	var result := _gdsc_reconstruct(tokens, identifiers, constants, line_map, col_map)
	if result.is_empty():
		return ""
	_log_info("[Detokenize] Reconstructed: %s (%d tokens, %d lines) -- parse OK" \
			% [script_path, tokens.size(), result.count("\n") + 1])
	return result

func _gdsc_reconstruct(tokens: Array, identifiers: Array[String], constants: Array,
		line_map: Dictionary, col_map: Dictionary) -> String:
	var lines := PackedStringArray()
	var current_line := ""
	var current_line_num := 1
	var need_space := false
	var prev_tk := -1
	var line_started := false  # has any visible token been emitted on this line?

	for i in tokens.size():
		var tk: int = tokens[i][0]
		var idx: int = tokens[i][1]

		# Handle line changes via line_map.
		if line_map.has(i):
			var new_line: int = line_map[i]
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == 99:  # EOF
			break

		if tk == 88:  # NEWLINE
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue

		if tk == 89 or tk == 90:  # INDENT / DEDENT -- skip, we use col_map instead
			prev_tk = tk
			continue

		# Build the text for this token.
		var text := ""
		if tk == 2:  # IDENTIFIER
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == 1:  # ANNOTATION
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == 3:  # LITERAL
			text = _gdsc_variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _TOKEN_TEXT.has(tk):
			text = _TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		# Apply indentation from column data for the first visible token on a line.
		if not line_started:
			line_started = true
			if col_map.has(i):
				var col: int = col_map[i]
				# Convert column to tabs (Godot uses tab_size=4 for indentation).
				var tabs: int = col / 4
				for _t in tabs:
					current_line += "\t"

		# Spacing logic.
		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if _SPACE_BEFORE.has(tk):
				add_space_before = true
			elif tk == 2 or tk == 3 or tk == 1 or (tk >= 40 and tk <= 72):
				# IDENTIFIER, LITERAL, ANNOTATION, or any keyword -- space before
				# unless prev was an opener, dot, $, ~, !, indent, newline.
				# Note: annotation (1) excluded only for identifiers (part of the
				# annotation name), NOT for keywords like var/func after @export.
				var skip_anno := (prev_tk == 1 and (tk == 2 or tk == 1))  # ident/anno after anno
				if not skip_anno \
						and prev_tk != 77 and prev_tk != 73 \
						and prev_tk != 81 and prev_tk != 85 \
						and prev_tk != 18 \
						and prev_tk != 15 and prev_tk != 89 \
						and prev_tk != 88 and prev_tk != -1:
					add_space_before = true
			elif tk == 77:  # PAREN_OPEN
				# Space before ( after control-flow keywords, but NOT after
				# function-like keywords (func, preload, super, assert, await).
				if prev_tk >= 40 and prev_tk <= 50:  # if..when (control flow)
					add_space_before = true
			elif tk == 12 or tk == 15:  # NOT, BANG
				add_space_before = true

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "

		current_line += text

		# Set need_space for next token.  _SPACE_AFTER covers operators,
		# keywords, and punctuation.  Also need space after identifiers (2),
		# literals (3), close-parens (78), close-bracket (74), close-brace (76),
		# constants (91-94 PI/TAU/INF/NAN), and underscore (87).
		need_space = _SPACE_AFTER.has(tk) or tk == 2 or tk == 3 \
				or tk == 78 or tk == 74 or tk == 76 \
				or tk == 91 or tk == 92 or tk == 93 \
				or tk == 94 or tk == 87

		prev_tk = tk

	# Flush last line.
	if not current_line.is_empty():
		lines.append(current_line)

	# GDScript files should end with newline.
	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

func _gdsc_variant_to_source(value: Variant) -> String:
	if value == null:
		return "null"
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			var s := str(value)
			if "." not in s and "e" not in s and "inf" not in s.to_lower() and "nan" not in s.to_lower():
				s += ".0"
			return s
		TYPE_STRING:
			return '"%s"' % str(value).c_escape()
		TYPE_STRING_NAME:
			return '&"%s"' % str(value).c_escape()
		TYPE_NODE_PATH:
			return '^"%s"' % str(value).c_escape()
		TYPE_VECTOR2:
			return "Vector2(%s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y)]
		TYPE_VECTOR2I:
			return "Vector2i(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "Vector3(%s, %s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y), _gdsc_variant_to_source(value.z)]
		TYPE_VECTOR3I:
			return "Vector3i(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_COLOR:
			return "Color(%s, %s, %s, %s)" % [_gdsc_variant_to_source(value.r), _gdsc_variant_to_source(value.g), _gdsc_variant_to_source(value.b), _gdsc_variant_to_source(value.a)]
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item in value:
				parts.append(_gdsc_variant_to_source(item))
			return "[%s]" % ", ".join(parts)
		TYPE_DICTIONARY:
			var parts := PackedStringArray()
			for k in value:
				parts.append("%s: %s" % [_gdsc_variant_to_source(k), _gdsc_variant_to_source(value[k])])
			return "{%s}" % ", ".join(parts)
		_:
			return str(value)

func _read_vanilla_source(script_path: String) -> String:
	# On-disk cache first (pristine vanilla from a prior session's detokenize).
	# IMPORTANT: do NOT call load(script_path) here, not even to "verify" the
	# live script. Any load() triggers ResourceFormatLoaderGDScript to read
	# the PCK's .gdc (via the PCK's stale .gd.remap) and cache the tokenized
	# result at script_path. Subsequent hook-pack mounts + loads hit that
	# cached entry instead of our rewrite. Cache must stay cold until the
	# hook pack is mounted.
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			return cached

	# No cache: detokenize from raw .gdc bytes. This uses FileAccess only
	# (never ResourceLoader), so no cache entry is created.
	var source := _detokenize_script(script_path)
	if source.is_empty():
		return ""

	# Detect a rewrite accidentally served at the vanilla path (would mean
	# a prior session left a mount active that contaminated detokenize
	# input -- shouldn't happen in the current design, but catch it loudly
	# so we don't double-rewrite).
	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Hooks] Detokenized source for %s already contains rewrite markers -- possible stale overlay. Delete %s and restart." \
				% [script_path, ProjectSettings.globalize_path(HOOK_PACK_DIR)])
		return ""
	_save_vanilla_source(script_path, source)
	return source

func _save_vanilla_source(script_path: String, source: String) -> void:
	if source.is_empty():
		return  # never write 0-byte cache files
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(cache_file.get_base_dir()))
	var f := FileAccess.open(cache_file, FileAccess.WRITE)
	if f:
		f.store_string(source)
		f.close()

# --- Framework wrapper generation (port of RTVModLib's Rust codegen) --------
# Parses detokenized vanilla source and emits Framework<Name>.gd subclasses
# that dispatch through the RTVModLib meta. Same output as the Rust tool run
# over a gdre_tools decompile, modulo line endings.

var _rtv_re_extends: RegEx
var _rtv_re_class_name: RegEx
var _rtv_re_func: RegEx
var _rtv_re_static_func: RegEx
var _rtv_re_var: RegEx

func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	_rtv_re_func = RegEx.new()
	_rtv_re_func.compile('^func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_static_func = RegEx.new()
	_rtv_re_static_func.compile('^static\\s+func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_var = RegEx.new()
	_rtv_re_var.compile('^(?:@export\\s+)?var\\s+(\\w+)')

func _rtv_extract_param_names(params: String) -> Array:
	var names: Array = []
	if params.strip_edges().is_empty():
		return names
	for p in params.split(","):
		var trimmed := (p as String).strip_edges()
		var without_type := trimmed.split(":")[0]
		var without_default := (without_type as String).split("=")[0]
		var name := (without_default as String).strip_edges()
		if not name.is_empty():
			names.append(name)
	return names

func _rtv_script_hook_prefix(filename: String) -> String:
	var stem := filename
	if stem.ends_with(".gd"):
		stem = stem.substr(0, stem.length() - 3)
	return stem.to_lower()

# Returns:
#   { filename, path, extends, class_name, var_names, functions }
# Each function entry:
#   { name, params, param_names, line_number, is_static, return_type,
#     is_coroutine, has_return_value }
func _rtv_parse_script(filename: String, source: String) -> Dictionary:
	_rtv_compile_codegen_regex()
	var script := {
		"filename": filename,
		"path": "res://Scripts/" + filename,
		"extends": "",
		"class_name": null,
		"functions": [],
		"var_names": [],
	}
	var lines: PackedStringArray = source.split("\n")
	var func_starts: Array = []  # [line_num, name, params, param_names, is_static, return_type]

	for line_num in lines.size():
		var line: String = lines[line_num]
		var trimmed := line.strip_edges()

		var m_ext := _rtv_re_extends.search(trimmed)
		if m_ext != null:
			script["extends"] = m_ext.get_string(1)

		var m_cn := _rtv_re_class_name.search(trimmed)
		if m_cn != null:
			script["class_name"] = m_cn.get_string(1)

		# Top-level var names (line starts with "var" / "@export var" -- no leading indent).
		if not line.begins_with("\t") and not line.begins_with(" "):
			var m_var := _rtv_re_var.search(trimmed)
			if m_var != null:
				(script["var_names"] as Array).append(m_var.get_string(1))

		var m_sfunc := _rtv_re_static_func.search(trimmed)
		if m_sfunc != null:
			var ret_group = m_sfunc.get_string(4) if m_sfunc.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_sfunc.get_string(1), m_sfunc.get_string(2),
				_rtv_extract_param_names(m_sfunc.get_string(2)), true,
				ret_group,
			])
			continue

		var m_func := _rtv_re_func.search(trimmed)
		if m_func != null:
			var ret_group2 = m_func.get_string(4) if m_func.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_func.get_string(1), m_func.get_string(2),
				_rtv_extract_param_names(m_func.get_string(2)), false,
				ret_group2,
			])

	# Second pass: extract function bodies to detect await + return-with-value.
	for idx in func_starts.size():
		var fs: Array = func_starts[idx]
		var line_num: int = fs[0]
		var name: String = fs[1]
		var params: String = fs[2]
		var param_names: Array = fs[3]
		var is_static: bool = fs[4]
		var return_type = fs[5]  # String or null

		var body_start := line_num + 1
		var body_end := lines.size()
		if idx + 1 < func_starts.size():
			body_end = func_starts[idx + 1][0]

		var is_coroutine := false
		var has_return_value := false
		for i in range(body_start, body_end):
			if i >= lines.size():
				break
			var body_line := lines[i].strip_edges()
			if "await " in body_line:
				is_coroutine = true
			# "return <something>" (not bare "return").
			if body_line.begins_with("return ") and body_line.length() > 7:
				has_return_value = true

		# Explicit return type override (void → no value; anything else → has value).
		if return_type != null and return_type != "void":
			has_return_value = true
		if return_type != null and return_type == "void":
			has_return_value = false

		(script["functions"] as Array).append({
			"name": name,
			"params": params,
			"param_names": param_names,
			"line_number": line_num + 1,
			"is_static": is_static,
			"return_type": return_type,
			"is_coroutine": is_coroutine,
			"has_return_value": has_return_value,
		})

	return script

# Produce one Framework<Name>.gd source. Three method templates (matching
# generate_override in the Rust):
#   _ready   -- has a _rtv_ready_done flag so super() doesn't double-fire
#   non-void -- returns a value
#   void    -- engine lifecycle methods, or bodies with no `return <expr>`
func _rtv_generate_override(script: Dictionary) -> String:
	var out := ""
	var prefix := _rtv_script_hook_prefix(script["filename"])
	out += 'extends "%s"\n' % script["path"]

	var has_ready := false
	for func_entry in script["functions"]:
		if func_entry["name"] == "_ready" and not func_entry["is_static"]:
			has_ready = true
			break
	if has_ready:
		out += "var _rtv_ready_done = false\n"
	out += "\n"

	for func_entry in script["functions"]:
		if func_entry["is_static"]:
			continue

		var method_name: String = func_entry["name"]
		var hook_base := "%s-%s" % [prefix, method_name.to_lower()]
		var params: String = func_entry["params"]
		var param_names_str := ", ".join(func_entry["param_names"])

		var sig: String
		if params.is_empty():
			sig = "func %s():" % method_name
		else:
			sig = "func %s(%s):" % [method_name, params]

		var super_call: String
		if param_names_str.is_empty():
			super_call = "super()"
		else:
			super_call = "super(%s)" % param_names_str

		var args_array: String
		if param_names_str.is_empty():
			args_array = "[]"
		else:
			args_array = "[%s]" % param_names_str

		var is_engine_void: bool = method_name in RTV_ENGINE_VOID_METHODS
		var is_void: bool = is_engine_void or not bool(func_entry["has_return_value"])
		var is_ready: bool = method_name == "_ready"

		if is_ready:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\tif not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\t\treturn\n"
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\t_repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif !_did_skip and not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\telse:\n"
			out += "\t\tif not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n\n" % [hook_base, args_array]
		elif not is_void:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\treturn %s\n" % super_call
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _result\n"
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\tvar _replret = _repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif _did_skip:\n"
			out += "\t\t\t_result = _replret\n"
			out += "\t\telse:\n"
			out += "\t\t\t_result = %s\n" % super_call
			out += "\telse:\n"
			out += "\t\t_result = %s\n" % super_call
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [hook_base, args_array]
			out += "\treturn _result\n\n"
		else:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\t%s\n" % super_call
			out += "\t\treturn\n"
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\t_repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif !_did_skip:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\telse:\n"
			out += "\t\t%s\n" % super_call
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n\n" % [hook_base, args_array]

	return out

# Inline source-rewrite generator (Option C / Phase 1 Step A).
#
# Produces the full rewritten source of a vanilla script where each hookable
# method <name> is renamed to _rtv_vanilla_<name> and a new <name> method is
# appended that dispatches through RTVModLib hooks, then calls the renamed
# original.
#
# Unlike _rtv_generate_override which produces a separate wrapper class that
# extends vanilla, this rewrites the vanilla script itself. When shipped at
# res://Scripts/<Name>.gd via a hook pack, it becomes the script Godot compiles
# for that path -- no extends chain, no class_name registry asymmetry, no bug
# #83542 regardless of what mods do with take_over_path.
#
# Caller MUST pass pristine vanilla source (e.g. from .gdc bytecode via
# _read_vanilla_source / _detokenize_script). Passing already-rewritten source
# produces duplicate-function parse errors.
func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, rename_prefix: String = "_rtv_vanilla_") -> String:
	# rename_prefix defaults to "_rtv_vanilla_" for vanilla scripts.
	# Mod subclasses pass "_rtv_mod_" so the renamed mod body doesn't shadow
	# vanilla's renamed body via virtual dispatch. Without this: mod's body
	# is _rtv_vanilla_<name>, vanilla's body is ALSO _rtv_vanilla_<name>, and
	# vanilla's wrapper calls _rtv_vanilla_<name>() on self -- which is a mod
	# instance -- which dispatches to mod's body again. Infinite loop.
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		hookable.append(fe)
	if hookable.is_empty():
		return source

	# Build set of hookable method names for fast lookup during rename pass.
	var hookable_names: Dictionary = {}
	for fe in hookable:
		hookable_names[fe["name"]] = true

	# Normalize line endings. IXP ships CRLF-encoded source; our appended
	# wrappers use LF only. Mixing CRLF and LF in a single file confuses
	# GDScript's parser with a "tab character for indentation" error (even
	# when there are no tabs -- the misleading error is triggered by the
	# ending mismatch). Strip all CR so the whole file is pure LF.
	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")

	# Pass 1: rename top-level "func <name>(" to "func _rtv_vanilla_<name>("
	# AND rewrite bare super() calls inside that body to super.<name>().
	# Only matches at line start (static methods already filtered). Inner-class
	# methods (indented) keep their names. class_name stays intact -- scripts
	# ship at res://Scripts/<Name>.gd matching the PCK's class-cache
	# registration, and extends-by-path from other scripts needs the target
	# to carry a class_name to resolve.
	#
	# super() rewrite rationale: in IXP's Loader.gd `func CheckVersion(): ...
	# return super()`, `super()` means "parent's version of the current
	# function". After we rename the enclosing func to _rtv_vanilla_CheckVersion,
	# GDScript's strict reload parser looks for _rtv_vanilla_CheckVersion on the
	# parent -- which vanilla Loader doesn't have. Rewriting to
	# `super.CheckVersion()` keeps it resolving to the original method name on
	# parent (which is now our dispatch wrapper). `super.<explicit_method>()`
	# and `super.OtherMethod()` are already explicit and pass through untouched.
	var lines: PackedStringArray = src.split("\n")
	var current_hooked_method: String = ""
	for i in lines.size():
		var line: String = lines[i]
		# Top-level line (no indent): may open or close a method block.
		if not line.is_empty() and line[0] != "\t" and line[0] != " ":
			current_hooked_method = ""
			if line.begins_with("func "):
				var open_paren := line.find("(")
				if open_paren >= 0:
					var name_end := open_paren
					while name_end > 5 and line[name_end - 1] == " ":
						name_end -= 1
					var method_name := line.substr(5, name_end - 5)
					if hookable_names.has(method_name):
						lines[i] = "func " + rename_prefix + method_name + line.substr(name_end)
						current_hooked_method = method_name
			continue
		# Indented line: inside some block. If inside a renamed method, rewrite
		# bare super( / super ( to super.<orig_name>( so it still resolves.
		if current_hooked_method.is_empty():
			continue
		if not ("super" in line):
			continue
		lines[i] = _rewrite_bare_super(line, current_hooked_method)

	# Pass 2: append dispatch wrappers at EOF. Match the source's indent
	# style -- GDScript rejects tab/space mixing in a single file. IXP uses
	# 4-space indent; vanilla RTV uses tabs.
	var indent := _detect_indent_style(src)
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n# --- Metro mod loader inline hook dispatch wrappers ---\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent, rename_prefix) + "\n"

	return "\n".join(lines) + appended

# Rewrite bare `super(` / `super (` in a line to `super.<method>(`. Preserves
# the rest of the line verbatim. Skips `super.<something>(` (already explicit),
# and skips occurrences inside strings or comments by stopping at the first
# `#` or quote. Called per-line within a renamed method's body.
func _rewrite_bare_super(line: String, method_name: String) -> String:
	# Strip inline comment/string content before matching to avoid false hits.
	# Simple heuristic: search the part of the line before the first # (not in
	# a string). Strings with # are rare enough that we accept false negatives.
	var scan_end := line.length()
	var comment_idx := line.find("#")
	if comment_idx >= 0:
		scan_end = comment_idx
	var out := line
	var cursor := 0
	while cursor < scan_end:
		var idx := out.find("super", cursor)
		if idx < 0 or idx >= scan_end:
			break
		# Must be a whole word: preceding char can't be alphanumeric or _ or .
		# (dot would mean this is `x.super...` -- not a super call).
		if idx > 0:
			var prev := out[idx - 1]
			if prev == "." or prev == "_" or prev.to_upper() != prev.to_lower() \
					or (prev >= "0" and prev <= "9"):
				cursor = idx + 5
				continue
		# After "super", skip optional whitespace, then require "(".
		var after := idx + 5
		while after < out.length() and out[after] == " ":
			after += 1
		if after >= out.length() or out[after] != "(":
			cursor = idx + 5
			continue
		# Rewrite "super(" segment to "super.<method>(", keeping the rest.
		var before := out.substr(0, idx)
		var rest := out.substr(after)  # from "("
		out = before + "super." + method_name + rest
		# Advance past the replaced region and update scan_end for shift.
		var delta := 1 + method_name.length()  # added ".<name>"
		cursor = idx + 5 + delta + 1  # past "super.<name>("
		scan_end += delta
	return out

# Scan source for the first indented (non-empty, non-comment) line and return
# its leading whitespace as the indent unit. Falls back to tab when the file
# has no indentation (rare -- empty method bodies use `pass` which is typically
# indented). Used to make generated wrappers match the file's existing style,
# since GDScript forbids mixing tabs and spaces.
func _detect_indent_style(source: String) -> String:
	for line: String in source.split("\n"):
		if line.is_empty():
			continue
		var ch: String = line[0]
		if ch != "\t" and ch != " ":
			continue
		# Skip pure-whitespace lines.
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if ch == "\t":
			return "\t"
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		if n > 0:
			return " ".repeat(n)
	return "\t"

# Produces ONE inline dispatch wrapper that calls _rtv_vanilla_<name>(...).
#
# Mirrors _rtv_generate_override's templates but:
#  - calls _rtv_vanilla_<name>(...) instead of super(...)
#  - no _rtv_ready_done flag (same class, no inheritance-chain double-fire)
#  - prepends `await` when the vanilla method is a coroutine
func _rtv_dispatch_inline_src(fe: Dictionary, prefix: String, indent: String = "\t", rename_prefix: String = "_rtv_vanilla_") -> String:
	var method_name: String = fe["name"]
	var params: String = fe["params"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "%s%s(%s)" % [rename_prefix, method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = bool(fe["is_coroutine"])
	var is_engine_void: bool = method_name in RTV_ENGINE_VOID_METHODS
	var is_void: bool = is_engine_void or not bool(fe["has_return_value"])
	var aw: String = "await " if is_coro else ""

	var sig: String = "func %s():" % method_name if params.is_empty() \
			else "func %s(%s):" % [method_name, params]

	# Indent levels. GDScript requires consistent tabs-or-spaces per file;
	# IXP uses 4-space, vanilla RTV uses tabs. Caller passes the source's
	# detected indent so the emitted wrapper matches.
	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	# Dispatch-live probe: one counter per hook_base via Engine meta dict,
	# plus a one-shot print the first time each wrapper fires. That
	# gives a definitive list of every wrapper that executes at runtime
	# AND proves the wrapper body actually runs (not just that source
	# matches). Remove in Step E.
	var probe: String = ""
	probe += "%svar _rtv_bh = Engine.get_meta(\"_rtv_dispatch_by_hook\", {}) as Dictionary\n" % I1
	probe += "%svar _rtv_prev = int(_rtv_bh.get(\"%s\", 0))\n" % [I1, hook_base]
	probe += "%s_rtv_bh[\"%s\"] = _rtv_prev + 1\n" % [I1, hook_base]
	probe += "%sEngine.set_meta(\"_rtv_dispatch_by_hook\", _rtv_bh)\n" % I1
	probe += "%sEngine.set_meta(\"_rtv_dispatch_count\", int(Engine.get_meta(\"_rtv_dispatch_count\", 0)) + 1)\n" % I1
	probe += "%sif _rtv_prev == 0:\n" % I1
	probe += "%sprint(\"[RTV-WRAPPER-FIRST] %s\")\n" % [I2, hook_base]
	# Step C re-entry guard: when a mod's rewritten wrapper fires and its body
	# calls super() into vanilla's rewritten wrapper, the nested wrapper would
	# dispatch again. Guard checks _lib._wrapper_active for this hook_base and
	# if already set, skips ALL dispatch + replace lookup and just runs the
	# vanilla body. One dispatch per logical call regardless of chain depth.
	if not is_void:
		out += "%s\n" % sig
		out += probe
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n" % I1
		out += "%sif !_lib:\n" % I1
		out += "%sEngine.set_meta(\"_rtv_dispatch_no_lib\", int(Engine.get_meta(\"_rtv_dispatch_no_lib\", 0)) + 1)\n" % I2
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%svar _replret = _repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif _did_skip:\n" % I2
		out += "%s_result = _replret\n" % I3
		out += "%selse:\n" % I2
		out += "%s_result = %s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s_result = %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		out += probe
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n" % I1
		out += "%sif !_lib:\n" % I1
		out += "%sEngine.set_meta(\"_rtv_dispatch_no_lib\", int(Engine.get_meta(\"_rtv_dispatch_no_lib\", 0)) + 1)\n" % I2
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%s_repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif !_did_skip:\n" % I2
		out += "%s%s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
	return out

# Step C: mod-script extends scanner. For each enabled mod, walk the archive
# looking for .gd files whose first non-trivial line is extends-by-literal
# "res://Scripts/<X>.gd" where <X> is a vanilla script we already rewrite.
# Those mod scripts get the same rename+dispatch-wrapper treatment, shipped
# at their own res:// path, so hooks fire even when the mod replaces a
# method without calling super().
#
# Returns Array of Dictionary: { mod_name, res_path, vanilla_filename,
# source, load_index }. res_path is the mod's path (res://ModDir/X.gd),
# vanilla_filename keys hook dispatch prefix ("Controller.gd" -> "controller").
func _scan_mod_extends_targets(vanilla_filenames: Dictionary) -> Array:
	var candidates: Array = []
	var entries := _ui_mod_entries.duplicate()
	entries.sort_custom(_compare_load_order)
	var load_index := 0
	for entry: Dictionary in entries:
		if not entry["enabled"]:
			continue
		var mod_name: String = entry["mod_name"]
		var archive_path: String = entry["full_path"]
		var ext: String = entry["ext"]
		# Resolve to zip path for ZIPReader access.
		var abs_archive: String = archive_path
		if ext == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			var cached := cache_dir.path_join(archive_path.get_file().get_basename() + ".zip")
			if not FileAccess.file_exists(cached):
				load_index += 1
				continue
			abs_archive = cached
		elif ext == "folder":
			# Folder mods materialize to a tmp zip during load_all_mods. Skip
			# if that hasn't happened yet this session (rare path).
			var folder_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
					archive_path.get_file() + "_dev.zip")
			if not FileAccess.file_exists(folder_zip):
				load_index += 1
				continue
			abs_archive = folder_zip
		elif ext != "zip" and ext != "pck":
			load_index += 1
			continue
		var zr := ZIPReader.new()
		if zr.open(abs_archive) != OK:
			load_index += 1
			continue
		for f: String in zr.get_files():
			var normalized := f.replace("\\", "/")
			if normalized.get_extension().to_lower() != "gd":
				continue
			var bytes := zr.read_file(f)
			if bytes.is_empty():
				continue
			var text := bytes.get_string_from_utf8()
			var ext_target := _parse_extends_literal(text)
			if ext_target.is_empty() or not ext_target.begins_with("res://Scripts/"):
				continue
			var vfn := ext_target.get_file()
			if not vanilla_filenames.has(vfn):
				continue
			candidates.append({
				"mod_name": mod_name,
				"res_path": "res://" + normalized,
				"vanilla_filename": vfn,
				"source": text,
				"load_index": load_index,
			})
		zr.close()
		load_index += 1
	return candidates

# Parse first non-empty non-comment line for `extends "res://..."`. Returns
# the quoted path, or "" if the script uses class-name extends, non-literal
# extends (preload/load/variable), or something else.
func _parse_extends_literal(source: String) -> String:
	for raw in source.split("\n"):
		var s := raw.strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		# Skip tool/icon annotations that may precede extends.
		if s.begins_with("@"):
			continue
		if not s.begins_with("extends"):
			return ""
		# "extends <target>" -- strip keyword + whitespace.
		var rest := s.substr(7).strip_edges()
		if rest.begins_with("\""):
			var close := rest.find("\"", 1)
			if close < 0:
				return ""
			return rest.substr(1, close - 1)
		return ""
	return ""

# --- Script enumeration -----------------------------------------------------
# DirAccess.get_files_at() returns at most 1 entry on res://Scripts/ in
# Godot 4.6 -- it doesn't enumerate PCK contents. Parse the PCK file table
# directly instead.

# Returns res://Scripts/*.gd paths found in the game's PCK, or [] on failure
# (encrypted pack, embedded pack, new format, missing file). Callers fall
# back to _class_name_to_path when empty.
func _enumerate_game_scripts() -> Array[String]:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var candidates := ["RTV.pck", OS.get_executable_path().get_file().get_basename() + ".pck"]
	for cand in candidates:
		var pck_path := exe_dir.path_join(cand)
		if not FileAccess.file_exists(pck_path):
			continue
		var paths := _parse_pck_file_list(pck_path)
		if paths.is_empty():
			continue
		var scripts: Array[String] = []
		for p in paths:
			# Packed paths lack the res:// prefix; Godot adds it on load.
			var normalized := p
			if not normalized.begins_with("res://"):
				normalized = "res://" + normalized.trim_prefix("/")
			if not normalized.begins_with("res://Scripts/"):
				continue
			# Canonicalize .gdc / .gd.remap / .remap to .gd.
			var canonical := normalized
			if canonical.ends_with(".gd.remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			elif canonical.ends_with(".remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			if canonical.ends_with(".gdc"):
				canonical = canonical.substr(0, canonical.length() - 4) + ".gd"
			if canonical.ends_with(".gd") and canonical not in scripts:
				scripts.append(canonical)
		_log_info("[RTVCodegen] parsed %s -- %d total file(s), %d .gd script(s) under res://Scripts/" \
				% [cand, paths.size(), scripts.size()])
		return scripts
	return []

# Minimal PCK header + file-table parser. V2 (Godot 4.0–4.5) has 16 reserved
# dwords before the directory; V3 (Godot 4.6+) replaces them with an explicit
# 64-bit directory offset. Reference: core/io/file_access_pack.cpp.
func _parse_pck_file_list(pck_path: String) -> PackedStringArray:
	const MAGIC_GDPC: int = 0x43504447  # "GDPC" little-endian
	const PACK_DIR_ENCRYPTED := 1
	const PACK_FORMAT_V2 := 2
	const PACK_FORMAT_V3 := 3
	var result := PackedStringArray()
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		_log_warning("[PCK] cannot open: %s" % pck_path)
		return result

	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		# Would need footer-scan if embedded; not supported.
		_log_warning("[PCK] %s: not a standalone PCK (magic=0x%x)" % [pck_path, magic])
		f.close()
		return result

	var pack_format_version: int = f.get_32()
	if pack_format_version < PACK_FORMAT_V2 or pack_format_version > PACK_FORMAT_V3:
		_log_warning("[PCK] %s: unsupported format version %d" % [pck_path, pack_format_version])
		f.close()
		return result

	f.get_32()  # godot major
	f.get_32()  # godot minor
	f.get_32()  # godot patch
	var pack_flags: int = f.get_32()
	f.get_64()  # file_base

	if pack_format_version == PACK_FORMAT_V3:
		f.seek(f.get_64())  # explicit dir offset; absolute for standalone PCK
	else:
		for i in 16:
			f.get_32()  # reserved

	if pack_flags & PACK_DIR_ENCRYPTED:
		_log_warning("[PCK] %s: directory encrypted -- can't enumerate" % pck_path)
		f.close()
		return result

	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			_log_warning("[PCK] %s: suspicious path_len=%d at entry %d -- abort" \
					% [pck_path, path_len, i])
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		f.get_64()        # offset
		f.get_64()        # size
		f.get_buffer(16)  # md5
		f.get_32()        # per-file flags (V2 and V3)
		if not path.is_empty():
			result.append(path)

	f.close()
	return result

# Build the framework pack: enumerate res://Scripts/*.gd, detokenize each via
# _read_vanilla_source, parse + generate wrappers, zip them, mount the zip.
#
# The zip mounts at res://modloader_hooks/ and wrappers load from there. NOT
# from user:// -- Godot 4.6's extends-chain resolution for class_name parents
# breaks for scripts loaded from user://, which shows up as broken super()
# dispatch on class_name-wrapped scripts.
func _generate_hook_pack() -> String:
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
		# Self-referencing .remap to override any stale redirect from the
		# mod archive (mods usually ship source-only, but defend anyway).
		var mod_remap_entry := zip_rel + ".remap"
		if zp.start_file(mod_remap_entry) == OK:
			var mod_remap_body := "[remap]\npath=\"%s\"\n" % cand["res_path"]
			zp.write_file(mod_remap_body.to_utf8_buffer())
			zp.close_file()
		# Empty .gdc shadow.
		var mod_gdc_entry: String = zip_rel.replace(".gd", ".gdc")
		if zp.start_file(mod_gdc_entry) == OK:
			zp.write_file(PackedByteArray())
			zp.close_file()
		mod_script_count += 1
		mod_hook_count += hookable_count * 4
		mod_packed.append({"res_path": cand["res_path"], "vanilla_filename": vanilla_filename})
		_log_debug("[RTVCodegen] Rewrote mod script %s (ext=%s, %d hooks) [%s]" \
				% [cand["res_path"], vanilla_filename, hookable_count * 4, mod_name])

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
		if ProjectSettings.load_resource_pack(HOOK_PACK_ZIP, true):
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
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload)" \
			% [activated, filenames.size(), preactivated])

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
	for fname: String in filenames:
		var vp := "res://Scripts/" + fname
		var s := load(vp) as GDScript
		if s == null:
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
		_log_info("[RTVCodegen] COMPILE-PROOF %s: %d methods compiled, _rtv_vanilla_* present=%s (e.g. %s)" \
				% [vp, methods.size(), has_vanilla_rename, sample_rename])

	# Autoload instance inspection: for the "Already in use" set, the
	# script's get_script_method_list() shows our renames, BUT the live
	# autoload node might still be holding a pointer to the original
	# bytecode via its get_script() property. If script_match=false for
	# any of these, our rewrite isn't reaching the actual game instance.
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

# Recursively walk the scene tree, collecting nodes whose attached script
# (or any ancestor in its extends chain) has the given class_name. Base
# chain walk is needed because mods that override vanilla via
# take_over_path typically use extends-by-path (no class_name of their
# own), so their instances report get_global_name() == "". Matching via
# base chain catches IXP's Controller which extends our class_name
# Controller rewrite.
func _rtv_collect_nodes_by_class(node: Node, cls_name: String, out: Array) -> void:
	var scr := node.get_script() as GDScript
	if scr != null:
		var matched := false
		var s: GDScript = scr
		var depth := 0
		while s != null and depth < 8:
			if str(s.get_global_name()) == cls_name:
				matched = true
				break
			s = s.get_base_script() as GDScript
			depth += 1
		if matched:
			out.append(node)
	for child in node.get_children():
		_rtv_collect_nodes_by_class(child, cls_name, out)

# Archive scanner

func scan_and_register_archive_claims(archive_path: String, mod_name: String,
		archive_file: String, load_index: int) -> void:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		_log_warning("  Could not scan archive: " + archive_file)
		return

	var files := zr.get_files()

	# Archives repacked on Windows via ZipFile.CreateFromDirectory() write backslash
	# separators. Godot mounts the pack but can't resolve those paths.
	var backslash_count := 0
	var example_bad := ""
	for f: String in files:
		if "\\" in f:
			backslash_count += 1
			if example_bad == "":
				example_bad = f
	if backslash_count > 0:
		_log_critical("  BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths.")
		_log_critical("    Re-pack with 7-Zip. Example bad entry: '" + example_bad + "'")

	var tracked_count := 0
	var path_set: Dictionary = {}
	var gd_analysis: Dictionary = {
		"take_over_literal_paths": [],
		"extends_paths":           [],
		"uses_dynamic_override":   false,
		"lifecycle_no_super":      [],
		"calls_update_tooltip":    false,
		"class_names":             [],
		"extends_class_names":     [],
		"override_methods":        {},   # extends_path -> Array[method_name]
		"preload_paths":           [],
		"calls_base":              false, # uses base() instead of super() -- Godot 3 or removed method
		"total_gd_files":          0,
	}

	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
			var gd_bytes := zr.read_file(f)
			if gd_bytes.size() > 0:
				var gd_text := gd_bytes.get_string_from_utf8()
				if _developer_mode:
					_scan_gd_source(gd_text, gd_analysis)
				if _class_name_to_path.size() > 0:
					_check_class_name_safety(gd_text, f, mod_name)

		var res_path := _normalize_to_res_path(f)
		if res_path == "" and f.ends_with(".remap"):
			res_path = _normalize_to_res_path(f.trim_suffix(".remap"))
		if res_path == "":
			continue

		path_set[res_path] = true
		tracked_count += 1
		_register_claim(res_path, mod_name, archive_file, load_index)

		var bare_name := res_path.get_file().get_basename().to_lower()
		var is_db_file := bare_name == "database" and res_path.get_extension().to_lower() == "gd"

		if is_db_file:
			if _database_replaced_by == "":
				_database_replaced_by = mod_name
				_log_info("  DATABASE OVERRIDE: " + mod_name + " replaces Database.gd")
			else:
				_log_warning("  DATABASE COPY: " + mod_name + " bundles a private Database.gd at " + res_path)
				_log_warning("    Hardcoded preload() paths may break if companion mods aren't present.")

	zr.close()
	_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set

	_log_info("  " + str(tracked_count) + " resource path(s)")

	if gd_analysis["total_gd_files"] > 0:
		var override_count: int = (gd_analysis["take_over_literal_paths"] as Array).size() \
				+ (gd_analysis["extends_paths"] as Array).size()
		var dynamic_tag := " [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""
		_log_info("  " + str(gd_analysis["total_gd_files"]) + " .gd file(s), "
				+ str(override_count) + " override target(s)" + dynamic_tag)

func _normalize_to_res_path(zip_path: String) -> String:
	var path := zip_path.replace("\\", "/")
	if path.begins_with("res://"):   return path
	if path.begins_with("/"):        return "res:/" + path
	if path.begins_with(".") or path == "mod.txt": return ""
	if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
		return "res://" + path
	return ""

# GDScript source analysis

func _scan_gd_source(text: String, analysis: Dictionary) -> void:
	for m in _re_take_over.search_all(text):
		var path := m.get_string(1)
		if path not in (analysis["take_over_literal_paths"] as Array):
			(analysis["take_over_literal_paths"] as Array).append(path)

	var m_ext := _re_extends.search(text)
	if m_ext:
		var path := m_ext.get_string(1)
		if path not in (analysis["extends_paths"] as Array):
			(analysis["extends_paths"] as Array).append(path)

	# Detect extends via class_name (e.g. "extends Weapon") -- breaks override chains.
	var m_ext_cn := _re_extends_classname.search(text)
	if m_ext_cn:
		var cn := m_ext_cn.get_string(1)
		if cn not in (analysis["extends_class_names"] as Array):
			(analysis["extends_class_names"] as Array).append(cn)

	# Detect class_name declarations -- Godot bug #83542: can only be overridden once.
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if cn not in (analysis["class_names"] as Array):
			(analysis["class_names"] as Array).append(cn)

	if not analysis["uses_dynamic_override"]:
		analysis["uses_dynamic_override"] = "get_base_script()" in text \
				or "take_over_path(parentScript" in text

	# UpdateTooltip() is inventory-UI only. World-item tooltips are written directly
	# by HUD._physics_process from gameData.tooltip -- this override has no effect there.
	if not analysis["calls_update_tooltip"]:
		analysis["calls_update_tooltip"] = "UpdateTooltip" in text

	# Detect base() calls -- Godot 3 pattern or removed parent method.
	if not analysis["calls_base"]:
		analysis["calls_base"] = "base(" in text

	# preload() paths -- used for stale-cache detection.
	for m_pl in _re_preload.search_all(text):
		var pl_path := m_pl.get_string(1)
		if pl_path not in (analysis["preload_paths"] as Array):
			(analysis["preload_paths"] as Array).append(pl_path)

	# Method declarations -- needed for mod collision detection.
	var func_matches := _re_func.search_all(text)

	# Determine the extends target for this file (if any).
	var ext_target := ""
	if m_ext:
		ext_target = m_ext.get_string(1)

	for i in func_matches.size():
		var func_name := func_matches[i].get_string(1)

		# Track method names per extends target for collision detection.
		if ext_target != "":
			if not (analysis["override_methods"] as Dictionary).has(ext_target):
				(analysis["override_methods"] as Dictionary)[ext_target] = []
			var method_list: Array = (analysis["override_methods"] as Dictionary)[ext_target]
			if func_name not in method_list:
				method_list.append(func_name)

		# Warn if lifecycle methods lack super() in scripts that extend game scripts.
		if ext_target == "":
			continue
		const _LIFECYCLE := ["_ready", "_process", "_physics_process",
				"_input", "_unhandled_input", "_unhandled_key_input"]
		if func_name not in _LIFECYCLE:
			continue
		var body_start := func_matches[i].get_end()
		var body_end := text.length() if i + 1 >= func_matches.size() \
				else func_matches[i + 1].get_start()
		var body := text.substr(body_start, body_end - body_start)
		if "super(" not in body and "super." not in body:
			if func_name not in (analysis["lifecycle_no_super"] as Array):
				(analysis["lifecycle_no_super"] as Array).append(func_name)

func _check_class_name_safety(text: String, file_path: String, mod_name: String) -> void:
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if _class_name_to_path.has(cn):
			var res_path := _normalize_to_res_path(file_path)
			var game_path: String = _class_name_to_path[cn]
			if res_path != game_path:
				_log_critical("  CONFLICT: %s re-declares class_name %s (game has it at %s)" % [file_path, cn, game_path])
	for m_to in _re_take_over.search_all(text):
		var to_path := m_to.get_string(1)
		for cn: String in _class_name_to_path:
			if _class_name_to_path[cn] == to_path:
				_log_critical("  DANGER: %s calls take_over_path on class_name script %s (%s) -- this will crash" % [file_path, to_path, cn])
				break

# Override diagnostics (developer mode)

# Log which mods use overrideScript() -- overrides apply after scene reload.
func _log_override_timing_warnings() -> void:
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]:
			continue
		var targets: Array = analysis["extends_paths"]
		if targets.is_empty():
			continue
		var target_list := ", ".join(targets.map(func(p): return (p as String).get_file()))
		_log_debug(mod_name + " uses overrideScript() on: " + target_list
				+ " -- applies after scene reload")

# Two-pass helpers

func _build_autoload_sections() -> Dictionary:
	# Wipe previous early-autoload extractions so stale scripts don't linger.
	_clean_early_autoload_dir()
	var prepend: Array[Dictionary] = []
	var append: Array[Dictionary] = []
	for entry in _pending_autoloads:
		if entry.get("is_early", false):
			var path: String = entry["path"]
			var disk_path := _ensure_early_autoload_on_disk(path, entry.get("mod_name", ""))
			prepend.append({ "name": entry["name"], "path": disk_path })
		else:
			append.append({ "name": entry["name"], "path": entry["path"] })
	return { "prepend": prepend, "append": append }

const EARLY_AUTOLOAD_DIR := "user://modloader_early"

func _clean_early_autoload_dir() -> void:
	var dir_path := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# Simple recursive wipe -- this directory is entirely modloader-managed.
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()

# Extract an early autoload .gd script to disk if it only exists inside a
# mounted archive.  Godot opens [autoload_prepend] scripts before file-scope
# code runs, so archive-only scripts must be on disk for the restart.
# Scene autoloads (.tscn) are handled by file-scope mounting -- returned as-is.
func _ensure_early_autoload_on_disk(res_path: String, mod_name: String) -> String:
	var global := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(global):
		return res_path

	# Only .gd scripts need extraction -- scenes resolve via file-scope mount.
	var script := load(res_path) as GDScript
	if script == null or not script.has_source_code():
		return res_path

	var rel := res_path.trim_prefix("res://")
	var disk_dir := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	var target := disk_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write early autoload to disk: " + target + " [" + mod_name + "]")
		return res_path
	f.store_string(script.source_code)
	f.close()

	# Return as user:// path so Godot finds it without archive mounting.
	var user_path := EARLY_AUTOLOAD_DIR.path_join(rel)
	_log_info("  Extracted early autoload to disk: " + user_path + " [" + mod_name + "]")
	return user_path

func _collect_enabled_archive_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)
	for c in candidates:
		if c["ext"] == "zip":
			continue
		if c["ext"] == "folder":
			# Folder mods are zipped to a temp cache during load_all_mods().
			# Store the temp zip path -- the folder itself can't be mounted.
			var folder_name: String = c["full_path"].get_file()
			var tmp_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
					folder_name + "_dev.zip")
			if FileAccess.file_exists(tmp_zip):
				paths.append(tmp_zip)
			else:
				_log_warning("Folder mod '%s' has no cached zip -- skipping from pass state"
						% c["mod_name"])
			continue
		paths.append(c["full_path"])
	return paths

# Reads override.cfg and returns lines for sections OTHER than [autoload] and
# [autoload_prepend]. Used to preserve user/game settings when rewriting.
static func _read_preserved_cfg_sections(cfg_path: String) -> String:
	if not FileAccess.file_exists(cfg_path):
		return ""
	var f := FileAccess.open(cfg_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	var result := PackedStringArray()
	var in_autoload_section := false
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("["):
			var section := stripped.to_lower()
			in_autoload_section = section == "[autoload]" or section == "[autoload_prepend]"
			if not in_autoload_section:
				result.append(line)
			continue
		if not in_autoload_section and stripped != "":
			result.append(line)
	var preserved := "\n".join(result).strip_edges()
	if preserved.is_empty():
		return ""
	return "\n" + preserved + "\n"

# Uses FileAccess instead of ConfigFile (which erases null keys).
# ModLoader listed last in [autoload_prepend] = loaded first (reverse insertion).
func _write_override_cfg(prepend_autoloads: Array[Dictionary]) -> Error:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var tmp := path + ".tmp"
	var preserved := _read_preserved_cfg_sections(path)
	var lines := PackedStringArray()
	# Always put ModLoader in [autoload_prepend] (last = loaded first via
	# reverse insertion). Without this, when no mods use the "!" prefix,
	# ModLoader falls into plain [autoload] and some game autoloads
	# (Database, GameData, Loader, Simulation) load before our class-level
	# static init runs -- pinning their .gdc bytecode before our hook pack
	# can preempt them.
	lines.append("[autoload_prepend]")
	for entry in prepend_autoloads:
		lines.append('%s="*%s"' % [entry["name"], entry["path"]])
	lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
	lines.append("")
	lines.append("[autoload]")
	lines.append("")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string("\n".join(lines) + "\n" + preserved)
	f.close()
	# Windows DirAccess.rename() won't overwrite -- remove target first.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var dir := DirAccess.open(exe_dir)
	if dir == null:
		DirAccess.remove_absolute(tmp)
		return ERR_CANT_OPEN
	var err := dir.rename(tmp.get_file(), path.get_file())
	if err != OK:
		DirAccess.remove_absolute(tmp)
	return err

func _persist_hook_pack_state() -> void:
	# Write hook_pack_path to pass_state so _mount_previous_session() can
	# mount it at static init in the next session. Piggybacks on the
	# existing pass_state ConfigFile -- doesn't overwrite other keys.
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)  # OK if missing; we populate below
	cfg.set_value("state", "hook_pack_path", HOOK_PACK_ZIP)
	# Store exe mtime alongside so _mount_previous_session's existing
	# exe-mtime check also invalidates the hook pack on game updates.
	cfg.set_value("state", "hook_pack_exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	if cfg.get_value("state", "modloader_version", "") == "":
		cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	if cfg.save(PASS_STATE_PATH) == OK:
		_log_info("[RTVCodegen] Persisted hook pack path for next-session static-init mount")

func _write_pass_state(archive_paths: PackedStringArray, state_hash: String = "") -> Error:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	var count: int = cfg.get_value("state", "restart_count", 0)
	cfg.set_value("state", "restart_count", count + 1)
	cfg.set_value("state", "mods_hash", state_hash)
	cfg.set_value("state", "archive_paths", archive_paths)
	cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	cfg.set_value("state", "timestamp", Time.get_unix_time_from_system())
	# Persist script overrides so Pass 2 can apply them without re-parsing mods.
	var override_data: Array = []
	for entry in _pending_script_overrides:
		override_data.append(entry.duplicate())
	cfg.set_value("state", "script_overrides", override_data)
	var err := cfg.save(PASS_STATE_PATH)
	if err != OK:
		_log_critical("Failed to save pass state (error %d)" % err)
	return err

func _compute_state_hash(archive_paths: PackedStringArray, prepend_autoloads: Array[Dictionary]) -> String:
	if archive_paths.is_empty() and prepend_autoloads.is_empty():
		return ""
	var parts := PackedStringArray()
	var sorted_paths := Array(archive_paths)
	sorted_paths.sort()
	for p in sorted_paths:
		# Include mtime so replacing a file with the same name triggers a restart.
		parts.append("a:%s@%d" % [p, FileAccess.get_modified_time(p)])
	for entry in prepend_autoloads:
		parts.append("p:%s=%s" % [entry["name"], entry["path"]])
	for entry in _ui_mod_entries:
		if entry["enabled"] and entry.get("cfg") != null:
			var ver: String = (entry["cfg"] as ConfigFile).get_value("mod", "version", "")
			if not ver.is_empty():
				parts.append("v:%s=%s" % [entry["mod_id"], ver])
	for entry in _pending_script_overrides:
		parts.append("so:%s=%s" % [entry["vanilla_path"], entry["mod_script_path"]])
	parts.append("ml:" + MODLOADER_VERSION)
	return "\n".join(parts).md5_text()

func _write_heartbeat() -> void:
	var f := FileAccess.open(HEARTBEAT_PATH, FileAccess.WRITE)
	if f:
		f.store_string("started:%d" % Time.get_unix_time_from_system())
		f.close()

func _delete_heartbeat() -> void:
	if FileAccess.file_exists(HEARTBEAT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(HEARTBEAT_PATH))

func _check_crash_recovery() -> void:
	if not FileAccess.file_exists(HEARTBEAT_PATH):
		return
	_log_warning("Heartbeat detected -- previous launch may have crashed")
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		var count: int = cfg.get_value("state", "restart_count", 0)
		if count >= MAX_RESTART_COUNT:
			_log_critical("Restart loop (%d crashes) -- resetting to clean state" % count)
			_restore_clean_override_cfg()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_delete_heartbeat()
			return
	_delete_heartbeat()

func _check_safe_mode() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var safe_path := exe_dir.path_join(SAFE_MODE_FILE)
	if not FileAccess.file_exists(safe_path):
		return
	_log_warning("Safe mode file detected -- resetting to clean state")
	_restore_clean_override_cfg()
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
	_delete_heartbeat()
	DirAccess.remove_absolute(safe_path)

func _clean_stale_cache() -> void:
	# Remove cached zips whose source .vmz / folder no longer exists in the mods dir.
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname.get_extension().to_lower() != "zip":
			continue
		var base := fname.get_basename()
		if base.ends_with("_dev"):
			# Folder mod cache -- check if the source folder still exists.
			var folder_name := base.substr(0, base.length() - 4)
			if DirAccess.dir_exists_absolute(_mods_dir.path_join(folder_name)):
				continue
		else:
			# VMZ cache -- check if the source .vmz still exists.
			var vmz_name := base + ".vmz"
			if FileAccess.file_exists(_mods_dir.path_join(vmz_name)):
				continue
		DirAccess.remove_absolute(cache_dir.path_join(fname))
		_log_debug("Removed stale cache: " + fname)
	dir.list_dir_end()

func _restore_clean_override_cfg() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var preserved := _read_preserved_cfg_sections(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write override.cfg -- game dir may be read-only: " + exe_dir)
		return
	f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
	f.close()

func _clear_restart_counter() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)

# Conflict summary

func _print_conflict_summary() -> void:
	_log_info("")
	_log_info("============================================")
	_log_info("=== ModLoader Compatibility Summary      ===")
	_log_info("============================================")
	_log_info("Mods loaded:  " + str(_loaded_mod_ids.size()))

	var conflicted_paths: Array[String] = []
	for res_path: String in _override_registry:
		var claims: Array = _override_registry[res_path]
		if claims.size() > 1:
			conflicted_paths.append(res_path)

	_log_info("Conflicting resource paths: " + str(conflicted_paths.size()))

	if conflicted_paths.is_empty():
		_log_info("No resource path conflicts -- all mods appear compatible.")
	else:
		_log_info("")
		_log_info("--- Conflicted Paths (last loader wins) ---")
		for res_path in conflicted_paths:
			var claims: Array = _override_registry[res_path]
			var winner: Dictionary = claims[claims.size() - 1]
			_log_warning("CONFLICT: " + res_path)
			for claim in claims:
				var marker := " <-- wins" if claim == winner else ""
				_log_info("    [" + str(claim["load_index"] + 1) + "] "
						+ claim["mod_name"] + " via " + claim["archive"] + marker)

	if not _hook_swap_map.is_empty():
		_log_info("")
		_log_info("--- Framework Overrides Active ---")
		_log_info("  %d framework(s) take_over_path'd" % _hook_swap_map.size())
		for res_path: String in _hook_swap_map:
			_log_info("  %s" % res_path)

	if not _hooks.is_empty():
		_log_info("")
		_log_info("--- Hook Registrations ---")
		for hook_name: String in _hooks:
			var arr: Array = _hooks[hook_name]
			if arr.size() > 0:
				_log_info("  %s (%d callback(s))" % [hook_name, arr.size()])

	_log_info("============================================")
	_log_info("")

func _write_conflict_report() -> void:
	var f := FileAccess.open(CONFLICT_REPORT_PATH, FileAccess.WRITE)
	if f == null:
		_log_warning("Could not write report to: " + CONFLICT_REPORT_PATH)
		return
	for line in _report_lines:
		f.store_line(line)
	f.close()
	_log_info("Conflict report written to: " + CONFLICT_REPORT_PATH)

# Autoload instantiation

func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
	var resource: Resource = load(res_path)
	if resource == null:
		_log_critical("Autoload failed: %s -> %s [%s]" % [autoload_name, res_path, mod_name])
		if _developer_mode:
			_log_debug("  FileAccess=%s  ResourceLoader=%s"
					% [str(FileAccess.file_exists(res_path)), str(ResourceLoader.exists(res_path))])
		return

	if get_tree().root.has_node(autoload_name):
		_log_warning("Autoload name '" + autoload_name + "' conflicts with existing node at /root/"
				+ autoload_name + " -- Godot will rename it. [" + mod_name + "]")

	if resource is PackedScene:
		var instance: Node = (resource as PackedScene).instantiate()
		if instance == null:
			_log_critical("PackedScene.instantiate() returned null: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			return
		instance.name = autoload_name
		get_tree().root.add_child(instance)
		_log_info("Autoload instantiated (scene): " + autoload_name + " [" + mod_name + "]")
		return

	if resource is GDScript:
		var gdscript := resource as GDScript
		if not gdscript.can_instantiate():
			_log_critical("Autoload script failed to compile: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			_log_critical("  can_instantiate() returned false. Check the Godot log above for parse errors.")
			return
		var inst: Variant = gdscript.new()
		if inst == null:
			_log_warning("Autoload script returned null: " + autoload_name)
			return
		if inst is Node:
			(inst as Node).name = autoload_name
			get_tree().root.add_child(inst as Node)
			_log_info("Autoload instantiated (script): " + autoload_name + " [" + mod_name + "]")
			return
		_log_warning("Autoload is not a Node -- not added to tree: " + autoload_name
				+ " [" + mod_name + "]")
		return

	_log_warning("Autoload is not a PackedScene or GDScript: " + autoload_name
			+ " -> " + res_path + " [" + mod_name + "]")

# Mount helper

func _try_mount_pack(path: String) -> bool:
	if ProjectSettings.load_resource_pack(path):
		_resolve_remaps(path)
		return true
	if path.get_extension().to_lower() != "vmz":
		return false
	var zip_path := _static_vmz_to_zip(path)
	if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
		_resolve_remaps(zip_path)
		return true
	return false

# Resolve .remap files in a mounted archive so preload()/load() work with
# the original .tscn/.tres paths (load_resource_pack doesn't follow remaps).
func _resolve_remaps(archive_path: String) -> void:
	var remap_count := _static_resolve_remaps(archive_path)
	if remap_count > 0:
		_log_debug("  Resolved %d .remap file(s)" % remap_count)

static func _static_resolve_remaps(archive_path: String) -> int:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		return 0

	var count := 0
	for f: String in zr.get_files():
		if not f.ends_with(".remap"):
			continue
		var remap_bytes := zr.read_file(f)
		if remap_bytes.is_empty():
			continue
		var cfg := ConfigFile.new()
		if cfg.parse(remap_bytes.get_string_from_utf8()) != OK:
			continue
		var target: String = cfg.get_value("remap", "path", "")
		if target.is_empty():
			continue
		var original_path := f.trim_suffix(".remap")
		if not original_path.begins_with("res://"):
			original_path = "res://" + original_path
		var res: Resource = load(target)
		if res != null:
			res.take_over_path(original_path)
			count += 1
	zr.close()
	return count

# mod.txt parser

func read_mod_config(path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return null
	if not zr.file_exists("mod.txt"):
		# Nested mod.txt (e.g. "SubFolder/mod.txt") means bad packaging.
		for f: String in zr.get_files():
			if f.get_file() == "mod.txt":
				_last_mod_txt_status = "nested:" + f
				zr.close()
				return null
		zr.close()
		return null
	var raw := zr.read_file("mod.txt")
	zr.close()
	if raw.size() == 0:
		_last_mod_txt_status = "parse_error"
		return null
	var text := raw.get_string_from_utf8()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func read_mod_config_folder(folder_path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	var mod_txt_path := folder_path.path_join("mod.txt")
	if not FileAccess.file_exists(mod_txt_path):
		return null
	var f := FileAccess.open(mod_txt_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func _parse_mod_txt(text: String) -> ConfigFile:
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return null
	return cfg

# Folder → temp zip (developer mode)

func zip_folder_to_temp(folder_path: String) -> String:
	var folder_name := folder_path.get_file()
	var tmp_zip_path := ProjectSettings.globalize_path(TMP_DIR).path_join(
			folder_name + "_dev.zip")
	var zp := ZIPPacker.new()
	if zp.open(tmp_zip_path) != OK:
		_log_critical("Failed to create temp zip: " + tmp_zip_path)
		return ""
	# Zip contents without a top-level wrapper -- the folder's internal structure
	# already mirrors the res:// paths the mod expects.
	_zip_folder_recursive(zp, folder_path, "")
	zp.close()
	return tmp_zip_path

func _zip_folder_recursive(zp: ZIPPacker, disk_path: String, archive_prefix: String) -> void:
	var dir := DirAccess.open(disk_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := disk_path.path_join(entry)
		var arc_path := entry if archive_prefix == "" else archive_prefix.path_join(entry)
		if dir.current_is_dir():
			_zip_folder_recursive(zp, full, arc_path)
		else:
			var data := FileAccess.get_file_as_bytes(full)
			zp.start_file(arc_path)
			zp.write_file(data)
			zp.close_file()
	dir.list_dir_end()

# Update fetch helpers

# Returns -1/0/1 for version comparison (a < b, equal, a > b).
func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var pa := a.lstrip("vV").split(".")
	var pb := b.lstrip("vV").split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var sa := pa[i] if i < pa.size() else "0"
		var sb := pb[i] if i < pb.size() else "0"
		var va := int(sa) if sa.is_valid_int() else 0
		var vb := int(sb) if sb.is_valid_int() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0

func fetch_latest_modworkshop_versions(ids: Array[int]) -> Dictionary:
	var latest_versions := {}
	for chunk_ids in _chunk_int_array(ids, MODWORKSHOP_BATCH_SIZE):
		var req := HTTPRequest.new()
		req.timeout = API_CHECK_TIMEOUT
		add_child(req)
		var err := req.request(MODWORKSHOP_VERSIONS_URL,
			PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
			HTTPClient.METHOD_GET, JSON.stringify({"mod_ids": chunk_ids}))
		if err != OK:
			req.queue_free()
			continue

		var res: Array = await req.request_completed
		req.queue_free()
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
			continue
		var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
		if parsed is Dictionary:
			latest_versions.merge(parsed, true)
	return latest_versions

func download_and_replace_mod(target_path: String, modworkshop_id: int) -> bool:
	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id))
	if err != OK:
		req.queue_free()
		return false
	# request_completed → [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return false
	var response_body: PackedByteArray = res[3]
	if response_body.is_empty():
		return false

	var temp_path   := target_path + ".download"
	var backup_path := target_path + ".bak"
	if FileAccess.file_exists(temp_path):   DirAccess.remove_absolute(temp_path)
	if FileAccess.file_exists(backup_path): DirAccess.remove_absolute(backup_path)

	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		return false
	out.store_buffer(response_body)
	out.close()

	if read_mod_config(temp_path) == null:
		DirAccess.remove_absolute(temp_path)
		return false

	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		return false

	if FileAccess.file_exists(target_path):
		if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
			DirAccess.remove_absolute(temp_path)
			return false

	if dir_access.rename(temp_path.get_file(), target_path.get_file()) != OK:
		if FileAccess.file_exists(backup_path):
			dir_access.rename(backup_path.get_file(), target_path.get_file())
		DirAccess.remove_absolute(temp_path)
		return false

	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	return true

func _chunk_int_array(arr: Array[int], chunk_size: int) -> Array:
	var result: Array = []
	for i in range(0, arr.size(), chunk_size):
		result.append(arr.slice(i, i + chunk_size))
	return result
