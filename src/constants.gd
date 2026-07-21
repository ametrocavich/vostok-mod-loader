## ----- constants.gd -----
## Shared constants and module-scope state (vars, signals) -- the flat
## namespace's cross-domain surface. Subsystem-local consts live with
## their subsystem instead (gdsc_detokenizer's TK_* table, security_scan's
## rule tables, modpacks' MODPACK_* prefixes, mws_api's cache TTLs,
## boot.gd's EARLY_AUTOLOAD_DIR); add a constant HERE only when more than
## one domain file reads it. All top-level names share one namespace
## across src/*.gd (build.sh concatenation), so they must be globally
## unique. A const whose initializer references another const must be
## declared after it -- for cross-file references that means earlier in
## build.sh's FILES order.

# release-please bumps MODLOADER_VERSION automatically via Conventional Commits:
#   feat: ... -> minor bump
#   fix: ...  -> patch bump
#   feat!: or BREAKING CHANGE: -> major bump
# The major/minor/patch accessors parse this single source of truth so mods can
# compare against it without hand-maintaining a second set of constants.
# x-release-please-start-version
const MODLOADER_VERSION := "3.3.0"
# x-release-please-end

const MODLOADER_RES_PATH := "res://modloader.gd"
const MOD_DIR := "mods"

# Tab node names. TabContainer displays the child node's name as the tab
# title, and the rebuild helpers look tabs up by these exact strings -- so
# each name is a cross-function contract, not just a label.
const UI_TAB_MODS := "Mods"
const UI_TAB_BROWSE := "Browse"
const UI_TAB_MODPACKS := "Modpacks"
const UI_TAB_UPDATES := "Updates"

# Dependency ids satisfied by the mod loader itself. Mod authors copy
# "requires Metro Mod Loader" from their ModWorkshop page into
# [dependencies]; blocking a mod because the loader "isn't installed"
# would be absurd, so these ids always count as present.
const LOADER_ID_ALIASES: Array[String] = [
	"metro_mod_loader", "metromodloader", "vostok_mod_loader",
	"mod_loader", "modloader", "mml", "rtvmodlib",
]
# --- Persistent files: caches, config, boot sentinels, pass state ---

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
# Same effect as DISABLED_FILE but auto-cleared by the modloader on the
# next launch -- written by the launcher's "Launch Vanilla" button so the
# game runs vanilla once and reverts to normal modded flow afterward.
const DISABLED_ONCE_FILE := "modloader_disabled_once"
const MAX_RESTART_COUNT := 2

# --- Hook pack / rewriter cache ---

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
# --- ModWorkshop network API ---

const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_DOWNLOAD_URL_TEMPLATE := "https://api.modworkshop.net/mods/%s/download"
const MODWORKSHOP_PAGE_URL_TEMPLATE := "https://modworkshop.net/mod/%s"
# ModWorkshop ID for this modloader itself. Used by the launcher's self-update
# check to flag when the installed MODLOADER_VERSION is older than what's
# published on ModWorkshop. Set to <= 0 to disable the check entirely.
const MODLOADER_MODWORKSHOP_ID := 55623
const MODWORKSHOP_BATCH_SIZE := 100
const API_CHECK_TIMEOUT := 15.0
# HTTPRequest.timeout covers the WHOLE transfer, not just connect/stall, and
# mod bodies run to ~256MB -- 30s failed any large mod on a normal connection.
# 5 minutes is generous enough for big packs on slow links while still
# bounding a truly dead connection.
const API_DOWNLOAD_TIMEOUT := 300.0

# Browse-tab API client. Lives in mws_api.gd; constants here so the rest of
# the codebase can build URLs without re-importing the module's namespace.
# Empty/default User-Agent gets a 403 from api.modworkshop.net -- the template
# is non-optional. Game ID 864 = Road to Vostok (resolved via /games once,
# baked here to avoid an extra round-trip on every UI open).
const MWS_API_BASE := "https://api.modworkshop.net"
const MWS_STORAGE_BASE := "https://storage.modworkshop.net"
const MWS_RTV_GAME_ID := 864
const MWS_PAGE_LIMIT := 50
const MWS_USER_AGENT_TEMPLATE := "vostok-mod-loader/%s (+https://github.com/ametrocavich/vostok-mod-loader)"

