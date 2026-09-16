# Config Files

Where your mod setup lives on disk. This page answers "what's enabled?", "how do I back up my setup?", "what's safe to delete?", and "how do I recover from a bad state?".

## Where to find them

Godot's `user://` paths resolve to a per-user state directory. Road to Vostok uses its own project name for it:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Road to Vostok\` |
| Linux | `~/.local/share/Road to Vostok/` |
| macOS | `~/Library/Application Support/Road to Vostok/` |

Paste the Windows path into File Explorer's address bar to jump there.

The sentinel files and `override.cfg` live in the game's install directory (next to the `.exe`), not under `user://`. They are covered separately below.

## `mod_config.cfg`. Your profiles and settings

This is the user-facing config. The pre-launch UI reads and writes it. Plain INI, safe to inspect or edit by hand while the game is closed. Every save first copies the previous file to `mod_config.cfg.bak`, and the launcher falls back to that copy if the live file fails to parse.

### Shape

```ini
[settings]

developer_mode=true
active_profile="Default"

[profile.Default.enabled]

doinkoink-mcm@2.6.3=true
rtv-coop@5.0.0=true
item-spawner-ce@1.2.1=true
immersive-xp@3.0.2=false
xp-skills-system@2.5.6=true

[profile.Default.priority]

doinkoink-mcm@2.6.3=-100
rtv-coop@5.0.0=10
item-spawner-ce@1.2.1=1
immersive-xp@3.0.2=0
xp-skills-system@2.5.6=0

[profile.MyHardcoreBuild.enabled]

rtv-coop@5.0.0=true
harsher-weather@1.0.0=true

[profile.MyHardcoreBuild.priority]

rtv-coop@5.0.0=10
harsher-weather@1.0.0=200

[mod_sources]

rtv-coop@5.0.0="{\"provider\":\"modworkshop\",\"id\":\"12345\",\"modworkshop_id\":12345,\"version\":\"5.0.0\"}"
harsher-weather@1.0.0="{\"provider\":\"vostokmods\",\"id\":\"harsher-weather\",\"version\":\"1.0.0\"}"
```

Godot's `ConfigFile` writes a blank line after every section header, quotes String values (`active_profile="Default"`), and writes bools and ints unquoted. Don't hand-edit the quotes; the parser is strict about them.

### Sections

| Section | Meaning |
|---|---|
| `[settings]` | `active_profile`: the selected profile. `developer_mode`: enables dev-only UI (folder mods, conflict report, extra diagnostics). `ui_scale`: launcher zoom, 1.0 to 2.0. `active_modpack`, `modpack_backup_profile`, `modpack_backup_valid`: modpack state, see below. `test_pack_precedence`: developer test flag for the static-init mount canary; leave it unset. |
| `[profile.<name>.enabled]` | `profile_key -> true\|false`. The list you see checked in the UI under that profile. One section per named profile. |
| `[profile.<name>.priority]` | `profile_key -> int` in `[-999, 999]`. A higher number loads later and wins file conflicts. |
| `[profile.<name>.dep_ignore]` | `profile_key -> true`. The "Load anyway" dependency overrides for that profile. Sparse: only mods you told to load past a missing or disabled requirement appear, always as `=true`. New in 3.3. |
| `[profile.<name>.settings]` | Per-profile launcher view settings. Currently `hide_disabled`, the Mods tab's hide-disabled-mods filter. |
| `[mod_sources]` | `profile_key -> JSON record` of where each mod is hosted: `{provider, id, modworkshop_id?, version?}`. Written by every download made through Browse, an update or a modpack, and filled in from each mod's `mod.txt` at scan time. An explicit `source=` in `mod.txt` replaces the stored record; a legacy `modworkshop=` line does not replace a record that names another host. This is how the update check and the missing-mod rows know a mod's host when its `mod.txt` says nothing, and how a modpack can offer Download for a mod that failed to install. |
| `[modloader_update]` | `last_seen_version`: the newest loader release the update dialog has already shown you, so it only pops once per release. |

### Profile keys

The left-hand identifier for each mod. Two shapes:

- `<mod_id>@<version>`: mods whose `mod.txt` declares `[mod] id=...`. This is the normal case. Stable across `.vmz` renames. The version segment may be empty (`scantest_clean@=false`) if `mod.txt` has an `id` but no `version`.
- `zip:<file_name>`: fallback for mods without a declared `mod_id`. Identity is the archive filename, so renaming the `.vmz` orphans the profile entry.

