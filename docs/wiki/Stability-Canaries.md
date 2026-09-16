# Stability Canaries

Boot-time probes that log one loud line when something the loader depends on stops working. Silent breakage is the worst case: mods fail in ways nobody can trace. One actionable `[STABILITY]` line beats a stream of downstream symptom warnings.

## Canary A: COMPILE-PROOF

Location: [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd), the summary block in `_activate_rewritten_scripts`. It runs for every player; the developer-mode probes in `debug.gd` follow it.

The compile-proof check and this alarm run for every player, in developer mode or not (the end-to-end hook probes and the autoload inspection stay developer-only). Its outcome is also written to `user://modloader_hook_status.json`, and the launcher reads that record on the next start: if none of the rewrites took effect, or a critical script lost its rewrite, the Mods tab shows a red banner saying hooks did not work last session, with a button to the loader's release page. Canary B and canary C write the same record when they stop generation, so an unsupported script format after a game update is reported in the launcher as well as the log. A record written by another loader version, or before the game executable changed, is ignored. Static init also drops a `user://modloader_game_updated` marker when the executable's mtime changes; the Mods tab shows a notice while it exists, and the next healthy activation removes it.

Probe: after activation, inspect `get_script_method_list()` of each rewritten vanilla script that was not deferred. Any `_rtv_vanilla_*` method name proves the rewrite compiled into the cached GDScript.

Alarm levels:

- Zero of N rewrites active, critical:
  ```
  [STABILITY] ALL N rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken.
  Mods will NOT work this session. Click 'Reset to Vanilla' in the UI
  or create modloader_disabled in the game folder.
  ```
  ("Reset to Vanilla" is the string in the code; the button is labeled "Launch vanilla", see the escape hatches below.)
- A critical script failed, critical. The set is `Controller.gd, Camera.gd, WeaponRig.gd, Door.gd, Trader.gd, Hitbox.gd, LootContainer.gd, Pickup.gd`:
  ```
  [STABILITY] Hook rewrites missing on critical scripts: <list>.
  Hooks on these scripts will NOT fire this session
  (likely cache-pinning fallback failure).
  ```
- Everything fine, info:
  ```
  [STABILITY] COMPILE-PROOF summary: N/M rewrites active (K pinned-fallback), X deferred to lazy-compile
  ```

Why: activation has a fallback (`CACHE_MODE_IGNORE + take_over_path`) for scripts the PCK pre-compiled. If the fallback fails, this is the only signal that hooks on those scripts will not fire. `hook()` still succeeds and the dispatch machinery still runs; it just never intercepts anything.

## Canary B: GDSC tokenizer version

Location: the start of `_generate_hook_pack` in hook_pack.gd, using `_probe_gdsc_version` in [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd).

Probe: read the header of the first readable script among `Camera`, `Controller`, `Audio`, `AI` (`.gd`, then `.gdc`), confirm the `GDSC` magic in the first four bytes, return the u32 version at offset 4. Returns -1 when none of the four is readable.

Alarm levels:

- Not 100 or 101, and not -1, critical:
  ```
  [STABILITY] Unsupported GDSC tokenizer vN on Godot <version>.
  This ModLoader supports v100 (Godot 4.3-4.4) and v101 (Godot 4.5-4.6).
  Hook pack generation disabled -- script hooks will not fire.
  See README for supported Godot versions.
  ```
- Supported, info: `[STABILITY] Detokenizer compatible: GDSC vN on Godot <version>`.
- -1: no line, generation proceeds without this check.

Why: a future Godot with a v102 tokenizer would otherwise produce an "Empty detokenized source" warning for every hookable script and fall back to vanilla one script at a time. Canary B stops generation with one message before any rewrite work.

## Canary C: detokenizer round-trip

Location: `_canary_detokenizer_roundtrip_ok` in hook_pack.gd, called from `_generate_hook_pack` right after the no-mods short-circuit.

Probe: with mods loaded and canary B passed, detokenize the probe scripts that carry GDSC bytes (same four as canary B) through `_detokenize_script` directly, not `_read_vanilla_source`, so a pristine on-disk cache from an earlier session cannot mask a detokenizer that is broken against the current build. The canary passes on the first probe whose reconstruction has a colon-terminated `func` line followed by a tab-indented body line, and fails only when some probe produced source and none passed, so one unusual script cannot disable hooks for the session.

Alarm levels:

- Inconclusive (no probe detokenizable, or the version probe returned -1): proceed, same as canary B.
- The indentation check fails, critical:
  ```
  [STABILITY] Detokenized vanilla source failed the indentation sanity check on Godot <version>
  (GDSC version is still <N>). Two known causes: the .gdc column format changed, or the game's
  scripts are no longer indented with 4 spaces per level -- _indent_from_column's `col / 4`
  depends on that. See the note above _indent_from_column in gdsc_detokenizer.gd.
  Hook pack generation disabled -- script hooks will not fire.
  Update the ModLoader to a version that supports this game build.
  ```

Why: the engine can keep the version at 101 while changing what the column map means, and a game update that reindents the scripts breaks `col / 4` without touching the version. Canary B only reads the integer. On failure `_generate_hook_pack` returns empty and vanilla runs.

`check_detok.sh` covers the reader against synthetic buffers; canary C is still the only check against a real `.gdc` from the shipped PCK.

## VFS-precedence canary

Location: `_generate_hook_pack`, a file written just before the pack zip closes and read back right after `load_resource_pack`.

Probe: the pack carries `__modloader_canary__.txt` with the content `MODLOADER-VFS-CANARY-<pack zip filename>`. The filename is the per-call ticks-stamped one, so a stale previous-session mount cannot satisfy the readback. After mounting, `FileAccess.get_file_as_string("res://__modloader_canary__.txt")` must match exactly.

Alarm levels:

- Missing or wrong content, critical:
  ```
  [STABILITY] VFS canary FAILED (got '<prefix>', expected '<canary content>')
  -- hook pack mounted but files aren't served. Skipping activation: script hooks will not fire
  this session, vanilla scripts run. Pack state not persisted; next launch regenerates.
  ```
- Readable, info: `[STABILITY] VFS canary OK: hook pack mount precedence verified (<content>)`.

Why: `ProjectSettings.load_resource_pack` can return true while the mount serves nothing (stale handles, format mismatch). Activating anyway would leave a half-modded state: cached scripts rewritten through direct source mutation, lazy VFS loads falling back to vanilla. So the loader skips `_activate_rewritten_scripts` and does not persist the pack path; a transient failure heals on the next launch instead of static init remounting a broken pack.

The mount and write steps fail the same way:

- `load_resource_pack` returns false: critical `[RTVCodegen] Failed to mount hook pack at <path> -- script hooks will not fire this session, vanilla scripts run. Next launch regenerates the pack.`
- Writing the zip fails (disk full, I/O error): the partial zip is deleted, critical `[RTVCodegen] Hook pack write failed (disk full / I/O error?) at <path> -- pack discarded, hooks disabled this session, running vanilla.`

In all three cases nothing is persisted, so the next launch starts from scratch.

## DEFER-VERIFY watchdog

