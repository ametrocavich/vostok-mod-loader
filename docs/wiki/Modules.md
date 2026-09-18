# Modules

A tour of the `src/` tree. The order follows the `FILES` array in `build.sh`, which is the order the files are concatenated into `modloader.gd`. Dependencies flow top-down: a const referenced by another const's initializer must come earlier, and everything shares one namespace. Function bodies can call anything anywhere. One section per file.

Links point at the file; function names are the anchors. Line numbers drift.

## Fundamentals

### [header.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/header.gd)

Ten lines: the top-of-file doc comment plus `extends Node`. This is the only `extends` in the built `modloader.gd`; `build.sh` enforces that.

### [constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)

Shared `const`, `var` and `signal` declarations: anything read by more than one file. Subsystem-local consts stay with their subsystem. Residents worth knowing:

- `MODLOADER_VERSION`, bumped by release-please between the `x-release-please-start-version` / `x-release-please-end` markers.
- The persistent paths: `UI_CONFIG_PATH`, `PASS_STATE_PATH`, `HEARTBEAT_PATH`, `PASS2_DIRTY_PATH`, `CRASH_STREAK_PATH`, the three exe-dir sentinels (`SAFE_MODE_FILE`, `DISABLED_FILE`, `DISABLED_ONCE_FILE`), `HOOK_PACK_DIR` and `VANILLA_CACHE_DIR`. `MAX_RESTART_COUNT` is 2.
- `API_CHECK_TIMEOUT`, the request timeout shared by the host transport and the loader's own update check.
- `PACK_FORMAT_V2` / `V3` / `V4` and `GDSC_VERSION_V100` / `V101`, the engine binary formats the parsers accept.
- The rewriter skip lists: `RTV_SKIP_LIST` (7 scripts), `RTV_RESOURCE_SERIALIZED_SKIP` (11), `RTV_RESOURCE_DATA_SKIP` (25), each entry with its reason inline.
- The hook registry state (`_hooks`, `_hooked_bases`, `_any_mod_hooked`, `_caller`), the host-seam response cache `_host_cache` and the live Mods-tab row nodes `_mods_meta_nodes`.

### [logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd)

`_log_info`, `_log_warning`, `_log_critical`, `_log_debug`. Each prefixes `[ModLoader][Level] `, prints or pushes, and appends to `_report_lines` through `_report_append`, which caps the buffer at `REPORT_LINES_MAX` (5000) so a per-frame logger cannot grow it forever. `_log_debug` is a no-op unless `_developer_mode` is on. Most registry verbs called by mods use `push_warning` directly and never reach the report; `scene_nodes` is the exception and logs through `_log_warning`.

## File + archive helpers

### [fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)

Disk I/O with no game logic: `.vmz` to `.zip` cache copies (`_static_vmz_to_zip`, keyed by a `.src` sidecar holding the source mtime and size), the static-init log writer, `_read_preserved_cfg_sections`, `_try_mount_pack` plus `.remap` resolution after a mount, `read_mod_config` / `_parse_mod_txt` (ConfigFile syntax with the unquoted-`[hooks]` value repair and an empty-section workaround for `[registry]`), and the folder-mod zipper `zip_folder_to_temp` with its `_folder_dev_zip_current` staleness check.

Static functions are the ones static init can call before an instance exists.

## Static-init boot layer

### [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)

Owns the boot sequence; its header comment is the short form of [Architecture](Architecture).

- `var _filescope_mounted: Dictionary = _mount_previous_session()` at the top of the file: a module-scope var with a call initializer, which is what runs static init before `_ready`.
- `_mount_previous_session`, the static-init entry point.
- Sentinel handling: `_is_modloader_disabled`, `_check_safe_mode`, the Pass 2 dirty marker branch.
- The crash streak: `_static_read_crash_streak`, `_static_write_crash_streak`, `_crash_breaker_tripped`.
- `override.cfg` reading and writing: `_write_override_cfg`, `_restore_clean_override_cfg`, `_static_reset_override_cfg`, `_static_write_cfg_atomic`, `_autoload_entry_writable`.
- Pass state: `_write_pass_state`, `_persist_hook_pack_state`, `_compute_state_hash`, `_stable_path_mtime`.
- Game-update detection: `_static_game_pck_path`, `_static_game_pck_stamp`, `_static_game_build_changed`. The executable's mtime and the PCK's mtime and size are both recorded, because a content patch can replace the PCK alone.
- Heartbeat and crash recovery: `_write_heartbeat`, `_delete_heartbeat`, `_check_crash_recovery`, `_clear_restart_counter`.
- Hook-cache wiping and orphan-pack cleanup: `_static_wipe_hook_cache`, `_static_cleanup_orphan_hook_packs`, `_static_hook_pack_path_sane`.
- Early-autoload extraction to `user://modloader_early/` (`_ensure_early_autoload_on_disk`) and `_clean_stale_cache`.

