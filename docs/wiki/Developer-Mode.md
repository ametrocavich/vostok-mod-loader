# Developer Mode

Dev mode is a per-user setting that unlocks folder-mod loading, verbose logging, and a battery of diagnostic probes. Off by default.

## How to enable

UI toolbar checkbox in the Mods tab: **Developer mode** ([ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd)). Toggle persists to `[settings] developer_mode` in `user://mod_config.cfg`.

`_load_developer_mode_setting` (ui.gd) loads the saved value at boot on both Pass 1 and Pass 2 (lifecycle.gd). If the live config is missing or corrupt, it reads `developer_mode` from the rolling `.bak` config instead, so a recoverable corrupt config doesn't silently turn dev mode off and strand folder mods for the session. Log line `"Developer mode: ON"` if enabled.

## What it unlocks

### 1. Unpacked folder mods

Subdirectories of `<exe>/mods/` are recognized as mod archives and zipped to `user://vmz_mount_cache/<name>_dev.zip` on the fly. Without dev mode, subdirectories are ignored ([mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)).

The temp zip is only rebuilt when the folder's contents actually changed -- a folder-state hash (newest mtime + file count + per-file path@mtime) is stored in a `.zip.src` sidecar at zip time and compared on each launch (`_folder_dev_zip_current`, fs_archive.gd). Unchanged folders reuse the cached zip and mount; edits, deletions, or timestamp changes force a rebuild on the next launch.

Folder entries show `[dev folder]` label in red in the UI ([ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd)).

Dev folders are never offered update downloads: the Updates tab skips them during the check (a downloaded archive would land as a duplicate beside your folder) and shows a "Dev folder" status instead of an Update button. Your working copy on disk is always what loads.

Use case: in-development mods you haven't packaged yet.

### 2. Verbose logging (`_log_debug`)

`_log_debug` ([logging.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd)) is gated on `_developer_mode`. When off, it is a full no-op -- debug-level lines are neither printed nor appended to the report buffer.

Debug-level entries include:

- Skip-list rejections from the rewriter (`"[RTVCodegen] Skipped <file> (runtime-sensitive)"`)
- Per-mod rewrite summaries (`"[RTVCodegen] Rewrote Scripts/<file> (N hooks)"`)
- Sibling-autofix carry-forward (`"[Autofix] Carried N unchanged mod sibling script(s) forward into new hook pack"`)
- Stale cache cleanup (`"Removed stale cache: <name>"`)
- Replace-hook rejection details (`"[RTVModLib] replace hook '<name>' already owned (id=N), registration rejected"`)
- FileAccess / ResourceLoader existence diagnostics for failed autoload loads

### 3. Conflict report

`_print_conflict_summary` + `_write_conflict_report` ([conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd)) run only when dev mode is on, called from every finish path in lifecycle.gd.

Writes `user://modloader_conflicts.txt` with every log line from the session.

Console summary includes:

- Mods loaded count
- Conflicted resource paths with per-claim breakdown (marking `<-- wins` on the last entry)
- Hook registrations per name

### 4. Source scanner

[`_scan_gd_source` in mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) runs per-mod when the mod has `.gd` files. Captures:

- `take_over_literal_paths` -- `take_over_path("res://...")` literal calls
- `extends_paths` -- `extends "res://..."` paths
- `extends_class_names` -- `extends ClassName` references (breaks override chains)
- `class_names` -- own `class_name` declarations (interacts with Godot bug #83542)
- `uses_dynamic_override` -- any `take_over_path(` call (superset)
- `lifecycle_no_super` -- list of lifecycle methods (`_ready`, `_process`, etc.) in scripts with `extends` that don't call `super(`
- `calls_base` -- `base(` -- Godot-3 pattern, usually a removed parent method
- `preload_paths` -- all `preload("res://...")`
- `override_methods` -- `extends_path -> [method_names]` for collision detection

Consumed by downstream diagnostics and stored in `_mod_script_analysis`.

### 5. Override timing warnings

[`_log_override_timing_warnings` in conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd) (dev-only) logs which mods use `overrideScript()` -- those overrides only apply after scene reload:

```
<ModName> uses overrideScript() on: Controller.gd, Camera.gd
  -- applies after scene reload
```

### 6. OverrideVerify

Runs once after `frameworks_ready` from [`_verify_script_overrides` in conflict_report.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd).

For each mod that uses `overrideScript()` dynamically, loads the declared target path post-autoloads and logs its `resource_path` + source head so operators can eyeball whether the `take_over_path` took effect:

```
[OverrideVerify] MyMod | res://Scripts/Controller.gd | resource_path=res://Scripts/Controller.gd src_head=[extends "res://ModBase.gd" | ...]
```

Before v3.0.1, this probe classified cache state by method prefix (`_rtv_mod_*` / `_rtv_vanilla_*`). With mod source no longer rewritten under the cutover, there's no in-source signal for STALE/BROKEN classification -- operators read the source head and decide. Layer B node_added probe, AutoloadInstanceProbe auto-swap, and tree-walk fallback were removed along with the Step C pipeline they classified against.

### 7. Live-probe hooks

[hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) registers real hooks via the public `hook()` API on 8 well-known methods:

| Hook | Fires |
|---|---|
| `loader-_physics_process-pre` | Every tick from game start |
| `simulation-_process-pre` | Every tick |
| `profiler-_process-pre` | Every tick |
| `menu-_ready-pre` | Menu UI init |
| `settings-loadpreferences-pre` | User loads preferences |
| `controller-_physics_process-pre` | Every tick in world |
| `character-_physics_process-pre` | Every tick in world |
| `camera-_physics_process-pre` | Every tick in world |

Counters live in `Engine.meta("_rtv_probe_counts")`. A 30-second timer (hook_pack.gd) then logs a `[RTVCodegen] HOOK-API <key>: count=N first_arg=...` line per probe, followed by a verdict:

- **HOOK-API-LIVE / HOOK-API-DEAD**: `"HOOK-API-LIVE: N callback fires total across probes -- full chain verified"` (OK) or `"HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken"` (critical).

When dispatch counts are nonzero, the same timer also prints `DISPATCH-COUNT top 20 / N tracked methods` -- a per-method breakdown of the hottest hook dispatches in the window -- and a critical `LIFECYCLE-RUNAWAY` line if any `_ready` / `_enter_tree` / `_init` fired more than 10 times (those should fire once per node; elevated counts usually mean a mod is re-invoking them from a loop, the typical cause of connect-already-connected error spam).

### 8. AUTOLOAD-CHECK

In [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) (dev-only). For each of the 9 known autoloads, logs:

```
[RTVCodegen] AUTOLOAD-CHECK <name>: script=<path> script_has_rename=<bool> instance_has_rename=<bool>
```

If `script_has_rename=true` but `instance_has_rename=false`, the autoload node is still holding a pointer to the old bytecode via its `get_script()` -- rewrite isn't reaching the actual game instance.

### 9. IXP-VERIFY

In [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) (inside the 30s timer, dev-only). For Controller / Camera / WeaponRig, finds the first instance via `_rtv_collect_nodes_by_class`, walks its extends chain up to depth 6, and logs:

```
[IXP-VERIFY] <class> instance script: path=<path> src_len=<n> ixp_content=<bool> rewrite_content=<bool>
[IXP-VERIFY]   base[1]: path=<path> src_len=<n> ixp=<bool> rewrite=<bool>
[IXP-VERIFY]   base[2]: ...
```

Detects ImmersiveXP markers (`"ImmersiveXP"`, `"IXP "`, `"overrideScript"`) to confirm IXP's `take_over_path` chain is intact. If IXP is active: instance script shows IXP markers, base chain walks IXP -> our rewrite -> engine class. If IXP failed: instance script is our rewrite directly (no IXP ancestor).

### 10. Registry smoke probe

Dev-only (behind the same `if not _developer_mode: return` gate as the probes) in [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd). Logs under `[RegistryProbe]`: verifies `Database._rtv_vanilla_scenes` is populated and `db.get(first_key)` returns a PackedScene; warns on failure.

### 11. Dispatch counters

Per-hook-base counts accumulate in the loader's `_dispatch_counts` dict (constants.gd). The generated dispatch wrappers increment it only when dev mode is on (rewriter.gd emits the increment inside an `if _lib._developer_mode:` block). The dict is cleared at the start of the 30s probe window (hook_pack.gd) and printed as the DISPATCH-COUNT top-20 breakdown, with the LIFECYCLE-RUNAWAY red-flag check described in section 7.

## Dev-mode gate placement

The gate is applied at:

- `_log_debug` (logging.gd) -- full no-op when off, nothing printed or buffered.
- The diagnostic entry points in hook_pack.gd -- a single `if not _developer_mode: return` covers the live probes, COMPILE-PROOF, AUTOLOAD-CHECK, the registry probe, IXP-VERIFY, and the 30s timer.
- The conflict summary / report calls in lifecycle.gd.
- Inside the generated dispatch wrappers, for the `_dispatch_counts` increments.

Dev mode is load-affecting in exactly one way: folder mods are only discovered and loaded while it is on.

## What dev mode does NOT change

- Pass-1 / Pass-2 restart logic: same in both modes.
- Hook pack generation + mount: same.
- `RTVModLib` API: same.
- Override.cfg writing: same.
- Stability canaries B and C and the VFS-precedence canary: always fire at their critical levels. Canary A (the COMPILE-PROOF summary) is dev-only.

Aside from making folder mods eligible, dev mode is additive -- extra logging and probes.
