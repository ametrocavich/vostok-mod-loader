# Developer Mode

Dev mode is a per-user setting. It turns on folder-mod loading, debug logging and a set of boot-time probes. Off by default.

## How to enable

Tick the **Developer mode** checkbox in the toolbar of the Mods tab ([ui_mods.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods.gd)). Its tooltip reads "Enables verbose logging, conflict report, and loose folder loading", and the bottom-bar hint says the same. The toggle persists as `[settings] developer_mode` in `user://mod_config.cfg`; toggling it rescans the mods folder and keeps the active profile.

[`_load_developer_mode_setting`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profiles.gd) reads the saved value at the start of both Pass 1 and Pass 2 (lifecycle.gd). If the live config is missing or corrupt it reads `developer_mode` from the rolling `.bak` instead, so a recoverable config error does not silently turn dev mode off and strand your folder mods for the session. When on, the log says `Developer mode: ON`.

## What it unlocks

### 1. Unpacked folder mods

Subdirectories of `<exe>/mods/` count as mods and are zipped to `user://vmz_mount_cache/<name>_dev.zip` on the fly. With dev mode off, subdirectories are ignored; `_record_hidden_folder` in [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd) still tracks them so the orphan scan and dependency checks treat them as present.

The temp zip is rebuilt only when the folder's contents changed. A folder-state stamp (newest mtime, file count, a per-file `path@mtime` hash) is stored in a `.zip.src` sidecar at zip time and compared on every launch (`_folder_dev_zip_current`, fs_archive.gd). An unchanged folder reuses the cached zip; an edit, a deletion or a timestamp change forces a rebuild on the next launch.

Folder entries show a red `[dev folder]` label in the Mods tab. A folder whose `mod.txt` does not parse carries the same `mod.txt parse error at ...` row warning an archive gets; the archive-shape warnings do not apply to folders.

Dev folders never get update downloads. The update check skips them, since a downloaded archive would land as a duplicate beside your folder. Your working copy on disk is always what loads.

This is for mods you have not packaged yet.

### 2. Debug logging (`_log_debug`)

`_log_debug` ([logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd)) is gated on `_developer_mode`. When off it is a full no-op: nothing printed, nothing appended to the report buffer.

Debug-level lines include:

- Skip-list rejections from the rewriter (`[RTVCodegen] Skipped <file> (runtime-sensitive)`)
- Per-script rewrite summaries (`[RTVCodegen] Rewrote res://Scripts/<file> (N hooks)`)
- The per-target reconciliation table (`[RTVCodegen] reconcile <path> :: <methods> [<declared>] -> <status>`)
- Sibling-autofix carry-forward (`[Autofix] Carried N unchanged mod sibling script(s) forward into new hook pack ...`)
- Stale cache cleanup (`Removed stale cache: <name>`)
- Replace-hook rejections (`[RTVModLib] replace hook '<name>' already owned (id=N), registration rejected`)
- The override timing and OverrideVerify lines from sections 5 and 6
- FileAccess / ResourceLoader existence checks for autoloads that failed to load

### 3. Conflict report

`_print_conflict_summary` and `_write_conflict_report` ([conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd)) run from every finish path in lifecycle.gd, only when dev mode is on.

The report is `user://modloader_conflicts.txt`, every buffered log line from the session (capped at 5000 lines by `_report_append`).

The console summary lists the loaded mod count, each conflicted resource path with its claimants (`<-- wins` on the last one), and hook registrations per name.

### 4. Source scanner

`_scan_gd_source` in [mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) runs per mod with `.gd` files, in every mode; only the reporting is dev-gated. It fills `_mod_script_analysis[mod_name]` with:

- `take_over_literal_paths`: literal `take_over_path("res://...")` calls
- `extends_paths`: `extends "res://..."` paths
- `extends_class_names`: `extends ClassName` references (these break override chains)
- `class_names`: the mod's own `class_name` declarations (Godot bug #83542)
- `uses_dynamic_override`: any `take_over_path(` call at all
- `lifecycle_no_super`: lifecycle methods (`_ready`, `_process`, ...) in extending scripts that never call `super(`
- `calls_base`: `base(` calls, the Godot 3 pattern
- `preload_paths`: every `preload("res://...")`
- `override_methods`: `extends_path -> [method_names]`, for collision detection
- `hook_calls`: literal `.hook("...")` calls, which `_merge_hook_calls_into_wrap_mask` folds into the wrap surface

### 5. Override timing warnings

`_log_override_timing_warnings` in conflict_report.gd logs, at debug level, which mods use `overrideScript()`. Those overrides only apply after a scene reload:

```
<ModName> uses overrideScript() on: Controller.gd, Camera.gd -- applies after scene reload
```

### 6. OverrideVerify

`_verify_script_overrides` in conflict_report.gd runs once from `_emit_frameworks_ready`, in every mode. For each mod that uses `overrideScript()`, it loads the declared target after the autoloads have run and logs the `resource_path` plus the head of the source, at debug level:

```
[OverrideVerify] MyMod | res://Scripts/Controller.gd | resource_path=res://Scripts/Controller.gd src_head=[extends "res://ModBase.gd" | ...]
```

