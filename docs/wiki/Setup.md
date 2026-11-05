# Setup

How to install the mod loader and get your first mods running.

## Install the loader

1. Download the latest release from the [Releases page](https://github.com/ametrocavich/vostok-mod-loader/releases/latest). You need two files, `override.cfg` and `modloader.gd`. The release also ships `windows-installer.bat` and `linux-installer.sh`, which fetch and place them for you. They look in the usual Steam folders and in Steam's own list of library folders; when they ask for the path, the game folder and the path to `RTV.exe` both work.
2. Copy `override.cfg` and `modloader.gd` into the Road to Vostok game folder. On Windows that is usually
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
   and on Linux
   ```
   ~/.steam/steam/steamapps/common/Road to Vostok/
   ```
   Right-clicking the game in Steam and choosing `Manage > Browse local files` opens it on either system.
3. Create a `mods` folder in that same game folder if there isn't one already.
4. Launch the game. The mod loader window appears before the main menu.

From that window you turn mods on and off, download new ones, and launch the game; [Mods](Mods) walks through it, including how the main menu's **Mods** button reopens it.

## Get some mods

- The **Browse** tab searches [Vostok Mods](https://vostokmods.net) from inside the loader, or [ModWorkshop](https://modworkshop.net) if you pick it in the source menu. See [Browse](Browse).
- The **Modpacks** tab applies a whole setup published on Vostok Mods in one go. See [Modpacks](Modpacks).
- You can also install a mod by hand: drop its `.vmz` (or `.zip` / `.pck`) file into the `mods` folder.

Some things mods can't do are engine limits, not bugs. See [Limitations](Limitations).

## Starting the game from another mod manager

A mod manager outside the game can skip the loader's window and load the active profile's mods as if **Launch** had been clicked. Start the game with `--modloader-skip-ui` (for example in Steam's launch options), or create an empty `modloader_skip_ui_once` file beside `RTV.exe` for one launch; the loader deletes the file as it skips. When the set of mods changed since the last launch the game still restarts once to load them.

## When something goes wrong

[Troubleshooting](Troubleshooting) covers a game that will not start, a mod that does nothing, and how to reset the loader.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder, and any `override.cfg.bak` or `override.cfg.bak.previous` the installer left beside them. Your `mods` folder can stay or go; it is only your downloaded mods. Your profiles live in `%APPDATA%\Road to Vostok\mod_config.cfg` if you want those gone too (see [Config-Files](Config-Files)).
