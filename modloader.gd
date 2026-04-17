## Metro Mod Loader -- community mod loader for Road to Vostok (Godot 4.6+).
## Loads .vmz/.pck archives from <game>/mods/ via a pre-game config window.
## Two-pass architecture: mounts archives at file-scope, optionally restarts to
## prepend mod autoloads before the game's own autoloads via [autoload_prepend].
extends Node

const MODLOADER_VERSION := "2.3.0"
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

# Runtime script-swap state.
var _hook_swap_map: Dictionary = {}      # res_path -> framework GDScript
var _original_scripts: Dictionary = {}   # res_path -> vanilla script ref (UID identity)
var _vanilla_id_to_path: Dictionary = {} # script.get_instance_id() -> res_path
var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _node_swap_connected := false
var _swap_count: int = 0
var _rtv_modlib_registered := false      # true if Engine.set_meta("RTVModLib", ...) was us
var _defer_to_tetra_modlib := false      # true if tetra's mod is loaded -- we stand down

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
var _file_scope_mounts: int = _mount_previous_session()

static func _mount_previous_session() -> int:
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")

	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		_write_filescope_log(log_lines)
		return 0
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
		return 0
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
			return 0
	var paths: PackedStringArray = cfg.get_value("state", "archive_paths", PackedStringArray())
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		_write_filescope_log(log_lines)
		return 0

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
			f.store_string("[autoload]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n" + preserved)
			f.close()
		var state_path := ProjectSettings.globalize_path(PASS_STATE_PATH)
		if FileAccess.file_exists(state_path):
			DirAccess.remove_absolute(state_path)
		_write_filescope_log(log_lines)
		return 0

	if any_stale:
		# Source gone but cache works -- invalidate hash so Pass 1 rewrites state.
		cfg.set_value("state", "mods_hash", "")
		cfg.save(PASS_STATE_PATH)

	var count := 0
	for path in paths:
		if ProjectSettings.load_resource_pack(path):
			var remaps := _static_resolve_remaps(path)
			log_lines.append("[FileScope]   MOUNTED: " + path
					+ (" (%d remaps)" % remaps if remaps > 0 else ""))
			count += 1
		elif path.get_extension().to_lower() == "vmz":
			var zip_path := _static_vmz_to_zip(path)
			if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
				var remaps := _static_resolve_remaps(zip_path)
				log_lines.append("[FileScope]   MOUNTED (vmz→zip): " + path
						+ (" (%d remaps)" % remaps if remaps > 0 else ""))
				count += 1
			else:
				log_lines.append("[FileScope]   MOUNT FAILED (vmz): " + path + " zip_path=" + zip_path)
		else:
			log_lines.append("[FileScope]   MOUNT FAILED: " + path)

	# Framework wrappers are NOT mounted at file scope. Each is take_over_path'd
	# individually in _activate_hooked_scripts() after mods register. Mounting
	# would shadow vanilla scripts in the VFS at init_cache time, causing every
	# instantiation to go through the wrapper regardless of whether any mod
	# wanted that framework active.

	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % count)
	_write_filescope_log(log_lines)
	return count

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
	f.store_string("[autoload]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n" + preserved)
	f.close()
	log_lines.append("[FileScope] override.cfg reset to clean [autoload] state")

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
	if "--modloader-restart" in OS.get_cmdline_user_args():
		await _run_pass_2()
	else:
		await _run_pass_1()

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
	if _file_scope_mounts > 0 or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
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
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _file_scope_mounts)
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
	if _file_scope_mounts > 0 or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
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

	if not _try_mount_pack(mount_path):
		_log_critical("Failed to mount: " + file_name + " (path: " + mount_path + ")")
		return

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
# We do NOT pre-set _rtv_ready_done before _ready (RTVModLib does). If vanilla
# _ready has an await (Trader), set_script kills the coroutine on the old
# instance and the post-await code never runs (UIManager stays null, etc).
# Letting super() run vanilla _ready a second time on the new instance gets
# it to completion. The pre-await statements re-run, which is harmless for
# every script we've tested (timer.start / animations.play / @onready
# assignments are all idempotent).
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

# --- GDSC Binary Tokenizer (text -> GDSC) ------------------------------------
# Converts GDScript source text into binary-tokenized GDSC format (inverse of
# the detokenizer above).  Output is ZSTD-compressed and can be written into
# the game's .pck to replace binary scripts before init_cache loads them.

