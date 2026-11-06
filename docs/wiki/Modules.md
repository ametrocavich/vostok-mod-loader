# Modules

One row per file in `src/`, grouped as `build.sh` assembles them
(`./build.sh --list` prints the order). Every file is a fragment of one class,
so a constant read by another constant's initializer must come earlier; function
bodies call across files freely. [Development](Development) maps tasks to
files and [Architecture](Architecture) walks the boot.

## Fundamentals and archives

| File | Responsibility |
|---|---|
| [header.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/header.gd) | The file comment and the single `extends Node` of the built loader. |
| [constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd) | Shared constants, persistent-file paths, the rewriter skip lists, `MODLOADER_VERSION` and module-scope state. |
| [logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd) | The four loggers; they also feed the developer-mode conflict report. |
| [fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd) | Disk I/O without game logic: `.vmz` cache copies, `mod.txt` parsing, pack mounting, folder-mod zipping. |

## Boot

| File | Responsibility |
|---|---|
| [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) | Static init: mounts the previous session's archives and hook pack before `_ready`, and resets `override.cfg` when that state is stale. |
| [pass_state.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pass_state.gd) | What Pass 1 hands the restarted process: `override.cfg`, pass state, the state hash, extracted early autoloads. |
| [crash_recovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/crash_recovery.gd) | The crash streak and its breaker, the heartbeat, safe mode and the launcher's crash notice. |
| [cache_cleanup.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/cache_cleanup.gd) | Launch-time housekeeping: interrupted downloads, orphaned cache zips, retired `user://` state. |

## Mod hosts

Every network call to a mod site goes through `host_api.gd`, which dispatches
on the provider id to one adapter per host.

| File | Responsibility |
|---|---|
| [host_types.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_types.gd) | Provider ids, failure codes and the provider-neutral records; every field is always present. |
| [host_http.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_http.gd) | The one GET, its response cache and the per-provider cooldown table. |
| [host_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_api.gd) | The seam: one `match` per operation, and the filter that hides the loader's own listing. |
| [host_mws.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_mws.gd) | ModWorkshop adapter. |
| [host_vostokmods.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/host_vostokmods.gd) | Vostok Mods adapter, the default host; a mod is addressed by slug or UUID. |

## Mods, packs and loading

| File | Responsibility |
|---|---|
| [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd) | Scans the mods folder, without mounting, into the launcher's entry dictionaries with their row warnings and author notes. |
| [mod_dependencies.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_dependencies.gd) | Dependency declarations, readiness and the one load order the launcher, loading and boot share. |
| [mod_identity.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_identity.gd) | Mod identity, version comparison and which duplicate survives. |
| [mod_downloads.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_downloads.gd) | Downloads and updates of mod archives, entered through `download_mod_from_ref` and `replace_mod_from_ref`. |
| [mod_sources.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_sources.gd) | Where each installed mod came from: the source record, its precedence and its copies on disk. |
| [modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd) | Local modpacks: discovery, apply, unload and the managed profile slots ([Profile-Format](Profile-Format)). |
| [hosted_modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hosted_modpacks.gd) | Turns a Vostok Mods pack manifest into an ordinary local pack zip. |
| [mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) | Runtime loading: mounts archives, scans their scripts, registers file claims, queues autoloads and script overrides. |
| [conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd) | Developer-mode override checks, the console conflict summary and the report file. |

## Profiles and launcher

| File | Responsibility |
|---|---|
| [profiles.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profiles.gd) | Profile selection and `mod_config.cfg` persistence. |
| [profile_snapshots.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profile_snapshots.gd) | Per-profile MCM snapshots and the swap at restart. |
| [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) | The launcher window, its tabs, scaling and the launch buttons (`show_mod_ui`). |
| [ui_images.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_images.gd) | Thumbnail cells, image decoding and the texture caches. |
| [ui_format.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_format.gd) | Ages, sizes, timestamps and the Markdown-to-BBCode converter. |
| [loader_update.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/loader_update.gd) | The loader's own release check and its notice. |
| [ui_theme.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_theme.gd) | Color and size tokens, the Theme, the `style_*` helpers and the code-drawn glyphs. |
| [ui_dialogs.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_dialogs.gd) | Dialog plumbing shared by every tab, and the profile dialogs. |
| [ui_mods.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods.gd) | The Mods tab: banners, toolbar, filters, update and missing sections, load-order preview. |
| [ui_mods_rows.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods_rows.gd) | One installed-mod row: checkbox, thumbnail, dependency lines, load order, Remove. |
| [ui_mods_metadata.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods_metadata.gd) | Host thumbnails and authors on Mods rows: session memo, disk sidecar and fetch queue. |
| [mod_updates.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_updates.gd) | Update checks for installed mods and the state the Mods tab reads. |
| [ui_browse.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_browse.gd) | The Browse tab: the Mods/Modpacks switch, listings, offline landing snapshots, the detail dialog and the download queue. |
| [ui_modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_modpacks.gd) | Modpacks: the Your packs rows, the apply flow and its dialogs, and the Vostok Mods pack list Browse shows. |

