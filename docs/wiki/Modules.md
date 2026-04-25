# Modules

Tour of the `src/` tree. Order follows `build.sh`'s `FILES` array, which is the concat order used to produce `modloader.gd`. Dependencies flow top-down -- earlier files may not reference code defined later.

## Fundamentals

### [header.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/header.gd)

10 lines. Top-of-file doc comment plus `extends Node`. This is the only `extends` in the compiled `modloader.gd` -- `build.sh` enforces that invariant.

### [constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)

All module-scope `const`, `var`, and `signal` declarations. Everything has to land here so it's declared before any function body references it. Notable residents:

- `MODLOADER_VERSION` at [constants.gd:13](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L13) -- release-please bumps this via Conventional Commits, bracketed by `x-release-please-start/end` markers
- `RTV_SKIP_LIST` (7 scripts), `RTV_RESOURCE_SERIALIZED_SKIP` (11), `RTV_RESOURCE_DATA_SKIP` (25) -- scripts the rewriter refuses to touch, each with inline rationale
- `_filescope_mounted := _mount_previous_session()` at [constants.gd:198](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L198) -- a module-scope var with a function-call initializer. This is what triggers the static-init mount before `_ready`

### [logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd)

Four helpers: `_log_info`, `_log_warning`, `_log_critical`, `_log_debug`. Each prefixes `[ModLoader][Level] ` and appends to `_report_lines` (later written to `user://modloader_conflicts.txt`). `_log_debug` is gated on `_developer_mode`.

## File + archive helpers

### [fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)

Pure disk I/O. No game logic. VMZ-to-ZIP conversion, mod.txt parsing, zip packing for dev-mode folder mods, `.remap` resolution post-mount, path normalization for tracked extensions.

Includes both static functions (callable from static init before instance state exists) and instance functions.

## Static-init boot layer

### [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)

The largest domain. Owns:

- `_mount_previous_session` at [boot.gd:32](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L32) -- the static-init entry point triggered by `constants.gd:198`
- Sentinel handling (disabled, safe mode, Pass 2 dirty marker)
- `override.cfg` reading + writing (`_write_override_cfg`, `_restore_clean_override_cfg`)
- Pass state persistence (`_write_pass_state`, `_compute_state_hash`)
- Heartbeat + crash-recovery logic
- Hook-cache wiping
- Early-autoload disk extraction (`_ensure_early_autoload_on_disk`)
- Stale cache cleanup

See [Architecture](Architecture) for the control flow.

## Discovery + loading

### [security_scan.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/security_scan.gd)

Lightweight static scanner. Reads each file inside a candidate mod (`.vmz`/`.zip`, `.pck`, or developer-mode folder) WITHOUT mounting it and looks for combinations of GDScript patterns that are nearly diagnostic of known malware.

Not a virus scanner. Catches lazy / copy-paste attacks (the dropper screenshot that motivated this branch); a determined attacker with the modloader source can write around the rules. Loading is never blocked. The launcher shows a "suspicious code" tag on flagged mods and pops a confirmation dialog at Launch time.