A `load()` that returns null is a warning in every mode. Mod source is never rewritten, so there is no marker in a mod's own script to classify cache state against; the probe reports the head and leaves the judgement to you.

### 7. Live-probe hooks

`_dev_hook_probes` in [debug.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/debug.gd), called from `_activate_rewritten_scripts` in dev mode, registers real hooks through the public `hook()` API on eight methods:

| Hook | Fires |
|---|---|
| `loader-_physics_process-pre` | Every tick from game start |
| `simulation-_process-pre` | Every tick |
| `profiler-_process-pre` | Every tick |
| `menu-_ready-pre` | Menu UI init |
| `settings-loadpreferences-pre` | Preferences load |
| `controller-_physics_process-pre` | Every tick in the world |
| `character-_physics_process-pre` | Every tick in the world |
| `camera-_physics_process-pre` | Every tick in the world |

Counters live in `Engine.get_meta("_rtv_probe_counts")`. A 30-second timer then logs one `[RTVCodegen] HOOK-API <key>: count=N first_arg=...` line per probe, followed by a verdict: `HOOK-API-LIVE: N callback fires total across probes -- full chain verified` (info) or `HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken` (critical).

When dispatch counts are non-zero the same timer prints `DISPATCH-COUNT top 20 / N tracked methods`, the hottest wrapped methods in the window, and a critical `LIFECYCLE-RUNAWAY` line if any `_ready`, `_enter_tree` or `_init` fired more than 10 times. Those fire once per node; a high count usually means a mod calls them from a loop, which is where connect-already-connected error spam comes from.

### 8. AUTOLOAD-CHECK

Also in `_dev_hook_probes`. For each of nine autoloads (`Database`, `GameData`, `Settings`, `Menu`, `Loader`, `Inputs`, `Mode`, `Profiler`, `Simulation`) it logs:

```
[RTVCodegen] AUTOLOAD-CHECK <name>: script=<path> script_has_rename=<bool> instance_has_rename=<bool>
```

`script_has_rename=true` with `instance_has_rename=false` means the autoload node still holds the old bytecode through `get_script()`: the rewrite is not reaching the live instance.

### 9. IXP-VERIFY

Inside the 30-second timer. For `Controller`, `Camera` and `WeaponRig` it finds the first instance with `_rtv_collect_nodes_by_class`, walks the `extends` chain up to depth 6, and logs:

```
[IXP-VERIFY] <class> instance script: path=<path> src_len=<n> ixp_content=<bool> rewrite_content=<bool>
[IXP-VERIFY]   base[1]: path=<path> src_len=<n> ixp=<bool> rewrite=<bool>
[IXP-VERIFY]   base[2]: ...
```

ImmersiveXP markers (`"ImmersiveXP"`, `"IXP "`, `"overrideScript"`) confirm IXP's `take_over_path` chain is intact. With IXP active, the instance script shows IXP markers and the base chain walks IXP, then our rewrite, then the engine class. If IXP failed, the instance script is our rewrite directly.

### 10. Registry smoke probe

Also in `_dev_hook_probes`. Logs under `[RegistryProbe]`: checks that `Database._rtv_vanilla_scenes` exists and is populated and that `db.get(first_key)` returns a PackedScene, warning on each failure.

### 11. Dispatch counters

Per-hook-base counts accumulate in `_dispatch_counts` (constants.gd). The generated wrappers increment it only when dev mode is on; `_rtv_dispatch_inline_src` in rewriter_rewrite.gd emits the increment inside an `if _lib._developer_mode:` block. The dict is cleared when the 30-second window starts and printed as the DISPATCH-COUNT breakdown from section 7.

### 12. Mod author notes

Mods-tab rows show notes meant for the mod's author only while dev mode is on: an unquoted `[mod] version`, a missing `id=`, a stale export bake beside the sources, an unrecognized `[updates] source=`. Real breakage (an invalid zip, a `mod.txt` that fails to parse or sits in a subfolder, an autoload path that resolves nowhere) shows to everyone regardless. `_build_entry_author_notes` in mod_discovery.gd builds the list.

## Where the gate sits

- `_log_debug` (logging.gd): full no-op when off.
- `_activate_rewritten_scripts` (hook_pack.gd) calls `_dev_preactivate_summary` and `_dev_hook_probes` (debug.gd) only when dev mode is on; between them COMPILE-PROOF (canary A) runs for everyone.
- The conflict summary and report calls in lifecycle.gd.
- The `_dispatch_counts` increment inside each generated wrapper.

Dev mode changes what loads in exactly one way: folder mods are discovered and loaded only while it is on.

## What dev mode does not change

- The Pass 1 / Pass 2 restart logic.
- Hook pack generation, mount and activation.
- The `RTVModLib` API.
- `override.cfg` writing.
- Canaries A, B and C, the VFS-precedence canary and the DEFER-VERIFY watchdog all fire at their critical levels in every mode. Only canary A's per-script `[COMPILE-PROOF]` detail lines and the end-to-end hook probes are dev-only.

Apart from folder mods, dev mode only adds logging and probes.
