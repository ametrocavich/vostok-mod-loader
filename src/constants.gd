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
const UI_TAB_UPDATES := "Updates"

# Dependency ids satisfied by the mod loader itself; always count as present.
const LOADER_ID_ALIASES: Array[String] = [
	"metro_mod_loader", "metromodloader", "vostok_mod_loader",
	"mod_loader", "modloader", "mml", "rtvmodlib",
]
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
# --- ModWorkshop network API ---

const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_PAGE_URL_TEMPLATE := "https://modworkshop.net/mod/%s"
# GitHub repository that publishes loader releases, for the self-update
# check; "" disables it. Release tags are "v<MODLOADER_VERSION>" and the
# latest-release endpoint already excludes drafts and prereleases.
const MODLOADER_GITHUB_REPO := "ametrocavich/vostok-mod-loader"
const MODLOADER_RELEASES_API_URL := "https://api.github.com/repos/%s/releases/latest"
const MODLOADER_RELEASES_PAGE_URL := "https://github.com/%s/releases/latest"
const MODWORKSHOP_BATCH_SIZE := 100
const API_CHECK_TIMEOUT := 15.0
# HTTPRequest.timeout covers the whole transfer; mod bodies run to ~256MB.
const API_DOWNLOAD_TIMEOUT := 300.0

# ModWorkshop API (host_mws.gd): an empty/default User-Agent gets a 403; game 864 = RTV.
const MWS_API_BASE := "https://api.modworkshop.net"
const MWS_STORAGE_BASE := "https://storage.modworkshop.net"
const MWS_RTV_GAME_ID := 864
const MWS_PAGE_LIMIT := 50
# The API caps search queries at 150 chars and answers longer ones with a 422.
const MWS_QUERY_MAX_LEN := 150
const MWS_USER_AGENT_TEMPLATE := "vostok-mod-loader/%s (+https://github.com/ametrocavich/vostok-mod-loader)"

# --- Profile / modpack snapshot storage ---

# Per-profile MCM snapshot slots; profile switches rotate user://MCM/ through
# them. Vanilla is exempt: it snapshots the outgoing profile only.
const MCM_SOURCE_DIR := "user://MCM"
const MCM_SNAPSHOT_BASE := "user://.profile_snapshots"

# Write-once restore points taken before a modpack apply; newest MODPACK_SNAPSHOT_KEEP kept.
const MODPACK_SNAPSHOT_DIR := "user://.modpack_backups"
const MODPACK_SNAPSHOT_KEEP := 5

# --- Mod entry limits + tracked content ---

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]

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
	"Message.gd",          # await-based _ready -- dispatch wrapper doesn't await super, kills coroutine
	"Mine.gd",             # queue_free after detonation -- wrapper lifecycle breaks timing
	"Explosion.gd",        # await + @onready -- coroutine dies, particles don't emit
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
var _ui_launch_btn: Button = null
# Kept on self so _rebuild_mods_tab can carry scroll position across teardown.
var _ui_mods_scroll: ScrollContainer = null
var _ui_modpacks_scroll: ScrollContainer = null
# Debounce guard for priority-spinbox saves (see _schedule_priority_save).
var _priority_save_pending: bool = false
# Self-update check state; both cleared on UI close.
var _modloader_latest_version: String = ""
# Page of the release the self-update check found; "" until it runs, in
# which case the alert falls back to the repository's latest-release page.
var _modloader_release_url: String = ""
var _ui_update_alert_btn: LinkButton = null
var _has_loaded := false
# Most recent mod.txt read result: "none", "ok", "parse_error" (details in
# _last_mod_txt_error), "nested:<path>", "pck". Copied into candidates as
# "mod_txt_status"; new values need both mod_discovery consumers checked.
var _last_mod_txt_status := "none"
# Author-facing parse diagnostic; empty unless status == "parse_error".
var _last_mod_txt_error := ""
# Archive file list captured by read_mod_config, read only by the next
# _build_entry_warnings call. Not stored per entry. Empty for .pck/folder.
var _last_mod_txt_files := {}
var _database_replaced_by := ""
# Once _boot_complete, UI mutations set _dirty_since_boot; reopen flow restarts on close.
var _boot_complete: bool = false
var _dirty_since_boot: bool = false

# Mods-tab filter state. _mods_hide_disabled is per-profile; focus_pending
# lets the search input reclaim focus after the text_changed rebuild.
var _mods_filter_text: String = ""
var _mods_hide_disabled: bool = false
var _mods_filter_focus_pending: bool = false

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
var _next_id: int = 1
var _skip_super: bool = false
var _seq: int = 0
var _caller: Node = null                 # public: source node of the current dispatch
var _is_ready: bool = false              # public: true once frameworks_ready has emitted
# Re-entry guard: hook_bases currently executing a wrapper. Prevents
# double-fire when a rewritten subclass super()s into rewritten vanilla.
var _wrapper_active: Dictionary = {}
# Warn-once dedupe for legacy 2-arg post-hook callbacks, keyed by
# "<hook_name>::<callback object_id>".
var _post_legacy_warned: Dictionary = {}