# --- Profile / modpack snapshot storage ---

# Per-profile MCM snapshot storage. Switching profiles rotates the contents of
# user://MCM/ in and out of these per-profile slots, so MCM settings stay
# bound to the profile that authored them. Vanilla is exempt -- switching to
# Vanilla snapshots the OUTGOING profile's MCM but leaves user://MCM/ alone.
const MCM_SOURCE_DIR := "user://MCM"
const MCM_SNAPSHOT_BASE := "user://.profile_snapshots"

# Independent, write-once restore points taken right before a modpack apply.
# Distinct from MCM_SNAPSHOT_BASE (which the apply/unload state machine reads
# and rewrites): nothing but the snapshot/restore code touches these, so they
# survive any crash-window bug as a guaranteed recovery point. Only the most
# recent MODPACK_SNAPSHOT_KEEP are retained; older ones are pruned on apply.
const MODPACK_SNAPSHOT_DIR := "user://.modpack_backups"
const MODPACK_SNAPSHOT_KEEP := 5

# --- Mod entry limits + tracked content ---

const PRIORITY_MIN := -999
const PRIORITY_MAX := 999
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]

# --- Supported engine binary formats (GDPC pack + GDSC script versions) ---

# GDPC pack format versions the .pck header parsers accept. Shared by
# _parse_pck_file_list (pck_enumeration.gd) and
# _security_pck_list_with_offsets (security_scan.gd) so the two bounds
# checks cannot drift. V2 = Godot 4.0-4.5, V3 = Godot 4.6.
const PACK_FORMAT_V2 := 2
const PACK_FORMAT_V3 := 3
# Godot 4.7+ writes pack format v4 (encrypted-directory salt, sparse
# bundles). Diagnosis only -- NEVER accepted: the 4.6 engine under us
# cannot read v4 packs either, so both parsers keep rejecting it and use
# this constant to emit a modder-friendly message instead of a generic
# "unsupported version". See .research/GODOT_47_COMPAT.md section 2.1.
const PACK_FORMAT_V4 := 4

# GDSC (compiled .gdc script) tokenizer versions the detokenizer
# understands. Shared by _detokenize_script (gdsc_detokenizer.gd) and
# STABILITY canary B in _generate_hook_pack (hook_pack.gd).
# v100 = Godot 4.0-4.4, v101 = Godot 4.5+ (TOKENIZER_VERSION is still 101
# in 4.7-stable; see .research/GODOT_47_COMPAT.md section 2.2 -- which is
# why canary C round-trips real output instead of trusting this number).
const GDSC_VERSION_V100 := 100
const GDSC_VERSION_V101 := 101

# --- Rewriter skip lists + codegen tables ---

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

# ===== Module-scope state (mutable vars + signals) below this line =====

