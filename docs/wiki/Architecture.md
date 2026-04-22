# Architecture

The mod loader runs in two stages:

1. **Static init** (before `_ready`): mounts archives from the previous session, preempts `class_name` scripts Godot would otherwise pin to PCK bytecode, and checks sentinel files.
2. **`_ready`**: dispatches to **Pass 1** (show UI + optionally restart) or **Pass 2** (post-restart finalization), based on a cmdline arg.

## Entry points

| Stage | Trigger | Code |
|---|---|---|
| Static init | Module-scope var initializer evaluates before `_ready` | `var _filescope_mounted := _mount_previous_session()` at [src/constants.gd:175](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L175) |
| `_ready` | Godot calls it after scene enters tree | [src/lifecycle.gd:7](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L7) |

The static-init trick works because Godot evaluates `var = <call>()` initializers at script-load time. The mounts land in VFS before any autoload scene graph resolves, so game autoloads can `preload(res://ModPath/Foo.gd)` without the archive being explicitly mounted in `_ready`.

## Static init (`_mount_previous_session`)

Defined at [src/boot.gd:32](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L32). Sequence:

1. **Disabled sentinel check** -- if `<exe_dir>/modloader_disabled` exists, force vanilla state and return. See [Stability-Canaries](Stability-Canaries) for the escape hatches.
2. **Crashed Pass 2 recovery** -- if `user://modloader_pass2_dirty` exists, Pass 2 was interrupted before cleanup; full wipe.
3. **Pre-init cache snapshot** -- probe the scripts pass_state recorded as wrapped last session (from `hook_pack_wrapped_paths`) and classify each as tokenized (PCK-pinned) / source-loaded (our prior-session rewrite) / not-yet-loaded. Before v3.0.1 this was a hardcoded 16-entry list; now it's driven by what mods actually declared.
4. **Load pass state** from `user://mod_pass_state.cfg`; early return if missing.
5. **Version mismatch** -- if saved `modloader_version` != current `MODLOADER_VERSION`, wipe state (pass-state format may have changed).
6. **Exe mtime check** -- if the game exe was updated since last session, wipe hook cache (vanilla scripts may have changed).
7. **Archive existence scan** -- if any archive from last session is missing, write a clean `override.cfg` and reset.
8. **Mount loop** -- each archive via `ProjectSettings.load_resource_pack`, with `.vmz -> .zip` fallback.
9. **Hook pack preempt mount** ([boot.gd:208-287](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L208)) -- mount `user://modloader_hooks/framework_pack.zip` with `replace_files=true`, then force a fresh source-compile of each script in `hook_pack_wrapped_paths` via `ResourceLoader.load(..., CACHE_MODE_IGNORE)` + `take_over_path`. Scripts not in that set are left to Godot's lazy-compile path. When no mods are loaded at all the pack file doesn't exist and this step short-circuits; when mods are loaded but none opt into the hook surface, `hook_pack_wrapped_paths` narrows to just `res://Scripts/Menu.gd` (the core-owned wrap for the launcher's main-menu button) -- legacy loadouts boot with that one script preempted and nothing else.
10. **Test pack mount** (dev-only, gated on `user://test_pack_precedence.zip` presence).

The hook pack preempt is the only way to rewire scripts Godot pre-compiles during `class_cache` population. Once pinned, runtime `source_code + reload()` and `CACHE_MODE_IGNORE + take_over_path` both fail against autoload-backed scripts (see [Limitations](Limitations)).

## Pass 1 (normal launch)

Defined at [src/lifecycle.gd:34](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L34). Outline:

```
check crash recovery (heartbeat + restart count)
check safe mode sentinel
compile regex, build class_name lookup, load dev-mode setting
collect_mod_metadata()          # scan <exe>/mods/ -- no mounting
clean_stale_cache
load_ui_config
await show_mod_ui()             # user configures and clicks Launch Game
save_ui_config
load_all_mods()                 # mount archives, scan, queue autoloads
_apply_script_overrides         # from [script_overrides] in mod.txt
sections    = _build_autoload_sections()
archive_paths = _collect_enabled_archive_paths()
new_hash    = _compute_state_hash(...)

if new_hash == old_hash and not empty:
    _finish_with_existing_mounts()     # fast path -- same mod set as last session
    return

if archive_paths not empty:
    _register_rtv_modlib_meta
    _generate_hook_pack(defer_activation=true)    # Pass 2 activates
    _write_heartbeat
    _write_override_cfg(sections.prepend)
    _write_pass_state(archive_paths, new_hash)
    OS.set_restart_on_exit(true, args + "--modloader-restart")
    get_tree().quit()
else:
    remove pass_state, restore clean override.cfg, wipe hook cache
    _finish_single_pass()
```

`defer_activation=true` on the first-time pack generation is deliberate: without it, activation runs against the already-pinned PCK bytecode in this engine process, fires a misleading `"hooks WILL NOT fire this session"` STABILITY alarm, then restarts anyway. Passing `defer_activation=true` writes the zip + pass state and lets Pass 2's fresh engine mount it cleanly. See [hook_pack.gd:392-402](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L392).

## Pass 2 (post-restart)

Triggered by `--modloader-restart` in `OS.get_cmdline_user_args()`. Defined at [src/lifecycle.gd:160](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L160).

Archives are already mounted at file-scope (static init handled it). Early autoloads are already in the tree (Godot loaded them from `[autoload_prepend]`). This pass:

1. Writes `user://modloader_pass2_dirty` sentinel first thing. If Pass 2 crashes before cleanup, next launch's static init detects the marker and force-wipes.
2. Restores `[script_overrides]` from pass state and applies them.
3. Clears restart counter.
4. Re-runs metadata collection + `load_all_mods("Pass 2")`. Archives already file-scope-mounted skip re-mount via `_filescope_mounted.has(full_path)` check.
5. Generates + mounts the hook pack (this time without `defer_activation`).
6. Instantiates pending autoloads (skips ones already in tree from `[autoload_prepend]`).
7. `_emit_frameworks_ready` -- runs verification probes (see [Developer-Mode](Developer-Mode)).
8. Deletes heartbeat, clears the Pass 2 dirty marker.
9. `reload_current_scene()` if any archives or autoloads changed.

## override.cfg lifecycle

`override.cfg` is written directly to the game directory (not `user://`) because Godot reads it at engine startup before any script runs. Canonical layout ([boot.gd:177](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L177)):

```
[autoload_prepend]
<early_autoload1>="*<path>"
<early_autoload2>="*<path>"
ModLoader="*res://modloader.gd"

[autoload]

<preserved>
```

Three invariants:

- **ModLoader is always in `[autoload_prepend]`, last entry.** `[autoload_prepend]` is reverse-insertion -- last listed = first loaded. This ensures ModLoader's static-init mount runs before any mod autoload's script references resolve. See the rationale at [boot.gd:470-475](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L470).
- **Late autoloads never appear in `override.cfg`.** If they did, Godot would try to load them before archives are mounted in static init. They're instantiated manually in `_finish_*` helpers after mounts land.
- **Atomic write via `.tmp` + rename.** [boot.gd:483-498](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L483). `DirAccess.rename()` on Windows won't overwrite, so the target is removed first.

Non-autoload sections (`[display]`, `[input]`, etc.) are preserved via `_read_preserved_cfg_sections` ([fs_archive.gd:49](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd#L49)) and re-concatenated.

## Pass state

`user://mod_pass_state.cfg` persists between sessions. Keys in `[state]`:

| Key | Purpose |
|---|---|
| `restart_count` | Crash-loop guard -- `_check_crash_recovery` wipes when `>= MAX_RESTART_COUNT` (2) |
| `mods_hash` | md5 of archive paths + mtimes + autoloads + script_overrides + `MODLOADER_VERSION` + `modloader.gd` mtime. Mismatch forces restart |
| `archive_paths` | `PackedStringArray` replayed by static init's mount loop |
| `modloader_version` | Version wipe check -- format may have changed |
| `exe_mtime` | Game-update detection |
| `timestamp` | Unix time, diagnostic only |
| `script_overrides` | `[{vanilla_path, mod_script_path, mod_name, priority}]` for Pass 2 to replay |
| `hook_pack_path` | Static init mounts this at next boot |
| `hook_pack_exe_mtime` | Separate invalidation key for hook pack |

Writer: `_write_pass_state` at [boot.gd:515](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L515). Hash computed at [boot.gd:535](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L535).

Including `modloader.gd`'s own mtime in the hash is load-bearing ([boot.gd:554-568](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L554)): `ProjectSettings.load_resource_pack` dedupes by path, so rebuilding the loader without a restart would leave the old hook pack mount active with stale file offsets.

## Heartbeat + safe mode

- **Heartbeat file** (`user://modloader_heartbeat.txt`) written before restart, deleted post-Pass-2-cleanup. A surviving heartbeat means last launch crashed.
- **Restart counter** in pass state, incremented by `_write_pass_state`. `_check_crash_recovery` at [boot.gd:581](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L581) force-resets when it hits `MAX_RESTART_COUNT` (2).
- **Safe mode file** (`<exe>/modloader_safe_mode`) -- user-placed. `_check_safe_mode` at [boot.gd:596](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L596) detects, wipes state, removes the sentinel.
- **Disabled sentinel** (`<exe>/modloader_disabled`) -- user-placed, sticky. Checked at static init by `_is_modloader_disabled` at [boot.gd:8](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L8). Modloader sits idle for the whole session until the user removes the file.
- **Pass 2 dirty marker** (`user://modloader_pass2_dirty`) -- written at Pass 2 start, deleted at Pass 2 end. Detected at next static init to force-wipe on interrupted runs.

See [Stability-Canaries](Stability-Canaries) for the escape hatches in detail.
