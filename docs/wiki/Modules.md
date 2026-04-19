# Modules

Tour of the `src/` tree. Order follows `build.sh`'s `FILES` array, which is the concat order used to produce `modloader.gd`. Dependencies flow top-down -- earlier files may not reference code defined later.

## Fundamentals

### [header.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/header.gd)

10 lines. Top-of-file doc comment plus `extends Node`. This is the only `extends` in the compiled `modloader.gd` -- `build.sh` enforces that invariant.

### [constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)

All module-scope `const`, `var`, and `signal` declarations. Everything has to land here so it's declared before any function body references it. Notable residents:

- `MODLOADER_VERSION` at [constants.gd:13](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L13) -- release-please bumps this via Conventional Commits, bracketed by `x-release-please-start/end` markers
- `RTV_SKIP_LIST` (7 scripts), `RTV_RESOURCE_SERIALIZED_SKIP` (11), `RTV_RESOURCE_DATA_SKIP` (25) -- scripts the rewriter refuses to touch, each with inline rationale
- `_filescope_mounted := _mount_previous_session()` at [constants.gd:161](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L161) -- a module-scope var with a function-call initializer. This is what triggers the static-init mount before `_ready`

### [logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd)

Four helpers: `_log_info`, `_log_warning`, `_log_critical`, `_log_debug`. Each prefixes `[ModLoader][Level] ` and appends to `_report_lines` (later written to `user://modloader_conflicts.txt`). `_log_debug` is gated on `_developer_mode`.

## File + archive helpers

### [fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)

Pure disk I/O. No game logic. VMZ-to-ZIP conversion, mod.txt parsing, zip packing for dev-mode folder mods, `.remap` resolution post-mount, path normalization for tracked extensions.

Includes both static functions (callable from static init before instance state exists) and instance functions.

## Static-init boot layer

### [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)

The largest domain. Owns:

- `_mount_previous_session` at [boot.gd:32](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L32) -- the static-init entry point triggered by `constants.gd:161`
- Sentinel handling (disabled, safe mode, Pass 2 dirty marker)
- `override.cfg` reading + writing (`_write_override_cfg`, `_restore_clean_override_cfg`)
- Pass state persistence (`_write_pass_state`, `_compute_state_hash`)
- Heartbeat + crash-recovery logic
- Hook-cache wiping
- Early-autoload disk extraction (`_ensure_early_autoload_on_disk`)
- Stale cache cleanup

See [Architecture](Architecture) for the control flow.

## Discovery + loading

### [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)

Scans `<exe>/mods/`, parses mod.txt metadata, handles ModWorkshop version checks and downloads. No mounting -- that's `mod_loading`.

- `collect_mod_metadata` at [mod_discovery.gd:7](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L7) -- the main scanner
- `compare_versions` -- semver-ish with `v` prefix tolerance
- `fetch_latest_modworkshop_versions` / `download_and_replace_mod` -- chunked HTTP against `api.modworkshop.net`

### [mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd)

Runtime loading pipeline. Mounts archives, scans .gd files for safety issues, registers file-claims, instantiates autoloads, applies `[script_overrides]`.

- `load_all_mods` at [mod_loading.gd:7](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L7) -- entry point
- `_process_mod_candidate` at [mod_loading.gd:54](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L54) -- per-mod pipeline
- `_apply_script_overrides` at [mod_loading.gd:199](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L199) -- sorts by priority asc, `load` + `source_code` + fresh `GDScript.new()` + `reload` + `take_over_path`
- `scan_and_register_archive_claims` -- detects Windows-backslash zip paths, Database.gd collisions, builds per-file analysis
- `_instantiate_autoload` -- dispatches PackedScene vs GDScript vs other

### [conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd)

Developer-mode diagnostics. Most functions only run when `_developer_mode = true`, except `_print_conflict_summary` + `_write_conflict_report` which always run but filter logs.

Two-layer override verification:

- **Layer A** (`_verify_script_overrides` at [conflict_report.gd:53](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L53)): cache-level check. Loads each declared override target post-autoloads, inspects method names for `_rtv_mod_` / `_rtv_vanilla_` rename prefixes to classify the cache state
- **Autoload instance check** at [conflict_report.gd:120-204](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L120): auto-swaps stale autoload instances via `node.set_script(load(ap))`. Matches RTVCoop's manual pattern and Godot's own `reload_scripts` at `gdscript.cpp:2419`
- **Layer B** (`_on_override_probe_node_added`): one-shot-per-path instance probe armed on `get_tree().node_added`
- **Tree-walk fallback** (`_probe_tree_walk`): scheduled 12s after `frameworks_ready`, full scene-tree walk for cases `node_added` missed

## UI

### [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd)

Pre-game launcher window. Two tabs (Mods, Updates), dark theme, Reset-to-Vanilla action. Closing the window equals clicking Launch Game.

- `show_mod_ui` at [ui.gd:70](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L70)
- `build_mods_tab` / `build_updates_tab` -- tab content
- `make_dark_theme` -- Theme resource with pure-black backgrounds
- `_reset_to_vanilla_and_restart` -- unchecks every mod, calls `_static_force_vanilla_state`, strips `--modloader-restart` from cmdline so the relaunch is a clean Pass 1

