# Road to Vostok — Community Mod Loader

A community-built mod loader for **Road to Vostok Demo** (Godot 4). Adds a launcher UI before the game starts, letting you enable/disable mods, set load order priority, check for updates, and preview compatibility issues before they cause problems in-game.

---

## Requirements

- Road to Vostok Demo (PC, Steam)
- Mods packaged as `.zip`, `.vmz`, or `.pck` files

---

## Installation

1. Copy `override.cfg` into the game installation folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok Demo\
   ```

2. Copy `modloader.gd` into the game's data folder:
   ```
   C:\Users\<your username>\AppData\Roaming\Road to Vostok Demo\
   ```

3. Create a `mods` folder inside the game installation folder if it doesn't exist:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok Demo\mods\
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
Lists all detected mods. Use the checkbox to enable or disable each one. The **Priority** spinbox controls load order — higher value loads later and wins any file conflicts. The **Load Order** panel on the right shows the final order in real time.

### Updates
If your mods include ModWorkshop update info in their `mod.txt`, click **Check for Updates** to fetch the latest versions and download updates directly.

### Compatibility
*(Developer mode only)* Click **Run Analysis** to scan your enabled mods without mounting anything. Reports script conflicts, broken override chains, overhaul mod warnings, and Database.gd replacement issues before they affect your game.

### Settings
Toggle developer mode on/off. Developer mode enables:
- **Compatibility tab** — static analysis of override conflicts
- **Compile check** — loads each override script before launch to catch parse errors
- **Override audit** — warns when `overrideScript()` targets have zero live nodes in the scene tree
- **Conflict report** — full log saved to `modloader_conflicts.txt` after each launch
- **Debug logging** — verbose `[Debug]` lines covering load order, override timing, and mount state
- **Loose folder loading** — unzipped mod folders in the mods directory are treated as mods

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
| `priority` | Load order weight. Higher = loads later = wins conflicts. Default 0. |
| `[autoload]` | `Name=res://path/to/script.gd` — instantiated as a Node after all mods mount |
| `[updates] modworkshop` | ModWorkshop mod ID for update checking |

Mods without `mod.txt` are still mounted as resource packs — their files override vanilla resources, but no autoloads run.

---

## Supported Archive Formats

| Format | Notes |
|--------|-------|
| `.vmz` | Road to Vostok's native format (renamed zip) |
| `.zip` | Standard zip — must use forward-slash paths internally |
| `.pck` | Godot PCK — mount only, no mod.txt or autoloads |

---

## Understanding the Conflict Report

After each launch (with developer mode enabled), a full conflict log is written to:

```
%APPDATA%\Road to Vostok Demo\modloader_conflicts.txt
```

### What the messages mean

- **CONFLICT: {path}** — Two mods shipped the same file. The last-loaded mod wins. Adjust priorities if the wrong one is winning.
- **Script Conflict: {file}** — Two mods both call `take_over_path()` on the same script. Only the last-loaded version is active.
- **Chain Broken: {file}** — Mods using `overrideScript()` can stack via `extends + super()`. A mod in the chain is missing `super()` calls, so earlier mods' logic gets dropped.
- **Database.gd Replaced** — A mod replaced `Database.gd`. Scene overrides from other mods may not take effect due to `preload()` caching.
- **Likely Incompatible / Overlap** — Two mods modify many of the same files. The more overlap, the less likely they'll work together.
- **Method Overlap** — Two mods override the same function on the same script. Even with `super()`, their changes may interfere.
- **Bad Archive: {mod}** — The zip has backslash file paths (common with Windows repacking). Re-pack using 7-Zip.
- **class_name Crash: {name}** — Two mods override a script with `class_name`. Godot bug [#83542](https://github.com/godotengine/godot/issues/83542) causes a fatal engine crash. Disable all but one.
- **Missing Script: {file}** — A mod extends a script that no longer exists. The game may have been updated.
- **Uses base(): {mod}** — A mod calls `base()` which is a Godot 3 pattern. Should be `super()` in Godot 4.
- **Stale preload(): {file}** — A mod uses `preload()` on a file that another mod replaces. Use `load()` instead.

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

Settings are stored in `%APPDATA%\Road to Vostok Demo\mod_config.cfg` and can be deleted safely.

---

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