var _mods_dir: String = ""
var _developer_mode := false
var _active_profile := "Default"
var _ui_window: Window = null
# Bottom-bar label used as a makeshift status hint because Godot's native
# tooltips get layered behind our always_on_top launcher and aren't visible.
var _ui_hint_label: Label = null
# Launch button kept on self so refresh_launch_button_label can reach it
# from the mod-enable toggle handler.
var _ui_launch_btn: Button = null
# Mods-tab list scroller, kept on self so _rebuild_mods_tab can carry the
# scroll position across teardown -- without this, toggling a mod halfway
# down a long list snapped the view back to the top.
var _ui_mods_scroll: ScrollContainer = null
# Modpacks-tab list scroller, same carry-across-rebuild pattern for
# _rebuild_modpacks_tab (row actions rebuild the whole tab).
var _ui_modpacks_scroll: ScrollContainer = null
# Debounce guard for priority-spinbox saves (see _schedule_priority_save).
var _priority_save_pending: bool = false
# Self-update check state. _modloader_latest_version is populated by
# _check_modloader_update_async once the API responds; empty until then or
# when the check fails. _ui_update_alert_btn is the inline LinkButton in the
# launch row -- always shows the installed version dim by default, swaps to
# an orange "update available" prompt when the API reports a newer release.
# Both cleared on UI close.
var _modloader_latest_version: String = ""
var _ui_update_alert_btn: LinkButton = null
var _has_loaded := false
# Result of the most recent mod.txt read (read_mod_config /
# read_mod_config_folder in fs_archive.gd; mod_discovery sets "pck" for
# .pck mods, which carry no mod.txt). Values:
#   "none"            no mod.txt found (or nothing parsed yet)
#   "ok"              parsed successfully
#   "parse_error"     ConfigFile rejected it, or mod.txt was empty;
#                     details in _last_mod_txt_error when available
#   "nested:<path>"   mod.txt buried in a subfolder = bad packaging
#   "pck"             .pck mod, no mod.txt expected
# Copied per-entry into candidate dicts as "mod_txt_status" by
# mod_discovery; consumed by its warning builder and by
# _process_mod_candidate's boot-log messages. New status values need
# both consumers checked.
var _last_mod_txt_status := "none"
# Detailed parse-failure diagnostic written by _parse_mod_txt when ConfigFile
# rejects mod.txt. Plumbed into UI warnings + boot-log messages so authors
# see *which* line/section broke instead of a generic "Invalid mod" prompt.
# Empty when status != "parse_error".
var _last_mod_txt_error := ""
var _database_replaced_by := ""
# Post-boot UI re-open state. _boot_complete flips true once Pass 1 / Pass 2 /
# single-pass finish paths finalize. Once true, any mutation of mod_config.cfg
# via the launcher UI sets _dirty_since_boot, which the main-menu reopen flow
# uses to decide whether to restart on UI close.
var _boot_complete: bool = false
var _dirty_since_boot: bool = false

# Mods-tab filter state. _mods_filter_text narrows by name substring (cleared
# only on game restart; survives _rebuild_mods_tab). _mods_hide_disabled is
# per-profile, loaded by _apply_profile_to_entries from
# profile.<name>.settings.hide_disabled and written on toggle.
# _mods_filter_focus_pending lets the search input reclaim focus after the
# text_changed rebuild so the user can keep typing without re-clicking.
var _mods_filter_text: String = ""
var _mods_hide_disabled: bool = false
var _mods_filter_focus_pending: bool = false

var _ui_mod_entries: Array[Dictionary] = []
# profile_keys for folder mods that exist on disk but were skipped from entries
# because developer mode is off. Orphan-scan treats these as present so
# disabling dev mode doesn't spam the UI with false "missing" rows for dev
# mods the user still has installed.
var _hidden_folder_profile_keys: Dictionary = {}
var _hidden_folder_ids: Dictionary = {}
var _pending_autoloads: Array[Dictionary] = []
var _report_lines: Array[String] = []
# Loaded mods, keyed by mod_id. Value is a Dictionary with at least
# {version, file_name, priority, mod_name, dependencies}; populated by mod_loading.
# Public read API: lib.has_mod(id, ?min_version), lib.mod_info(id),
# lib.loaded_mods(). Code that just checks presence still works via
# Dict.has() since the key membership is unchanged from when the value
# was a bare `true`.
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
# Per-hook-base reference count. Keyed by hook_base ("<script>-<method>"
# lowercase, no -pre/-post/-callback suffix). Incremented when hook() registers
# any variant under that base, decremented (and erased at 0) by unhook(). The
# generated wrapper short-circuits when _hooked_bases.has(base) is false, so a
# wrapped method that nobody actually hooks costs one Dictionary.has() per call
# instead of the full _wrapper_active/_caller/_dispatch pipeline.
var _hooked_bases: Dictionary = {}
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
# Deprecation-warning suppression for legacy 2-arg post-hook callbacks.
# Keyed by "<hook_name>::<callback object_id>" so we warn once per (hook,
# callback) pair across the whole session. Without dedupe, a per-frame
# wrapped method would spam the log thousands of times.
var _post_legacy_warned: Dictionary = {}

