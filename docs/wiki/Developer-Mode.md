# Developer Mode

A per-user setting, off by default, for people writing mods. It changes what loads in one way only, unpacked folder mods load; everything else it adds is logging and boot-time probes.

## How to enable

Tick **Developer mode** in the Mods-tab toolbar. The choice is saved as `[settings] developer_mode` in `user://mod_config.cfg`; toggling it rescans the mods folder and keeps the active profile. [`_load_developer_mode_setting`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profiles.gd) reads it at the start of both passes, falling back to `mod_config.cfg.bak` when the live file is unreadable, so a recoverable config error does not strand your folder mods. When on, the log says `[Config] Developer mode: ON`.

## Folder mods

Each subfolder of `<game>/mods/` (except hidden ones starting with `.`) counts as a mod. Its contents are zipped to `user://vmz_mount_cache/<name>_dev.zip` and mounted, so it behaves exactly like the zip you will ship ([Mod-Format](Mod-Format#packaging-layout) has the layout). The zip is rebuilt only when the folder changed: a stamp of its files' paths, times and count is kept in a `.src` sidecar and compared at every launch.

- The row carries a red `[dev folder]` label. A `mod.txt` that does not parse shows the same row warning an archive gets; the archive-shape warnings do not apply.
- A folder never gets update downloads: the download would land beside it as a duplicate. Your working copy is what loads.
- With developer mode off, folders are not loaded but are still tracked, so a dependent mod reports the `hidden_folder` status ([Dependencies](Dependencies#skip-when-unmet-required-only)) instead of "not installed".

## What it adds

| Feature | When | Output |
|---|---|---|
| Debug logging | throughout | `_log_debug` lines, a full no-op when off: rewriter skips, per-script rewrite counts (`[RTVCodegen] Rewrote <path> (N hooks)`), the per-target `reconcile` table, stale-cache removal, rejected replace hooks, missing-autoload details |
| Author notes | Mods-tab rows | notes for the mod's author on a sourced or id-less archive ([Mod-Format](Mod-Format#modtxt-validity-and-row-warnings)); real breakage shows to everyone regardless |
| Conflict summary and report | end of boot | `--- Conflicted Paths (last loader wins) ---` with `<-- wins` on the winner, then `user://modloader_conflicts.txt`: every log line since mod loading began, capped at 5000 lines, written after `frameworks_ready` |
| Override timing | end of boot | `<mod> uses overrideScript() on: <scripts> -- applies after scene reload` for mods that call `take_over_path` |
| OverrideVerify | at `frameworks_ready` | `[OverrideVerify] <mod> \| <path> \| resource_path=... src_head=[...]` for each such target already in the cache, else `not loaded yet`; nothing is loaded to check |
| Pre-activate summary | before hook-pack activation | `[RTVCodegen] PRE-ACTIVATE preempted=N ...`: how many wrapped scripts static init already replaced |
| COMPILE-PROOF detail | after activation | one `[RTVCodegen] COMPILE-PROOF <path>` line per script; the `[STABILITY]` summary prints in every mode |
| Hook probe | after activation | a `menu-_ready-pre` hook on Menu.gd's `_ready`, which every hook pack wraps. 30 s later: `[RTVCodegen] HOOK-API menu_ready: count=N`, then `HOOK-API-LIVE` (info) or `HOOK-API-DEAD: 0 callback fires` (critical) |
| AUTOLOAD-CHECK | after activation | `[RTVCodegen] AUTOLOAD-CHECK <name>: script=<path> script_has_rename=<bool> instance_has_rename=<bool>` for `Loader`, `Database` and `Simulation`. `true` then `false` means the live node still runs the old bytecode |
| Registry probe | after activation | `[RegistryProbe]` lines checking that `Database` holds its extracted scenes and that `get()` returns a `PackedScene` |
| Dispatch counts | 30 s after activation | generated wrappers count calls only in developer mode. `[RTVCodegen] DISPATCH-COUNT top 20 / N tracked methods`, and a critical `LIFECYCLE-RUNAWAY` when a `_ready`, `_enter_tree` or `_init` fired more than 10 times: those run once per node, so a mod is calling them in a loop |

The code is in [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd), [conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd) and [logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd).

## What stays the same

The two-pass restart, hook-pack generation and activation, the `RTVModLib` API and `override.cfg` behave the same in every mode. The stability canaries, the VFS-precedence canary and the DEFER-VERIFY watchdog report at their usual levels whether developer mode is on or off ([Stability-Canaries](Stability-Canaries)).
