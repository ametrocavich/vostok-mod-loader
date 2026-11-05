<!--
Listing text for https://vostokmods.net/mod/metro-mod-loader
Category Libraries, tag Tools.

On release day:
  1. Description: paste everything below the last marker.
  2. New version: upload a zip built from the PUBLISHED GitHub release
     assets (modloader.gd, override.cfg, windows-installer.bat,
     linux-installer.sh), not from a local build.
  3. Changelog field: paste the new version's block, then every older block
     the listing never got (check which version it serves first).
  4. Game version: the build the release was accepted on.
Same body as MWS_PAGE.md; tools/dev.py check-docs fails when the two differ.
-->

<!-- changelog for the 3.5.0 version entry. If the listing is behind, paste this block and then the older blocks below it -->
**3.5.0**

* 3.5 is the long-term support line: it stays on Road to Vostok Build 2 (Nomads) and gets fixes only from here on.
* The launcher no longer scans mod archives for suspicious code. Vostok Mods scans every file it serves, and the in-launcher scan read large asset mods file by file, which could hold the launcher for minutes on every start.
* Update finishes when the new version is already in your mods folder, and a download whose file turns out to be another mod is refused instead of installed over yours.
* Deleting a mod removes it from every profile under every version it was ever installed as.
* The Mods window opened from the main menu lists what is in your mods folder now and sends you back to the game without a restart when nothing that loads changed; its button reads Back to game or Apply and restart. A profile switch made there swaps your in-game mod settings at the restart, so mods saving on exit no longer overwrite them.
* The launcher tells you when two launches with mods crashed in a row, so the last one skipped the restart and loaded mods in a single pass, and when a game update removed a method a mod hooks.
* The Windows installer merges a hand-edited override.cfg correctly (3.4.x replaced the merged result with the bare template) and both installers refuse a web page served in place of the loader.
* Vostok Mods rows in Browse show the date of the mod's newest file, and Recently updated sorts by it.
* A modpack mod the site cannot serve yet gets a Download button on the Mods tab, with the site's own reason, instead of "Download unavailable".
* Browse switches between Mods and Modpacks: Modpacks lists the packs on Vostok Mods with covers, search and sort; Get one from the list or a pasted link and see its mods before you apply. The Modpacks tab holds the packs you got. Modpacks are no longer labelled beta.
* Check for updates also reports the packs that changed on Vostok Mods, a pack whose mod settings are too many or too large is refused, and the launcher waits out the site's rate limit for as long as the site asks.
* Download size limits apply as written (the loader set a property Godot 4.6 does not have, so none applied); the mod download limit is 1 GiB.
* A dependency listed as both required and optional counts as required. Registry fixes: reverting a patched-then-overridden recipe, event or trader task restores the original entry; two mods enabling the same item for the same trader pool no longer undo each other.
* Internals cleaned up for the long-term line: the loader's code is about a quarter smaller (some 5,700 fewer lines). Mods that work on 3.4.x keep working; the mod API gained one call, below.
* For mod authors: RTVModLib.active_profile() names the profile the mods loaded from, and has_replace() no longer reports a replace slot whose owner is gone. Full notes on GitHub.
<!-- end changelog -->

<!-- changelog for the 3.4.2 version entry -->
**3.4.2**

* Vostok Mods modpacks apply with their mods turned on. Mods you already had are found whether their mod.txt names them by slug or by UUID, so they are no longer downloaded again, and Get from Vostok Mods lists the site's packs again.
* Browse thumbnails over 1 MB load, and animated covers show their first frame.
* An empty mod_config.cfg left by a crash or a full disk is recovered from its backup instead of losing your profiles.
* Update explains when an enabled .zip mod is locked by the game, and never replaces a mod with a different one.
* The launcher stays in view when dragged on screens larger than 1920x1080, and clicks beside it no longer reach the main menu. External mod managers can skip it with --modloader-skip-ui.
* The malware scan reads binary scenes and resources, and turning off the last hooking mod no longer leaves its hook pack mounted.
* For mod authors: scene_paths overrides of vanilla scenes and sounds-registry clips now work. Full notes on GitHub.
<!-- end changelog -->

<!-- changelog for the 3.4.1 version entry (sums up everything since the previous stable release) -->
**3.4.1**