# Class + script enumeration state (populated from PCK parse at boot).
var _class_name_to_path: Dictionary = {} # "Camera" -> "res://Scripts/Camera.gd"
var _all_game_script_paths: Array[String] = []  # populated by _enumerate_game_scripts from PCK parse; DirAccess can't list PCK contents in 4.6
var _pck_zero_byte_paths: Dictionary = {}  # res_path -> true for entries the base game PCK ships as 0-byte (e.g. CasettePlayer.gd in RTV 4.6.1). Populated by _parse_pck_file_list; checked by detokenize + hook-gen to skip silently. These files are not hookable and any vanilla or mod preload() of them will fail at engine level -- not a modloader bug.
var _scripts_with_scene_preloads: Dictionary = {}  # full res:// script path -> PackedStringArray of scene paths; scripts listed here are deferred from eager load+reload in _activate_rewritten_scripts. Rationale: their module-scope preload() fires at parse time; if we force-load them before mod autoloads run overrideScript(), scenes bake Script ext_resources to the pre-override vanilla. take_over_path then orphans those refs and instantiate() produces nodes with vanilla body, not mod body. Deferring to lazy-compile lets mod overrides run first -- the preload chain fires via extends resolution during mod's own overrideScript call, AFTER take_over_path took effect for prior targets. VFS mount precedence still serves our rewrite on lazy-load.

# Script overrides
var _pending_script_overrides: Array[Dictionary] = []  # {vanilla_path, mod_script_path, mod_name, priority, seq}
var _applied_script_overrides: Dictionary = {}         # vanilla_path -> true

# Opt-in declarations (v3.0.1 cutover). Populated by the [hooks] parser in
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
var _rtv_re_sig_tail: RegEx
var _rtv_re_param_name: RegEx
var _rtv_re_var: RegEx
var _rtv_re_ret_value: RegEx

# Mounts previous session's archives at file-scope (before _ready) so autoloads
# that load after ModLoader can resolve their res:// paths.
# Returns a dict keyed by the archive path as it appears in pass state -- used
# by _process_mod_candidate to skip redundant re-mounts that would clobber our
# own overlay overrides applied at static init (e.g. hook pack for mod scripts).
var _filescope_mounted: Dictionary = _mount_previous_session()

# Browse-tab API response cache. Keyed by full URL (query params included so
# different searches / pages / categories are distinct entries). Per-session
# memory only -- thumbnails persist to user://mws_cache/thumbs/, but JSON
# responses don't because the install state computed on top of them is
# session-scoped (rebuilds across launches anyway). Each entry is
# {data: Variant, expires_at: int (msec)}; expired entries get evicted on
# read in _mws_cache_get.
var _mws_cache: Dictionary = {}

# 429-aware backoff state for the MWS client. When a response comes back
# 429 (or X-RateLimit-Remaining shows the guest budget spent) mws_api.gd
# sets this to the Time.get_ticks_msec() moment requests may resume; until
# then fresh network calls fail fast (the response cache above still
# serves) and callers surface mws_rate_limit_message(). 0 = no cooldown.
var _mws_cooldown_until_ms: int = 0

# Whether the most recent _mws_get_json call failed at the transport layer
# (connection refused / timeout / DNS) rather than getting an HTTP response.
# Reset at the top of every call, set true only on RESULT_SUCCESS failure.
# Lets download callers tell "you're offline" apart from a genuine HTTP 404
# ("mod has no downloadable file") so the offline copy stays honest.
var _mws_last_transport_failed: bool = false

# Last-good Browse discover landing (offline grace). Written by mws_api.gd
# after every fully-populated mws_get_popular_and_latest, both here and to
# user://mws_cache/discover_snapshot.json so it survives relaunches.
# Shape: {"data": {popular: Array, latest: Array}, "saved_at_unix": int}.
# Empty until a successful fetch stores it or mws_discover_snapshot()
# lazy-loads it from disk. Serves ONLY the discover landing when a live
# fetch fails -- filter/search responses are never snapshotted (the
# 5-minute _mws_cache above is the only cache they get).
var _mws_discover_snapshot: Dictionary = {}

