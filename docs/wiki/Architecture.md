# Architecture

The mod loader runs in two stages:

1. Static init, before `_ready`: mounts the archives from the previous session, preempts the `class_name` scripts Godot would otherwise pin to PCK bytecode, and checks the sentinel files.
2. `_ready`: dispatches to Pass 1 (show the launcher, optionally restart) or Pass 2 (post-restart finalization), based on a command-line argument.

The header comment of [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) carries the short form of this sequence and the sentinel table; this page is the longer form. Function names are the anchors here, not line numbers.

## Entry points

| Stage | Trigger | Code |
|---|---|---|
| Static init | Module-scope var initializer runs at script-load time | `var _filescope_mounted: Dictionary = _mount_previous_session()` at the top of [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) |
| `_ready` | Godot calls it once the autoload enters the tree | `_ready` in [src/lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd) |

Godot evaluates `var = <call>()` initializers while the script loads, so the mounts land in the VFS before any autoload scene graph resolves. A game autoload can `preload("res://ModPath/Foo.gd")` without the archive being mounted again in `_ready`.

## Static init (`_mount_previous_session`)

Static function in `boot.gd`. It only has the static helpers and the constants to work with; the instance log helpers do not exist yet, so it collects lines and writes them to `user://modloader_filescope.log` through `_write_filescope_log`. The first line records the Godot version, the loader version and the OS. Sequence:

1. Disabled sentinel. If `<exe_dir>/modloader_disabled` or `<exe_dir>/modloader_disabled_once` exists (`_is_modloader_disabled`), call `_static_force_vanilla_state` and return with nothing mounted. See [Stability-Canaries](Stability-Canaries) for the escape hatches.
2. Crashed Pass 2. If `user://modloader_pass2_dirty` exists, the previous Pass 2 died before cleanup; same full wipe, nothing mounted.
3. Load `user://mod_pass_state.cfg`; return if it is missing.
4. Version mismatch. A saved `modloader_version` that differs from `MODLOADER_VERSION` wipes the hook cache, deletes pass state and resets `override.cfg`. Rewriter output can change between versions, so a stale pack must not be mounted.
5. Game update. If the exe mtime differs from the saved `exe_mtime`, same wipe: vanilla scripts may have changed.
6. Missing archives. If any recorded archive is gone, write a clean `override.cfg` and delete pass state. A same-basename cache zip that survived does not count as present.
7. Mount loop. Each archive goes through `ProjectSettings.load_resource_pack`, with the `.vmz -> .zip` cache fallback (`_static_vmz_to_zip`) and `.remap` resolution (`_static_resolve_remaps`).
8. Orphan hook packs. `_static_cleanup_orphan_hook_packs` deletes every `framework_pack_*.zip` except the one pass state points at. Nothing is mounted yet, so Windows lets them go.
9. Pre-init cache snapshot. For each path in `hook_pack_wrapped_paths`, record whether Godot's eager class-cache pass already compiled it (tokenized), whether it holds our source from a previous session, or whether it is not loaded yet. Diagnostic only; it answers "why didn't my hook fire".
10. Hook pack mount. The path in `hook_pack_path` must be a `framework_pack_*.zip` directly inside `user://modloader_hooks` (`_static_hook_pack_path_sane`; pass state is user-editable, so anything else is refused). The pack is mounted with `replace_files=true`, then every entry listed in `hook_pack_wrapped_paths` is force-compiled from source via `ResourceLoader.load(..., CACHE_MODE_IGNORE)` plus `take_over_path`. Entries the pack carries but the list does not are left to lazy compile. With no mods loaded the pack file does not exist and this step is skipped. With mods loaded but none opting into the hook surface, the list holds only `res://Scripts/Menu.gd`, the core-owned wrap for the launcher's main-menu button.
11. Test pack. `user://test_pack_precedence.zip` is mounted only when `[settings] test_pack_precedence` is set in `mod_config.cfg`; with the flag off, a leftover zip is deleted, never mounted.

The static-init mount is the only way to rewire scripts Godot compiles while it populates `class_cache`. Once a script is pinned, `source_code + reload()` and `CACHE_MODE_IGNORE + take_over_path` both fail against autoload-backed scripts (see [Limitations](Limitations)).

## Pass 1 (normal launch)

`_run_pass_1` in `lifecycle.gd`. Outline:

```
_check_crash_recovery()          # heartbeat survivor from the last launch
_check_safe_mode()               # user-placed modloader_safe_mode
_compile_regex(); _build_class_name_lookup(); _enumerate_game_scripts()
_load_developer_mode_setting()
_ui_mod_entries = collect_mod_metadata()   # scan <exe>/mods/, no mounting
_clean_stale_cache(); _remove_retired_state()
_load_ui_config()
await show_mod_ui()              # the user configures and clicks Launch
_save_ui_config()
load_all_mods()                  # mount archives, scan, queue autoloads
_apply_script_overrides()        # [script_extend] / [script_overrides]
sections      = _build_autoload_sections()
archive_paths = _collect_enabled_archive_paths()
new_hash      = _compute_state_hash(archive_paths, sections.prepend)

if new_hash == old_hash and not empty:
    _finish_with_existing_mounts()     # same mod set as last session
    return

if archive_paths not empty and _crash_breaker_tripped():
    reset streak, restore clean override.cfg, delete pass state
    _finish_single_pass()              # launcher stays reachable
    return

if archive_paths not empty:
    _register_rtv_modlib_meta()
    _generate_hook_pack(true)          # defer_activation: Pass 2 activates
    _write_heartbeat()
    _write_override_cfg(sections.prepend)
    _write_pass_state(archive_paths, new_hash)
    _modloader_restart(false)          # relaunch with --modloader-restart
else:
    delete pass state, restore clean override.cfg, wipe hook cache
    _finish_single_pass()
```

`_generate_hook_pack(true)` on the pre-restart path is deliberate. Without `defer_activation`, activation would run against the PCK bytecode this engine process already pinned, log a misleading "hooks WILL NOT fire this session" alarm, and restart anyway. With it, the call writes the zip and the pass-state entry and lets Pass 2's fresh engine mount it at static init. The branch is at the end of `_generate_hook_pack` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd).

`_modloader_restart` re-injects `--rendering-driver` and `--rendering-method` (Godot's own parser strips them from `OS.get_cmdline_args()`, and RTV's Steam launch presets set exactly those two) and forwards user args after `--`.

## Pass 2 (post-restart)

`_run_pass_2` in `lifecycle.gd`, chosen when `--modloader-restart` is in `OS.get_cmdline_user_args()`.

Archives are already mounted (static init did it in this process) and early autoloads are already in the tree (Godot loaded them from `[autoload_prepend]`). The pass:

1. Writes `user://modloader_pass2_dirty` first thing. If the pass crashes before cleanup, the next static init sees the marker and wipes.
2. Restores `[script_overrides]` entries from pass state and applies them.
3. Re-runs `_compile_regex`, class lookup, script enumeration, dev-mode setting, metadata collection and `_load_ui_config`, then `load_all_mods("Pass 2")`. Archives already in `_filescope_mounted` are not mounted again.
4. Registers the `RTVModLib` meta and generates plus activates the hook pack (no `defer_activation` this time).
5. Re-applies the test pack when the flag is set, copying it to a fresh `user://test_pack_reapply_<ticks>.zip` because `load_resource_pack` dedupes by path.
6. Instantiates pending autoloads, skipping any already in the tree from `[autoload_prepend]`.
7. Runs the dev-mode diagnostics, then `_emit_frameworks_ready`.
8. Deletes the heartbeat, clears the restart streak, deletes the dirty marker. The streak is cleared here and not at entry: `load_all_mods` and autoload instantiation are where a mod crashes, so clearing earlier would record a streak of zero for a crashed launch.
9. `reload_current_scene()` if any archive or autoload landed, then asks the OS for window focus (Windows hands foreground away when the Pass 1 process dies).

Pass 2 never shows the launcher.

## override.cfg lifecycle

`override.cfg` is written to the game directory, not `user://`, because Godot reads it at engine startup before any script runs. Layout, as written by `_write_override_cfg` in `boot.gd`:

```
[autoload_prepend]
<early_autoload1>="*<path>"
<early_autoload2>="*<path>"
ModLoader="*res://modloader.gd"

[autoload]

<preserved>
```

Three invariants:

- ModLoader is always the last entry in `[autoload_prepend]`. That section is reverse-insertion (last listed = first loaded), so ModLoader's static-init mount runs before any mod autoload's script references resolve. In plain `[autoload]` some game autoloads would pin their bytecode before static init could preempt them.
- Late autoloads never appear in `override.cfg`. Godot would try to load them before the archives are mounted. The `_finish_*` helpers instantiate them after the mounts land.
- The write is atomic: `.tmp`, then park the live file as `override.cfg.old`, promote the `.tmp`, drop the `.old`. Windows `DirAccess.rename()` will not overwrite, hence the park step. On any failure the `.old` is restored (by byte copy if the rename back fails too). The live file is never deleted before its replacement is proven in place; losing it would un-load the ModLoader autoload with no way to self-heal. `_static_write_cfg_atomic` does the same for the static reset paths.

Each early autoload line is checked by `_autoload_entry_writable` first: the name must be a plain identifier and the path a `res://` or extracted `user://modloader_early/` path with no quotes, backslashes or newlines. Godot stops applying entries at the first malformed line, and the ModLoader line comes after the mod entries.

Sections other than the two autoload ones (`[display]`, `[input]`, ...) survive through `_read_preserved_cfg_sections` in [src/fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd).

## Pass state

`user://mod_pass_state.cfg` persists between sessions. Keys in `[state]`:

| Key | Purpose |
|---|---|
| `restart_count` | Incremented by `_write_pass_state`, read by `_check_crash_recovery`. The crash-loop breaker itself reads the streak file below, because the crashed-Pass-2 wipe deletes this file |
| `mods_hash` | md5 of archive paths plus stable mtimes (folder mods hash the source tree, not the temp zip), prepend autoloads, enabled mods' declared versions, script overrides, `MODLOADER_VERSION` and `modloader.gd`'s own mtime. A mismatch forces a restart |
| `archive_paths` | `PackedStringArray` replayed by static init's mount loop |
| `modloader_version` | Version check at static init |
| `exe_mtime` | Game-update detection |
| `timestamp` | Unix time, diagnostic only |
| `script_overrides` | `[{vanilla_path, mod_script_path, mod_name, priority, seq}]` for Pass 2 to replay |
| `hook_pack_path` | The pack static init mounts next boot |
| `hook_pack_wrapped_paths` | The vanilla script paths the pack wrapped and activated eagerly; static init preempts exactly these. Scripts deferred for a module-scope scene preload are not listed and lazy-compile from the mounted pack |

Writer: `_write_pass_state`. Hash: `_compute_state_hash`. `_persist_hook_pack_state` writes the two hook-pack keys separately, seeding `exe_mtime` and `modloader_version` only when they are missing.

The crash streak lives in its own file, `user://modloader_crash_streak` (`CRASH_STREAK_PATH`): a bare integer, bumped by `_write_pass_state`, reset to zero by `_clear_restart_counter`, read by `_crash_breaker_tripped`. `_static_force_vanilla_state` never touches it. See [Stability-Canaries](Stability-Canaries#restart-counter).

Folding `modloader.gd`'s mtime into the hash matters: `ProjectSettings.load_resource_pack` dedupes by path, so rebuilding the loader without a restart would leave the old hook pack mount active with stale file offsets and reads of moved entries failing inside `file_access_zip.cpp`.

## Heartbeat + safe mode

- Heartbeat (`user://modloader_heartbeat.txt`). Written right before the Pass 1 to Pass 2 restart, deleted by every finish path. A survivor at the next Pass 1 means the previous launch died between the restart and the finish; `_check_crash_recovery` logs a warning and clears it.
- Restart counter. `restart_count` in pass state plus the streak file. `_check_crash_recovery` resets to clean state when a heartbeat survives and `restart_count >= MAX_RESTART_COUNT` (2). `_crash_breaker_tripped` refuses the two-pass restart when the streak reaches the same limit.
- Safe mode file (`<exe>/modloader_safe_mode`). User-placed. `_check_safe_mode` wipes state and removes the file.
- Disabled sentinel (`<exe>/modloader_disabled`). User-placed, sticky. The loader sits idle for the whole session until the file is removed.
- One-shot vanilla sentinel (`<exe>/modloader_disabled_once`). Written by the launcher's "Launch vanilla" button; `_ready` deletes it after one vanilla boot. If the game crashes before `_ready`, it persists and the next launch stays vanilla, which is the intended fail-safe.
- Pass 2 dirty marker (`user://modloader_pass2_dirty`). Written at Pass 2 start, deleted at Pass 2 end. A survivor makes the next static init force-wipe.

[Stability-Canaries](Stability-Canaries) covers the escape hatches in detail.