func _tokenize_to_gdsc(source: String, minimal_line_maps := false, target_size := 0) -> PackedByteArray:
	var lex := _gdsc_lex(source)
	if lex.tokens.is_empty():
		return PackedByteArray()
	var body := _gdsc_encode_body(lex, minimal_line_maps)
	var compressed := body.compress(FileAccess.COMPRESSION_ZSTD)
	# Header: magic(4) + version(4) + decompressed_size(4) = 12 bytes
	var result := PackedByteArray()
	result.resize(12)
	result[0] = 0x47; result[1] = 0x44; result[2] = 0x53; result[3] = 0x43  # "GDSC"
	result.encode_u32(4, 101)  # GDSC version
	result.encode_u32(8, body.size())
	result.append_array(compressed)

	# Pad to target_size with a ZSTD skippable frame so decompressor doesn't
	# choke on trailing bytes.  ZSTD recognizes magic 0x184D2A50-5F as
	# skippable frames and ignores them during decompression.
	if target_size > 0 and result.size() < target_size:
		var pad_total: int = target_size - result.size()
		if pad_total >= 8:
			# Skippable frame: magic(4) + frame_size(4) + data(frame_size)
			var frame := PackedByteArray()
			frame.resize(pad_total)
			frame.encode_u32(0, 0x184D2A50)  # skippable frame magic
			frame.encode_u32(4, pad_total - 8)  # data size
			# remaining bytes are already zero-filled
			result.append_array(frame)
		else:
			# Too small for a skippable frame -- fill with zeros and hope
			# ZSTD handles the trailing data (unlikely, but edge case)
			result.resize(target_size)

	return result

