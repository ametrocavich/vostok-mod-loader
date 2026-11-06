# Config Files

Where your mod setup lives on disk: what is enabled, how to back it up, what is safe to delete, and how to get out of a bad state.

## Where to find them

Godot's `user://` is a per-user folder named after the game:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Road to Vostok\` (paste it into File Explorer's address bar) |
| Linux (Steam Proton) | `<Steam library>/steamapps/compatdata/<app id>/pfx/drive_c/users/steamuser/AppData/Roaming/Road to Vostok/`: the game is a Windows build, so its folder is inside the Proton prefix |
| macOS | `~/Library/Application Support/Road to Vostok/` |

`override.cfg` and the sentinel files live in the game's install folder, next to the `.exe`, not under `user://`.

## `mod_config.cfg`. Your profiles and settings

The launcher reads and writes this file. It is plain INI, safe to read or edit while the game is closed. Every save first copies the previous file to `mod_config.cfg.bak`; when the live file fails to parse, or is empty while the backup is not, the launcher loads the backup. A file it cannot read is kept as `mod_config.cfg.corrupt` before the backup (or a fresh `Default`) replaces it, so nothing typed by hand is lost.

```ini
[settings]

developer_mode=true
active_profile="Default"

[profile.Default.enabled]

rtv-coop@5.0.0=true
immersive-xp@3.0.2=false

[profile.Default.priority]

rtv-coop@5.0.0=10
immersive-xp@3.0.2=0

[mod_sources]

rtv-coop@5.0.0="{\"provider\":\"vostokmods\",\"id\":\"rtv-coop\",\"version\":\"5.0.0\"}"
```

Godot writes a blank line after each section header, quotes strings and leaves bools and ints bare. Keep the quotes as they are; the parser is strict about them.

### Sections

- `[settings]`: `active_profile` (the selected profile), `developer_mode` ([Developer-Mode](Developer-Mode)), `ui_scale` (launcher zoom, 1.0 to 2.0), `browse_source` (the site Browse last showed), `browse_kind` (`mods` or `modpacks`, which list Browse last showed), the modpack keys below, and `mcm_pending_from` / `mcm_pending_to` (a profile switch made from the main menu whose mod-settings swap the next launch performs, then clears).
- `[profile.<name>.enabled]`: `profile_key -> true|false`, the mods ticked in that profile.
- `[profile.<name>.priority]`: `profile_key -> int` in `[-999, 999]`; higher loads later and wins file conflicts.
- `[profile.<name>.dep_ignore]`: `profile_key -> true` for each **Load anyway** override ([Dependencies](Dependencies)).
- `[profile.<name>.settings]`: `hide_disabled` (the Mods-tab filter); `listed=true`, which keeps a profile with no mods; and on a modpack slot `pack_sha256`, the hash of the pack zip it was built from (a zip replaced under the same name rebuilds the slot).
- `[mod_sources]`: `profile_key -> JSON {provider, id, modworkshop_id?, version?}`, where each mod is hosted. Written by every download through Browse, an update or a modpack, and filled from each `mod.txt` at scan time. A `source=` in `mod.txt` replaces the stored record; a legacy `modworkshop=` line does not replace a record naming another host. The update check and the missing-mod rows read it.
- `[modloader_update]`: `last_seen_version`, the newest loader release the update dialog has shown, so it pops once per release.

