# Metro Mod Loader wiki

Documentation for the community mod loader for Road to Vostok (Godot 4.6). The sidebar lists every page in four groups.

## Using the loader

The loader adds a window before the main menu with three tabs: [Mods](Mods) to turn installed mods on and off, set load order, keep profiles and check for updates; [Browse](Browse) to find and download mods from Vostok Mods or ModWorkshop, and to search and get the packs published on Vostok Mods; and [Modpacks](Modpacks) to apply, unload and refresh the packs you got. Start at [Setup](Setup); when something goes wrong, read [Troubleshooting](Troubleshooting).

## Writing a mod

Hooks, the registry and dependencies exist only in this loader, and these pages teach them from scratch:

- [Mod-Format](Mod-Format): the `mod.txt` every mod ships with.
- [Hooks](Hooks): run your code before, after or instead of a vanilla function.
- [Registry](Registry): add or change items, scenes, loot, recipes and other game content.
- [Dependencies](Dependencies): require another mod and load after it.

## For developers

You do not need these to write a mod. [Development](Development) maps a change to the code that owns it, [Architecture](Architecture) explains the boot and restart, and [Style](Style) sets what a line of source has to earn. [CONTRIBUTING](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md) covers building, checking and editing these pages.

The code in `src/` is the authority. If a page and the code disagree, the page is stale: open an issue or a PR.
