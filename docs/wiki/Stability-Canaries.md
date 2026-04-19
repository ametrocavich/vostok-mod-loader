# Stability Canaries

Boot-time probes that alarm loudly when something the loader depends on silently regresses. The design principle: silent breakage is the worst mode, because mods fail in non-obvious ways. One loud actionable log line beats a flood of downstream symptom warnings.

## Canary A: COMPILE-PROOF

**Location**: [hook_pack.gd:658-684](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L658)

**Probes**: after `_activate_rewritten_scripts` completes, inspects `get_script_method_list()` for each rewritten vanilla. The presence of any `_rtv_vanilla_*` method name confirms the rewrite compiled into the cached GDScript.

**Alarm levels**:

- **Zero of N rewrites active** -> critical:
  ```
  [STABILITY] ALL N rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken.
  Mods will NOT work this session. Click 'Reset to Vanilla' in the UI
  or create modloader_disabled in the game folder.
  ```
- **Any critical script failed** -> critical. The critical set ([hook_pack.gd:662-664](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L662)): `Controller.gd, Camera.gd, WeaponRig.gd, Door.gd, Trader.gd, Hitbox.gd, LootContainer.gd, Pickup.gd`
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

**Location**: [hook_pack.gd:50-60](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L50) + [gdsc_detokenizer.gd:437 `_probe_gdsc_version`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L437)

**Probes**: reads the first 4 bytes of a known-readable vanilla `.gd`/`.gdc` (Camera, Controller, Audio, AI), confirms `"GDSC"` magic, and returns the version byte.

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

## Canary C: VFS mount precedence

**Location**: write at [hook_pack.gd:366-374](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L366), readback at [hook_pack.gd:404-412](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L404)

**Probes**: adds a tiny known-content file `__modloader_canary__.txt` to the hook pack zip, with content `"MODLOADER-VFS-CANARY-" + MODLOADER_VERSION`. After mounting the pack, reads the file back via `FileAccess.get_file_as_string("res://__modloader_canary__.txt")`.

**Alarm levels**:

- Canary content missing or wrong -> critical:
  ```
  [STABILITY] VFS canary FAILED (got '<prefix>', expected MODLOADER-VFS-CANARY-*)
  -- hook pack mounted but files aren't served. Rewrites will not take effect this session.
  ```
- Canary readable -> info: `[STABILITY] VFS canary OK: hook pack mount precedence verified (<content>)`.

**Why it matters**: `ProjectSettings.load_resource_pack` can return true while the resulting mount doesn't actually serve files (stale handles, format mismatch, etc.). Canary C verifies mount precedence independently of the rewrite pipeline. If the canary fails, no script rewrite will take effect regardless of anything downstream.

## Escape hatches

### modloader_disabled sentinel

**Path**: `<exe_dir>/modloader_disabled` (in the game folder, not `user://`)

**Effect**: the loader's static init detects this file and skips everything -- no mounts, no UI, no autoloads. The game runs as if the loader weren't installed. Also force-resets persistent state (override.cfg, pass state, hook pack) for the NEXT launch.

**Check**: [boot.gd:8 `_is_modloader_disabled`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L8), handled at [boot.gd:41-44](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L41).

**When to use**: the loader itself is broken and the UI can't load. User creates this file manually, then removes it to re-enable.

### modloader_safe_mode sentinel

**Path**: `<exe_dir>/modloader_safe_mode`

**Effect**: on next boot, wipes pass state + resets `override.cfg` to clean baseline + deletes heartbeat + removes the sentinel file. Then normal Pass 1 proceeds, so the UI appears.

**Check**: [boot.gd:596 `_check_safe_mode`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L596), runs from within Pass 1.

**When to use**: mods are broken but the loader itself works. User removes misbehaving mods via the UI on next launch.

### UI Reset-to-Vanilla button

**Location**: bottom bar of the launcher UI, left of Launch Game.

**Effect**: unchecks every mod in memory, saves config, calls `_static_force_vanilla_state` (same cleanup as the disabled sentinel), strips `--modloader-restart` from cmdline args, and restarts the game clean.

**Source**: [ui.gd:48 `_reset_to_vanilla_and_restart`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L48).

**When to use**: mods loaded but the game crashes or behaves badly. User clicks the button, gets a guaranteed vanilla next launch.

## Crash recovery

### Heartbeat

**File**: `user://modloader_heartbeat.txt`

**Lifecycle**:
- Written just before the Pass-1-to-Pass-2 restart ([boot.gd:571 `_write_heartbeat`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L571))
- Deleted at the end of Pass 2 cleanup ([boot.gd:577 `_delete_heartbeat`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L577))

**Detection**: next launch's Pass 1 checks for the file at [boot.gd:581 `_check_crash_recovery`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L581). Presence means the previous launch didn't complete.

### Restart counter

**Key**: `[state] restart_count` in `user://mod_pass_state.cfg`

**Increment**: `_write_pass_state` ([boot.gd:519](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L519)) bumps on each write.

**Force-reset**: when `restart_count >= MAX_RESTART_COUNT` (2), `_check_crash_recovery` logs `"Restart loop (N crashes) -- resetting to clean state"`, restores clean `override.cfg`, deletes pass state, deletes heartbeat.

**Reset to zero**: Pass 2 cleanup calls `_clear_restart_counter` ([boot.gd:649](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L649)) on successful completion.

### Pass 2 dirty marker

**File**: `user://modloader_pass2_dirty`

**Lifecycle**:
- Written first thing in `_run_pass_2` ([lifecycle.gd:164-167](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L164)) with current timestamp
- Deleted after Pass 2 reaches its cleanup block ([lifecycle.gd:232-233](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L232))

**Detection**: static init at `_mount_previous_session` checks for the file at [boot.gd:50-53](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L50). Presence means Pass 2 was interrupted (force-quit, crash, power loss) -- hook pack may be half-written, pass state + override.cfg reference untrustworthy state. Full wipe via `_static_force_vanilla_state("pass 2 crashed mid-run", ...)`.

## Combined recovery flow

If something goes wrong mid-run, the order of defenses is:

1. **Crash during Pass 2** -> `modloader_pass2_dirty` survives -> static init wipes on next boot, user gets clean Pass 1.
2. **Crash during Pass 1 before restart** -> heartbeat survives but pass state wasn't written -> next boot sees heartbeat + no restart mismatch, just deletes heartbeat and continues normally.
3. **Two Pass 2 crashes in a row** -> `restart_count >= 2` + heartbeat -> `_check_crash_recovery` force-resets, user gets clean Pass 1.
4. **User created `modloader_safe_mode`** -> Pass 1 `_check_safe_mode` wipes state, continues to UI.
5. **User created `modloader_disabled`** -> static init skips everything, loader is idle for this session. User removes the file to re-enable.

Nothing asks Godot to "just try again" without resetting state -- compounding retries across a persistent fault is how you get a game that won't boot without a manual reinstall.
