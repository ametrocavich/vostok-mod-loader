## Metro Mod Loader -- community mod loader for Road to Vostok (Godot 4.6+).
## Loads .vmz/.zip/.pck archives from <game>/mods/ via a pre-game config window.
## Unpacked folder mods are also recognized when Developer Mode is enabled
## (toggle in the launcher's Mods tab).
## Two-pass architecture: mounts archives before _ready, optionally restarts to
## prepend mod autoloads before the game's own autoloads via [autoload_prepend].
##
## This file is built from src/*.gd by build.sh. Edit the sources and rebuild;
## never edit modloader.gd directly.
extends Node