* Runs on Road to Vostok Build 2 (Nomads). AI loadouts follow the new AI variants, AI type overrides follow the new spawner, and the trader, loot table and class lists know the Build 2 names. Mod authors: the Build-2-Migration page on the GitHub wiki lists what the game changed for mods.
* Browse and install mods from Vostok Mods (the default) or ModWorkshop without leaving the launcher. Check for updates asks each mod's own site.
* Modpacks from Vostok Mods: one small zip carries a mod selection, load order, MCM settings and download sources. Apply switches to the author's setup, Unload puts yours back.
* Required and optional dependencies: a mod that is missing something says what it needs, with one-click Enable dependency.
* The launcher tells you when a game update has stopped script hooks from working, and the loader's own update notice reads the GitHub release.
* After a game update, a loader change that no longer fits a game script is left out instead of breaking that script: the game keeps running and the launcher names what was skipped.
* The loader no longer edits mod scripts in any way. Mods run exactly as their authors shipped them.
* Many fixes to load order, profiles, crash recovery and hook reliability. Full notes on GitHub.

Coming from 3.2.1: copy the new `modloader.gd` and `override.cfg` over the old ones (or run the installer). Profiles, enabled mods and load order carry over.
<!-- end changelog -->

# Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game launcher for installing mods from Vostok Mods or ModWorkshop, managing load order and profiles, applying modpacks and checking for updates. It restores mod loading now that the original --main-pack injector method no longer works.

Back up your saves before installing any mods.

3.5 is the long-term support line: it runs on Road to Vostok Build 2 (Nomads) and gets fixes only from here on. Mod authors: the Build-2-Migration page on the GitHub wiki lists what the game changed for mods.

# What you get

Pre-game launcher. Mod profiles. In-launcher browser and installer for Vostok Mods and ModWorkshop. Modpacks from Vostok Mods. Dependency handling. Update check for both sites. Crash auto-recovery. Drop `.zip` or `.vmz` straight into the mods folder.

The launcher has three tabs: **Mods**, **Browse** and **Modpacks**.

* **Mods**: every detected mod with a checkbox and a priority spinbox; a higher priority loads later and wins file conflicts. Profiles, Developer mode and **Check for updates** live here; a mod with a newer version on its site is listed under Updates available with an Update button. Mods that declare required dependencies get a clear "won't load -- needs X" line with one-click **Enable dependency** and **Load anyway** buttons, and mods whose requirements aren't met are skipped instead of crashing.
* **Browse**: search Vostok Mods, or switch the source menu to ModWorkshop, and install mods without leaving the launcher. Downloads land in your mods folder and show up enabled in the Default profile (off in any other profile until you tick them). Multiple installs queue and run one at a time. Switch Browse to Modpacks to search the setups published on Vostok Mods and get one with a click.
* **Modpacks**: the packs you got, each a mod selection with load order, MCM settings and download sources shipped as one small `.zip`. Apply pulls down any mods you're missing and switches you to the author's exact setup; Unload puts your previous setup back.

# Installation

The download contains four files: `modloader.gd`, `override.cfg`, `windows-installer.bat`, and `linux-installer.sh`. Only the first two go in the game folder. The two installer scripts automate the manual steps; pick one path below.

## Automated (recommended)

* **Windows**: double-click `windows-installer.bat`. It locates the game folder, installs `modloader.gd` and `override.cfg`, and creates the `mods` directory.
* **Linux**: run `bash linux-installer.sh` from a terminal. Same flow.

## Manual

1. Right-click Road to Vostok in your Steam library and select `Manage > Browse local files`. Steam opens the game folder.
2. Copy `modloader.gd` and `override.cfg` into that folder. Do not copy the installer scripts. They are not needed for a manual install.
3. If a `mods` folder does not already exist next to them, create one.

The mod loader is now installed. Launch the game normally; no launch options are needed. The launcher appears before the main menu.

# Installing mods

Use the Browse tab, or drop `.vmz` or `.zip` mod files into the `mods` folder inside the game directory. Unpacked folders work too if you enable Developer mode in the launcher.

Example:

```
Road to Vostok/mods/ItemSpawner.vmz
Road to Vostok/mods/SomeOtherMod.zip
```

# How it works

This loader uses `override.cfg` to register `modloader.gd` as an autoload that Godot runs at startup. It scans the mods folder, mounts archives via `ProjectSettings.load_resource_pack()`, reads each mod's `mod.txt`, shows you the launcher, and instantiates autoloads in the order you chose.

# Credits

Original mod loader system: VostokMods by Ryhon0.
Hook API based on tetrahydroc's RTVModLib.
