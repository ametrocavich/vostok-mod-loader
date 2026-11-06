# Road to Vostok Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game window for installing mods, managing load order and profiles, applying modpacks, and checking for updates.

3.5 is the long-term support line of the loader: it runs on Road to Vostok Build 2 (Nomads) and gets fixes only. Mod authors updating a mod from the build before it: see the [Build-2-Migration wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Build-2-Migration).

Docs live on the [Wiki](https://github.com/ametrocavich/vostok-mod-loader/wiki). Changing the loader itself? Start with [CONTRIBUTING](CONTRIBUTING.md) and the [development map](docs/wiki/Development.md).

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz`, `.zip` or `.pck`. Unpacked folders work in developer mode.

## Installation

1. Download `override.cfg` and `modloader.gd` from the [latest release](https://github.com/ametrocavich/vostok-mod-loader/releases/latest), or run `windows-installer.bat` / `linux-installer.sh` from the same release: they find the game through Steam's library folders, place both files and create the `mods` folder.
2. Copy both files into the game folder, usually
   `C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\` on Windows or
   `~/.steam/steam/steamapps/common/Road to Vostok/` on Linux.
   Steam's `Manage > Browse local files` opens it.
3. Create a `mods` folder there if it doesn't exist.
4. Launch the game. The mod loader window appears before the main menu.

Install mods from the launcher, or drop `.vmz` files into `mods/`. The [Setup wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Setup) has the details.

## Launcher

- **Mods**: your mods with checkboxes, load priority (higher loads later and wins file conflicts), profiles, dependency fixes and **Check for updates**. See the [Mods wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mods).
- **Browse**: search and install mods from [Vostok Mods](https://vostokmods.net), or switch the source menu to [ModWorkshop](https://modworkshop.net). Switch Browse from Mods to Modpacks to search the packs published on Vostok Mods and get one from the list or from a pasted link. See the [Browse wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Browse).
- **Modpacks**: the packs you got, with Details, Apply, Unload and Refresh; Unload restores your own profile and mod settings. See the [Modpacks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Modpacks).

Click the launch button or close the window to start. The main menu's **Mods** button reopens the window.

## Writing a mod

A mod is a `.vmz` (a renamed `.zip`) with a `mod.txt` at its root; the [Mod-Format wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mod-Format) has every section and key. Mods hook vanilla methods through `Engine.get_meta("RTVModLib")`, an API drop-in compatible with [tetrahydroc's RTVModLib mod](https://github.com/tetrahydroc/rtv-mod-lib); see the [Hooks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Hooks).

## Troubleshooting

Click **Launch vanilla** in the launcher to start once with no mods. The [Troubleshooting wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Troubleshooting) covers a game that will not start, the launcher's banners and the reset steps.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder, and any `override.cfg.bak` or `override.cfg.bak.previous` the installer left beside them. The `mods/` folder can be removed separately. Your profiles live in `%APPDATA%\Road to Vostok\mod_config.cfg`; the [Config-Files wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Config-Files) lists every file the loader writes.

## License

MIT. See [LICENSE](LICENSE).
