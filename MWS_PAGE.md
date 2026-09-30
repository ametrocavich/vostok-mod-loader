<!--
Listing text for https://modworkshop.net/mod/55623
State seen 2026-09-30: still serves 3.2.1, and the changelog field still
carries the v2.1.0 -> v3.1.0 text. On release day: replace the description
with everything below the second marker, upload the 3.4.1 zip built from the
PUBLISHED GitHub release assets, and paste the block between the two markers
into the changelog field. Same body as VOSTOKMODS_PAGE.md; keep the two in
step.
-->

<!-- changelog for the 3.4.1 version entry (everything since 3.2.1, the version both listings still host) -->
**3.4.1**

* Runs on Road to Vostok Build 2 (Nomads). AI loadouts follow the new AI variants, AI type overrides follow the new spawner, and the trader, loot table and class lists know the Build 2 names. Mod authors: the Build-2-Migration page on the GitHub wiki lists what the game changed for mods.
* Browse and install mods from VostokMods (the default) or ModWorkshop without leaving the launcher. Check for updates asks each mod's own site.
* Modpacks from VostokMods (beta): one small zip carries a mod selection, load order, MCM settings and download sources. Apply switches to the author's setup, Unload puts yours back.
* Required and optional dependencies: a mod that is missing something says what it needs, with one-click Enable dependency.
* The launcher tells you when a game update has stopped script hooks from working, and the loader's own update notice reads the GitHub release.
* After a game update, a loader change that no longer fits a game script is left out instead of breaking that script: the game keeps running and the launcher names what was skipped.
* The loader no longer edits mod scripts in any way. Mods run exactly as their authors shipped them.
* Many fixes to load order, profiles, crash recovery and hook reliability. Full notes on GitHub.

Coming from 3.2.1: copy the new `modloader.gd` and `override.cfg` over the old ones (or run the installer). Profiles, enabled mods and load order carry over.
<!-- end changelog -->

# Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game launcher for installing mods from VostokMods or ModWorkshop, managing load order and profiles, applying modpacks and checking for updates. It restores mod loading now that the original --main-pack injector method no longer works.

Back up your saves before installing any mods.

3.4.1 supports Road to Vostok Build 2 (Nomads). Mod authors: the Build-2-Migration page on the GitHub wiki lists what the game changed for mods.

# What you get

Pre-game launcher. Mod profiles. In-launcher browser and installer for VostokMods and ModWorkshop. Modpacks from VostokMods. Dependency handling. Update check for both sites. Malware scanner. Crash auto-recovery. Drop `.zip` or `.vmz` straight into the mods folder.

The launcher has three tabs: **Mods**, **Browse** and **Modpacks**.

* **Mods** -- every detected mod with a checkbox and a priority spinbox; a higher priority loads later and wins file conflicts. Profiles, Developer Mode and **Check for updates** live here; a mod with a newer version on its site is listed under Updates available with an Update button. Mods that declare required dependencies get a clear "won't load -- needs X" line with one-click **Enable dependency** and **Load anyway** buttons, and mods whose requirements aren't met are skipped instead of crashing.
* **Browse** -- search VostokMods, or switch the source menu to ModWorkshop, and install mods without leaving the launcher. Downloads land in your mods folder and show up enabled in the Default profile (off in any other profile until you tick them). Multiple installs queue and run one at a time.
* **Modpacks** (beta) -- apply a setup published on VostokMods: a mod selection with load order, MCM settings and download sources, shipped as one small `.zip`. Apply pulls down any mods you're missing and switches you to the author's exact setup; Unload puts your previous setup back.

# Installation

The download contains four files: `modloader.gd`, `override.cfg`, `windows-installer.bat`, and `linux-installer.sh`. Only the first two go in the game folder. The two installer scripts are alternatives that automate the manual steps for you -- pick one path below.

## Automated (recommended)

* **Windows**: double-click `windows-installer.bat`. It locates the game folder, installs `modloader.gd` and `override.cfg`, and creates the `mods` directory.
* **Linux**: run `bash linux-installer.sh` from a terminal. Same flow.

## Manual

1. Right-click Road to Vostok in your Steam library and select `Manage > Browse local files`. Steam opens the game folder.
2. Copy `modloader.gd` and `override.cfg` into that folder. Do not copy the installer scripts. They are not needed for a manual install.
3. If a `mods` folder does not already exist next to them, create one.

## Upgrading from v2 or earlier

Older versions installed the loader into `%APPDATA%\Road to Vostok` (Windows) instead of the game folder. The Windows installer cleans those leftovers up automatically. If you are installing manually, delete the old `modloader.gd` and `override.cfg` from `%APPDATA%\Road to Vostok` first, then copy the new files into the game folder.

The mod loader is now installed. Launch the game normally -- no launch options required. The launcher appears before the main menu.

# Installing mods

Use the Browse tab, or drop `.vmz` or `.zip` mod files into the `mods` folder inside the game directory. Unpacked folders work too if you enable Developer Mode in the launcher.

Example:

```
Road to Vostok/mods/ItemSpawner.vmz
Road to Vostok/mods/SomeOtherMod.zip
```

# How it works

The original VostokMods injector used `--main-pack Injector.pck` as a launch option to take control before the game booted. The game no longer supports this.

This loader uses `override.cfg` to register `modloader.gd` as an autoload that Godot runs at startup. It scans the mods folder, mounts archives via `ProjectSettings.load_resource_pack()`, reads each mod's `mod.txt`, shows you the launcher, and instantiates autoloads in the order you chose -- reproducing the original injector's behavior without modifying launch options.

# Credits

Original mod loader system: VostokMods by Ryhon0.
Hook API based on tetrahydroc's RTVModLib.
