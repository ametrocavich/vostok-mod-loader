# Road to Vostok — Community Mod Loader

A community-built mod loader for **Road to Vostok Demo** (Godot 4). Adds a launcher UI before the game starts, letting you enable/disable mods, set load order priority, check for updates, and preview compatibility issues before they cause problems in-game.

---

## Requirements

- Road to Vostok Demo (PC, Steam)
- Mods packaged as `.zip` or `.vmz` files

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

`.pck` files are also supported (mounted silently, no UI controls or update checking).

---

## The Launcher UI

When you start the game, the mod loader window opens with three tabs:

### Mods
Lists all detected mods. Use the checkbox to enable or disable each one. The **Priority** spinbox controls load order — higher value loads later and wins any file conflicts. The **Load Order** panel on the right shows the final order in real time.

### Compatibility
Click **Run Analysis** to scan your enabled mods without mounting anything. Reports script conflicts, broken override chains, overhaul mod warnings, and Database.gd replacement issues before they affect your game.

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
| `priority` | Load order weight. Higher = loads later = wins conflicts. Default 0. |
| `[autoload]` | `Name=res://path/to/script.gd` — instantiated as a Node after all mods mount |
| `[updates] modworkshop` | ModWorkshop mod ID for automatic update checking |

Mods without `mod.txt` are still mounted as resource packs — their files override vanilla resources, but no autoloads run.

---

## Uninstalling

Delete `override.cfg` from the Steam installation folder and `modloader.gd` from the AppData folder. The `mods` folder and its contents can be removed separately.

Settings are stored in `%APPDATA%\Road to Vostok Demo\mod_config.cfg` and can be deleted safely.

---

## Conflict Report

After each launch, a full conflict log is written to:

```
%APPDATA%\Road to Vostok Demo\modloader_conflicts.txt
```

This includes load order, all resource path conflicts, script analysis results, and any critical warnings.