## Discovery + loading

### [security_scan.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/security_scan.gd)

Static scanner. Reads each file inside a candidate mod (`.vmz`/`.zip`, `.pck`, or a dev-mode folder) without mounting it and looks for GDScript pattern combinations that are close to diagnostic of known malware.

Not a virus scanner. It catches copy-paste droppers; someone with the loader source can write around the rules. Loading is never blocked: a red mod gets a "suspicious code" tag in the launcher, and clicking it shows what matched.

- `scan_mod` is the entry point, called from `_build_archive_entry` / `_build_folder_entry`, with a per-file cache keyed on path, mtime and size.
- 13 rules in `_SECURITY_RULES`, grouped into solo red triggers (`os_crash`, `disable_save_safety`), process-spawn, runtime-code-build and obfuscation families.
- `compute_risk_level` returns `RISK_CLEAN` (0) or `RISK_RED` (2). Red fires on a solo trigger, both obfuscation patterns together, or an obfuscation or runtime-code hit paired with a process spawn.
- `.gd` / `.tscn` / `.tres` / `.gdshader` get text scans with line comments stripped so a docstring naming an API does not trip a rule; `.scn` / `.res` / `.gdc` get byte searches.
- `.pck` mods go through `_security_pck_list_with_offsets`, a copy of `_parse_pck_file_list` that also returns offsets so blobs can be read without mounting. A pack-format-v4 file (Godot 4.7+) is refused with a message naming the exporting Godot version.

## Mod-host seam

Every network operation against a mod site goes through one function in `host_api.gd`, which dispatches on a provider id to an adapter. The types come first, then the transport, then the dispatcher, then one file per host. `check_host.sh` covers the pure parts of this layer.

### [host_types.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_types.gd)

The provider-neutral vocabulary. Provider ids (`HOST_MODWORKSHOP`, `HOST_VOSTOKMODS`), the failure codes (`HOST_ERR_OFFLINE`, `HOST_ERR_RATE_LIMITED`, `HOST_ERR_NO_FILE`, ...), the result envelope (`host_ok` / `host_err`), and the record constructors: `host_ref` / `host_ref_key` / `host_ref_from_key` for the `provider:id` grammar shared with mod.txt's `source=`, plus `host_empty_summary`, `host_empty_detail`, `host_empty_file`, `host_page`, `host_empty_caps`, `host_empty_scalars`. Every field in every record is always present with its declared type; missing data is a sentinel (`""`, `-1`, empty), never an absent key.

### [host_http.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_http.gd)

Shared HTTP transport: `_hnet_get_json` with the User-Agent, body cap, per-URL TTL cache (`_host_cache`), transport retry, and the per-provider cooldown table (`host_arm_cooldown`, `host_rate_cooldown_seconds`). A cooldown with under two seconds left is waited out inside the call; longer ones fail fast with `rate_limited`. Host-specific rate-limit header dialects stay in the adapters; `host_note_rate_headers` (in `host_api.gd`) runs the adapter and then arms the default window on a 429 that named no wait, so a file download is covered the same as a JSON call. The loader's own update check also uses this transport, under the provider id `"github"`.

### [host_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_api.gd)

The seam. `host_list_mods`, `host_get_mod`, `host_list_files`, `host_resolve_file`, `host_list_categories`, `host_latest_versions` (async) and `host_caps`, `host_display_name`, `host_mod_page_url`, `host_sorts`, `host_sections`, `host_limit`, `host_error_message` (synchronous). Dispatch is an explicit `match` on the provider, the same shape `registry.gd` uses, so the synchronous operations stay synchronous; a Callable table would turn each into a coroutine, and `host_mod_page_url` is called from code that has to return a Control. `host_providers()` lists the providers in display order (VostokMods first, so Browse opens on it); `host_browse_providers()` filters that by the `browse` capability, which is what the Browse source menu is built from. A provider with no arm in a dispatcher gets `HOST_ERR_UNWIRED` from its `_:` default. `check_host.sh` T9 reads the dispatchers off the built source and fails when a provider is missing from one, and checks each host's `page_url` and sort claims against what it builds.

