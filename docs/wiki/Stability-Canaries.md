# Stability Canaries

Boot-time probes that alarm loudly when something the loader depends on silently regresses. The design principle: silent breakage is the worst mode, because mods fail in non-obvious ways. One loud actionable log line beats a flood of downstream symptom warnings.

## Canary A: COMPILE-PROOF

**Location**: [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) `_activate_rewritten_scripts` (canary A summary block)

**Probes**: after `_activate_rewritten_scripts` completes, inspects `get_script_method_list()` for each rewritten vanilla. The presence of any `_rtv_vanilla_*` method name confirms the rewrite compiled into the cached GDScript.

**Alarm levels**:

- **Zero of N rewrites active** -> critical:
  ```
  [STABILITY] ALL N rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken.
  Mods will NOT work this session. Click 'Reset to Vanilla' in the UI
  or create modloader_disabled in the game folder.
  ```
  (The "Reset to Vanilla" wording is verbatim from the code string; the UI button is now labeled "Launch vanilla" -- see the escape hatches below.)
- **Any critical script failed** -> critical. The critical set (defined in the same summary block): `Controller.gd, Camera.gd, WeaponRig.gd, Door.gd, Trader.gd, Hitbox.gd, LootContainer.gd, Pickup.gd`
  ```
  [STABILITY] Hook rewrites missing on critical scripts: <list>.
  Hooks on these scripts will NOT fire this session
  (likely cache-pinning fallback failure).
  ```
- **Everything OK** -> info summary line with per-bucket counts:
  ```
  [STABILITY] COMPILE-PROOF summary: N/M rewrites active (K pinned-fallback), X deferred to lazy-compile
  ```

**Why it matters**: the activation flow has a fallback path (`CACHE_MODE_IGNORE + take_over_path`) for PCK-pre-compiled scripts. If that fallback fails, this canary is the only signal that hooks won't fire for those scripts -- `hook()` calls still succeed, dispatch machinery still runs, it just never intercepts anything.

## Canary B: GDSC tokenizer version

**Location**: [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) canary B gate in `_generate_hook_pack` + [gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd) `_probe_gdsc_version`

**Probes**: reads the header of a known-readable vanilla `.gd`/`.gdc` (Camera, Controller, Audio, AI), confirms the `"GDSC"` magic in the first 4 bytes, and returns the u32 version at offset 4.

**Alarm levels**:

- Not 100 or 101 (and not -1 for "file not tokenized") -> critical:
  ```
  [STABILITY] Unsupported GDSC tokenizer vN on Godot <version>.
  This ModLoader supports v100 (Godot 4.0-4.4) and v101 (Godot 4.5-4.6).
  Hook pack generation disabled -- script hooks will not fire.
  See README for supported Godot versions.
  ```
- Supported -> info: `[STABILITY] Detokenizer compatible: GDSC vN on Godot <version>`.

**Why it matters**: if Godot ships a v102 tokenizer in a future release, the detokenizer would cascade "Empty detokenized source" warnings through every hookable script and silently fall back to vanilla. Canary B short-circuits at the start of hook pack generation with one actionable message.

## Canary C: detokenizer round-trip

**Location**: [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) `_canary_detokenizer_roundtrip_ok`, invoked from `_generate_hook_pack` right after the no-mods short-circuit

**Probes**: after Canary B passes, and only when mods are loaded, detokenizes the first probe script that carries GDSC bytes (same probe set as Canary B: Camera, Controller, Audio, AI) via `_detokenize_script` directly -- NOT `_read_vanilla_source`, so a pristine on-disk cache from an earlier session cannot mask a detokenizer that is broken against the current game build -- and checks that at least one colon-terminated `func` declaration is followed by a tab-indented body line.

**Alarm levels**:

- Inconclusive (no probe script detokenizable, or `tok_version == -1`) -> proceed, mirroring Canary B.
- Round-trip fails the indentation check -> critical:
  ```
  [STABILITY] Detokenized vanilla source failed the indentation sanity check on Godot <version>
  -- the .gdc column format likely changed even though the GDSC version is still <N>.
  Hook pack generation disabled -- script hooks will not fire.
  Update the ModLoader to a version that supports this game build.
  ```

**Why it matters**: a future engine can keep the GDSC version at 101 while changing the serialized column semantics (raw string offsets instead of tab_size=4 columns). Canary B only reads the version integer, so without this check broken column math would produce silently mis-indented rewrites. On failure `_generate_hook_pack` returns empty -- hook pack generation stops and vanilla runs.

## VFS-precedence canary

**Location**: [hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) `_generate_hook_pack` -- canary write just before the pack zip closes, readback right after `load_resource_pack`

**Probes**: adds a tiny known-content file `__modloader_canary__.txt` to the hook pack zip, with content `"MODLOADER-VFS-CANARY-" + <pack zip filename>` (the per-call ticks-stamped pack filename, so a stale previous-session mount cannot satisfy the readback). After mounting the pack, reads the file back via `FileAccess.get_file_as_string("res://__modloader_canary__.txt")` and requires an exact match.

**Alarm levels**:

- Canary content missing or wrong -> critical:
  ```
  [STABILITY] VFS canary FAILED (got '<prefix>', expected '<canary content>')
  -- hook pack mounted but files aren't served. Skipping activation: script hooks will not fire
  this session, vanilla scripts run. Pack state not persisted; next launch regenerates.
  ```
- Canary readable -> info: `[STABILITY] VFS canary OK: hook pack mount precedence verified (<content>)`.

