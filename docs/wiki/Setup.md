# Setup

How to install the mod loader and get your first mods running.

## Install the loader

1. Download the latest release from the [Releases page](https://github.com/ametrocavich/vostok-mod-loader/releases/latest).
2. Copy `override.cfg` and `modloader.gd` from the download into the Road to Vostok game folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
3. Create a `mods` folder in that same game folder if there isn't one already.
4. Launch the game. The mod loader screen appears before the main menu.

That's it -- the loader is installed. From its screen you can turn mods on and off, download new ones, and launch the game.

## Get some mods

- The **Browse** tab searches [ModWorkshop](https://modworkshop.net) from inside the loader -- click **Download** on a mod to install it. See [Browse](Browse).
- The **Modpacks** tab lets you apply a friend's whole mod list in one go, or share yours. See [Modpacks](Modpacks).
- You can also install a mod by hand: drop its `.vmz` file into the `mods` folder.

Some things mods can't do are engine limits, not bugs -- see [Limitations](Limitations).

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder. Your `mods` folder can stay or go -- it's just your downloaded mods.
