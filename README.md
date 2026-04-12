# Road to Vostok — Community Mod Loader

A community-built mod loader for **Road to Vostok** (Godot 4). Adds a launcher UI before the game starts, letting you enable/disable mods, set load order priority, check for updates, and preview compatibility issues before they cause problems in-game.

---

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.zip`, `.vmz`, or `.pck` files

---

## Installation

1. Copy `override.cfg` into the game installation folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```

2. Copy `modloader.gd` into the game's data folder:
   ```
   C:\Users\<your username>\AppData\Roaming\Road to Vostok\
   ```

3. Create a `mods` folder inside the game installation folder if it doesn't exist:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\
   ```

4. Place your `.vmz` or `.zip` mod files inside the `mods` folder.

5. Launch the game normally. The mod loader UI will appear before the main menu.

---

## Installing Mods

Drop `.vmz` or `.zip` mod files into the `mods` folder. The mod loader finds them automatically on next launch.

`.pck` files are also supported (can be enabled/disabled and prioritized in the UI, but no mod.txt parsing, autoloads, or update checking).

---

## The Launcher UI

When you start the game, the mod loader window opens with tabs:

### Mods
Lists all detected mods. Use the checkbox to enable or disable each one. The **Load Order** number controls priority — higher number loads later and wins when mods share files. The **Load Order** panel on the right shows the final order in real time.

A **Developer Mode** checkbox in the toolbar enables extra features for mod creators:
- **Conflict report** — full log saved to `modloader_conflicts.txt` after each launch
- **Debug logging** — verbose `[Debug]` lines covering load order and mount state
- **Loose folder loading** — unzipped mod folders in the mods directory are treated as mods

### Updates
If your mods include ModWorkshop update info in their `mod.txt`, click **Check for Updates** to fetch the latest versions and download updates directly.

Click **Launch Game** (or close the window) when you are ready to play.

---

## mod.txt Reference

Mods can include a `mod.txt` at the root of their archive to register autoloads, set metadata, and enable update checking:

```ini
[mod]
name=My Mod
id=my_mod
version=1.0.0
priority=0

[autoload]
MyModMain=res://Scripts/MyModMain.gd

[updates]
modworkshop=12345
```

| Field | Description |
|---|---|
| `name` | Display name shown in the UI |
| `id` | Unique identifier — duplicates are skipped |
| `version` | Semver string used for update comparison |
| `priority` | Load order number. Higher = loads later = wins. Default 0. |
| `[autoload]` | `Name=res://path/to/script.gd` — instantiated as a Node after all mods mount |
| `[updates] modworkshop` | ModWorkshop mod ID for update checking |

Mods without `mod.txt` are still mounted as resource packs — their files override vanilla resources, but no autoloads run.

---

## Supported Archive Formats

| Format | Notes |
|--------|-------|
| `.vmz` | Road to Vostok's native mod format (renamed zip) |
| `.zip` | Must be renamed to `.vmz` before use |
| `.pck` | Godot PCK — mount only, no mod.txt or autoloads |

---

## Understanding the Conflict Report

After each launch (with developer mode enabled), a full conflict log is written to:

```
%APPDATA%\Road to Vostok\modloader_conflicts.txt
```

### What the messages mean

- **CONFLICT: {path}** — Two mods shipped the same file. The last-loaded mod wins. Adjust load order if the wrong one is winning.
- **DATABASE OVERRIDE: {mod}** — A mod replaced `Database.gd`. This is normal for overhaul mods.
- **BAD ZIP: {mod}** — The archive has broken file paths (common with Windows repacking). Re-download or re-pack using 7-Zip.

---

## For Mod Authors

- **Conflicts are load-order dependent.** Test with other mods installed and check the conflict report.
- **If you replace Database.gd**, every `preload()` path in your version must exist or the game will break.
- **Use `super()` in lifecycle methods.** Skipping it silently breaks any other mod that overrides the same class.
- **Avoid `take_over_path()` on commonly-overridden scripts** when possible. The `extends + super()` pattern composes across mods; flat `take_over_path()` doesn't.
- **`UpdateTooltip()` does not affect world items.** World-item tooltip text comes from `HUD._physics_process` reading `gameData.tooltip`.
- **Windows zip repacking** — use 7-Zip or a tool that writes forward-slash entry paths. .NET `ZipFile.CreateFromDirectory()` writes backslash paths by default, which Godot can't resolve.

---

## Uninstalling

Delete `override.cfg` from the Steam installation folder and `modloader.gd` from the AppData folder. The `mods` folder and its contents can be removed separately.

Settings are stored in `%APPDATA%\Road to Vostok\mod_config.cfg` and can be deleted safely.

---

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