- `scan_mod` -- top-level entry called from `_build_archive_entry` / `_build_folder_entry`
- 13 rules grouped into solo red triggers (`os_crash`, `disable_save_safety`), process-spawn, runtime-code-build, and obfuscation families
- `compute_risk_level` returns `RISK_CLEAN` (0) or `RISK_RED` (2). Red fires on solo triggers, both obfuscation patterns together, or any obfuscation/runtime-code paired with a process spawn
- `.gd` / `.tscn` / `.tres` / `.gdshader` get full text scans (with GDScript line-comment stripping so docstrings mentioning API names don't false-positive); `.scn` / `.res` / `.gdc` get byte-search for binary-safe rule patterns
- `.pck` mods scanned via local `_security_pck_list_with_offsets` that mirrors `pck_enumeration._parse_pck_file_list` but also returns offsets so individual blobs can be extracted without mounting

### [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)

Scans `<exe>/mods/`, parses mod.txt metadata, handles ModWorkshop version checks and downloads. No mounting -- that's `mod_loading`.

- `collect_mod_metadata` at [mod_discovery.gd:7](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L7) -- the main scanner
- `compare_versions` -- semver-ish with `v` prefix tolerance
- `fetch_latest_modworkshop_versions` / `download_and_replace_mod` -- chunked HTTP against `api.modworkshop.net`
- `_log_security_findings` -- emits `[ModScan]` summary + per-rule lines to the boot log when `entry["security_findings"]` is non-empty

### [mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd)

Runtime loading pipeline. Mounts archives, scans .gd files for safety issues, registers file-claims, instantiates autoloads, applies `[script_overrides]`.

- `load_all_mods` at [mod_loading.gd:7](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L7) -- entry point
- `_process_mod_candidate` at [mod_loading.gd:95](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L95) -- per-mod pipeline
- `_apply_script_overrides` at [mod_loading.gd:298](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L298) -- sorts by priority asc, `load` + `source_code` + fresh `GDScript.new()` + `reload` + `take_over_path`
- `scan_and_register_archive_claims` -- detects Windows-backslash zip paths, Database.gd collisions, builds per-file analysis
- `_instantiate_autoload` -- dispatches PackedScene vs GDScript vs other

### [conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd)

Developer-mode diagnostics. Most functions only run when `_developer_mode = true`, except `_print_conflict_summary` + `_write_conflict_report` which always run but filter logs.

Override verification:

- **`_verify_script_overrides`** at [conflict_report.gd:35](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L35): loads each declared override target post-autoloads and logs `resource_path` + source head. Operators read the heads to verify `take_over_path` landed. The v3.0.0 method-prefix classifier (Layer A/B, AutoloadInstanceProbe auto-swap, tree-walk fallback) was removed with Step C since there's no longer a `_rtv_mod_` in-source signal to classify against

## UI

### [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd)

Pre-game launcher window. Two tabs (Mods, Updates), dark theme, Reset-to-Vanilla action. Closing the window equals clicking Launch Game.

- `show_mod_ui` at [ui.gd:930](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L930)
- `build_mods_tab` / `build_updates_tab` -- tab content
- `make_dark_theme` -- Theme resource with pure-black backgrounds
- `refresh_launch_button_label` at [ui.gd:1063](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L1063) -- pessimistic label: switches between `"Launch with Mods (Restart)"` and `"Launch Unmodded"` depending on whether any enabled mod exists. Called on init, per-checkbox toggle, and profile/dev-mode tab rebuilds. Over-warns in the rare hash-match no-restart case
- `_reset_to_vanilla_and_restart` at [ui.gd:479](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L479) -- unchecks every mod, calls `_static_force_vanilla_state`, strips `--modloader-restart` from cmdline so the relaunch is a clean Pass 1

## Public API

### [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd)

The public surface mods call via `Engine.get_meta("RTVModLib")`. Version accessors, `hook`/`unhook`/`has_hooks`/`has_replace`/`get_replace_owner`/`skip_super`/`seq`, plus the internal `_dispatch` / `_dispatch_deferred` helpers used by generated wrappers.

See [Hooks](Hooks) for the full API + semantics.

### [registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd)

Public registry verbs: `register`, `override`, `patch`, `remove`, `revert`, plus the `get_entry` read API. Sixteen registry slots as of 3.1.1: scenes, items, loot, sounds, recipes, events, trader pools, trader tasks, inputs, scene paths, shelters, random scenes, AI types, fish species, resources, and scene nodes. See [Registry](Registry) for per-slot semantics.

`registry.gd` itself owns only the public verb dispatchers + the `Registry` const + shared rollback dicts (`_registry_registered`, `_registry_overridden`, `_registry_patched`). Per-slot handlers live in [src/registry/](https://github.com/ametrocavich/vostok-mod-loader/tree/development/src/registry) as 13 handler files (one file per topic -- `traders.gd` covers TRADER_POOLS + TRADER_TASKS, `loader.gd` covers SCENE_PATHS + SHELTERS + RANDOM_SCENES, everything else maps 1:1) plus `shared.gd` for helpers used across handlers. Adding a new slot is three edits: a `Registry.FOO` constant, a match arm per verb in this file, and a new `src/registry/foo.gd` with the handlers.

Vanilla-backed slots (scenes, scene_paths, ai_types, fish_species, shelters, random_scenes) rely on the rewriter injecting machinery into `Database.gd`, `Loader.gd`, `AISpawner.gd`, and `FishPool.gd` -- the list in `REGISTRY_TARGETS` at [hook_pack.gd:20](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L20). Those injections are gated on at least one mod declaring `[registry]` in its `mod.txt`. Without the declaration the whole-script wrap is skipped, and handlers degrade differently: `scenes.gd` and scene_paths in `loader.gd` explicitly check for the injected fields and `push_warning` with a `[registry]` hint; `ai.gd` and `fish.gd` broadcast via `Engine.set_meta` that the missing rewriter-injected resolver/prelude never reads (register returns true, override invisible); shelters and random_scenes in `loader.gd` rely on the rewriter's `const`->`var` capture snapshot for revert -- without it, revert semantics are undefined. See [Registry#opting-in](Registry#opting-in) for the user-facing version of this matrix.

Slots that track state in the registry's own internal dicts (items, loot, recipes, events, sounds, inputs, trader_pools, trader_tasks, resources, scene_nodes) don't depend on vanilla rewrites to function -- `scene_nodes` specifically subscribes to `SceneTree.node_added` at `frameworks_ready` and patches live instances directly.

**Limitation**: direct constant access (`Database.Potato`) bypasses the injected `_get()` override. Mods must use `Database.get("Potato")` to hit the registry.

### [framework_wrappers.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/framework_wrappers.gd)

Single-function file containing `_rtv_collect_nodes_by_class` -- a scene-tree walker that finds nodes whose attached script (or any ancestor in its `extends` chain) carries a given `class_name`. Used by hook_pack.gd's post-apply verification.

The legacy extends-wrapper pipeline (`[rtvmodlib] needs=` -> `Framework<X>.gd` subclass generation -> `node_added` swap / `_activate_hooked_scripts` / `_register_override` / `_connect_node_swap` / `_on_node_added` / `_deferred_swap`) was removed in v3.0.1 -- dead code under the source-rewrite model.

## Codegen pipeline

### [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd)

Reads Godot's binary-tokenized `.gdc` scripts and reconstructs source. Required because `load().source_code` is empty for tokenized scripts. Covers TOKENIZER_VERSION 100 (Godot 4.0-4.4) and 101 (Godot 4.5-4.6).

Also owns the vanilla-source cache under `user://modloader_hooks/vanilla/` -- the cache is cold until the hook pack is mounted, to prevent `ResourceFormatLoaderGDScript` from caching the PCK's tokenized result at the rewrite path.

See [GDSC-Detokenizer](GDSC-Detokenizer) for the binary format.

### [pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd)

PCK introspection. Parses the game's `RTV.pck` file table to enumerate every `res://Scripts/*.gd` -- `DirAccess.get_files_at()` returns 0-1 entries for PCK-backed paths in Godot 4.6.

- `_build_class_name_lookup` -- loads `res://.godot/global_script_class_cache.cfg`, falls back to a 58-entry hardcoded map if the cache is missing or shadowed by a mod that ships its own 1-entry cache
- `_enumerate_game_scripts` -- parses PCK, normalizes `.gdc` / `.gd.remap` to `.gd`, filters to `res://Scripts/`, tracks zero-byte entries into `_pck_zero_byte_paths` (base game ships e.g. empty `CasettePlayer.gd` in RTV 4.6.1)
- `_collect_module_scope_scene_preloads` -- column-0 `preload("res://...tscn|.scn")` matches, used to decide which rewritten scripts get deferred from eager compile

### [rewriter.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd)

Source-rewrite codegen for vanilla scripts in the opt-in wrap surface. Given detokenized vanilla source + a parse structure + a per-method wrap mask:

- Renames each non-static method in the mask from `Foo` to `_rtv_vanilla_Foo`
- Appends a dispatch wrapper at the original name that fires pre/replace/post/callback hooks then calls the renamed body
- Rewrites bare `super()` inside renamed bodies to `super.<orig_name>()` so the parent's dispatch wrapper resolves (Gotcha in Limitations)
- Autofixes legacy GDScript 3 syntax: bodyless blocks get a `pass`, `tool`/`onready var`/`export var` get the `@` annotation, `base(args)` -> `super.<enclosing>(args)`, `base().method(x)` -> `super.method(x)`
- Per-script transforms for registry targets: `Database.gd` gets `const X = preload(...)` rewritten to `_rtv_vanilla_scenes` dict entries + `_get()` injection; `Loader.gd` gets `const shelters` rewritten to `var` with a capture snapshot + `_rtv_mod_scene_paths`/`_rtv_override_scene_paths` dict injection; `AISpawner.gd` gets `agent = <Name>` assignments routed through a `_rtv_resolve_ai_type` lookup helper that reads `Engine.get_meta("_rtv_ai_overrides")`; `FishPool.gd` gets a `_ready()` prelude that appends mod-registered species from `Engine.get_meta("_rtv_fish_species")` before the random-spawn loop

Mod sources are **not rewritten** -- the old `_rtv_mod_` subclass rewrite (Step C) was removed in v3.0.1. Mod scripts that extend wrapped vanilla see the dispatch wrapper as their parent method via native Godot resolution; `super.foo(...)` from the mod lands on the wrapper naturally.

See [Hooks](Hooks) for details.

### [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)

Orchestrates the full rewrite pipeline:

1. **Opt-in gate**: if no mods are loaded, early-return (no pack file written). If mods are loaded but `_hooked_methods` is empty and no mod declared `[registry]`, log the "no user opt-in declarations" banner and proceed with a minimal pack containing only the core-owned `Menu.gd :: _ready` wrap (launcher main-menu button injection). User mods' vanilla targets stay unmodified either way.
2. Verify GDSC tokenizer version (STABILITY canary B)
3. Enumerate game scripts
4. Pre-read mod sibling scripts (before `ZIPPacker.open` invalidates existing VFS handles)
5. Build the per-path wrap mask from `_hooked_methods` + `[registry]` targets (whole-script) + `[hooks]` declarations (per-method)
6. Rewrite each vanilla script in the mask, pack as three entries: `Scripts/<Name>.gd` + `.gd.remap` + empty `.gdc` (the recipe that beats the PCK's bytecode)
7. Pack autofixed mod siblings into the overlay
8. Add VFS canary file (STABILITY canary C)
9. Mount `user://modloader_hooks/framework_pack.zip` with `replace_files=true`
10. Verify the canary reads back
11. Activate: walk each rewritten script, reload or fall back to `CACHE_MODE_IGNORE + take_over_path`
12. Persist hook pack path + wrapped paths to pass state for next session's static-init mount

See [Hooks](Hooks) + [Stability-Canaries](Stability-Canaries).

## Orchestration

### [lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd)

Top-level entry point. `_ready` dispatches to `_run_pass_1` or `_run_pass_2`. Finish helpers (`_finish_with_existing_mounts`, `_finish_single_pass`) wrap the non-restart paths by instantiating queued autoloads, running dev-mode diagnostics, calling `_emit_frameworks_ready`, and triggering `reload_current_scene` if anything mounted.

See [Architecture](Architecture).

### [main_menu_hook.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/main_menu_hook.gd)

Injects a "Mods" button into RTV's main menu (`res://Scripts/Menu.gd`) so users can reopen the launcher post-boot without restarting the game. Uses the same hook machinery mods use:

- `_seed_core_hooks` pre-populates `_hooked_methods["res://Scripts/Menu.gd"]["_ready"]` so the rewriter wraps `Menu.gd :: _ready` even when no user mod asked for it. Called from each finish path and from Pass 1's pre-restart pack generation so every code path that produces a hook pack includes this wrap.
- `_register_core_hooks` subscribes `_on_menu_ready` to `menu-_ready-post` via the public `hook()` API, fired from `_emit_frameworks_ready` in [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd).
- `_inject_mods_button` finds `Main/Buttons` on the menu root, inserts a button named `MetroMods` above `Quit`, and wires `pressed` to `reopen_mod_ui`.

Mutations to `mod_config.cfg` while the reopened UI is open flip `_dirty_since_boot`; on close the modloader restarts into a clean Pass 1 so the new mod set takes effect.

## Temporary scaffolding

### [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd)

Gated behind `[settings] test_pack_precedence = true` in `user://mod_config.cfg`. Default config has no such key, so the entire subsystem is a no-op unless the user explicitly sets it.

Contents: `_test_pack_precedence` (Pass 1 pack-precedence exercise) + `_test_post_autoload_verify` (deferred verify 1s after autoloads). Header comment: "Removable once the rewrite system is proven stable in production."