## Mod API and registry

[Hooks](Hooks) and [Registry](Registry) are the contracts; adding a registry
section is in [Development](Development#adding-a-registry-section).

| File | Responsibility |
|---|---|
| [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd) | What mods reach through `Engine.get_meta("RTVModLib")`: hooks, versions, mod queries, and the dispatch the generated wrappers call. |
| [registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd) | The `Registry` const, the rollback dicts, the verbs and their `*_many` forms, the read API. |
| [registry/shared.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/shared.gd) | Helpers used by more than one section handler. |
| [registry/scenes.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/scenes.gd) | `scenes`: the mod and override dicts injected into `Database.gd`. |
| [registry/items.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/items.gd) | `items`: ItemData keyed by `file`. |
| [registry/loot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/loot.gd) | `loot`: entries in a LootTable's `items`, by table name or path. |
| [registry/sounds.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/sounds.gd) | `sounds`: fields of `AudioLibrary.tres`. |
| [registry/recipes.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/recipes.gd) | `recipes`: the seven category arrays of `Recipes.tres`. |
| [registry/events.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/events.gd) | `events`: the array in `Events.tres`. |
| [registry/traders.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/traders.gd) | `trader_pools` and `trader_tasks`. |
| [registry/array_entries.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/array_entries.gd) | The shared verbs of the array-backed sections (`recipes`, `events`, `trader_tasks`, `loot`). |
| [registry/inputs.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/inputs.gd) | `inputs`: InputMap actions with a default binding. |
| [registry/loader.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/loader.gd) | `scene_paths`, `shelters`, `maps`, `random_scenes`: state on the Loader autoload. |
| [registry/ai.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/ai.gd) | `ai_types`: one enemy scene per spawner zone. |
| [registry/ai_loadouts.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/ai_loadouts.gd) | `ai_loadouts`: weapons added to an AI before it picks one. |
| [registry/fish.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/fish.gd) | `fish_species`: species appended to a fish pool. |
| [registry/resources.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/resources.gd) | `resources`: field patches on any vanilla `.tres`. |
| [registry/scene_nodes.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/scene_nodes.gd) | `scene_nodes`: property patches on vanilla scene nodes as they enter the tree. |
| [registry/aggregators.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/aggregators.gd) | `weapons`, `magazines`, `attachments` and the item and furniture bundles that fan out to the sections above. |
| [setup.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/setup.gd) | `lib.setup(plan)`, the declarative form ([Setup-Plans](Setup-Plans)). |

## Codegen and the hook pack

| File | Responsibility |
|---|---|
| [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd) | Source from the game's tokenized `.gdc` scripts, and the vanilla-source cache ([GDSC-Detokenizer](GDSC-Detokenizer)). |
| [pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) | The game's script list read from the PCK file table, and the vanilla `class_name` map. |
| [rewriter_parse.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_parse.gd) | Parses detokenized source: declarations and, per method, whether it awaits or returns a value. |
| [rewriter_rewrite.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_rewrite.gd) | Renames each hooked method to `_rtv_vanilla_<name>` and appends its dispatch wrapper. |
| [rewriter_registry_inject.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_registry_inject.gd) | Registry code per target script: declaration transforms, preludes and appendices. |
| [rewriter_text.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_text.gd) | The string- and comment-aware source mask. |
| [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) | Builds, probe-compiles, mounts and activates the hook pack (`_generate_hook_pack`); mod scripts never enter it. |
| [hook_status.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_status.gd) | The last session's hook outcome, read by the next launcher's banner. |

## Orchestration

| File | Responsibility |
|---|---|
| [lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd) | `_ready`: Pass 1 or Pass 2, the restarts and the reopened launcher; every path ends in `_finish_boot`. |
| [main_menu_hook.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/main_menu_hook.gd) | The main menu's Mods button, wired through the same post hook mods use. |
| [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd) | Developer-mode probes run after activation ([Developer-Mode](Developer-Mode)). |
