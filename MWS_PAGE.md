# Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a full pre-game launcher UI for managing your mod loadout, and restores mod loading after the original --main-pack injector method stopped working in the current demo build.

Back up your saves before installing any mods.

# What you get

Pre-game launcher. Mod profiles. ModWorkshop update checker. Malware scanner. Crash auto-recovery. Drop `.zip` or `.vmz` straight into the mods folder.

# Installation

The download contains four files: `modloader.gd`, `override.cfg`, `windows-installer.bat`, and `linux-installer.sh`. Only the first two go in the game folder. The two installer scripts are alternatives that automate the manual steps for you -- pick one path below.

## Automated (recommended)

* **Windows**: double-click `windows-installer.bat`. It locates the game folder, installs `modloader.gd` and `override.cfg`, and creates the `mods` directory.
* **Linux**: run `./linux-installer.sh` from a terminal. Same flow.

## Manual

1. Right-click Road to Vostok in your Steam library and select `Manage > Browse local files`. Steam opens the game folder.
2. Copy `modloader.gd` and `override.cfg` into that folder. Do not copy the installer scripts -- they are not needed for a manual install.
3. If a `mods` folder does not already exist next to them, create one.

## Upgrading from v2 or earlier

Older versions installed the loader into `%APPDATA%\Road to Vostok` (Windows) instead of the game folder. The Windows installer cleans those leftovers up automatically. If you are installing manually, delete the old `modloader.gd` and `override.cfg` from `%APPDATA%\Road to Vostok` first, then copy the new files into the game folder.

The mod loader is now installed. Launch the game normally -- no launch options required. The launcher UI appears before the main menu.

# Installing mods

Drop `.vmz` or `.zip` mod files into the `mods` folder inside the game directory. Unpacked folders work too if you enable Developer Mode in the launcher.

Example:

```
Road to Vostok/mods/ItemSpawner.vmz
Road to Vostok/mods/SomeOtherMod.zip
```

# How it works

The original VostokMods injector used `--main-pack Injector.pck` as a launch option to take control before the game booted. The current demo no longer supports this.

This loader uses `override.cfg` to register `modloader.gd` as an autoload that Godot runs at startup. It scans the mods folder, mounts archives via `ProjectSettings.load_resource_pack()`, reads each mod's `mod.txt`, shows you the launcher UI, and instantiates autoloads in the order you chose -- reproducing the original injector's behavior without modifying launch options.

# Credits

Original mod loader system: VostokMods by Ryhon0.
Hook API and framework wrappers based on tetrahydroc's RTVModLib.
