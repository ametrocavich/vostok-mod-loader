## Shared constants, persistent-file paths and module-scope state. A const that
## references another must come after it (across files: earlier in build.sh FILES).

# x-release-please-start-version
const MODLOADER_VERSION := "3.0.0"
# x-release-please-end

const MODLOADER_RES_PATH := "res://modloader.gd"
const MOD_DIR := "mods"

# Rebuild helpers look tabs up by these exact node names.
const UI_TAB_MODS := "Mods"
const UI_TAB_BROWSE := "Browse"
const UI_TAB_MODPACKS := "Modpacks"

const TMP_DIR := "user://vmz_mount_cache"
const UI_CONFIG_PATH := "user://mod_config.cfg"
# Reset-to-Vanilla value of `[settings] active_profile`; treated as all-off.
const VANILLA_PROFILE := "__vanilla__"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const PASS_STATE_PATH := "user://mod_pass_state.cfg"
const HEARTBEAT_PATH := "user://modloader_heartbeat.txt"
const PASS2_DIRTY_PATH := "user://modloader_pass2_dirty"
const SAFE_MODE_FILE := "modloader_safe_mode"
const DISABLED_FILE := "modloader_disabled"
const DISABLED_ONCE_FILE := "modloader_disabled_once"
# For an external mod manager: Pass 1 loads the active profile without the launcher.
const SKIP_UI_ARG := "--modloader-skip-ui"
# A manager that starts the game through Steam cannot pass an argument without Steam's prompt.
const SKIP_UI_ONCE_FILE := "modloader_skip_ui_once"
# User arg (after "--") that marks the relaunch Pass 1 arms.
const RESTART_ARG := "--modloader-restart"
const MAX_RESTART_COUNT := 2
# Its own file, not a pass-state key: the crashed-Pass-2 wipe deletes pass state.
const CRASH_STREAK_PATH := "user://modloader_crash_streak"
const CRASH_NOTICE_PATH := "user://modloader_crash_notice"
# Godot opens [autoload_prepend] scripts before any archive is mounted.
const EARLY_AUTOLOAD_DIR := "user://modloader_early"

const HOOK_PACK_DIR := "user://modloader_hooks"
# A fresh filename per generation: load_resource_pack dedups by path, and a
# same-path re-mount is a no-op with stale VFS offsets.
const HOOK_PACK_PREFIX := "framework_pack"
const VANILLA_CACHE_DIR := "user://modloader_hooks/vanilla"

const API_CHECK_TIMEOUT := 15.0

const MCM_SOURCE_DIR := "user://MCM"
const MCM_SNAPSHOT_BASE := "user://.profile_snapshots"

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999

# V2 = Godot 4.0-4.5, V3 = 4.6; V4 (4.7+) is never accepted, only named in the message.
const PACK_FORMAT_V2 := 2
const PACK_FORMAT_V3 := 3
const PACK_FORMAT_V4 := 4

# v100 = Godot 4.3-4.4, v101 = 4.5+. The integer alone does not pin a token
# layout, which is why canary C round-trips real output.
const GDSC_VERSION_V100 := 100
const GDSC_VERSION_V101 := 101

# Wrapper overhead or set_script breaks these.
const RTV_SKIP_LIST: Array[String] = [
	"TreeRenderer.gd",     # @tool script -- editor-only, no runtime hooks needed
	"MuzzleFlash.gd",      # 50ms flash effect -- dispatch overhead breaks timing
	"Hit.gd",              # per-shot instantiated -- overhead compounds under fire
	"ParticleInstance.gd", # GPUParticles3D -- set_script corrupts draw_passes array
	"Message.gd",          # await-based _ready -- not verified in game
	"Mine.gd",             # queue_free after detonation -- wrapper lifecycle breaks timing
	"Explosion.gd",        # await + @onready -- not verified in game
]

# Serialized to user:// -- ResourceSaver embeds the script path; wrapping breaks saves.
const RTV_RESOURCE_SERIALIZED_SKIP: Array[String] = [
	"CharacterSave.gd", "ContainerSave.gd", "FurnitureSave.gd",
	"ItemSave.gd", "Preferences.gd", "ShelterSave.gd",
	"SlotData.gd", "SwitchSave.gd", "TraderSave.gd",
	"Validator.gd", "WorldSave.gd",
]

