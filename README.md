# Road to Vostok - Community Mod Loader

Pre-game mod manager for Road to Vostok (Godot 4.6). Drop mods into a folder, pick which ones to enable, set load order, launch.

For mod authors and contributors: [DOCUMENTATION.md](DOCUMENTATION.md).

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz` or `.pck` (unpacked folders also work in Developer Mode)

## Install

1. Copy `override.cfg` and `modloader.gd` into the game folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
2. Create a `mods` folder next to them if it doesn't already exist.
3. Launch the game. The mod loader UI appears before the main menu.

## Adding mods

Drop mod files into the `mods` folder. They show up in the launcher on next launch.

| Format | Notes |
|--------|-------|
| `.vmz` | Road to Vostok's native mod format (a renamed zip). |
| `.pck` | Godot PCK. Mounts as resources only -- no `mod.txt`, autoloads, or update checking. |
| folder | Unpacked mod directory. **Developer Mode only** -- toggle the checkbox in the launcher's Mods tab. |

If a mod was distributed as a `.zip`, rename it to `.vmz`.

## Launcher

Two tabs:

- **Mods** -- detected mods with checkboxes and a priority spinner. Higher priority loads later and wins file conflicts. The right side shows the live load order.
- **Updates** -- check for and download mod updates if their `mod.txt` includes a ModWorkshop ID.

Click **Launch Game** (or close the window) to start.

## Something went wrong

- **Reset button.** Click **Reset to Vanilla** in the launcher. Wipes the hook pack, pass state, `override.cfg` mod entries, and unchecks every mod, then restarts into a clean vanilla run. Your mod files stay in `mods/`.
- **Wait it out.** After 2 failed launches in a row, the mod loader auto-resets.
- **Disable ModLoader entirely.** Create an empty file named `modloader_disabled` (no extension) in the game folder. ModLoader skips all work on next launch. Delete the file to re-enable. Use this when the loader itself is broken and you can't reach the UI.
- **One-shot reset.** Create an empty file named `modloader_safe_mode` (no extension) in the game folder. Triggers a clean reset on next launch, then deletes itself.
- **Nuclear.** Delete `override.cfg` from the game folder and replace it with a fresh copy from the mod loader release.

## Uninstall

Delete `override.cfg` and `modloader.gd` from the game folder. The `mods` folder can be removed separately.

The mod loader also writes these files in `%APPDATA%\Road to Vostok\` (safe to delete after uninstall):

- `mod_config.cfg` -- launcher settings
- `modloader_hooks\` -- hook cache, regenerated each launch
- `modloader_conflicts.txt` -- conflict log, Developer Mode only

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