func _gdsc_lex(source: String) -> Dictionary:
	# Returns { tokens: [[type, data_idx], ...], identifiers: [...], constants: [...] }
	var tokens: Array = []
	var identifiers: Array[String] = []
	var ident_map: Dictionary = {}   # string -> index
	var constants: Array = []
	var const_map: Dictionary = {}   # repr -> index
	var line_map: Dictionary = {}    # token_idx -> line_num
	var col_map: Dictionary = {}     # token_idx -> column

	# Build reverse lookup: keyword/operator text -> token type (longest first)
	var text_to_token: Dictionary = {}
	for tk_id: int in _TOKEN_TEXT:
		text_to_token[_TOKEN_TEXT[tk_id]] = tk_id
	# Sort operator keys longest-first for greedy matching
	var op_keys: Array[String] = []
	for k: String in text_to_token:
		# Only include non-alphanumeric operators for symbol matching
		if k.length() > 0 and not k[0].is_valid_identifier():
			op_keys.append(k)
	op_keys.sort_custom(func(a, b): return a.length() > b.length())

	# Keyword set (alphanumeric tokens from _TOKEN_TEXT)
	var keywords: Dictionary = {}
	for tk_id: int in _TOKEN_TEXT:
		var txt: String = _TOKEN_TEXT[tk_id]
		if txt.length() > 0 and (txt[0].is_valid_identifier() or txt[0] == "_"):
			keywords[txt] = tk_id

	var lines := source.split("\n")
	var indent_stack: Array[int] = [0]
	var line_num := 1
	var tok_idx := 0

	for line_i in lines.size():
		var line: String = lines[line_i]
		var stripped := line.strip_edges(true, false)  # strip left only for indent calc

		# Skip empty lines and comment-only lines.
		# Don't emit tokens or line_map entries -- the line_map on the NEXT
		# real token will jump past these lines, and the detokenizer fills
		# blank lines automatically from the line number gap.
		var content := line.strip_edges()
		if content.is_empty() or content.begins_with("#"):
			line_num += 1
			continue

		# Calculate indentation in col_map units (tab = 4, space = 1).
		# The detokenizer converts col_map values back via: tabs = col / 4
		var indent := 0
		for c in line:
			if c == "\t":
				indent += 4  # tab = 4 col_map units (detokenizer: col/4 = tabs)
			elif c == " ":
				indent += 1
			else:
				break
		var col_value: int = indent

		# Emit INDENT/DEDENT tokens
		var cur_indent: int = indent_stack[indent_stack.size() - 1]
		if indent > cur_indent:
			indent_stack.append(indent)
			tokens.append([89, 0])  # INDENT
			tok_idx += 1
		else:
			while indent_stack.size() > 1 and indent < indent_stack[indent_stack.size() - 1]:
				indent_stack.pop_back()
				tokens.append([90, 0])  # DEDENT
				tok_idx += 1

		# Record line number for first real token on this line
		line_map[tok_idx] = line_num
		col_map[tok_idx] = col_value

		# Lex the line content (skip leading whitespace)
		var pos := 0
		while pos < line.length() and (line[pos] == "\t" or line[pos] == " "):
			pos += 1
		var first_on_line := true

		while pos < line.length():
			var ch: String = line[pos]

			# Skip spaces between tokens
			if ch == " " or ch == "\t":
				pos += 1
				continue

			# Comment -- stop processing line
			if ch == "#":
				break

			# Record column for first visible token (already done above for line start)
			if not first_on_line:
				pass  # col_map only tracks first token per line
			first_on_line = false

			# String literals: ", ', """, '''
			if ch == '"' or ch == "'":
				var result := _gdsc_lex_string(line, pos)
				var ci: int
				var cr: String = var_to_str(result["value"])
				if const_map.has(cr):
					ci = const_map[cr]
				else:
					ci = constants.size()
					constants.append(result["value"])
					const_map[cr] = ci
				tokens.append([3, ci])  # LITERAL
				tok_idx += 1
				pos = result["end"]
				continue

			# StringName &"..." or NodePath ^"..."
			if (ch == "&" or ch == "^") and pos + 1 < line.length() and line[pos + 1] == '"':
				var is_sname := (ch == "&")
				var result := _gdsc_lex_string(line, pos + 1)
				var val = StringName(result["value"]) if is_sname else NodePath(result["value"])
				var ci: int
				var cr: String = var_to_str(val)
				if const_map.has(cr):
					ci = const_map[cr]
				else:
					ci = constants.size()
					constants.append(val)
					const_map[cr] = ci
				tokens.append([3, ci])
				tok_idx += 1
				pos = result["end"]
				continue

			# Annotation @name
			if ch == "@":
				pos += 1
				var start := pos
				while pos < line.length() and (line[pos].is_valid_identifier() or line[pos] == "_" or line[pos].is_valid_int()):
					pos += 1
				var aname := line.substr(start, pos - start)
				var ai: int
				if ident_map.has(aname):
					ai = ident_map[aname]
				else:
					ai = identifiers.size()
					identifiers.append(aname)
					ident_map[aname] = ai
				tokens.append([1, ai])  # ANNOTATION
				tok_idx += 1
				continue

			# Numbers
			if ch.is_valid_int() or (ch == "." and pos + 1 < line.length() and line[pos + 1].is_valid_int()):
				var result := _gdsc_lex_number(line, pos)
				var ci: int
				var cr: String = var_to_str(result["value"])
				if const_map.has(cr):
					ci = const_map[cr]
				else:
					ci = constants.size()
					constants.append(result["value"])
					const_map[cr] = ci
				tokens.append([3, ci])
				tok_idx += 1
				pos = result["end"]
				continue

			# Identifiers and keywords
			if ch.is_valid_identifier() or ch == "_":
				var start := pos
				while pos < line.length() and (line[pos].is_valid_identifier() or line[pos] == "_" or line[pos].is_valid_int()):
					pos += 1
				var word := line.substr(start, pos - start)

				# Check for true/false/null (encoded as LITERAL, not keyword)
				if word == "true":
					var ci: int
					var cr := "true"
					if const_map.has(cr):
						ci = const_map[cr]
					else:
						ci = constants.size()
						constants.append(true)
						const_map[cr] = ci
					tokens.append([3, ci])
					tok_idx += 1
					continue
				if word == "false":
					var ci: int
					var cr := "false"
					if const_map.has(cr):
						ci = const_map[cr]
					else:
						ci = constants.size()
						constants.append(false)
						const_map[cr] = ci
					tokens.append([3, ci])
					tok_idx += 1
					continue
				if word == "null":
					var ci: int
					var cr := "null"
					if const_map.has(cr):
						ci = const_map[cr]
					else:
						ci = constants.size()
						constants.append(null)
						const_map[cr] = ci
					tokens.append([3, ci])
					tok_idx += 1
					continue

				# Keyword?
				if keywords.has(word):
					tokens.append([keywords[word], 0])
					tok_idx += 1
					continue

				# Regular identifier
				var ii: int
				if ident_map.has(word):
					ii = ident_map[word]
				else:
					ii = identifiers.size()
					identifiers.append(word)
					ident_map[word] = ii
				tokens.append([2, ii])
				tok_idx += 1
				continue

			# Operators/punctuation (longest match first)
			var matched := false
			for op in op_keys:
				if pos + op.length() <= line.length() and line.substr(pos, op.length()) == op:
					tokens.append([text_to_token[op], 0])
					tok_idx += 1
					pos += op.length()
					matched = true
					break
			if matched:
				continue

			# Unknown character -- skip
			pos += 1

		# End of line -- emit NEWLINE
		tokens.append([88, 0])  # NEWLINE
		tok_idx += 1
		line_num += 1

	# Emit remaining DEDENTs
	while indent_stack.size() > 1:
		indent_stack.pop_back()
		tokens.append([90, 0])
		tok_idx += 1

	# EOF
	tokens.append([99, 0])
	tok_idx += 1

	return {
		"tokens": tokens,
		"identifiers": identifiers,
		"constants": constants,
		"line_map": line_map,
		"col_map": col_map,
	}