# res://-only data scripts; mods should hook the call sites instead.
const RTV_RESOURCE_DATA_SKIP: Array[String] = [
	"AIData.gd", "AttachmentData.gd", "AudioEvent.gd", "AudioLibrary.gd",
	"CasetteData.gd", "CatData.gd", "EventData.gd", "Events.gd",
	"FishingData.gd", "FurnitureData.gd", "GrenadeData.gd",
	"InstrumentData.gd", "ItemData.gd", "KnifeData.gd", "LootTable.gd",
	"RecipeData.gd", "Recipes.gd",
	"SpawnerChunkData.gd", "SpawnerData.gd", "SpawnerSceneData.gd",
	"SpineData.gd", "TaskData.gd", "TrackData.gd",
	"TraderData.gd", "WeaponData.gd",
]

# Always-void engine lifecycle methods; codegen picks the void template for these.
const RTV_ENGINE_VOID_METHODS: Array[String] = [
	"_ready", "_process", "_physics_process", "_input",
	"_unhandled_input", "_unhandled_key_input",
	"_enter_tree", "_exit_tree", "_notification",
]

# Mods await it through the RTVModLib meta.
signal frameworks_ready

var _mods_dir: String = ""
var _developer_mode: bool = false
var _active_profile := "Default"
# What this session loaded; _active_profile runs ahead while the launcher is
# reopened from the main menu, until the restart.
var _loaded_profile := ""
var _ui_window: Window = null
# Native tooltips layer behind the always_on_top launcher.
var _ui_hint_label: Label = null
var _ui_hint_default: String = ""
var _ui_launch_btn: Button = null
var _ui_mods_scroll: ScrollContainer = null
var _ui_modpacks_scroll: ScrollContainer = null
var _priority_save_pending: bool = false
var _booted_set_signature: String = ""
# The early autoloads already running read the outgoing MCM, so Pass 1 restarts.
var _mcm_switch_completed: bool = false
var _crash_notice_cache: Dictionary = {}
var _crash_notice_cached: bool = false
var _has_loaded: bool = false
# Launcher edits from then on apply at the restart that follows.
var _boot_complete: bool = false

var _mods_filter_text: String = ""
var _mods_hide_disabled: bool = false

var _ui_mod_entries: Array[Dictionary] = []
# Dev-mode-hidden folder mods; orphan-scan treats them as present.
var _hidden_folder_profile_keys: Dictionary = {}
var _hidden_folder_ids: Dictionary = {}
# Declared hook targets the last generation could not wrap ("File.gd::method (ModA)").
var _hook_pack_lost_targets: Array = []
var _pending_autoloads: Array[Dictionary] = []
var _report_lines: Array[String] = []
var _loaded_mod_ids: Dictionary = {}
var _registered_autoload_names: Dictionary = {}
var _override_registry: Dictionary = {}
var _mod_script_analysis: Dictionary = {}
var _archive_file_sets: Dictionary = {}

# Hook names are "<scriptname>-<methodname>[-pre|-post|-callback]", lowercase;
# a bare name is a replace hook (first wins).
var _hooks: Dictionary = {}              # hook_name -> Array of {callback, priority, id}
var _dispatch_counts: Dictionary = {}
# Until any mod calls hook(), wrappers skip dispatch entirely.
var _any_mod_hooked: bool = false
# "<script>-<method>" -> refcount, erased at 0 by unhook(); an unhooked wrapped
# method costs one has() per call.
var _hooked_bases: Dictionary = {}
var _skip_super: bool = false
var _caller: Object = null               # public: the object whose wrapped method is dispatching (usually a Node; a Resource for GameData.gd)
# Hook bases inside a wrapper: a rewritten subclass super()ing into rewritten
# vanilla must not fire twice.
var _wrapper_active: Dictionary = {}

var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _all_game_script_paths: Array[String] = []  # from the PCK parse; DirAccess cannot list PCK contents
# Scripts the PCK ships as 0 bytes; not hookable, skipped silently.
var _pck_zero_byte_paths: Dictionary = {}

var _pending_script_overrides: Array[Dictionary] = []  # {vanilla_path, mod_script_path, mod_name, priority, seq}
var _applied_script_overrides: Dictionary = {}         # vanilla_path -> true