See [Mod-Format](Mod-Format) for the mod.txt schema and [Profile-Format](Profile-Format) for the JSON format inside a modpack's `profile.json`.

### `active_profile` special values

- `"Default"`: the profile created on first launch. Persistent like every other profile.
- `"__vanilla__"`: a leftover from older versions' Reset to Vanilla. On load the launcher treats it as missing and switches to your first real profile. To boot the game without mods once, use the **Launch vanilla** button in the launcher; it writes a `modloader_disabled_once` file that is cleared on the next launch.

### Modpack keys and managed profiles (3.3)

Applying a modpack (see [Modpacks](Modpacks)) reuses the ordinary profile machinery, so an active modpack shows up in `mod_config.cfg` as a few `[settings]` keys plus profile sections under reserved name prefixes.

`[settings]` keys:

| Key | Meaning |
|---|---|
| `active_modpack` | Sanitized name of the modpack currently applied, or empty/absent if none. While set, the launcher locks the active profile to that pack's managed slot. Deleting this line by hand is the escape hatch if unload refuses. |
| `modpack_backup_profile` | The profile you were on when you applied the pack, where **Unload** restores your pre-pack `enabled`/`priority` to. Empty/absent when no pack is active. |
| `modpack_backup_valid` | `true` once apply has written the backup slot, even an empty one. Unload trusts this flag; without it, and with no backup sections, unload refuses, so your profile is never wiped. |

Managed profile sections. The launcher creates these and the Mods-tab profile dropdown hides them:

| Section prefix | Meaning |
|---|---|
| `[profile.modpack__<name>.enabled]` / `.priority` / `.dep_ignore` | Live state of the applied modpack `<name>`. Edits you make while it is active save here. Kept on unload so a re-apply resumes your edits. |
| `[profile._before_modpack_<name>.enabled]` / `.priority` | Backup of your profile taken at apply time. Unload restores from here, then removes it. If these are gone and `modpack_backup_valid` is unset, unload aborts and your real profile survives. |

`<name>` is the modpack's sanitized name (letters, digits, space, hyphen, underscore). Don't name your own profiles `modpack__*` or `_before_modpack_*`; the launcher treats those prefixes as reserved and filters them out of the dropdown.

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
Copy `mod_config.cfg` somewhere safe. That one file holds every profile and setting. To restore, paste it back while the game isn't running.

**Copy your setup to another install**
Two ways:
1. Copy `mod_config.cfg` into the same path on the other machine. That carries every profile and setting.
2. If your setup came from a VostokMods modpack, get and apply the same pack on the other machine. See [Modpacks](Modpacks).

**Reset one profile to empty**
Delete all of its sections: `[profile.<name>.enabled]`, `[profile.<name>.priority]`, and, if present, `[profile.<name>.dep_ignore]` and `[profile.<name>.settings]`. Keep your other profiles.

**Reset everything to fresh-install state**
Delete `mod_config.cfg` (and `mod_config.cfg.bak`, or the launcher recovers from it). Next launch creates a new `Default` profile with every installed mod enabled.

## `mod_pass_state.cfg`. Boot state (implementation detail)

Tracks what the loader mounted last session so it can resume at static init next session. Written by Pass 1 and the post-activation hook-pack persist step; read at boot before any archive mount.

You generally shouldn't touch this file. It is regenerated each session. If you want to read it:

```ini
[state]

restart_count=0
mods_hash="d90eae97b1868a4e9051f17ced71b7a6"
archive_paths=PackedStringArray("C:/Program Files (x86)/Steam/steamapps/common/Road to Vostok/mods/RTVCoopVMZ.vmz")
modloader_version="3.3.1"
exe_mtime=1776042534
timestamp=1776897837.26
script_overrides=[]
hook_pack_path="user://modloader_hooks/framework_pack_5758.zip"
hook_pack_wrapped_paths=PackedStringArray("res://Scripts/Menu.gd")
```