func _gdsc_lex_string(line: String, pos: int) -> Dictionary:
	# Parse a string literal starting at pos (which points to the opening quote).
	var quote: String = line[pos]
	var triple := false
	if pos + 2 < line.length() and line[pos + 1] == quote and line[pos + 2] == quote:
		triple = true
		pos += 3
	else:
		pos += 1
	var s := ""
	while pos < line.length():
		var ch: String = line[pos]
		if ch == "\\" and pos + 1 < line.length():
			var esc: String = line[pos + 1]
			match esc:
				"n": s += "\n"
				"t": s += "\t"
				"r": s += "\r"
				"\\": s += "\\"
				_: s += "\\" + esc  # preserve unknown escapes; also handles \" \'
				# Actually, handle quote escaping properly:
			if esc == quote:
				s = s.substr(0, s.length() - 2) + quote  # replace \' or \" with the quote char
			pos += 2
			continue
		if not triple and ch == quote:
			pos += 1
			break
		if triple and ch == quote and pos + 2 < line.length() \
				and line[pos + 1] == quote and line[pos + 2] == quote:
			pos += 3
			break
		s += ch
		pos += 1
	return { "value": s, "end": pos }

func _gdsc_lex_number(line: String, pos: int) -> Dictionary:
	var start := pos
	var is_float := false
	# Hex
	if pos + 1 < line.length() and line[pos] == "0" and line[pos + 1] == "x":
		pos += 2
		while pos < line.length() and (line[pos].is_valid_hex_number()):
			pos += 1
		return { "value": line.substr(start, pos - start).hex_to_int(), "end": pos }
	# Binary
	if pos + 1 < line.length() and line[pos] == "0" and line[pos + 1] == "b":
		pos += 2
		while pos < line.length() and (line[pos] == "0" or line[pos] == "1" or line[pos] == "_"):
			pos += 1
		return { "value": line.substr(start, pos - start).bin_to_int(), "end": pos }
	# Decimal / float
	while pos < line.length() and (line[pos].is_valid_int() or line[pos] == "_"):
		pos += 1
	if pos < line.length() and line[pos] == "." and (pos + 1 >= line.length() or line[pos + 1] != "."):
		is_float = true
		pos += 1
		while pos < line.length() and (line[pos].is_valid_int() or line[pos] == "_"):
			pos += 1
	if pos < line.length() and (line[pos] == "e" or line[pos] == "E"):
		is_float = true
		pos += 1
		if pos < line.length() and (line[pos] == "+" or line[pos] == "-"):
			pos += 1
		while pos < line.length() and line[pos].is_valid_int():
			pos += 1
	var num_str := line.substr(start, pos - start).replace("_", "")
	if is_float:
		return { "value": num_str.to_float(), "end": pos }
	else:
		return { "value": num_str.to_int(), "end": pos }