**Why it matters**: `ProjectSettings.load_resource_pack` can return true while the resulting mount doesn't actually serve files (stale handles, format mismatch, etc.). This canary verifies mount precedence independently of the rewrite pipeline. On failure the loader skips `_activate_rewritten_scripts` and runs pure vanilla -- activating anyway would leave a half-modded state (cached scripts rewritten via direct source mutation while lazy VFS loads fall back to vanilla). Pack state is deliberately not persisted, so a transient failure self-heals on the next launch instead of static-init remounting a broken pack; it does not disable modding permanently.

The mount and write steps fail the same way:

- If `load_resource_pack` returns false, the loader logs critical `[RTVCodegen] Failed to mount hook pack at <path> -- script hooks will not fire this session, vanilla scripts run. Next launch regenerates the pack.` and runs vanilla.
- If writing the pack zip fails (disk full / I/O error), the partial zip is deleted and the loader logs critical `[RTVCodegen] Hook pack write failed (disk full / I/O error?) at <path> -- pack discarded, hooks disabled this session, running vanilla.`

In all three cases nothing is persisted, so the next launch retries from scratch.

## Escape hatches

### modloader_disabled sentinel

**Path**: `<exe_dir>/modloader_disabled` (in the game folder, not `user://`)

**Effect**: the loader's static init detects this file and skips everything -- no mounts, no UI, no autoloads. The game runs as if the loader weren't installed. Also force-resets persistent state (override.cfg, pass state, hook pack) for the NEXT launch.

**Check**: [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) `_is_modloader_disabled`, handled early in `_mount_previous_session`.

**When to use**: the loader itself is broken and the UI can't load. User creates this file manually, then removes it to re-enable.

### modloader_safe_mode sentinel

**Path**: `<exe_dir>/modloader_safe_mode`

**Effect**: on next boot, wipes pass state + resets `override.cfg` to clean baseline + deletes heartbeat + removes the sentinel file. Then normal Pass 1 proceeds, so the UI appears.

**Check**: [boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) `_check_safe_mode`, runs from within Pass 1.

**When to use**: mods are broken but the loader itself works. User removes misbehaving mods via the UI on next launch.

### UI Launch-vanilla button

**Location**: bottom bar of the launcher UI, next to Launch. Button text: "Launch vanilla"; hover hint: "Launch without mods for this session. Restarts the game."

**Effect**: writes `modloader_disabled_once` in the game folder (same effect as `modloader_disabled`, but the loader auto-clears it on that next launch), runs `_static_force_vanilla_state` (same cleanup as the disabled sentinel), strips `--modloader-restart` from cmdline args, and restarts. One-shot: the following launch is vanilla; the launch after that is modded again, with profiles and mod selections untouched.

**Source**: [ui.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) `_launch_vanilla_once`.

**When to use**: mods loaded but the game crashes or behaves badly. One guaranteed vanilla launch without losing the mod setup. The `modloader_disabled_once` sentinel can also be created by hand -- it belongs to the same escape-hatch set as the two sentinels above.

## Crash recovery

### Heartbeat

**File**: `user://modloader_heartbeat.txt`

**Lifecycle**:
- Written just before the Pass-1-to-Pass-2 restart ([boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) `_write_heartbeat`)
- Deleted at the end of Pass 2 cleanup (boot.gd `_delete_heartbeat`)

**Detection**: next launch's Pass 1 checks for the file in boot.gd `_check_crash_recovery`. Presence means the previous launch didn't complete.

### Restart counter

**Key**: `[state] restart_count` in `user://mod_pass_state.cfg`

**Increment**: boot.gd `_write_pass_state` bumps on each write.

**Force-reset**: when `restart_count >= MAX_RESTART_COUNT` (2), `_check_crash_recovery` logs `"Restart loop (N crashes) -- resetting to clean state"`, restores clean `override.cfg`, deletes pass state, deletes heartbeat.

**Reset to zero**: Pass 2 cleanup calls boot.gd `_clear_restart_counter` on successful completion.

### Pass 2 dirty marker

**File**: `user://modloader_pass2_dirty`

**Lifecycle**:
- Written first thing in [lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd) `_run_pass_2` with current timestamp
- Deleted after Pass 2 reaches its cleanup block (same file)

**Detection**: static init checks for the file in boot.gd `_mount_previous_session`. Presence means Pass 2 was interrupted (force-quit, crash, power loss) -- hook pack may be half-written, pass state + override.cfg reference untrustworthy state. Full wipe via `_static_force_vanilla_state("pass 2 crashed mid-run", ...)`.

## Combined recovery flow

If something goes wrong mid-run, the order of defenses is:

1. **Crash during Pass 2** -> `modloader_pass2_dirty` survives -> static init wipes on next boot, user gets clean Pass 1.
2. **Crash during Pass 1 before restart** -> heartbeat survives but pass state wasn't written -> next boot sees heartbeat + no restart mismatch, just deletes heartbeat and continues normally.
3. **Two Pass 2 crashes in a row** -> `restart_count >= 2` + heartbeat -> `_check_crash_recovery` force-resets, user gets clean Pass 1.
4. **User created `modloader_safe_mode`** -> Pass 1 `_check_safe_mode` wipes state, continues to UI.
5. **User created `modloader_disabled`** -> static init skips everything, loader is idle for this session. User removes the file to re-enable.

Nothing asks Godot to "just try again" without resetting state -- compounding retries across a persistent fault is how you get a game that won't boot without a manual reinstall.