# Discovered modpacks. Populated lazily by collect_modpack_metadata when
# the Modpacks tab is built. Each entry: {file_path, file_name, raw_name,
# sanitized_name, enabled_count, total_count}. See modpacks.gd.
var _modpack_entries: Array[Dictionary] = []

# Mutex flag for the modpack apply flow. Set true at the START of any apply,
# cleared in a deferred at completion. Prevents two concurrent applies (e.g.
# user clicks Apply on Modpack B while Modpack A is mid-download) from
# racing on cfg writes + the backup slot. UI also gates Apply buttons on
# this so the second click never fires the lambda in the first place.
var _modpack_apply_in_progress: bool = false
# Set true by the apply progress dialog's Cancel button. apply_modpack
# checks between downloads and bails with a "cancelled" error if set.
# Cleared at the start of every apply.
var _modpack_apply_cancelled: bool = false

# Update-check results. Keyed by profile_key, value = {latest_version,
# mw_id, full_path, mod_name}. Populated by the Updates tab's check or the
# Mods tab's check-updates affordance. Mods tab rows read this to show
# inline "update available" badges + per-row Update button without having
# to switch tabs. Survives across rebuilds (module-scope) but resets on
# launcher close. mw_id == 0 entries are not stored (nothing to fetch).
var _mod_updates_state: Dictionary = {}
var _mod_updates_check_in_progress: bool = false

# Set when an Updates-tab check changes _mod_updates_state while the Mods tab
# is off-screen; the tab_changed listener rebuilds the Mods tab on next show so
# the per-row update badges actually appear (instead of waiting for some
# unrelated action to trigger a rebuild). Cleared by that rebuild.
var _mods_badges_dirty: bool = false

# profile_keys with a badge-triggered update download in flight. A mid-download
# _rebuild_mods_tab (e.g. from a filter keystroke) re-creates the Update button
# as a fresh enabled control while the pk is still in _mod_updates_state, so
# without this guard a second click would start a duplicate concurrent download
# of the same mod. The pressed handler refuses re-entry for a pk already here,
# and the rebuilt badge renders as a disabled "Updating..." button.
var _mod_update_in_flight: Dictionary = {}

# Recursion guard for _rebuild_modpacks_tab. The rebuild does
# remove_child + add_child + move_child, all of which can fire tab_changed
# (when current_tab shifts to a sibling during remove, or when we restore
# it at the end). The tab_changed listener calls _rebuild_modpacks_tab; this
# flag breaks the cycle so a single rebuild request doesn't recurse forever.
var _rebuilding_modpacks_tab: bool = false

# Shared re-entrancy guard for ALL in-place tab rebuilds (_rebuild_mods_tab,
# _rebuild_modpacks_tab, _rebuild_updates_tab). The per-tab flag above is not
# enough: remove_child shifts current_tab to a SIBLING, so the re-entrant
# tab_changed can dispatch into a DIFFERENT rebuild helper than the one in
# flight (e.g. removing the Updates tab lands current_tab on Modpacks, which
# then calls _rebuild_modpacks_tab mid-mutation -> "Parent node is busy
# adding/removing children"). The tab_changed listener bails while this is set,
# so no rebuild can nest inside another regardless of which tab it targets.
var _rebuilding_tab_in_place: bool = false

# Mods-tab ModWorkshop meta memo. _mods_load_mws_meta runs fire-and-forget for
# every MWS row on every _rebuild_mods_tab (checkbox/filter/toggle/profile), and
# _mws_get_json caches only SUCCESSFUL parses -- so offline/404/rate-limited mods
# would refetch on every rebuild forever, each spawning a live HTTPRequest. Memo
# successes for the session; gate failed/in-flight ids behind a short retry
# window so it's at most one attempt per mod per minute regardless of churn.
var _mods_mws_meta_by_id: Dictionary = {}       # mod_id -> mod object (successes only)
var _mods_mws_meta_retry_at: Dictionary = {}    # mod_id -> ticks_msec before which not to refetch