func _gdsc_encode_body(lex: Dictionary, minimal_line_maps := false) -> PackedByteArray:
	var tokens: Array = lex.tokens
	var identifiers: Array[String] = lex.identifiers
	var constants: Array = lex.constants
	var line_map: Dictionary = lex.line_map
	var col_map: Dictionary = lex.col_map

	# Line entries: use minimal map (1 entry) to save space when overwriting .pck.
	# Full maps add ~16 bytes per source line -- hundreds of lines of overhead
	# that only affects error stack traces (not runtime behavior).
	var line_entries: Array = []
	if minimal_line_maps:
		line_entries = [0]  # single entry: token 0 → line 1
	else:
		var sorted_tok_indices: Array = []
		for k in line_map:
			sorted_tok_indices.append(k)
		sorted_tok_indices.sort()
		for ti in sorted_tok_indices:
			line_entries.append(ti)

	var buf := PackedByteArray()

	# Metadata (v101: 16 bytes)
	buf.resize(16)
	buf.encode_u32(0, identifiers.size())
	buf.encode_u32(4, constants.size())
	buf.encode_u32(8, line_entries.size())
	buf.encode_u32(12, tokens.size())

	# Identifiers (XOR 0xb6 encoded UTF-32)
	for ident in identifiers:
		var str_len := ident.length()
		var ident_buf := PackedByteArray()
		ident_buf.resize(4 + str_len * 4)
		ident_buf.encode_u32(0, str_len)
		for ci in str_len:
			var cp: int = ident.unicode_at(ci)
			ident_buf[4 + ci * 4] = (cp & 0xFF) ^ 0xb6
			ident_buf[4 + ci * 4 + 1] = ((cp >> 8) & 0xFF) ^ 0xb6
			ident_buf[4 + ci * 4 + 2] = ((cp >> 16) & 0xFF) ^ 0xb6
			ident_buf[4 + ci * 4 + 3] = ((cp >> 24) & 0xFF) ^ 0xb6
		buf.append_array(ident_buf)

	# Constants (Variant-encoded)
	for c in constants:
		buf.append_array(var_to_bytes(c))

	# Line map
	for ti in line_entries:
		var entry := PackedByteArray()
		entry.resize(8)
		entry.encode_u32(0, ti)
		entry.encode_u32(4, line_map.get(ti, 1))
		buf.append_array(entry)

	# Column map (same count as line map)
	for ti in line_entries:
		var entry := PackedByteArray()
		entry.resize(8)
		entry.encode_u32(0, ti)
		entry.encode_u32(4, col_map.get(ti, 0))
		buf.append_array(entry)

	# Token stream
	for tok in tokens:
		var tk_type: int = tok[0]
		var data_idx: int = tok[1]
		if data_idx < (1 << 24):
			# 5-byte format: type in low 7 bits, data in upper bits
			var raw: int = (data_idx << _GDSC_TOKEN_BITS) | tk_type
			var tok_buf := PackedByteArray()
			tok_buf.resize(5)
			tok_buf.encode_u32(0, raw)
			tok_buf[4] = 0
			buf.append_array(tok_buf)
		else:
			# 8-byte format: high bit set
			var tok_buf := PackedByteArray()
			tok_buf.resize(8)
			tok_buf.encode_u32(0, tk_type | _GDSC_TOKEN_BYTE_MASK)
			tok_buf.encode_u32(4, data_idx)
			buf.append_array(tok_buf)

	return buf