## Public API

### [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd)

The public surface mods call via `Engine.get_meta("RTVModLib")`. Version accessors, `hook`/`unhook`/`has_hooks`/`has_replace`/`get_replace_owner`/`skip_super`/`seq`, plus the internal `_dispatch` / `_dispatch_deferred` helpers used by generated wrappers.

See [Hooks](Hooks) for the full API + semantics.

### [registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd)

Public registry verbs: `register`, `override`, `patch`, `remove`, `revert`. Currently only `Registry.SCENES` (on `Database` autoload) is active; inline comments reserve slots for items, loot, recipes, events, sounds, etc.

Per-registry handlers talk to dicts the rewriter injected into vanilla scripts -- `Database.gd` gets `_rtv_vanilla_scenes` / `_rtv_mod_scenes` / `_rtv_override_scenes` + a `_get()` override that routes `Database.get(name)` through the mod layer before vanilla.

**Limitation**: direct constant access (`Database.Potato`) bypasses `_get()`. Mods must use `Database.get("Potato")` to hit the registry.

### [framework_wrappers.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/framework_wrappers.gd)

**Mostly dead code.** The legacy `[rtvmodlib] needs= -> Framework<X>.gd subclass -> node_added` path. Source-rewrite replaced it.

Live:
- `_collect_needed_from_mods` -- still parses `[rtvmodlib] needs=` across enabled mods
- `_rtv_collect_nodes_by_class` -- tree walk used by post-activation IXP-VERIFY probe in hook_pack

Dead (marked with "DEAD-LOOP" / "DEAD CODE" comments, verified 2026-04-19):
- `_activate_hooked_scripts` -- body loop never enters `_register_override` because `Framework<X>.gd` files are no longer generated
- `_register_override`, `_connect_node_swap`, `_on_node_added`, `_deferred_swap` -- chain never fires

Scheduled for removal; kept as scaffolding in case the Framework-subclass path ever needs revival.

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

Source-rewrite codegen. Given detokenized vanilla source + a parse structure:

- Renames each non-static method `Foo` to `_rtv_vanilla_Foo` (or `_rtv_mod_Foo` for mod subclasses)
- Appends a dispatch wrapper at the original name that fires pre/replace/post/callback hooks then calls the renamed body
- Rewrites bare `super()` inside renamed bodies to `super.<orig_name>()` so the parent's dispatch wrapper resolves (Gotcha #2 in Limitations)
- Autofixes legacy GDScript 3 syntax: bodyless blocks get a `pass`, `tool`/`onready var`/`export var` get the `@` annotation
- For `Database.gd`: converts top-level `const X = preload(...)` into a `_rtv_vanilla_scenes` dict entry, injects `_get()` override

Also owns `_scan_mod_extends_targets` -- scans mod archives for `.gd` files whose first non-trivial line is `extends "res://Scripts/<X>.gd"` where `<X>` is a vanilla script already rewritten. Those mod scripts get the same rename+dispatch treatment (with `_rtv_mod_` prefix) shipped at their own res:// path.

See [Hooks](Hooks) for details.

### [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)

Orchestrates the full rewrite pipeline:

1. Verify GDSC tokenizer version (STABILITY canary B)
2. Enumerate game scripts
3. Pre-read mod sibling scripts (before `ZIPPacker.open` invalidates existing VFS handles)
4. Rewrite each vanilla script, pack as three entries: `Scripts/<Name>.gd` + `.gd.remap` + empty `.gdc` (the recipe that beats the PCK's bytecode)
5. Rewrite mod subclasses with `_rtv_mod_` prefix
6. Pack autofixed mod siblings into the overlay
7. Add VFS canary file (STABILITY canary C)
8. Mount `user://modloader_hooks/framework_pack.zip` with `replace_files=true`
9. Verify the canary reads back
10. Activate: walk each rewritten script, reload or fall back to `CACHE_MODE_IGNORE + take_over_path`
11. Persist hook pack path to pass state for next session's static-init mount

See [Hooks](Hooks) + [Stability-Canaries](Stability-Canaries).

## Orchestration

### [lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd)

Top-level entry point. `_ready` dispatches to `_run_pass_1` or `_run_pass_2`. Finish helpers (`_finish_with_existing_mounts`, `_finish_single_pass`) wrap the non-restart paths by instantiating queued autoloads, running dev-mode diagnostics, calling `_emit_frameworks_ready`, and triggering `reload_current_scene` if anything mounted.

See [Architecture](Architecture).

## Temporary scaffolding

### [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd)

Gated behind `[settings] test_pack_precedence = true` in `user://mod_config.cfg`. Default config has no such key, so the entire subsystem is a no-op unless the user explicitly sets it.

Contents: `_test_pack_precedence` (Pass 1 pack-precedence exercise) + `_test_post_autoload_verify` (deferred verify 1s after autoloads). Header comment: "Removable once the rewrite system is proven stable in production."
