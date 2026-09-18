## ----- constants.gd -----
## Shared constants and module-scope state. Add a constant here only when more
## than one domain file reads it; subsystem-local consts live with their
## subsystem. build.sh concatenates src/*.gd into one namespace, so top-level
## names must be globally unique, and a const referencing another const must
## be declared after it (for cross-file references: earlier in FILES order).

# release-please bumps MODLOADER_VERSION; the major/minor/patch accessors parse it.
# x-release-please-start-version
const MODLOADER_VERSION := "3.3.1"
# x-release-please-end

const MODLOADER_RES_PATH := "res://modloader.gd"
const MOD_DIR := "mods"

# Tab node names; rebuild helpers look tabs up by these exact strings.
const UI_TAB_MODS := "Mods"
const UI_TAB_BROWSE := "Browse"
const UI_TAB_MODPACKS := "Modpacks"

# --- Persistent files: caches, config, boot sentinels, pass state ---

const TMP_DIR := "user://vmz_mount_cache"
const UI_CONFIG_PATH := "user://mod_config.cfg"
# Reset-to-Vanilla sentinel for `[settings] active_profile`; treated as all-off.
const VANILLA_PROFILE := "__vanilla__"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const PASS_STATE_PATH := "user://mod_pass_state.cfg"
const HEARTBEAT_PATH := "user://modloader_heartbeat.txt"
const PASS2_DIRTY_PATH := "user://modloader_pass2_dirty"
const SAFE_MODE_FILE := "modloader_safe_mode"
const DISABLED_FILE := "modloader_disabled"
# DISABLED_FILE, but auto-cleared after one launch ("Launch Vanilla" button).
const DISABLED_ONCE_FILE := "modloader_disabled_once"
const MAX_RESTART_COUNT := 2
# Consecutive crashed two-pass restarts. Its own file, not a pass-state key:
# the crashed-Pass-2 wipe deletes pass state, the very event being counted.
const CRASH_STREAK_PATH := "user://modloader_crash_streak"

# --- Hook pack / rewriter cache ---

const HOOK_PACK_DIR := "user://modloader_hooks"
# "<prefix>_<timestamp_ms>.zip". A fresh filename per generate sidesteps
# load_resource_pack's path-dedup (a same-path re-mount is a no-op with stale
# VFS offsets); orphans are swept at static init.
const HOOK_PACK_PREFIX := "framework_pack"
const VANILLA_CACHE_DIR := "user://modloader_hooks/vanilla"

# --- Network ---

const API_CHECK_TIMEOUT := 15.0

# --- Profile / modpack snapshot storage ---

# Per-profile MCM snapshot slots; profile switches rotate user://MCM/ through
# them. Vanilla is exempt: it snapshots the outgoing profile only.
const MCM_SOURCE_DIR := "user://MCM"
const MCM_SNAPSHOT_BASE := "user://.profile_snapshots"

# --- Mod entry limits ---

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999

# --- Supported engine binary formats (GDPC pack + GDSC script versions) ---

# Pack formats both .pck parsers accept. V2 = Godot 4.0-4.5, V3 = 4.6.
const PACK_FORMAT_V2 := 2
const PACK_FORMAT_V3 := 3
# Godot 4.7+ format: never accepted, used only for a modder-friendly message.
const PACK_FORMAT_V4 := 4

# GDSC tokenizer versions the detokenizer understands. v100 = Godot 4.3-4.4,
# v101 = 4.5+. The integer alone does not pin a token layout, which is why
# canary C round-trips real output instead of trusting it.
const GDSC_VERSION_V100 := 100
const GDSC_VERSION_V101 := 101

# --- Rewriter skip lists + codegen tables ---

