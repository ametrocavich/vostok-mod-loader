# Config Files

Where your mod setup lives on disk. This page answers "what's enabled?", "how do I back up my setup?", "what's safe to delete?", and "how do I recover from a bad state?".

## Where to find them

Godot's `user://` paths resolve to a per-user state dir. Road to Vostok uses a custom project name for this dir, so the path is:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Road to Vostok\` |
| Linux | `~/.local/share/Road to Vostok/` |
| macOS | `~/Library/Application Support/Road to Vostok/` |

Paste the Windows path into File Explorer's address bar to jump there directly.

Three sentinel files live in the **game's install directory** (next to the `.exe`), not under `user://`. Those are covered separately below.

## `mod_config.cfg` -- your profiles and settings

This is the user-facing config. The pre-launch UI reads and writes it. Plain INI, safe to inspect or edit by hand.

### Shape

```ini
[settings]
active_profile="Default"
developer_mode=false

[profile.Default.enabled]
rtvcoop@1.2.3=true
immersivexp@0.4.1=true
customhud@2.0.0=false
zip:SomeMod.vmz=true

[profile.Default.priority]
rtvcoop@1.2.3=100
immersivexp@0.4.1=50
customhud@2.0.0=0

[profile.MyHardcoreBuild.enabled]
rtvcoop@1.2.3=true
harsherweather@1.0.0=true

[profile.MyHardcoreBuild.priority]
rtvcoop@1.2.3=100
harsherweather@1.0.0=200
```

### Sections

| Section | Meaning |
|---|---|
| `[settings]` | `active_profile` -- currently-selected profile. `developer_mode` -- enables dev-only UI (folder mods, conflict report, extra diagnostics). |
| `[profile.<name>.enabled]` | `profile_key -> true\|false`. The list you see checked in the UI under that profile. One section per named profile. |
| `[profile.<name>.priority]` | `profile_key -> int` in `[-999, 999]`. Higher number loads later -> wins file conflicts. |

### Profile keys

The left-hand identifier for each mod. Two shapes:

- `<mod_id>@<version>` -- mods whose `mod.txt` declares `[mod] id=...`. Stable across `.vmz` renames.
- `zip:<file_name>` -- mods without a declared `mod_id`. Identity is the archive filename; renaming the `.vmz` orphans the profile entry.

See [Mod-Format](Mod-Format) for mod.txt schema. See [Profile-Format](Profile-Format) for the shareable export payload.

### `active_profile` special values

- `"Default"` -- the profile materialized on first launch. Persistent like every other profile.
- `"__vanilla__"` -- the **Reset to Vanilla** sentinel. Loads with every mod off, without touching your stored profiles. Clicking any non-Vanilla profile in the dropdown switches back.

### Common tasks

**See what's enabled in your current profile**
```bash
# Windows (PowerShell)
notepad "$env:APPDATA\Road to Vostok\mod_config.cfg"

# Linux
${EDITOR:-nano} "$HOME/.local/share/Road to Vostok/mod_config.cfg"
```
Find the `[profile.<active>.enabled]` section.

**Back up / restore your setup**
Copy `mod_config.cfg` somewhere safe. That one file contains all profiles and settings. Restoring: paste it back while the game isn't running.

**Copy your setup to another install**
Two ways:
1. **Full config copy** -- copy `mod_config.cfg` and paste into the same path on the other machine. Carries every profile + settings.
2. **Shareable profile payload** -- in-game, open the launcher, click **Share** on the profile, copy the `MTRPRF1....` string, paste into Discord / whatever, recipient clicks **Import** and pastes. Carries only that one profile. See [Profile-Format](Profile-Format) for the wire format.

**Reset one profile to empty**
Delete its two sections (`[profile.<name>.enabled]` and `[profile.<name>.priority]`). Keep your other profiles.

**Reset everything to fresh-install state**
Delete `mod_config.cfg`. Launcher materializes a new `Default` profile with every installed mod enabled on next launch.

## `mod_pass_state.cfg` -- boot state (implementation detail)

Tracks what modloader mounted last session so it can resume cleanly at static-init next session. Written by Pass 1 and the post-activation hook-pack persist step; read at boot before any archive mount.

You generally shouldn't touch this file. It's regenerated each session. But if you want to understand it:

| Key | Meaning |
|---|---|
| `archive_paths` | The `.vmz`/`.zip`/`.pck` paths that were mounted last session, in load order. |
| `modloader_version` | The modloader version that wrote this state. Mismatch with current = state gets wiped. |
| `exe_mtime` | Game `.exe` modification time at write. Change = hook cache gets wiped (vanilla scripts may have moved). |
| `hook_pack_path` | `user://modloader_hooks/framework_pack_<timestamp>.zip` path to mount at static-init. |
| `hook_pack_wrapped_paths` | List of `res://Scripts/<Name>.gd` paths in the pack; drives which scripts get `CACHE_MODE_IGNORE` preempt. |
| `restart_count` | Pass-2-restart counter. Max 2; resets after a clean boot. Prevents infinite restart loops. |
| `mods_hash` | Content hash of the enabled modlist. Unchanged hash + matching state = skip hook pack regeneration. |

**Safe to delete.** Next launch rebuilds it. You'll pay a cold-boot cost (regenerate hook pack).

## `override.cfg` -- Godot's autoload manifest

This file lives in the **game's install directory** (next to the `.exe`), not `user://`. Godot reads it at engine startup to override `project.godot` autoload entries.