# Class + script enumeration state (populated from PCK parse at boot).
var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _all_game_script_paths: Array[String] = []  # populated by _enumerate_game_scripts from PCK parse; DirAccess can't list PCK contents in 4.6
# res_path -> true for scripts the PCK ships as 0 bytes (e.g.
# CasettePlayer.gd in RTV 4.6.1); not hookable, skipped silently.
var _pck_zero_byte_paths: Dictionary = {}

# res:// script path -> scene paths; these are deferred from the eager
# load+reload in _activate_rewritten_scripts. Their module-scope preload()
# fires at parse time, so force-loading before mod overrides run would bake
# scenes against pre-override vanilla; deferring to lazy-compile lets
# overrides land first, and VFS precedence still serves the rewrite.
var _scripts_with_scene_preloads: Dictionary = {}

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

# Rewriter regex (compiled in _rtv_compile_codegen_regex)
var _rtv_re_extends: RegEx
var _rtv_re_class_name: RegEx
var _rtv_re_func: RegEx
var _rtv_re_static_func: RegEx
var _rtv_re_sig_tail: RegEx
var _rtv_re_param_name: RegEx
var _rtv_re_var: RegEx
var _rtv_re_ret_value: RegEx

# Mounts the previous session's archives at file-scope (before _ready). Keyed
# by pass-state path; _process_mod_candidate skips re-mounts that would
# clobber static-init overlays.
var _filescope_mounted: Dictionary = _mount_previous_session()

# Host-transport response cache, keyed by full URL (absolute, so providers
# cannot collide). Entry: {data: Variant, expires_at: int (msec)}; evicted
# on read. Session memory only.
var _host_cache: Dictionary = {}

# Rate-limit cooldowns, provider id -> ticks_msec resume moment.
# Per-provider: hosts have independent budgets.
var _host_cooldown_until_ms: Dictionary = {}

# Discovered modpacks, populated lazily by collect_modpack_metadata. Entry:
# {file_path, file_name, raw_name, sanitized_name, enabled_count, total_count}.
var _modpack_entries: Array[Dictionary] = []

# Mutex for the modpack apply flow; prevents concurrent applies racing on cfg
# writes + the backup slot. UI also gates Apply buttons on it.
var _modpack_apply_in_progress: bool = false
# Set by the apply dialog's Cancel button; apply_modpack checks between
# downloads. Cleared at the start of every apply.
var _modpack_apply_cancelled: bool = false

# Update-check results: profile_key -> {latest_version, ref, full_path,
# mod_name}. Read by Mods-tab rows for inline badges; resets on launcher
# close. Entries with no host ref are not stored.
var _mod_updates_state: Dictionary = {}
var _mod_updates_check_in_progress: bool = false

# Set when a check changes _mod_updates_state while the Mods tab is
# off-screen; the tab_changed listener rebuilds it on next show.
var _mods_badges_dirty: bool = false

# profile_keys with an update download in flight. A mid-download rebuild
# re-creates the Update button enabled, so without this a second click would
# start a duplicate download; rebuilt badges render disabled instead.
var _mod_update_in_flight: Dictionary = {}

# Recursion guard for _rebuild_modpacks_tab: child moves fire tab_changed,
# whose listener calls _rebuild_modpacks_tab again.
var _rebuilding_modpacks_tab: bool = false

# Shared re-entrancy guard for all in-place tab rebuilds. The per-tab flag is
# not enough: remove_child shifts current_tab to a sibling, so the re-entrant
# tab_changed can dispatch into a different rebuild helper mid-mutation
# ("Parent node is busy adding/removing children").
var _rebuilding_tab_in_place: bool = false

# Mods-tab host meta memo, keyed by host_ref_key. The seam caches only
# successful responses, so failed refs would refetch on every rebuild; memo
# successes for the session and gate failures behind a retry window (one
# attempt per mod per minute).
var _mods_meta_by_key: Dictionary = {}       # ref_key -> ModSummary or ModDetail (successes only)
var _mods_meta_retry_at: Dictionary = {}     # ref_key -> ticks_msec before which not to refetch

# Sidecar bookkeeping: ref_key -> unix time of the last real detail fetch.
# Only keys here reach the on-disk sidecar; a stale stamp triggers the
# background soft refresh. _mods_meta_sidecar_loaded gates the lazy read.
var _mods_meta_saved_at: Dictionary = {}
var _mods_meta_sidecar_loaded: bool = false

# Live Mods-tab row nodes for meta painting: ref_key -> Array of {thumb,
# name_col, holder} (several rows can share one host mod). Rebuilt every
# (re)build so a late async fetch paints current rows, not freed ones.
var _mods_meta_nodes: Dictionary = {}
