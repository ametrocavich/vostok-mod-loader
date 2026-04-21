## ----- constants.gd -----
## All top-level const declarations and module-scope state (vars, signals).
## These must appear in the compiled modloader.gd before any function body
## that references them.

# release-please bumps MODLOADER_VERSION automatically via Conventional Commits:
#   feat: ... -> minor bump
#   fix: ...  -> patch bump
#   feat!: or BREAKING CHANGE: -> major bump
# The major/minor/patch accessors parse this single source of truth so mods can
# compare against it without hand-maintaining a second set of constants.
# x-release-please-start-version
const MODLOADER_VERSION := "2.4.0"
# x-release-please-end

const MODLOADER_RES_PATH := "res://modloader.gd"
const MOD_DIR := "mods"
const TMP_DIR := "user://vmz_mount_cache"
const UI_CONFIG_PATH := "user://mod_config.cfg"
# Sentinel value for `[settings] active_profile` written by Reset to Vanilla.
# Has no stored sections -- `_apply_profile_to_entries` treats it as "all off".
const VANILLA_PROFILE := "__vanilla__"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const PASS_STATE_PATH := "user://mod_pass_state.cfg"
const HEARTBEAT_PATH := "user://modloader_heartbeat.txt"
const PASS2_DIRTY_PATH := "user://modloader_pass2_dirty"
const SAFE_MODE_FILE := "modloader_safe_mode"
const DISABLED_FILE := "modloader_disabled"
const MAX_RESTART_COUNT := 2

const HOOK_PACK_DIR := "user://modloader_hooks"
# Hook pack filename: "<prefix>_<timestamp_ms>.zip". A fresh filename per
# _generate_hook_pack call sidesteps ProjectSettings.load_resource_pack's
# path-dedup (a same-path re-mount is a no-op and the VFS keeps stale file
# offsets from the original mount -- FileAccess reads return prior-session
# bytes even though ZIPPacker rewrote the file on disk). Different filename
# = new mount = fresh offsets. Orphan files from prior sessions are cleaned
# up at static-init in _mount_previous_session before any mount happens.
const HOOK_PACK_PREFIX := "framework_pack"
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

# Scripts skipped from rewrite. Dispatch-wrapper overhead and set_script
# semantics break these specific use patterns. Inherited from tetra's original
# RTVLib skip_list and still applicable to the source-rewrite system:
# coroutines, short-lived effect instances, and @tool scripts all need to
# stay untouched to preserve game behavior.
const RTV_SKIP_LIST: Array[String] = [
	"TreeRenderer.gd",     # @tool script -- editor-only, no runtime hooks needed
	"MuzzleFlash.gd",      # 50ms flash effect -- dispatch overhead breaks timing
	"Hit.gd",              # per-shot instantiated -- overhead compounds under fire
	"ParticleInstance.gd", # GPUParticles3D -- set_script corrupts draw_passes array
	"Message.gd",          # await-based _ready -- dispatch wrapper doesn't await super, kills coroutine
	"Mine.gd",             # queue_free after detonation -- wrapper lifecycle breaks timing
	"Explosion.gd",        # await + @onready -- coroutine dies, particles don't emit
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

var _mods_dir: String = ""
var _developer_mode := false
var _active_profile := "Default"
var _ui_window: Window = null
# Bottom-bar label used as a makeshift status hint because Godot's native
# tooltips get layered behind our always_on_top launcher and aren't visible.
var _ui_hint_label: Label = null
var _has_loaded := false
var _last_mod_txt_status := "none"
var _database_replaced_by := ""

var _ui_mod_entries: Array[Dictionary] = []
# profile_keys for folder mods that exist on disk but were skipped from entries
# because developer mode is off. Orphan-scan treats these as present so
# disabling dev mode doesn't spam the UI with false "missing" rows for dev
# mods the user still has installed.
var _hidden_folder_profile_keys: Dictionary = {}
var _hidden_folder_ids: Dictionary = {}
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
# Dev-mode-only: per-hook_base dispatch counter. Incremented inside each
# wrapper AFTER the _any_mod_hooked short-circuit when _developer_mode is
# true. Summary at 30s timer in _activate_rewritten_scripts pinpoints
# runaway method calls (e.g. connect-already-connected error spam from a
# _ready firing thousands of times).
var _dispatch_counts: Dictionary = {}
# Fast-path short-circuit: flipped true the first time any mod calls hook().
# Dispatch wrappers skip the full _wrapper_active/_caller/_dispatch path
# when no mod has hooked anything at all. Sticky -- stays true once set.
# Same approach as godot-mod-loader's `_ModLoaderHooks.any_mod_hooked`.
var _any_mod_hooked: bool = false
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
var _all_game_script_paths: Array[String] = []  # populated by _enumerate_game_scripts from PCK parse; DirAccess can't list PCK contents in 4.6
var _pck_zero_byte_paths: Dictionary = {}  # res_path -> true for entries the base game PCK ships as 0-byte (e.g. CasettePlayer.gd in RTV 4.6.1). Populated by _parse_pck_file_list; checked by detokenize + hook-gen to skip silently. These files are not hookable and any vanilla or mod preload() of them will fail at engine level -- not a modloader bug.
var _scripts_with_scene_preloads: Dictionary = {}  # filename -> PackedStringArray of scene paths; scripts listed here are deferred from eager load+reload in _activate_rewritten_scripts. Rationale: their module-scope preload() fires at parse time; if we force-load them before mod autoloads run overrideScript(), scenes bake Script ext_resources to the pre-override vanilla. take_over_path then orphans those refs and instantiate() produces nodes with vanilla body, not mod body. Deferring to lazy-compile lets mod overrides run first -- the preload chain fires via extends resolution during mod's own overrideScript call, AFTER take_over_path took effect for prior targets. VFS mount precedence still serves our rewrite on lazy-load.
var _node_swap_connected := false
var _swap_count: int = 0
var _ready_is_coroutine_by_path: Dictionary = {}  # res_path -> bool. Sync (false) means
                                                  # _deferred_swap pre-sets _rtv_ready_done
                                                  # so super() doesn't re-run vanilla _ready.

# Script overrides
var _pending_script_overrides: Array[Dictionary] = []  # {vanilla_path, mod_script_path, mod_name, priority}
var _applied_script_overrides: Dictionary = {}         # vanilla_path -> true

# Opt-in declarations (v2.4.0 cutover). Populated by the [hooks] parser in
# mod_loading.gd and by .hook() call scanning. Drives the wrap surface in
# _generate_hook_pack. If both are empty AND _any_mod_declared_registry is
# false, _generate_hook_pack early-returns and no hook pack is produced --
# the modlist behaves byte-identical to pre-hook-system (v2.1.0) behavior.
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
var _rtv_re_var: RegEx

# Mounts previous session's archives at file-scope (before _ready) so autoloads
# that load after ModLoader can resolve their res:// paths.
# Returns a dict keyed by the archive path as it appears in pass state -- used
# by _process_mod_candidate to skip redundant re-mounts that would clobber our
# own overlay overrides applied at static init (e.g. hook pack for mod scripts).
var _filescope_mounted: Dictionary = _mount_previous_session()
