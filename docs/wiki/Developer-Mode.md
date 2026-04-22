# Developer Mode

Dev mode is a per-user setting that unlocks folder-mod loading, verbose logging, and a battery of diagnostic probes. Off by default.

## How to enable

UI toolbar checkbox in the Mods tab: **Developer Mode** ([ui.gd:1302-1329](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L1302)). Toggle persists to `[settings] developer_mode` in `user://mod_config.cfg`.

Loading the saved value runs at Pass-1 boot via [ui.gd:14 `_load_developer_mode_setting`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L14). Log line `"Developer mode: ON"` if enabled.

## What it unlocks

### 1. Unpacked folder mods

Subdirectories of `<exe>/mods/` are recognized as mod archives and zipped to `user://vmz_mount_cache/<name>_dev.zip` on the fly. Without dev mode, subdirectories are ignored ([mod_discovery.gd:29](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L29)).

Folder entries show `[dev folder]` label in red in the UI ([ui.gd:1506-1511](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L1506)).

Use case: in-development mods you haven't packaged yet.

### 2. Verbose logging (`_log_debug`)

`_log_debug` ([logging.gd:20](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/logging.gd#L20)) is gated on `_developer_mode`. When off, debug-level lines are dropped silently.

Debug-level entries include:

- Skip-list rejections from the rewriter (`"[RTVCodegen] Skipped <file> (runtime-sensitive)"`)
- Per-mod rewrite summaries (`"[RTVCodegen] Rewrote Scripts/<file> (N hooks)"`)
- Sibling-autofix carry-forward (`"[Autofix] Carried N unchanged mod sibling script(s) forward into new hook pack"`)
- Stale cache cleanup (`"Removed stale cache: <name>"`)
- Replace-hook rejection details (`"[RTVModLib] replace hook '<name>' already owned (id=N), registration rejected"`)
- FileAccess / ResourceLoader existence diagnostics for failed autoload loads

### 3. Conflict report

`_print_conflict_summary` + `_write_conflict_report` ([conflict_report.gd:383,430](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L383)) always run, but are particularly useful in dev mode paired with the verbose logs.

Writes `user://modloader_conflicts.txt` with every log line from the session.

Console summary includes:

- Mods loaded count
- Conflicted resource paths with per-claim breakdown (marking `<-- wins` on the last entry)
- Framework overrides active (legacy path, usually empty)
- Hook registrations per name

### 4. Source scanner

[mod_loading.gd:319 `_scan_gd_source`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L319) runs per-mod when the mod has `.gd` files. Captures:

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

[conflict_report.gd:8 `_log_override_timing_warnings`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L8) (dev-only) logs which mods use `overrideScript()` -- those overrides only apply after scene reload:

```
<ModName> uses overrideScript() on: Controller.gd, Camera.gd
  -- applies after scene reload
```

### 6. OverrideVerify

Runs once after `frameworks_ready` from [conflict_report.gd:35 `_verify_script_overrides`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/conflict_report.gd#L35).

For each mod that uses `overrideScript()` dynamically, loads the declared target path post-autoloads and logs its `resource_path` + source head so operators can eyeball whether the `take_over_path` took effect:

```
[OverrideVerify] MyMod | res://Scripts/Controller.gd | resource_path=res://Scripts/Controller.gd src_head=[extends "res://ModBase.gd" | ...]
```

Before v3.0.1, this probe classified cache state by method prefix (`_rtv_mod_*` / `_rtv_vanilla_*`). With mod source no longer rewritten under the cutover, there's no in-source signal for STALE/BROKEN classification -- operators read the source head and decide. Layer B node_added probe, AutoloadInstanceProbe auto-swap, and tree-walk fallback were removed along with the Step C pipeline they classified against.

### 7. Live-probe hooks

[hook_pack.gd:599-623](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L599) registers real hooks via the public `hook()` API on 8 well-known methods:

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

Counters live in `Engine.meta("_rtv_probe_counts")`. 30-second timer ([hook_pack.gd:755-820](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L755)) logs per-hook counts + first-arg samples.

Verdict logs:

- **DISPATCH-LIVE / DISPATCH-DEAD**: `"DISPATCH-LIVE: N wrapper call(s) in 30s"` (OK) or `"DISPATCH-DEAD: 0 wrapper calls in 30s -- game code not hitting rewrite"` (critical).
- **HOOK-API-LIVE / HOOK-API-DEAD**: `"HOOK-API-LIVE: N callback fires total across probes -- full chain verified"` (OK) or `"HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken"` (critical).

If DISPATCH-LIVE fires but HOOK-API-DEAD, the dispatch wrapper runs but callbacks aren't registered -- `_hooks` dict state broken. If DISPATCH-DEAD, the wrapper itself isn't running -- VFS mount or activation broken.

### 8. AUTOLOAD-CHECK

[hook_pack.gd:692-719](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L692) (dev-only). For each of the 9 known autoloads, logs:

```
[RTVCodegen] AUTOLOAD-CHECK <name>: script=<path> script_has_rename=<bool> instance_has_rename=<bool>
```

If `script_has_rename=true` but `instance_has_rename=false`, the autoload node is still holding a pointer to the old bytecode via its `get_script()` -- rewrite isn't reaching the actual game instance.

### 9. IXP-VERIFY

[hook_pack.gd:785-820](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L785) (inside the 30s timer, dev-only). For Controller / Camera / WeaponRig, finds the first instance via `_rtv_collect_nodes_by_class`, walks its extends chain up to depth 6, and logs:

```
[IXP-VERIFY] <class> instance script: path=<path> src_len=<n> ixp_content=<bool> rewrite_content=<bool>
[IXP-VERIFY]   base[1]: path=<path> src_len=<n> ixp=<bool> rewrite=<bool>
[IXP-VERIFY]   base[2]: ...
```

Detects ImmersiveXP markers (`"ImmersiveXP"`, `"IXP "`, `"overrideScript"`) to confirm IXP's `take_over_path` chain is intact. If IXP is active: instance script shows IXP markers, base chain walks IXP -> our rewrite -> engine class. If IXP failed: instance script is our rewrite directly (no IXP ancestor).

### 10. Registry smoke probe

**Always runs** (not gated on dev mode) at [hook_pack.gd:721-745](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L721). Verifies `Database._rtv_vanilla_scenes` is populated and `db.get(first_key)` returns a PackedScene. Warns on failure.

### 11. Dispatch-live counters

Every dispatch wrapper increments counters in `Engine.meta`:

- `_rtv_dispatch_count` -- total wrapper calls this session
- `_rtv_dispatch_no_lib` -- calls where `RTVModLib` meta was missing (fallback path)
- `_rtv_dispatch_by_hook` -- dict of per-hook-base counts
- First wrapper call per hook prints `"[RTV-WRAPPER-FIRST] <hook_base>"` exactly once

These run regardless of dev mode but the 30s summary log is dev-only.

## Dev-mode gate placement

The gate is applied at the logging helper and at specific diagnostic entry points. The underlying telemetry (Engine meta counters, `_report_lines` append) runs unconditionally. Turning dev mode on in the UI surfaces the already-collected data; turning it off hides the summary logs but doesn't change loader behavior.

## What dev mode does NOT change

- Pass-1 / Pass-2 restart logic: same in both modes.
- Hook pack generation + mount: same.
- `RTVModLib` API: same.
- Override.cfg writing: same.
- Stability canary A / B / C alarms: always fire at their critical levels.

Dev mode is strictly additive -- extra logging and probes, no behavior changes in the loading path itself.