func _read_vanilla_source(script_path: String) -> String:
	# If take_over_path already swapped this script to a framework wrapper, the
	# live source will contain our markers. Fall back to the vanilla cache.
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			var live := load(script_path) as GDScript
			var live_is_wrapper := live != null and not live.source_code.is_empty() \
					and ("_rtv_ready_done" in live.source_code \
						or 'Engine.get_meta("RTVModLib"' in live.source_code)
			if live and not live.source_code.is_empty() and not live_is_wrapper:
				if live.source_code != cached:  # game updated
					_save_vanilla_source(script_path, live.source_code)
					return live.source_code
				return cached
			return cached  # live is a framework wrapper or binary-tokenized -- trust cache

	var script := load(script_path) as GDScript
	if script == null:
		return ""

	var source := script.source_code
	if source.is_empty():
		# Script is binary-tokenized (GDSC format) -- detokenize from raw bytes.
		source = _detokenize_script(script_path)
		if source.is_empty():
			return ""

	# Detect a framework wrapper accidentally loaded at the vanilla path --
	# means take_over_path already ran and we have no way back to vanilla.
	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Hooks] Cannot read vanilla source for %s -- framework wrapper is at the vanilla path. Delete %s and restart." \
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
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\", null)\n"
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
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\", null)\n"
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
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\", null)\n"
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
	for script_path: String in script_paths:
		var filename := script_path.get_file()

		if filename in RTV_SKIP_LIST:
			_log_debug("[RTVCodegen] Skipped %s (runtime-sensitive)" % filename)
			continue
		if filename in RTV_RESOURCE_SERIALIZED_SKIP or filename in RTV_RESOURCE_DATA_SKIP:
			continue

		# Warn if a [script_overrides] replacement is also in play -- the
		# framework wrapper's super() will flow into the override, not vanilla.
		if _override_registry.has(script_path) or _applied_script_overrides.has(script_path):
			var sources: PackedStringArray = []
			if _override_registry.has(script_path):
				for claim in _override_registry[script_path]:
					sources.append(claim["mod_name"])
			for entry in _pending_script_overrides:
				if entry["vanilla_path"] == script_path:
					sources.append(entry["mod_name"] + " [script_overrides]")
			if sources.size() > 0:
				_log_warning("[RTVCodegen] %s is framework-wrapped and also overridden by %s -- wrappers will super() into the override" \
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
		if hookable_count == 0:
			continue

		var wrapper := _rtv_generate_override(parsed)
		var out_name := "Framework" + filename
		var zip_internal := "modloader_hooks/" + out_name  # res:// prepended on mount
		if zp.start_file(zip_internal) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % zip_internal)
			continue
		zp.write_file(wrapper.to_utf8_buffer())
		zp.close_file()

		script_count += 1
		hook_count += hookable_count * 4  # pre/post/callback/replace per method
		_log_debug("[RTVCodegen] Packed %s (%d hooks)" % [out_name, hookable_count * 4])

	zp.close()

	# Mount must happen BEFORE mod autoloads run so [rtvmodlib] needs= resolves.
	if script_count > 0:
		if ProjectSettings.load_resource_pack(HOOK_PACK_ZIP):
			_log_info("[RTVCodegen] Generated %d framework wrapper(s), %d hook points -- pack mounted at %s" \
					% [script_count, hook_count, HOOK_PACK_MOUNT_BASE])
		else:
			_log_critical("[RTVCodegen] Failed to mount framework pack at %s -- wrappers won't be loadable" % zip_abs)
	else:
		_log_info("[RTVCodegen] No frameworks produced -- no pack mounted")
	return HOOK_PACK_ZIP

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

# After reload, do any live nodes actually match the override targets?
func _audit_override_instances() -> void:
	var override_targets: Dictionary = {}  # res_path -> mod_name
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		for path in (analysis["take_over_literal_paths"] as Array):
			override_targets[path] = mod_name
		if analysis["uses_dynamic_override"]:
			for path in (analysis["extends_paths"] as Array):
				override_targets[path] = mod_name

	if override_targets.is_empty():
		return

	var live_script_paths: Dictionary = {}
	_collect_live_scripts(get_tree().root, live_script_paths)

	for target_path: String in override_targets:
		var mod_name: String = override_targets[target_path]
		if live_script_paths.has(target_path):
			_log_debug("Override applied: " + target_path.get_file()
					+ " -- " + str(live_script_paths[target_path]) + " node(s) [" + mod_name + "]")
		else:
			_log_debug("Override registered but 0 nodes use " + target_path.get_file()
					+ " in current scene -- likely spawned at runtime [" + mod_name + "]")

func _collect_live_scripts(root_node: Node, out: Dictionary) -> void:
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var script: Script = node.get_script() as Script
		if script:
			var path := script.resource_path
			if path != "":
				out[path] = (out.get(path, 0) as int) + 1
		stack.append_array(node.get_children())

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
	if prepend_autoloads.size() > 0:
		lines.append("[autoload_prepend]")
		for entry in prepend_autoloads:
			lines.append('%s="*%s"' % [entry["name"], entry["path"]])
		lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
		lines.append("")
	lines.append("[autoload]")
	if prepend_autoloads.is_empty():
		lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
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
	f.store_string("[autoload]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n" + preserved)
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