# What the hook pack wraps: method masks from [hooks], .hook() and the Mods button
# ({} wraps every method), plus the registry targets once a mod needs the registry.
var _hooked_methods: Dictionary = {}             # res_path -> {method_name: true}
var _any_mod_declared_registry: bool = false

var _re_take_over: RegEx
var _re_extends: RegEx
var _re_class_name: RegEx
var _re_filename_priority: RegEx
var _re_hook_call: RegEx
var _re_mod_stem_version: RegEx
var _re_mod_stem_named: RegEx
var _re_md_image: RegEx
var _re_md_link: RegEx
var _re_md_color: RegEx
var _re_md_heading: RegEx
var _re_md_list_item: RegEx
var _re_md_bold: RegEx
var _re_md_bold_underscore: RegEx
var _re_md_strike: RegEx
var _re_md_italic: RegEx

func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	# VostokMods compat: "100-ModName.vmz" encodes priority in the filename.
	_re_filename_priority = RegEx.new()
	_re_filename_priority.compile('^(-?\\d+)-(.*)')
	# Group 1 is the quote, 2 the script stem, 3 the method; the -pre/-post/
	# -callback suffix is a dispatch variant, not part of the method name.
	_re_hook_call = RegEx.new()
	_re_hook_call.compile("\\.hook\\s*\\(\\s*([\"'])([A-Za-z_][\\w]*)-([A-Za-z_][\\w]*?)(?:-(?:pre|post|callback))?\\1")
	# A version token: a [_-.] or space separator plus a v-number or dotted
	# number, or an attached v-number. A bare integer is a part number
	# ("Ammo Pack 1" and "Ammo Pack 2" are different mods).
	_re_mod_stem_version = RegEx.new()
	_re_mod_stem_version.compile("^(.*?)(?:[_\\-.]+(?:v[0-9]+(?:[._][0-9]+)*|[0-9]+(?:[._][0-9]+)+)| +v[0-9]+(?:[._][0-9]+)*| +[0-9]+(?:[._][0-9]+)+|v[0-9]+(?:[._][0-9]+)*)$")
	_re_mod_stem_named = RegEx.new()
	_re_mod_stem_named.compile("[a-z]")
	# Markdown for the Browse descriptions, in the order _markdown_to_bbcode runs them.
	_re_md_image = RegEx.new()
	_re_md_image.compile("!\\[([^\\]]*)\\]\\([^)]*\\)")
	_re_md_link = RegEx.new()
	_re_md_link.compile("\\[([^\\]]*)\\]\\(([^)\\s]+)\\)")
	_re_md_color = RegEx.new()
	_re_md_color.compile("\\{#([0-9a-fA-F]{3,8})\\}\\(([^)]*)\\)")
	_re_md_heading = RegEx.new()
	_re_md_heading.compile("^(#{1,6})\\s+(.*)$")
	_re_md_list_item = RegEx.new()
	_re_md_list_item.compile("^\\s*[-*+]\\s+(.*)$")
	_re_md_bold = RegEx.new()
	_re_md_bold.compile("\\*\\*([^*]+)\\*\\*")
	_re_md_bold_underscore = RegEx.new()
	_re_md_bold_underscore.compile("__([^_]+)__")
	_re_md_strike = RegEx.new()
	_re_md_strike.compile("~~([^~]+)~~")
	_re_md_italic = RegEx.new()
	_re_md_italic.compile("(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])")

var _host_cache: Dictionary = {}

var _modpack_entries: Array[Dictionary] = []

# Set by the apply dialog's Cancel; apply_modpack checks it between downloads.
var _modpack_apply_cancelled: bool = false

# profile_key -> {latest_version, ref, full_path, mod_name}; reset on launcher close.
var _mod_updates_state: Dictionary = {}
var _mod_updates_check_in_progress: bool = false

# A mid-download rebuild re-creates the Update button enabled; this keeps a
# second click from starting a duplicate download.
var _mod_update_in_flight: Dictionary = {}

# remove_child shifts current_tab to a sibling, so the re-entrant tab_changed
# can dispatch into another rebuild mid-mutation ("Parent node is busy").
var _rebuilding_tab_in_place: bool = false

# ref_key -> Array of {thumb, name_col, holder}, rebuilt every (re)build so a
# late async fetch paints current rows, not freed ones.
var _mods_meta_nodes: Dictionary = {}