### [host_mws.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_mws.gd)

ModWorkshop adapter (`_mwsp_*`). Declares the capabilities (browse, search, categories, file history, version pin, batch version check, and `sort_ignored_with_query`, since the API ignores `sort` when `query` is set and Browse re-sorts client-side), the sort menu, and the two landing sections. Normalizes the api.modworkshop.net payloads into `host_types.gd` records and reads `x-ratelimit-remaining` into the cooldown table.

### [host_vostokmods.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_vostokmods.gd)

VostokMods adapter (`_vmp_*`), the default host. Talks to `https://vostokmods.net/api` through `host_http.gd`. A mod's identity is its slug, so a ref is `host_ref("vostokmods", "<slug>")` and mod.txt declares `source="vostokmods:<slug>"`. The host scans uploads and marks unscanned or dirty versions `downloadable: false`; the adapter reports those as having no file, so Browse shows "No file yet" instead of a Download button. Listing pages are 24 rows and the search query caps at 100 characters.

### [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)

Scans `<exe>/mods/`, parses mod.txt into entry Dictionaries, orders them, and owns the host-neutral install path. No mounting; that is `mod_loading.gd`. An entry is a plain Dictionary; its fields are listed in the comment above `_entry_from_config`.

- `collect_mod_metadata` is the scanner. Accepted extensions are `vmz`, `zip`, `pck`, plus folders in dev mode; a zip with `profile.json` at its root is a modpack and goes to `modpacks.gd`.
- `_entry_from_config`, `_build_entry_warnings` and `_build_entry_author_notes` turn a mod.txt read record (`{cfg, status, error, files}`) into an entry, its row warnings (broken or misplaced mod.txt, bad autoload path) and the author notes developer mode shows (unquoted version, missing `id=`, stale bake, unrecognized source).
- Dependency handling: `_parse_dependency_list`, `_apply_dependency_ordering`, `_loadable_enabled_entries`, `_refresh_dependency_status`.
- Identity: `_dedupe_by_mod_id` and `_normalized_mod_stem`, which `check_identity.sh` covers.
- `compare_versions`, semver-ish with a `v` prefix tolerance and prerelease ordering.
- Downloads and updates: `download_mod_from_ref`, `replace_mod_from_ref`, `fetch_latest_versions` take a host ref and dispatch through the seam; `_http_download_to_temp` is the one place a response body is written to disk, under a temporary name; `_host_install_downloaded_archive` (a new install) and `replace_mod_from_ref` (an update) each validate that file and rename it into `mods/`.
- Source records: `_parse_source_token`, `_mod_source_from_cfg` (reads `source="provider:id"` and the legacy `modworkshop=<id>`, and says which one it read), `_normalize_source_record`, `_resolve_mod_source` (an explicit `source=` wins, then the stored record, then the legacy line), `_persist_mod_sources_for_entries` (the `[mod_sources]` section of `mod_config.cfg`, so a Browse download is remembered even when mod.txt says nothing). The legacy `modworkshop_id` mirror is written only when the provider is ModWorkshop.
- `_log_security_findings` writes the `[ModScan]` lines when an entry has findings.

### [modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd)

Modpack discovery, apply, unload. A modpack is a `.zip` in `<game>/mods/` with `profile.json` at its root; scan time routes it to the Modpacks tab. Packs published on VostokMods arrive through `hosted_modpacks.gd` and become the same local zips.

- An applied pack is a regular profile under the `modpack__<sanitized_name>` prefix, so profile switching, saving and MCM snapshots need no special cases. The zip is a template read on first apply, and again after a Refresh that changed it (`_modpack_forget_slot` drops the kept slot).
- Pre-apply state goes to a `_before_modpack_<sanitized_name>` profile slot plus an MCM snapshot; `[settings] active_modpack` names the single active pack.
- `apply_modpack` / `_apply_modpack_inner` download missing mods through the seam (`_get_missing_mods_for_modpack`, `retry_failed_downloads`), then `_modpack_reconcile_profile_keys` rewrites the pack's `.enabled` / `.priority` / `.dep_ignore` keys to the profile keys of the mods that actually landed. `unload_modpack` restores the backup slot.
- `_materialize_modpack_profile` is the live parser of `profile.json`. Its writer is `_hosted_manifest_to_profile` in `hosted_modpacks.gd`.


### [hosted_modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hosted_modpacks.gd)