A profile key is `<mod_id>@<version>` for a mod that declares `[mod] id`, else `zip:<file_name>`; [Profile-Format](Profile-Format#profile-key-format) has the rules. A mod that needs the profile name calls `active_profile()` ([Hooks](Hooks#api-reference)) instead of reading this file: the file changes as soon as the player picks another profile, while the running mods belong to the old one until the restart.

### Modpack keys and managed profiles

Applying a [modpack](Modpacks) uses the ordinary profile machinery under reserved names.

| Key or section | Meaning |
|---|---|
| `[settings] active_modpack` | The applied pack's sanitized name. While set, the active profile is locked to the pack's slot. When Unload cannot restore your previous profile, the launcher offers **Keep as profile** instead |
| `[settings] modpack_backup_profile` | The profile you were on at apply; Unload restores it |
| `[settings] modpack_backup_valid` | `true` once apply has written the backup, even an empty one. Without it and without backup sections, Unload refuses, so your profile is never wiped |
| `[profile.modpack__<name>.*]` | The pack's live state; edits made while it is active save here. Kept on unload, dropped when **Refresh** rewrites the pack |
| `[profile._before_modpack_<name>.*]` | Your profile as it was at apply. Unload restores from it, then removes it |
| `user://.profile_snapshots/modpack__<name>/`, `_before_modpack_<name>/` | The pack's MCM settings and your pre-apply MCM settings |

`<name>` keeps letters, digits, space, hyphen and underscore. The `modpack__` and `_before_modpack_` prefixes are reserved and hidden from the profile dropdown.

### Common tasks

- **See what is enabled.** Open `mod_config.cfg` and find `[profile.<active_profile>.enabled]`. On Linux, `find ~/.steam/steam/steamapps/compatdata -path '*/Roaming/Road to Vostok/mod_config.cfg'` locates it.
- **Enable a mod without the launcher.** With the game closed, add `<profile_key>=true` under `[profile.<active>.enabled]` and a priority under `[profile.<active>.priority]`.
- **Back up your setup.** With the game closed, copy `mod_config.cfg`, `MCM/` and `.profile_snapshots/` from `user://`, plus the mod archives and pack zips in the game's `mods/` folder. Restore them as one set. Mods that keep settings outside MCM document their own files.
- **Copy your setup to another install.** Restore that backup there, or get and apply the same pack from Vostok Mods (your local edits do not travel).
- **Start a profile empty.** Use **New profile** with **Empty**, or clear the search filter and click **Disable all**.
- **Reset profiles and launcher preferences.** Delete `mod_config.cfg` and `mod_config.cfg.bak`. The next launch creates `Default` with every installed mod enabled; MCM files and mods stay.

## `mod_pass_state.cfg`

What the loader mounted last session, so static init can mount it again before the game starts. Written by Pass 1 before the restart and when the hook pack is saved; regenerated every session. [Architecture](Architecture#pass-state) explains each key. Safe to delete: the next launch boots cold and rebuilds the hook pack.

## `override.cfg`

In the install folder. Godot reads it at startup, and it is what loads the mod loader. The loader rewrites its `[autoload_prepend]` and `[autoload]` sections ([Architecture](Architecture) has the lifecycle) and keeps every other section. If a hand edit breaks it, the game boots to a black screen: replace its contents with the clean state below, copy it again from the release, or rerun the installer. Deleting it is not a fix; without it the loader never starts.

```ini
[autoload_prepend]
ModLoader="*res://modloader.gd"

[autoload]
```

## Sentinel files. Escape hatches

Empty files in the install folder, next to the `.exe`. Create one to trigger it.

| File | Effect | Removed by |
|---|---|---|
| `modloader_disabled` | Full bypass. Static init resets `override.cfg`, deletes pass state and the Pass 2 marker, wipes the hook pack and early autoloads, and mounts nothing; the game runs vanilla. Use it when the loader itself breaks, or to check a problem is mod-related | you |
| `modloader_disabled_once` | The same for one launch. **Launch vanilla** writes it | the loader, at that launch |
| `modloader_safe_mode` | One-shot reset when the launcher is about to open: clean `override.cfg`, no pass state, no heartbeat. The launcher still opens, so you can disable a bad mod. The previous session's archives and `!` early autoloads are already up by then; a mod that crashes before the launcher needs `modloader_disabled` | the loader, after the reset |
| `modloader_skip_ui_once` | The next launch skips the launcher and loads the active profile, as if **Launch** were clicked. For mod managers that start the game through Steam; the `--modloader-skip-ui` flag does the same on every launch that passes it | the loader, at that launch |

On Windows: right-click in the game folder, New, Text Document, and rename it to `modloader_disabled` with no extension.

### Crash and state markers

In `user://`. The loader writes and clears these itself; each is safe to delete.

| File | Written | Cleared | A survivor means |
|---|---|---|---|
| `modloader_heartbeat.txt` | right before the Pass 1 to Pass 2 restart | by every finish path, and by safe mode | the last launch died between restart and finish; Pass 1 logs it and resets once the restart count reaches 2 |
| `modloader_pass2_dirty` | at static init of the restarted process, before the first mount | after Pass 2 finishes | Pass 2 was interrupted; the next static init forces vanilla state as `modloader_disabled` does, for one launch |
| `modloader_crash_streak` | +1 each time Pass 1 writes pass state for a restart | by every clean finish, and when the fallback below trips | at 2, Pass 1 skips the restart and loads in a single pass, so the launcher stays reachable; its own file because the crash wipe deletes pass state |
| `modloader_crash_notice` | when that single-pass fallback trips | by the next launcher, which shows it once as a banner | |

## Generated files. Safe to delete

Everything here is regenerated; the cost is a slower first boot while the hook pack rebuilds.

| Path in `user://` | Contents |
|---|---|
| `modloader_hooks/framework_pack_<millis>.zip` | The hook pack, mounted at static init. A fresh name per generation, because Godot keeps stale offsets for a pack path it has mounted; old ones are removed |
| `modloader_hooks/vanilla/` | Vanilla script source decoded from the game's own `.pck`. Its `format` and `build` stamp files name the cache layout and the game build; a mismatch rebuilds it |
| `vmz_mount_cache/` | `.vmz` copies as `.zip`, folder-mod zips, and their `.src` stamps |
| `modloader_early/` | Copies of `!` early autoload scripts that live inside archives |
| `modloader_filescope.log` | What static init mounted or reset before the launcher opened; the first place to look when mods did not mount |
| `modloader_hook_status.json` | Whether last session's hooks worked; the launcher shows a banner from it, until the loader or the game changes |
| `modloader_conflicts.txt` | Developer mode: the conflict report |
| `mws_cache/` | Browse and Modpacks caches: `thumbs/` (ModWorkshop images), `landing_<site>.json` (each site's last landing, for offline use), `landing_vostokmods_packs.json` (the last first page of Browse > Modpacks) and `mods_meta_v2.json` (host details shown on Mods-tab rows) |

When mod updates do not take effect, delete `framework_pack_*.zip`; after a game update that left boot strange, delete `modloader_hooks/`; for suspected stale state, delete `mod_pass_state.cfg`.

Not regenerable: `user://MCM/` holds the active profile's mod settings, and `user://.profile_snapshots/<profile>/` each other profile's. Deleting a profile in the launcher removes its snapshot. Back both up with `mod_config.cfg`.

## Related

- [Mod-Format](Mod-Format): what each mod declares in `mod.txt`
- [Profile-Format](Profile-Format): the `profile.json` inside a modpack
- [Troubleshooting](Troubleshooting): what to try first when something breaks
