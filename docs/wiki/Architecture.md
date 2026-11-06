# Architecture

The loader runs in two stages in every process:

1. Static init, before `_ready`: `var _filescope_mounted: Dictionary = _mount_previous_session()`
   at the top of [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)
   runs when the ModLoader autoload instance is constructed (not when the script
   compiles). It mounts the previous session's archives and hook pack. Logs call
   this phase "static init" or "FileScope".
2. `_ready` in [src/lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd):
   registers the `RTVModLib` Engine meta before its first await, so early mod
   autoloads find the API, then compiles the regex helpers and runs Pass 1 (the
   launcher, then a restart when mods need one) or, with `--modloader-restart`
   among the user args, Pass 2.

The exe-dir sentinel files that stop or reset all of this are listed in
[Config-Files](Config-Files#sentinel-files-escape-hatches).

## Early mounts

`_mount_previous_session` uses only constants and static helpers, since the
instance is still under construction, and writes its lines to
`user://modloader_filescope.log` (one line names the Godot version, the loader
version and the OS). In order:

1. A disabled sentinel, or a `user://modloader_pass2_dirty` left by a Pass 2 that
   died, forces vanilla state (`_static_force_vanilla_state`): clean
   `override.cfg`, no pass state, no hook cache, no extracted early autoloads.
   Nothing mounts.
2. No `user://mod_pass_state.cfg`: nothing to do. Otherwise a restart launch
   writes the dirty marker now, before the first mount, so a crash while Godot
   builds the early autoloads still counts.
3. `_drop_stale_pack`: another loader version, or a changed game build (the
   executable's mtime, or the PCK's mtime and size, since a content patch can
   replace the PCK alone), wipes the hook cache and pass state and resets
   `override.cfg`. The archives still mount: Godot already read `override.cfg`,
   so the previous session's early autoloads load this launch and need them.
4. A recorded archive is missing (a folder mod counts as missing when its source
   folder is gone, even if its cache zip survives): `_reset_for_missing_archives`
   and nothing mounts.
5. Each archive mounts through `_try_mount_pack` (a `.vmz` falls back to a zip
   copy). Nothing is loaded: the engine follows a mounted `.remap` itself, and a
   `load()` here would compile vanilla scripts before the hook pack is in.
6. Unless step 3 dropped it, `_static_mount_hook_pack` deletes every other
   `framework_pack_*.zip` (Windows cannot delete a mounted one), refuses a
   `hook_pack_path` that is not a generated pack inside `user://modloader_hooks`
   (`_pack_path_sane`; pass state is hand-editable), mounts the pack with
   `replace_files=true` and `_preempt_wrapped_scripts` force-compiles each path
   in `hook_pack_wrapped_paths` with `CACHE_MODE_IGNORE` plus `take_over_path`.

A script that fails to compile still loads with its source, so the preempt
counts one only when it has a `_rtv_vanilla_*` method and logs the rest as `did
not compile, left alone`. A script the engine cached before this point cannot be
replaced; activation and the canaries detect that ([Limitations](Limitations)).

## Pass 1

`_run_pass_1`, in outline:

1. Crash and safe-mode checks, `_scan_game_and_mods`, cache cleanup, the
   profile config; `show_mod_ui` unless the launcher is skipped (below).
2. `load_all_mods`, `_apply_script_overrides`, the autoload sections, the hash.
3. Same hash as pass state, and no profile switch finished at this launch:
   `_finish_boot` with what static init mounted; no restart.
4. Archives to load but the crash breaker tripped: write the launcher notice,
   reset the streak, clean `override.cfg`, delete pass state, finish single-pass
   so the launcher stays reachable.
5. Archives to load: `_pass1_arm_restart` generates the hook pack with
   `defer_activation`, writes the heartbeat, `override.cfg` and pass state, and
   `_restart_with(true)` relaunches with `--modloader-restart`. A failed write
   finishes single-pass instead.
6. Nothing to load: clear pass state and `override.cfg` (a failure asks Retry or
   Quit), wipe the hook cache, and restart once more if static init mounted the
   previous set, since only a new process is free of it.

The pre-restart generation defers activation because this process already
pinned the PCK's bytecode; Pass 2's fresh engine mounts the pack at static init.
It is also the generation that probe-compiles each rewrite and persists the
verdicts as `hook_pack_demotions`
([Stability-Canaries](Stability-Canaries#pre-ship-compile-probe)).

`--modloader-skip-ui` (either side of `--`) or a one-shot
`<exe_dir>/modloader_skip_ui_once` file, consumed on every Pass 1, skips the
launcher as if Launch were clicked. `_restart_with` forwards the user args and
re-adds `--rendering-driver` and `--rendering-method`, which RTV's Steam presets
set and Godot strips from the arguments.

## Pass 2

`_run_pass_2` writes the dirty marker, replays `script_overrides` from pass
state, rescans, and runs `load_all_mods("Pass 2")`, which skips archives static
init mounted. Then `_finish_boot`, the tail every boot path shares: generate and
activate the hook pack (repeating Pass 1's probe verdicts, not probing),
instantiate queued autoloads not already in the tree, run the developer-mode
diagnostics, emit `frameworks_ready`, reload the current scene when anything
landed, then delete the heartbeat and clear the crash counters. Back in
`_run_pass_2` the dirty marker goes and the window asks for focus. Pass 2 never
shows the launcher.

## override.cfg lifecycle

Godot reads `override.cfg` from the game directory at startup, before any
script. `_write_override_cfg` writes `[autoload_prepend]` with the early mod
autoloads followed by `ModLoader="*res://modloader.gd"`, an empty `[autoload]`,
then every other section it found, kept as read.

- ModLoader is the last `[autoload_prepend]` entry: that section loads in
  reverse, so ModLoader loads first. In plain `[autoload]` game autoloads would
  pin their bytecode before static init.
- Late autoloads never appear there; `_finish_boot` instantiates them.
- Each early entry passes `_autoload_entry_writable` (an identifier name, a
  `res://` or `user://modloader_early/` path with no quote, backslash or
  newline): Godot stops at the first bad line, and ModLoader's comes last.
- `_static_write_cfg_atomic` is the one writer: write `.tmp`, park the live file
  as `.old`, promote, drop `.old`, and restore `.old` on any failure. The live
  file is never deleted first, because without it ModLoader never loads again.

## Pass state

`user://mod_pass_state.cfg`, section `[state]`. Writer `_write_pass_state`;
`_persist_hook_pack_state` writes the three hook-pack keys.

| Key | Purpose |
|---|---|
| `restart_count` | Bumped per armed restart; a heartbeat survivor with a count of 2 or more resets to clean state |
| `mods_hash` | `_compute_state_hash`: archive paths in load order with stable mtimes, early autoloads, enabled versions, script overrides, the loader version and `modloader.gd`'s mtime (a rebuilt loader must restart, or the old pack mount reads stale offsets) |
| `archive_paths` | The archives static init mounts, in load order |
| `modloader_version`, `exe_mtime`, `pck_stamp` | Stale-state detection for step 3 of the early mounts |
| `timestamp` | Diagnostic only |
| `script_overrides` | `[script_extend]` / `[script_overrides]` entries for Pass 2 to replay |
| `hook_pack_path` | The pack static init mounts, `user://modloader_hooks/framework_pack_<millis>.zip`; a new name per generation sidesteps Godot's per-path mount dedup |
| `hook_pack_wrapped_paths` | The scripts static init preempts; deferred ones are left out |
| `hook_pack_demotions` | Probe verdicts, script path to `"wrap_only"` or `"excluded"`; a generation that finds the key repeats them |

## Crash recovery

- Heartbeat, `user://modloader_heartbeat.txt`: written before the restart,
  deleted by `_finish_boot`. A survivor at the next Pass 1 means the launch died
  in between; `_check_crash_recovery` warns and clears it.
- Crash streak, `user://modloader_crash_streak`: `restart_count` cannot be the
  breaker on its own, because a crashed Pass 2 makes the next static init delete
  pass state. The streak file is bumped with it and survives the wipe; at 2
  (`MAX_RESTART_COUNT`) `_crash_breaker_tripped` stops Pass 1 from arming a
  restart and leaves `user://modloader_crash_notice` for the next launcher.
- `_clear_restart_counter` zeroes both at the end of `_finish_boot`, after the
  scene reload: loading, autoload instantiation and the reload are where a mod
  crashes, so clearing earlier would record a crashed launch as clean.
- `_ready` deletes `modloader_disabled_once` after one idle boot, so a crash
  before `_ready` keeps the next launch vanilla too.
