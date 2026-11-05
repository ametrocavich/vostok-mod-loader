# Stability Canaries

Checks around hook-pack generation and activation that log one `[STABILITY]` line when something the loader depends on stops working. A silent failure is the worst case: hooks register, nothing fires, and nobody can trace why. All of them run for every player, in developer mode or not. The sentinel files that turn the loader off are in [Config-Files](Config-Files#sentinel-files-escape-hatches).

## The lines

Each line opens with the text below; the rest names the scripts or counts.

| Check | Level | Line | Meaning |
|---|---|---|---|
| A | critical | `ALL N rewrites failed to take effect` | No rewrite is live; hook mods do nothing this session |
| A | critical | `Hook rewrites missing on critical scripts:` | Hooks on the listed core scripts do not fire |
| A | info | `COMPILE-PROOF summary: N/M rewrites active` | Healthy; counts of failed and deferred scripts follow |
| B | critical | `Unsupported GDSC tokenizer vN on Godot <version>` | No hook pack this launch |
| B | info | `Detokenizer compatible: GDSC vN` | Healthy |
| C | critical | `Detokenized vanilla source failed the indentation sanity check` | No hook pack this launch |
| Probe | critical | `<file>: registry code does not compile against this game build` | The script ships with hooks only |
| Probe | critical | `<file>: the rewrite does not compile against this game build` | The script runs vanilla |
| Probe | info | `Probe-compiled N rewrite(s) in M ms before packing` | Counts shipped in full, without registry code, left vanilla |
| Probe | warning | `Repeating the last probe's verdicts:` | A later generation reuses the Pass 1 verdicts |
| VFS | critical | `VFS canary FAILED` | Pack mounted but not served; vanilla runs |
| VFS | info | `VFS canary OK` | Healthy |
| Watchdog | critical | `DEFER-VERIFY (60s): N deferred script(s) lazy-compiled WITHOUT the rewrite` | Hooks on those scripts do not fire |

Every failure also writes `user://modloader_hook_status.json`, and the next launcher turns it into a red banner on the Mods tab with a button to the loader's release page. A record from another loader version, game executable or game `.pck` is ignored, so a game update alone shows nothing until the next activation says whether hooks still work.

## Canary A: COMPILE-PROOF

After activation, `_compile_proof` in [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) reads `get_script_method_list()` of each rewritten script that was not deferred; a `_rtv_vanilla_*` method proves the rewrite compiled into the cached script. `_canary_a_verdict` raises the alarm when none passed, or when one of `_CANARY_A_CRITICAL_SCRIPTS` (`Controller.gd`, `Camera.gd`, `WeaponRig.gd`, `Door.gd`, `Trader.gd`, `Hitbox.gd`, `LootContainer.gd`, `Pickup.gd`) failed.

Activation has a fallback for scripts the engine compiled from bytecode ([Hook-Pack](Hook-Pack#activation)). When that fails too, `hook()` still succeeds and the dispatch machinery still runs, but nothing intercepts anything; this check is the only signal.

## Canary B: GDSC tokenizer version

`_pack_preflight`, the first step of `_generate_hook_pack`, calls `_probe_gdsc_version` in [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd). It reads the first of `Camera`, `Controller`, `Audio` and `AI` (`.gd`, then `.gdc`) that has the `GDSC` magic and returns the version at offset 4, or -1 when none is readable.

Anything but 100, 101 or -1 stops generation. Without the check, a new tokenizer would fail every script one at a time with an empty-source warning each. On -1 there is no line, and generation proceeds without canaries B and C.

## Canary C: detokenizer round-trip

With mods loaded and canary B passed, `_canary_detokenizer_roundtrip_ok` detokenizes the same probe scripts through `_detokenize_script` (not `_read_vanilla_source`, so a cache from an earlier session cannot mask a broken detokenizer). It passes on the first reconstruction that has a colon-terminated `func` line followed by a tab-indented body line, and fails only when some probe produced source and none passed, so one odd script cannot disable hooks.

The engine can keep version 101 while changing what the column map means, and a game update that reindents its scripts breaks `_indent_from_column`'s `col / 4` without touching the version ([GDSC-Detokenizer](GDSC-Detokenizer#reconstruction)). Canary B only reads the integer. `check_detok.sh` covers the reader on synthetic buffers; this canary is the only check against the shipped `.gdc` files.

## Pre-ship compile probe

The pack serves its `.gd` over the game's bytecode and shadows the `.gdc`, so a rewrite that does not compile would take the vanilla script down with it. The likeliest cause is a game update renaming a member the registry code names ([Limitations](Limitations#a-game-update-can-outdate-the-registry-code)).

`_hook_pack_vet_rewrite` compiles each rewrite before `_hook_pack_write_zip` packs it, through `_rtv_probe_compiles`: a `GDScript.new()` bound to no path, given the source minus its `class_name` line, then `reload()`. It passes when `reload()` returns OK and the method list has a `_rtv_vanilla_*` name. A failure tries the wrap-only form (hooks, no registry code), then leaves the script out of the pack. A demotion counts only when the plain vanilla text compiles in the same probe; otherwise the probe cannot judge the script and the full rewrite ships, with a debug line. Two engine facts shape this: a script that fails to compile still loads non-null with its source (only `can_instantiate()` is false and the method list is empty), and `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` at a live script's path recompiles that live script in place.

When: `_hook_pack_begin_vetting` probes on the Pass 1 generation, whose process exits right after, because compiling a script also compiles what its module-scope preloads pull in, which anywhere else would get ahead of mod overrides. The verdicts go to pass state as `hook_pack_demotions` (`res://` path to `wrap_only` or `excluded`), and later generations repeat them without probing. A generation with no pass state (the crash-breaker single pass) probes live, except scripts deferred to lazy compile. A mod-set change, a loader rebuild and a game update all force Pass 1, so every new input is probed. The gap: a script that first enters the surface in Pass 2, through `add_hook()` in a `!` early autoload that did not run in the Pass 1 process, ships unvetted.

The boot report marks a script left vanilla `LOST` and a wrap-only one `PARTIAL`, missing `registry code`. The status record is `demoted` with the script paths unless canary A has something worse; when every rewrite was excluded, nothing is packed and generation writes the record itself. The registry verbs that depend on a demoted target return `false` ([Registry](Registry#opting-in)).

## VFS-precedence canary

`_hook_pack_write_zip` adds `__modloader_canary__.txt` containing `MODLOADER-VFS-CANARY-<pack file name>`; the name is unique per generation, so a stale mount cannot satisfy it. `_hook_pack_mount_and_activate` reads it back through `res://` right after `load_resource_pack` and requires an exact match.

`load_resource_pack` can return true while the mount serves nothing. Activating then would leave cached scripts rewritten and lazy loads vanilla, so the loader skips `_activate_rewritten_scripts` and does not persist the pack path; the next launch regenerates it instead of remounting a broken pack. A failed mount and a failed zip write (disk full, I/O error) are handled the same way with `[RTVCodegen]` criticals, and all three write a `pack_failed` status record.

## DEFER-VERIFY watchdog

`_activate_rewritten_scripts` arms a one-shot 60-second timer when any rewritten script was deferred to lazy compile ([Limitations](Limitations#scene-preload-deferred-compile)). `_verify_deferred_scripts` then checks each deferred script game code has loaded (`ResourceLoader.has_cached`; nothing is force-loaded, which would recreate the ordering bug the deferral avoids) by walking the script and its base chain for a `_rtv_vanilla_*` method, so a mod override on top of the rewrite does not false-alarm. Otherwise it logs a debug line with the live count and the scripts not loaded yet. Deferred scripts skip canary A, so without this a VFS regression on exactly those scripts would be invisible.

## Crash recovery

The heartbeat, the Pass 2 dirty marker and safe mode are in [Architecture](Architecture); the files are listed in [Config-Files](Config-Files).

### Restart counter

There are two counters, because the obvious one cannot work alone. `[state] restart_count` in `user://mod_pass_state.cfg` is bumped by `_write_pass_state` and read by `_check_crash_recovery`, which resets to a clean state at `MAX_RESTART_COUNT` (2). But a Pass 2 crash leaves the dirty marker behind, the next static init calls `_static_force_vanilla_state`, and that deletes pass state with the counter in it.

So the streak also lives in `user://modloader_crash_streak` (`CRASH_STREAK_PATH`), a bare integer bumped by `_write_pass_state` and never touched by the wipe. When `_crash_breaker_tripped` sees it reach `MAX_RESTART_COUNT`, Pass 1 logs `Restart loop detected (N consecutive crashed restarts) -- staying single-pass this launch.`, resets the streak, restores a clean `override.cfg`, deletes pass state and finishes in a single pass, so the launcher stays reachable and the offending mod can be turned off. It leaves `user://modloader_crash_notice` for the next launcher's banner.

Every boot path ends in `_finish_boot`, which calls `_clear_restart_counter` after the autoloads are up and the scene reload has run, zeroing both counters. Pass 2 clears at its end, not its start: `load_all_mods`, autoload instantiation and the reload are the crash window. `check_boot_state.sh` pins all of this.