Modpacks published on vostokmods.net. Turns a pack manifest (`GET /api/modpacks/{slug}/manifest`) into an ordinary local modpack zip so the apply path in `modpacks.gd` needs no second format. `_hosted_manifest_to_profile` builds the `profile.json` payload (mods keyed `vostokmods:<slug>`, sources pinned to the manifest version, `unavailable` and `checksums` maps, a `hosted` record with the site's change hash); `_hosted_mcm_files` writes the pack's MCM settings, merging an MCM export file into per-mod `config.ini` the way MCM's own Import does; `_hosted_pack_from_link` and `_hosted_refresh_pack` are the network entry points. The site's listing and manifest calls live in `host_vostokmods.gd` (`_vmp_list_modpacks`, `_vmp_fetch_modpack_manifest`, `_vmp_modpack_manifest_url`), called directly because packs are a VostokMods feature.
### [mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd)

The runtime loading pipeline: mounts archives, scans `.gd` files, registers file claims, queues autoloads, applies `[script_extend]` / `[script_overrides]`.

- `load_all_mods` is the entry point; `_process_mod_candidate` is the per-mod pipeline. It reads `[registry]` itself and hands the other sections to `_apply_hooks_section`, `_apply_extend_sections` and `_apply_autoload_section`. `MOD_TXT_KNOWN_SECTIONS` feeds the unrecognized-section notice.
- `_apply_script_overrides` sorts by priority (ties by declaration order), autofixes each source, compiles a fresh `GDScript`, and `take_over_path`s it onto the vanilla path. Each override's `extends` resolves to the previous occupant, so `ModB -> ModA -> vanilla` chains work.
- `scan_and_register_archive_claims` detects Windows-backslash zip paths and `Database.gd` collisions, records `_archive_zip_paths` (the readable zip for each archive, used by the hook pack's sibling pre-read), and builds the per-file analysis through `_scan_gd_source`.
- `_merge_hook_calls_into_wrap_mask` turns literal `.hook("...")` calls found in mod sources into wrap-mask entries.
- `_instantiate_autoload` handles PackedScene, GDScript and other resources.

### [conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd)

Developer-mode diagnostics. `_print_conflict_summary` and `_write_conflict_report` run from every finish path when dev mode is on. `_verify_script_overrides` runs from `_emit_frameworks_ready` regardless, loads each dynamically overridden target and logs its `resource_path` and source head at debug level (the `load()` itself matters: it populates the cache as autoloads finish). There is no automatic stale/broken classification; mod source is never rewritten, so there is no marker to test against.

## UI

### [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) and the `ui_*.gd` files

The launcher window shown before the game starts. Three tabs (Mods, Browse, Modpacks) plus the bottom bar with Launch and "Launch vanilla". Closing the window is the same as clicking Launch. Six files share the work; `build.sh` concatenates them, so every helper is reachable from every tab.

| File | Owns |
|---|---|
| `ui.gd` | `show_mod_ui` and the window chrome, `refresh_launch_button_label`, `_launch_vanilla_once`, profiles and `mod_config.cfg` I/O (`_load_ui_config`, `_save_ui_config`, `_apply_profile_to_entries`, `_switch_profile`, the MCM snapshot mechanic), the shared thumbnail cell and image loader, `_markdown_to_bbcode`, `_json_truthy`, and the loader's own update check |
| `ui_theme.gd` | The `COL_*` / `FS_*` / `SP_*` tokens (the VostokMods site palette: dark grey surfaces, one accent green, one success green, one red), `make_dark_theme`, the `style_*` voices, the badge and banner builders, the code-drawn glyphs |
| `ui_dialogs.gd` | `_attach_ui_dialog` and the dialog plumbing, `_await_dialog_choice`, the content-mod disable confirm, the New / Rename / Delete profile dialogs |
| `ui_mods.gd` | `build_mods_tab` and `_rebuild_mods_tab`, the update check (`_run_updates_check_for_mods`) and its badges, the host meta sidecar (`mods_meta_v2.json`), the security findings dialog, the row Remove confirm |
| `ui_browse.gd` | `build_browse_tab`, the per-host landing snapshots (`landing_<host>.json`), `_browse_render_mod_row`, the Browse detail dialog |
| `ui_modpacks.gd` | `build_modpacks_tab`, row rendering, the apply flow and progress dialog, the failure and retry dialogs, the pack detail dialog, the VostokMods pack picker |

- `refresh_launch_button_label` counts what will actually load, not what is checked, so a dependency-blocked mod does not promise a modded session: `"Launch modded"` when at least one enabled mod is loadable, `"Launch unmodded (%d blocked)"` when everything enabled is blocked, `"Launch"` when nothing is enabled.
- `_launch_vanilla_once` writes the `DISABLED_ONCE_FILE` sentinel, calls `_static_force_vanilla_state`, and restarts into a clean Pass 1 with `--modloader-restart` stripped. Mod checkboxes stay as they were.
- Profiles: `_load_ui_config`, `_save_ui_config`, `_apply_profile_to_entries`, `_delete_active_profile`, `_rename_profile`, with `PROFILE_SUBSECTIONS` naming the four per-profile sections (`.enabled`, `.priority`, `.settings`, `.dep_ignore`). `_load_developer_mode_setting` lives here too.
- Caches under `user://mws_cache/`: `thumbs/` for host images, `landing_<host>.json` for each host's Browse landing snapshot (`_browse_landing_snapshot_store`), `mods_meta_v2.json` for the Mods-tab detail sidecar.
- The self-update check reads the GitHub releases API for `MODLOADER_GITHUB_REPO` and shows a link to the release page.
- `_mark_mod_set_changed` flips `_dirty_since_boot` after a post-boot download, update or modpack fetch, so closing the reopened launcher restarts into the new mod set.

## Public API

### [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd)

The surface mods reach through `Engine.get_meta("RTVModLib")`: the static version accessors, `hook` / `add_hook` / `hook_many` / `unhook` / `has_hooks` / `has_replace` / `get_replace_owner` / `skip_super` / `seq`, the mod-info reads `has_mod` / `mod_info` / `loaded_mods`, and the internal `_dispatch` / `_dispatch_post` / `_dispatch_deferred` the generated wrappers call. `_emit_frameworks_ready` registers the core hooks, connects the scene-nodes listener, emits the signal and runs `_verify_script_overrides`.

See [Hooks](Hooks) for semantics.

### [registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd)

The registry verbs: `register`, `override`, `patch`, `append`, `prepend`, `remove_from`, `remove`, `revert`, their `*_many` batch forms, and the read API (`get_entry`, `has`, `keys`, `list`, `find`). Twenty-one slots in the `Registry` const: scenes, items, loot, sounds, recipes, events, trader pools, trader tasks, inputs, scene paths, shelters, maps, random scenes, AI types, fish species, resources, scene nodes, AI loadouts, and the aggregator slots weapons, magazines and attachments. [Registry](Registry) has the per-slot semantics.

`registry.gd` owns only the dispatchers, the `Registry` const and the rollback dicts (`_registry_registered`, `_registry_overridden`, `_registry_patched`). The handlers live in `src/registry/`:

| File | Slots |
|---|---|
| `shared.gd` | Helpers used by more than one handler |
| `scenes.gd` | `scenes`: writes into the dicts the rewriter injects into `Database.gd` |
| `items.gd` | `items`: ItemData kept in the registry's own dict keyed by `file` |
| `loot.gd` | `loot`: mutates `items` on loaded LootTable resources |
| `sounds.gd` | `sounds`: AudioLibrary entries |
| `recipes.gd` | `recipes`: the seven category arrays in `Recipes.tres` |
| `events.gd` | `events`: the `events` array in `Events.tres` |
| `traders.gd` | `trader_pools`, `trader_tasks` |
| `inputs.gd` | `inputs`: InputMap actions with a default binding |
| `loader.gd` | `scene_paths`, `shelters`, `maps`, `random_scenes`: state on the Loader autoload |
| `ai.gd` | `ai_types`: zone to agent-scene overrides read by the injected `_rtv_resolve_ai_type` |
| `ai_loadouts.gd` | `ai_loadouts`: weapon injection through the `AI.SelectWeapon` prelude |
| `fish.gd` | `fish_species`: appended by the `FishPool._ready` prelude |
| `resources.gd` | `resources`: patch/revert on any vanilla `.tres` by path |
| `scene_nodes.gd` | `scene_nodes`: patch node properties inside vanilla scenes via `node_added` |
| `aggregators.gd` | `weapons`, `magazines`, `attachments`, plus `register_item` / `register_furniture` bundles that fan out to the primitive slots |

Adding a slot takes a `Registry.FOO` constant, a match arm in each dispatcher (`register`, `override`, `patch`, `_array_op_dispatch`, `remove`, `revert`, `get_entry`, `_enumerate_vanilla`), a new `src/registry/foo.gd`, and a `build.sh` FILES entry. [CONTRIBUTING.md](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md) has the checklist.

The vanilla-backed slots depend on the rewriter injecting code into the six `REGISTRY_TARGETS` in `hook_pack.gd`: `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd`, `Compiler.gd`. Those wraps happen only when at least one mod declares `[registry]` in its mod.txt. Without that, `scenes.gd` and the scene-paths handler in `loader.gd` check for the injected fields and `push_warning` with a `[registry]` hint; `ai.gd`, `ai_loadouts.gd` and `fish.gd` write Engine meta that nothing reads (register returns true, the override is invisible); shelters and maps in `loader.gd` need the rewriter to turn vanilla's `const shelters` into a `var` and to inject `_rtv_mod_shelters`. [Registry#opting-in](Registry#opting-in) is the user-facing version.

Slots that keep state in the registry's own dicts or mutate a plain vanilla `var` (items, loot, recipes, events, sounds, inputs, trader pools and tasks, random scenes, resources, scene nodes) work without any vanilla rewrite. `scene_nodes` subscribes to `SceneTree.node_added` at `frameworks_ready` and patches live instances.

Limitation: direct constant access (`Database.Potato`) bypasses the injected `_get()`. Mods must call `Database.get("Potato")` to reach the registry.

### [setup.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/setup.gd)

`lib.setup(plan)`, the declarative install entry point. A plan is an Array of `[verb, ...args]` entries applied in order, so register-then-patch reads naturally. Each entry maps to a public verb (`register`, `override`, `patch`, `append`, `prepend`, `remove_from`, `revert`, `remove`, `hooks`, the aggregator verbs) plus the meta verb `when` for conditional sub-plans. It sits after the registry handlers in `build.sh` because it binds the `*_many` verbs and `hook_many`. See [Setup-Plans](Setup-Plans).

### [framework_wrappers.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/framework_wrappers.gd)

One function, `_rtv_collect_nodes_by_class`: a scene-tree walk that finds nodes whose script, or any ancestor in its `extends` chain, carries a given `class_name`. Used by the dev-mode IXP-VERIFY probe in `debug.gd`. The name is left over from the extends-wrapper pipeline (`[rtvmodlib] needs=`, generated `Framework<X>.gd` subclasses, `node_added` swaps) that v3.0.1 removed.

## Codegen pipeline

### [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd)

Reads Godot's binary-tokenized `.gdc` scripts and reconstructs source, since `load().source_code` is empty for tokenized scripts. Handles TOKENIZER_VERSION 100 (Godot 4.3-4.4) and 101 (Godot 4.5-4.6), normalizing the v100 token indices that sit one below the v101 table from index 83 up.

Also owns the vanilla-source cache under `user://modloader_hooks/vanilla/` (`_read_vanilla_source`, `_save_vanilla_source`) and the canary B probe `_probe_gdsc_version`. Nothing in this file calls `load()`: any `load()` would make `ResourceFormatLoaderGDScript` cache the PCK's tokenized result at the path the hook pack later needs to win.

`check_detok.sh` covers it. See [GDSC-Detokenizer](GDSC-Detokenizer) for the format.

### [pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd)

PCK introspection. `DirAccess.get_files_at()` returns at most one entry for PCK-backed paths in Godot 4.6, so the file table of `RTV.pck` is parsed directly.

- `_build_class_name_lookup` loads `res://.godot/global_script_class_cache.cfg` and falls back to the 58-entry `_get_hardcoded_class_map` when the cache is missing or a mounted mod has shadowed it with a tiny one (fewer than 10 entries).
- `_enumerate_game_scripts` parses the PCK (`_parse_pck_file_list`, pack formats v2 and v3; v4 is refused with a message naming the exporting Godot version), canonicalizes `.gdc` and `.remap` entries to `.gd`, keeps `res://Scripts/`, records zero-byte entries in `_pck_zero_byte_paths` (RTV 4.6.1 ships an empty `CasettePlayer.gd`), and caches the list in `user://modloader_hooks/script_index.txt` stamped with the exe mtime and the PCK stamp.
- `_collect_module_scope_scene_preloads` finds column-0 `preload("res://...tscn|.scn")` lines, which decide which rewritten scripts are deferred from eager compile.

### rewriter_*.gd

Source-rewrite codegen for the vanilla scripts in the opt-in wrap surface. Four files, formerly one `rewriter.gd`:

| File | Owns |
|---|---|
| [rewriter_parse.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_parse.gd) | Regex compilation (`_compile_regex`, `_rtv_compile_codegen_regex`), signature scanning, parameter splitting, `_rtv_parse_script`. Its header carries the pipeline map and the recipe for adding a rewrite target |
| [rewriter_rewrite.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_rewrite.gd) | `_rtv_rewrite_vanilla_source`, the orchestrator; `_rewrite_bare_super`; `_detect_indent_style`; the wrapper emitter `_rtv_dispatch_inline_src` |
| [rewriter_registry_inject.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_registry_inject.gd) | The per-script transforms: `Database.gd` and `Loader.gd` declaration rewrites, the preludes for `Loader.LoadScene`, `FishPool._ready`, `Compiler.Spawn` and `AI.SelectWeapon`, the `AISpawner.gd` agent-assignment rewrite, and the registry appendices |
| [rewriter_autofix.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_autofix.gd) | `_rtv_autofix_legacy_syntax` (bodyless blocks, `tool` / `onready` / `export`, `base()`), `_rtv_strip_helper_reload` |

Given detokenized vanilla source, a parse structure and a per-method mask, the rewriter:

- Renames each non-static method in the mask from `Foo` to `_rtv_vanilla_Foo`.
- Appends a dispatch wrapper at the original name that runs pre, replace, post and callback hooks around the renamed body. The wrapper awaits the vanilla body only when that body is itself a coroutine; `check.sh` greps the templates for a literal `await` and `check_codegen.sh` compiles the output to keep it that way.
- Rewrites bare `super()` inside renamed bodies to `super.<orig_name>()` so the parent's wrapper resolves.
- Repairs Godot 3 syntax: a `pass` for bodyless blocks, `@tool` / `@onready var` / `@export var`, `base(args)` to `super.<enclosing>(args)`.
- Applies the registry transforms: `Database.gd` gets its `const X = preload(...)` lines rewritten into a `_rtv_vanilla_scenes` dict plus `_rtv_mod_scenes` / `_rtv_override_scenes` and a `_get()`; `Loader.gd` gets `shelters` rewritten `const` to `var` with a snapshot, the `_rtv_mod_scene_paths` / `_rtv_override_scene_paths` / `_rtv_mod_shelters` dicts and a `LoadScene` prelude; `AISpawner.gd` gets each `agent = <Name>` routed through `_rtv_resolve_ai_type`, reading `Engine.get_meta("_rtv_ai_overrides")`; `AI.gd` gets a `SelectWeapon` prelude reading `_rtv_ai_loadouts`; `FishPool.gd` gets a `_ready` prelude reading `_rtv_fish_species`; `Compiler.gd` gets a `Spawn` prelude for shelters and maps. `REGISTRY_EXPECTED_MARKERS` in `hook_pack.gd` checks that each transform actually landed.

Mod sources are not rewritten. A mod script that extends a wrapped vanilla sees the wrapper as its parent method through Godot's own resolution, so `super.foo(...)` lands on the wrapper.

### [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)

`_generate_hook_pack` runs the pipeline end to end, as six functions in order: `_hook_pack_preflight` (steps 1 to 4), `_hook_pack_script_paths`, `_hook_pack_wrap_surface` (5 and 6), `_hook_pack_collect_siblings` (7), `_hook_pack_write_zip` (8 to 10) and `_hook_pack_mount_and_activate` (11).

1. Clear `_scripts_with_scene_preloads`, pick a fresh `user://modloader_hooks/framework_pack_<ticks>.zip` name (a same-path remount is a no-op in Godot, and Windows will not let a mounted zip be deleted).
2. Canary B: `_probe_gdsc_version` must return 100, 101 or -1.
3. Return with no pack when no mods are loaded.
4. Canary C: `_canary_detokenizer_roundtrip_ok`.
5. `_seed_core_hooks` adds the `Menu.gd :: _ready` wrap for the main-menu button. If no user mod declared `[hooks]`, `.hook()` or `[registry]`, log the "No user opt-in declarations" line and carry on with that one core wrap.
6. Build the wrap mask from `_hooked_methods` (per method) and, when any mod declared `[registry]`, the six `REGISTRY_TARGETS` (whole script). Every declared target gets a reconciliation ledger entry.
7. Pre-read mod sibling scripts from their archives before `ZIPPacker.open`, which would invalidate the previous session's VFS handle to the old pack.
8. For each vanilla script in the mask: skip lists win (with a warning naming the declaring mod), zero-byte entries are skipped, a `[script_extend]` / `[script_overrides]` claimant at the same path is warned about (the rewrite wins), then detokenize, parse, rewrite, verify the renames and registry markers, and write three zip entries: `Scripts/<Name>.gd`, `Scripts/<Name>.gd.remap` (self-referencing, beats the PCK's remap to `.gdc`) and an empty `Scripts/<Name>.gdc`.
9. Pack the autofixed siblings, then the VFS canary file.
10. `_log_hook_reconciliation`: one info line when every declared target made it, a critical block per lost target otherwise.
11. With `defer_activation`, persist the pack path and stop. Otherwise mount with `replace_files=true`, read the canary back, and call `_activate_rewritten_scripts`.

`_activate_rewritten_scripts` defers scripts with module-scope scene preloads to lazy compile (with a 60-second DEFER-VERIFY watchdog), and for the rest checks whether static init already preempted the script, then falls back to `source_code + reload()` and finally `CACHE_MODE_IGNORE + take_over_path`. It warns again when it displaces a mod's replacement script, persists `hook_pack_path` and `hook_pack_wrapped_paths`, runs the canary A compile proof for every player, and in dev mode hands off to `_dev_preactivate_summary` and `_dev_hook_probes` in `debug.gd`. See [Stability-Canaries](Stability-Canaries) and [Developer-Mode](Developer-Mode).

## Orchestration


### [hook_status.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_status.gd)

The hook system's last outcome, written where the launcher can read it (`user://modloader_hook_status.json`). Generation and activation run after the launcher closes, so without this a game update that breaks the rewriter is visible only in the log. `_hook_status_write` is called from the canary B and C stops, the no-mods short-circuit, the pack write, mount and VFS-canary failures, and the end of activation; `_hook_status_problem` turns the record (and the static-init `modloader_game_updated` marker) into the banner `build_mods_tab` shows. Records from another loader version or another game build (executable mtime or PCK stamp) are ignored.
### [lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd)

`_ready` clears the one-shot vanilla sentinel or dispatches to `_run_pass_1` / `_run_pass_2`. `_modloader_restart` is the shared relaunch helper (keeps the Steam rendering flags, forwards user args). `reopen_mod_ui` is the post-boot entry from the main-menu button; it restarts into a clean Pass 1 when the session is dirty. Every boot path ends in `_finish_boot`, which registers the meta, generates the pack, instantiates queued autoloads, run the dev-mode diagnostics, emits `frameworks_ready`, clears the heartbeat and the streak, and reloads the current scene when asked; `_finish_with_existing_mounts` and `_finish_single_pass` are the Pass 1 entries that pick the reload rule, and Pass 2 calls it directly. See [Architecture](Architecture).

### [main_menu_hook.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/main_menu_hook.gd)

Injects a "Mods" button into RTV's main menu (`res://Scripts/Menu.gd`) so the launcher can be reopened without restarting. It uses the same machinery mods use:

- `_seed_core_hooks` puts `_ready` into `_hooked_methods["res://Scripts/Menu.gd"]` so the rewriter wraps it even when no mod asked. Called from `_hook_pack_wrap_surface`, which runs after the no-mods short-circuit in `_hook_pack_preflight`, so every generated pack includes the wrap and a pure-vanilla session generates nothing.
- `_register_core_hooks` subscribes `_on_menu_ready` to `menu-_ready-post` through the public `hook()`, from `_emit_frameworks_ready`.
- `_inject_mods_button` finds `Main/Buttons` on the menu root, inserts a button named `MetroMods` above `Quit`, and wires `pressed` to `reopen_mod_ui`.

Mutations to `mod_config.cfg` while the reopened launcher is open flip `_dirty_since_boot`; on close the loader restarts into a clean Pass 1.

## Developer probes and test scaffolding

### [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd)

`_dev_preactivate_summary` and `_dev_hook_probes` are the developer-mode probes `_activate_rewritten_scripts` runs: the pre-activation classification, the eight live hooks, AUTOLOAD-CHECK, the registry smoke probe, IXP-VERIFY and the 30-second report timer ([Developer-Mode](Developer-Mode) lists them). The rest is gated behind `[settings] test_pack_precedence = true` in `user://mod_config.cfg`; the default config has no such key. `_load_test_pack_flag` is static so `boot.gd` can read it at static init. `_test_pack_precedence` (Pass 1, before the restart) exercises pack-over-bytecode precedence for `Controller.gd`; `_test_pack_reapply` (Pass 2, from `_finish_boot`) mounts the pack again from a fresh copy after the re-mounts; `_test_post_autoload_verify` runs one second after the autoloads and reports what took over the path.