Location: `_activate_rewritten_scripts`, a one-shot 60-second timer armed when any rewritten script was deferred from eager compile because of a module-scope scene `preload()` (see [Limitations](Limitations#scene-preload-deferred-compile)).

Probe: for each deferred script that game code has loaded by then (`ResourceLoader.has_cached`; nothing is force-loaded, since that would recreate the ordering bug the deferral avoids), walk the script and its base chain for a `_rtv_vanilla_*` method, so a mod override sitting on top of the rewrite does not false-alarm.

Alarm levels:

- Any loaded deferred script lacks the rewrite, critical:
  ```
  [STABILITY] DEFER-VERIFY (60s): N deferred script(s) lazy-compiled WITHOUT the rewrite
  -- VFS did not serve the hook pack for: <list>. Hooks on these will not fire this session.
  ```
- Otherwise a debug line with the live count and the scripts not loaded yet.

Why: deferred scripts skip COMPILE-PROOF, so without this a VFS precedence regression on exactly those scripts would be invisible.

## Escape hatches

### modloader_disabled sentinel

Path: `<exe_dir>/modloader_disabled`, in the game folder, not `user://`.

Effect: static init sees the file and does nothing this session: no mounts, no launcher, no autoloads. The game runs as if the loader were not installed. It also resets the persistent state (override.cfg autoload sections, pass state, hook pack) for the next launch.

Check: `_is_modloader_disabled` in [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd), first thing in `_mount_previous_session`.

Use it when the loader itself is broken and the launcher cannot come up. Create the file by hand, remove it to re-enable.

### modloader_safe_mode sentinel

Path: `<exe_dir>/modloader_safe_mode`.

Effect: on the next boot, wipe pass state, reset `override.cfg` to the clean baseline, delete the heartbeat, remove the sentinel. Then Pass 1 continues and the launcher appears.

Check: `_check_safe_mode` in boot.gd, from Pass 1.

Use it when mods are broken but the loader works. Remove the bad mod in the launcher on the next launch.

### Launch vanilla button

Location: the bottom bar of the launcher, next to Launch. Button text "Launch vanilla"; hint "Launch without mods for this session. Restarts the game."

Effect: writes `modloader_disabled_once` in the game folder (same effect as `modloader_disabled`, but the loader deletes it after that one launch), runs `_static_force_vanilla_state` (the same cleanup as the disabled sentinel), strips `--modloader-restart` from the command line, and restarts. One shot: the following launch is vanilla, the one after that is modded again, profiles and selections untouched.

Source: `_launch_vanilla_once` in [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd).

Use it when mods loaded but the game crashes or misbehaves and you want one guaranteed vanilla launch without losing your setup. The `modloader_disabled_once` file can also be created by hand.

## Crash recovery

### Heartbeat

File: `user://modloader_heartbeat.txt`.

Written just before the Pass 1 to Pass 2 restart (`_write_heartbeat`, boot.gd); deleted by every finish path (`_delete_heartbeat`).

Detection: `_check_crash_recovery` at the next Pass 1. A surviving heartbeat means the previous launch did not finish; the loader warns and clears it. If pass state also shows `restart_count >= MAX_RESTART_COUNT` (2), it logs `Restart loop (N crashes) -- resetting to clean state`, restores a clean `override.cfg`, deletes pass state and the heartbeat.

### Restart counter

Two counters, because the obvious one cannot work on its own.

`[state] restart_count` in `user://mod_pass_state.cfg` is bumped by `_write_pass_state` and read by `_check_crash_recovery` above. But a Pass 2 crash leaves the dirty marker behind, the next static init calls `_static_force_vanilla_state`, and that deletes pass state, the file the counter lives in. A counter kept only there could never trip.

So the streak lives in its own file, `user://modloader_crash_streak` (`CRASH_STREAK_PATH`): a bare integer, bumped by `_write_pass_state`, never touched by the wipe. `_crash_breaker_tripped` returns true when it reaches `MAX_RESTART_COUNT`. Pass 1 checks it before arming a two-pass restart and, when tripped, logs

```
Restart loop detected (N consecutive crashed restarts) -- staying single-pass this launch.
Disable recently added mods if the game is unstable.
```

resets the streak, restores a clean `override.cfg`, deletes pass state and finishes single-pass. The launcher stays reachable, so you can turn the offending mod off.

Reset to zero: every boot path ends in `_finish_boot`, which calls `_clear_restart_counter` after the autoloads are instantiated; that zeroes both counters. Pass 2 clears at its end, not at entry: `load_all_mods` and autoload instantiation are the crash window, and clearing before them would record a streak of zero for a crashed launch.

`check_boot_state.sh` pins all of this: the streak survives the wipe, one crash does not trip, two do, a clean finish resets to zero, and the Pass 2 clear stays after the crash window.

### Pass 2 dirty marker

File: `user://modloader_pass2_dirty`.

Written first thing in `_run_pass_2` ([lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd)) with the current timestamp; deleted in the cleanup block at the end of the same function.

Detection: static init checks for it in `_mount_previous_session`. A survivor means Pass 2 was interrupted (force quit, crash, power loss); the hook pack may be half-written and pass state plus `override.cfg` describe a state that never finished. Full wipe through `_static_force_vanilla_state("pass 2 crashed mid-run", ...)`.

## Combined recovery flow

When something goes wrong mid-run, the defenses fire in this order:

1. Crash during Pass 2: `modloader_pass2_dirty` survives, static init wipes on the next boot, you get a clean Pass 1. The streak file survives the wipe.
2. Crash during Pass 1 before the restart: no heartbeat was written, the next boot is a normal Pass 1.
3. Two crashed restarts in a row: the streak reaches 2, `_crash_breaker_tripped` makes Pass 1 refuse the restart and stay single-pass with the launcher available.
4. You created `modloader_safe_mode`: Pass 1's `_check_safe_mode` wipes state and continues to the launcher.
5. You created `modloader_disabled`: static init skips everything and the loader idles until the file is removed.

Nothing asks Godot to try again without resetting state. Compounding retries across a persistent fault is how a game ends up not booting without a reinstall.