# Skipped from rewrite; wrapper overhead / set_script break these (per-entry notes).
const RTV_SKIP_LIST: Array[String] = [
	"TreeRenderer.gd",     # @tool script -- editor-only, no runtime hooks needed
	"MuzzleFlash.gd",      # 50ms flash effect -- dispatch overhead breaks timing
	"Hit.gd",              # per-shot instantiated -- overhead compounds under fire
	"ParticleInstance.gd", # GPUParticles3D -- set_script corrupts draw_passes array
	"Message.gd",          # await-based _ready -- not verified in game under the coroutine-aware wrapper
	"Mine.gd",             # queue_free after detonation -- wrapper lifecycle breaks timing
	"Explosion.gd",        # await + @onready -- not verified in game under the coroutine-aware wrapper
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
	"AIWeaponData.gd", "AttachmentData.gd", "AudioEvent.gd", "AudioLibrary.gd",
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

# Module-scope state

var _mods_dir: String = ""
var _developer_mode := false
var _active_profile := "Default"
var _ui_window: Window = null
# Status-hint label; native tooltips layer behind the always_on_top launcher.
var _ui_hint_label: Label = null
# What the hint label shows when nothing is hovered; the tab listener sets it.
var _ui_hint_default: String = ""
var _ui_launch_btn: Button = null
# Kept on self so _rebuild_mods_tab can carry scroll position across teardown.
var _ui_mods_scroll: ScrollContainer = null
var _ui_modpacks_scroll: ScrollContainer = null
# Debounce guard for priority-spinbox saves (see _schedule_priority_save).
var _priority_save_pending: bool = false
var _has_loaded := false
# Once _boot_complete, UI mutations set _dirty_since_boot; reopen flow restarts on close.
var _boot_complete: bool = false
var _dirty_since_boot: bool = false

# Mods-tab filter state; _mods_hide_disabled is per-profile.
var _mods_filter_text: String = ""
var _mods_hide_disabled: bool = false

var _ui_mod_entries: Array[Dictionary] = []
# Dev-mode-hidden folder mods; orphan-scan treats them as present.
var _hidden_folder_profile_keys: Dictionary = {}
var _hidden_folder_ids: Dictionary = {}
var _pending_autoloads: Array[Dictionary] = []
var _report_lines: Array[String] = []
# Loaded mods: mod_id -> {version, file_name, priority, mod_name, dependencies}.
# Public read API: lib.has_mod, lib.mod_info, lib.loaded_mods.
var _loaded_mod_ids: Dictionary = {}
var _registered_autoload_names: Dictionary = {}
var _override_registry: Dictionary = {}
var _mod_script_analysis: Dictionary = {}
var _archive_file_sets: Dictionary = {}
var _archive_zip_paths: Dictionary = {}  # bare file_name -> readable zip path

# Hook registry. Hook names are "<scriptname>-<methodname>[-pre|-post|-callback]",
# lowercase. A bare name (no suffix) is a replace hook (first-wins).
signal frameworks_ready
var _hooks: Dictionary = {}              # hook_name -> Array of {callback, priority, id}
# Dev-mode per-hook_base dispatch counter (30s summary pinpoints runaway calls).
var _dispatch_counts: Dictionary = {}
# Sticky flag: until any mod calls hook(), wrappers skip dispatch entirely.
var _any_mod_hooked: bool = false
# Per-hook-base refcount, keyed by "<script>-<method>" lowercase (no suffix);
# erased at 0 by unhook(). Wrappers short-circuit on _hooked_bases.has(base),
# so an unhooked wrapped method costs one Dictionary.has() per call.
var _hooked_bases: Dictionary = {}
var _skip_super: bool = false
var _caller: Node = null                 # public: source node of the current dispatch
# Re-entry guard: hook_bases currently executing a wrapper. Prevents
# double-fire when a rewritten subclass super()s into rewritten vanilla.
var _wrapper_active: Dictionary = {}

# Class + script enumeration state (populated from PCK parse at boot).
var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _all_game_script_paths: Array[String] = []  # populated by _enumerate_game_scripts from PCK parse; DirAccess can't list PCK contents in 4.6
# res_path -> true for scripts the PCK ships as 0 bytes (e.g.
# CasettePlayer.gd in RTV 4.6.1); not hookable, skipped silently.
var _pck_zero_byte_paths: Dictionary = {}

var _pending_script_overrides: Array[Dictionary] = []  # {vanilla_path, mod_script_path, mod_name, priority, seq}
var _applied_script_overrides: Dictionary = {}         # vanilla_path -> true

# Opt-in declarations from the [hooks] parser and .hook() scanning; drive the
# wrap surface in _generate_hook_pack. All empty -> no hook pack, untouched
# vanilla.
var _hooked_methods: Dictionary = {}             # res_path -> {method_name: true}
var _any_mod_declared_registry: bool = false     # set by [registry] parser

var _re_take_over: RegEx
var _re_extends: RegEx
var _re_extends_classname: RegEx
var _re_class_name: RegEx
var _re_func: RegEx
var _re_preload: RegEx
var _re_filename_priority: RegEx
var _re_hook_call: RegEx
var _re_mod_stem_version: RegEx
var _re_mod_stem_named: RegEx
# Markdown constructs _markdown_to_bbcode converts, in the order it runs them.
var _re_md_image: RegEx
var _re_md_link: RegEx
var _re_md_color: RegEx
var _re_md_heading: RegEx
var _re_md_list_item: RegEx
var _re_md_bold: RegEx
var _re_md_bold_underscore: RegEx
var _re_md_strike: RegEx
var _re_md_italic: RegEx

# Host-transport response cache, keyed by full URL (absolute, so providers
# cannot collide). Entry: {data: Variant, expires_at: int (msec)}; evicted
# on read. Session memory only.
var _host_cache: Dictionary = {}

# Discovered modpacks, populated lazily by collect_modpack_metadata. Entry:
# {file_path, file_name, raw_name, sanitized_name, enabled_count, total_count}.
var _modpack_entries: Array[Dictionary] = []

# Set by the apply dialog's Cancel button; apply_modpack checks between
# downloads. Cleared at the start of every apply.
var _modpack_apply_cancelled: bool = false

# Update-check results: profile_key -> {latest_version, ref, full_path,
# mod_name}. Read by Mods-tab rows for inline badges; resets on launcher
# close. Entries with no host ref are not stored.
var _mod_updates_state: Dictionary = {}
var _mod_updates_check_in_progress: bool = false

# profile_keys with an update download in flight. A mid-download rebuild
# re-creates the Update button enabled, so without this a second click would
# start a duplicate download; rebuilt badges render disabled instead.
var _mod_update_in_flight: Dictionary = {}

# Shared re-entrancy guard for all in-place tab rebuilds. The per-tab flag is
# not enough: remove_child shifts current_tab to a sibling, so the re-entrant
# tab_changed can dispatch into a different rebuild helper mid-mutation
# ("Parent node is busy adding/removing children").
var _rebuilding_tab_in_place: bool = false

# Live Mods-tab row nodes for meta painting: ref_key -> Array of {thumb,
# name_col, holder} (several rows can share one host mod). Rebuilt every
# (re)build so a late async fetch paints current rows, not freed ones.
var _mods_meta_nodes: Dictionary = {}