Modloader writes it during Pass 1 and restores it to a clean single-entry state after Pass 2 completes. Shape during active mod session:

```ini
[autoload_prepend]
SomeModEarly="*res://SomeMod/Early.gd"
ModLoader="*res://modloader.gd"

[autoload]
SomeModRegular="*res://SomeMod/Main.gd"
```

Clean state (no mods queued):
```ini
[autoload_prepend]
ModLoader="*res://modloader.gd"

[autoload]
```

`[autoload_prepend]` entries load **before** the game's built-in autoloads. Modloader is always the **last** entry in `[autoload_prepend]` because Godot loads in reverse order (last listed = first loaded). See [Architecture](Architecture).

**Editing this file by hand is risky.** If you corrupt it, the game fails to load autoloads and boots to a black screen. If that happens, delete it -- Godot will boot vanilla with no autoloads; then launch through Steam / your usual entry point and modloader will regenerate a clean version.

## Sentinel files -- escape hatches

These live in the **game's install directory** (next to the `.exe`), not `user://`. Create them as empty files to trigger behavior; delete them to revert.

| File | Effect |
|---|---|
| `modloader_disabled` | Full bypass. Modloader's static-init exits early on detection; game boots 100% vanilla. No mods mount, no hook pack, nothing. Use when modloader itself is broken or you want to confirm a problem is mod-related. |
| `modloader_safe_mode` | Boots modloader + the UI, but skips archive mount + hook pack. Lets you change profiles / disable a bad mod without loading it. Useful when a mod is crashing at autoload time. |

On Windows: right-click the game folder -> New -> Text Document -> rename to `modloader_disabled` (no extension). Or run `echo. > modloader_disabled` in `cmd`.

See [Stability-Canaries](Stability-Canaries) for the full crash-recovery + sentinel system.

## Generated files -- safe to delete

Everything under `user://modloader_hooks/` is regenerated on demand:

| Path | Contents |
|---|---|
| `user://modloader_hooks/framework_pack_<timestamp>.zip` | The generated hook pack. Mounted at static-init. Regenerated by Pass 1 when mod state changes. |
| `user://modloader_hooks/vanilla/` | Cached detokenized vanilla source, keyed by exe mtime. Speeds up subsequent hook-pack generation. |
| `user://vmz_mount_cache/` | `.vmz -> .zip` copies so Godot's `load_resource_pack` can mount them. |
| `user://modloader_early/` | Extracted copies of `!`-prefixed early-autoload scripts that live inside archives. |
| `user://modloader_heartbeat.txt` | Crash-detection sentinel. Written each launch, deleted at clean boot. Presence on next launch = previous session crashed. |
| `user://modloader_pass2_dirty` | Pass-2-in-progress marker. Presence on next launch = Pass 2 was interrupted mid-execution (crash, force-quit). Next launch wipes state and retries. |
| `user://modloader_conflicts.txt` | Developer-mode only. Dumps the conflict report (which mods claim the same `res://` paths). |

**Deleting any of these is safe.** Next launch regenerates whatever it needs. The "cost" is a slower cold boot because the hook pack has to rebuild.

**When to delete them:**
- Mod updates aren't taking effect -> delete the `framework_pack_*.zip`. (The 3.0.0 stale-pack bug is fixed in 3.0.1, but manual deletion is a safe workaround.)
- Weird boot behavior after a game update -> delete the whole `user://modloader_hooks/` directory to force full regen.
- Suspect cached state corruption -> delete `user://mod_pass_state.cfg`.

## Frequently-asked

**Q: Where is the list of mods I have enabled?**  
A: `mod_config.cfg` -> section `[profile.<active_profile>.enabled]`. The name of your active profile is in `[settings] active_profile`. `true` = enabled, `false` = disabled.

**Q: I edited `mod_config.cfg` by hand but the change didn't apply.**  
A: Modloader reads it at launch and overwrites it on exit. Edit while the game is closed.

**Q: I want to enable a mod without launching the UI.**  
A: Add a line under `[profile.<active>.enabled]`: `<profile_key>=true`. Profile key is `<mod_id>@<version>` from the mod's `mod.txt`, or `zip:<filename>` if no `mod_id` is declared. Also add it to `[profile.<active>.priority]` with a value (0 if you don't care).

**Q: How do I make modloader stop running entirely?**  
A: Create a file named `modloader_disabled` (no extension) in the game's install directory.

**Q: Everything broke after an update. How do I reset?**  
A: 
1. Delete `mod_config.cfg` (resets the UI / profiles to fresh-install state).
2. Delete `user://mod_pass_state.cfg` (forces rebuild of boot state).
3. Delete `user://modloader_hooks/` (forces hook pack regeneration).
4. If the game won't launch at all, create `modloader_disabled` in the install dir, launch vanilla, then remove the sentinel and relaunch. Modloader rebuilds from scratch.

**Q: What's the difference between the `user://` location and the game install dir?**  
A: `user://` is per-user state (your profiles, generated caches) -- preserved across game updates. The game install dir is where the `.exe` + `.pck` live -- overwritten on game update. Sentinel files and `override.cfg` live there because they need to be visible to Godot before `user://` is even resolved.

## Related

- [Mod-Format](Mod-Format) -- `mod.txt` schema (what each mod declares)
- [Profile-Format](Profile-Format) -- the shareable `MTRPRF1....` export payload
- [Architecture](Architecture) -- two-pass boot flow, `override.cfg` lifecycle
- [Stability-Canaries](Stability-Canaries) -- crash recovery, safe mode, sentinel files