| Key | Meaning |
|---|---|
| `archive_paths` | The `.vmz`/`.zip`/`.pck` paths mounted last session, in load order. Stored as `PackedStringArray(...)`. |
| `modloader_version` | The loader version that wrote this state. A mismatch with the current version wipes the state. |
| `exe_mtime` | Game `.exe` modification time at write. A change (game update) wipes the state, since vanilla scripts may have moved. |
| `timestamp` | Unix epoch seconds when Pass 1 wrote the file. Informational. |
| `restart_count` | Pass-2 restart counter. Max 2; cleared after a clean boot. Stops infinite restart loops. |
| `mods_hash` | Content hash of the enabled mod list. Unchanged hash + matching state = skip hook pack regeneration. |
| `script_overrides` | Dynamic `overrideScript()` targets declared by mods, used by the dev-mode conflict report. `[]` on most installs. |
| `hook_pack_path` | `user://modloader_hooks/framework_pack_<millis>.zip` to mount at static init next boot. A fresh filename per generation sidesteps Godot's `load_resource_pack` path dedup. |
| `hook_pack_wrapped_paths` | The `res://Scripts/<Name>.gd` paths in the pack; drives which scripts get `CACHE_MODE_IGNORE` preempt at static init. Often just `["res://Scripts/Menu.gd"]` for loadouts that only use the core hook. |

Safe to delete. Next launch rebuilds it at the cost of a slower cold boot (the hook pack regenerates).

## `override.cfg`. Godot's autoload manifest

This file lives in the game's install directory (next to the `.exe`), not `user://`. Godot reads it at engine startup to override `project.godot` autoload entries.

The loader writes it during Pass 1 and restores it to a clean single-entry state after Pass 2 completes. Shape during an active mod session:

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

`[autoload_prepend]` entries load before the game's built-in autoloads. ModLoader is always the last entry in `[autoload_prepend]` because Godot loads that section in reverse order (last listed = first loaded). Sections other than the two autoload ones are preserved across rewrites. See [Architecture](Architecture).

Editing this file by hand is risky. If you corrupt it, the game fails to load autoloads and boots to a black screen. If that happens, delete it: Godot boots vanilla with no autoloads, and the loader regenerates a clean copy the next time you launch through Steam.

## Sentinel files. Escape hatches

These live in the game's install directory (next to the `.exe`), not `user://`. Create them as empty files to trigger the behavior; delete them to revert.

| File | Effect |
|---|---|
| `modloader_disabled` | Full bypass. The loader's static init resets `override.cfg`, pass state and the hook pack, then mounts nothing; the game boots vanilla. Use when the loader itself is broken or you want to confirm a problem is mod-related. |
| `modloader_disabled_once` | One-shot version of `modloader_disabled`: the next launch boots vanilla, then the file is deleted so the launch after that is modded again. The launcher's **Launch vanilla** button creates this for you; you can also create it by hand. |
| `modloader_safe_mode` | One-shot reset. On the next launch the loader restores a clean `override.cfg`, deletes `mod_pass_state.cfg` and the crash heartbeat, then deletes the safe-mode file itself. The launcher still opens, so you can change profiles or disable a bad mod before the next modded boot. Useful when a mod is crashing at autoload time. |

On Windows: right-click the game folder, New, Text Document, rename to `modloader_disabled` (no extension). Or run `echo. > modloader_disabled` in `cmd`.

See [Stability-Canaries](Stability-Canaries) for the full crash-recovery and sentinel system.

## Generated files. Safe to delete

Everything here is regenerated on demand:

| Path | Contents |
|---|---|
| `user://modloader_hooks/framework_pack_<millis>.zip` | The generated hook pack, mounted at static init. Each Pass-1 generation picks a fresh timestamp suffix (Godot's `load_resource_pack` dedups by path and would keep stale mount offsets). Old generations are cleaned up before mount. |
| `user://modloader_hooks/vanilla/` | Cached vanilla script source, decoded from the game's own `.pck` (never from a mounted mod), wiped on a game update. A `format` stamp at its root names the cache layout; a missing or older stamp rebuilds the cache. Speeds up later hook-pack generation. |
| `user://vmz_mount_cache/` | `.vmz -> .zip` copies so Godot's `load_resource_pack` can mount them, plus `.zip.src` sidecars naming the source. |
| `user://modloader_early/` | Extracted copies of `!`-prefixed early-autoload scripts that live inside archives. |
| `user://modloader_heartbeat.txt` | Crash-detection sentinel. Written each launch, deleted at clean boot. Present on the next launch = the previous session crashed. |
| `user://modloader_pass2_dirty` | Pass-2-in-progress marker. Present on the next launch = Pass 2 was interrupted (crash, force-quit). Next launch wipes state and retries. |
| `user://modloader_crash_streak` | Count of consecutive crashed two-pass restarts. At 2 the loader refuses the two-pass restart and finishes in a single pass instead: mods that can load still load, and the launcher stays reachable so you can disable the one that crashes. Cleared by a clean boot. |
| `user://modloader_conflicts.txt` | Developer mode only. The conflict report (which mods claim the same `res://` paths). |
| `user://modloader_hook_status.json` | What happened to the hook system last session (whether the script rewrites took effect, or why generation stopped). The launcher reads it on the next start and shows a banner on the Mods tab when hooks did not work. Ignored once the loader or the game executable changes. |
| `user://modloader_game_updated` | Written when the game executable changed since the last run. The Mods tab shows a "Road to Vostok was updated" notice while it exists; the next session in which the hook rewrites work removes it. |
| `user://mws_cache/` | Browse-tab caches. `thumbs/` holds ModWorkshop thumbnail and banner images (VostokMods images stay in memory). `landing_<site>.json` holds each site's last successful Browse landing so the offline view survives a relaunch. `mods_meta_v2.json` caches the host detail each installed mod's row shows on the Mods tab. Search and filter responses are cached in memory only. |

Deleting anything in that table is safe. Next launch regenerates whatever it needs; the cost is a slower cold boot while the hook pack rebuilds.

Two more `user://` directories are deliberately not in that table:

| Path | Contents |
|---|---|
| `user://.profile_snapshots/<profile>/` | Per-profile MCM snapshot (`MCM/` tree), restored when you switch into that profile. Not regenerable: deleting it discards saved per-profile MCM settings. New in 3.3. |

When to delete things:
- Mod updates aren't taking effect: delete the `framework_pack_*.zip`. (The 3.0.0 stale-pack bug is fixed in 3.0.1, but manual deletion is a safe workaround.)
- Weird boot behavior after a game update: delete the whole `user://modloader_hooks/` directory to force a full regeneration.
- Suspected cached-state corruption: delete `user://mod_pass_state.cfg`.

## Frequently-asked

**Q: Where is the list of mods I have enabled?**  
A: `mod_config.cfg`, section `[profile.<active_profile>.enabled]`. The name of your active profile is in `[settings] active_profile`. `true` = enabled, `false` = disabled.

**Q: I edited `mod_config.cfg` by hand but the change didn't apply.**  
A: The loader reads it at launch and overwrites it on exit. Edit while the game is closed.

**Q: I want to enable a mod without launching the UI.**  
A: Add a line under `[profile.<active>.enabled]`: `<profile_key>=true`. The profile key is `<mod_id>@<version>` from the mod's `mod.txt`, or `zip:<filename>` if no `mod_id` is declared. Add it to `[profile.<active>.priority]` too, with a value (0 if you don't care).

**Q: How do I make the loader stop running entirely?**  
A: Create a file named `modloader_disabled` (no extension) in the game's install directory.

**Q: Everything broke after an update. How do I reset?**  
A: 
1. Delete `mod_config.cfg` (resets the UI and profiles to fresh-install state).
2. Delete `user://mod_pass_state.cfg` (forces a rebuild of boot state).
3. Delete `user://modloader_hooks/` (forces hook pack regeneration).
4. If the game won't launch at all, create `modloader_disabled` in the install dir, launch vanilla, then remove the sentinel and relaunch. The loader rebuilds from scratch.

**Q: What's the difference between the `user://` location and the game install dir?**  
A: `user://` is per-user state (your profiles, generated caches), preserved across game updates. The game install dir is where the `.exe` and `.pck` live, and a game update overwrites it. Sentinel files and `override.cfg` live there because Godot has to see them before `user://` is even resolved.

## Related

- [Mod-Format](Mod-Format): `mod.txt` schema (what each mod declares)
- [Profile-Format](Profile-Format): the JSON format inside a modpack's `profile.json`
- [Browse](Browse): installing mods from VostokMods or ModWorkshop (`user://mws_cache/`)
- [Modpacks](Modpacks): `active_modpack`, the managed profile slots, and `.profile_snapshots`
- [Architecture](Architecture): two-pass boot flow, `override.cfg` lifecycle
- [Stability-Canaries](Stability-Canaries): crash recovery, safe mode, sentinel files
