## Metro Mod Loader -- community mod loader for Road to Vostok (Godot 4.6+).
## Loads .vmz/.pck archives from <game>/mods/ using the saved profile.
## The manager opens from the main-menu Mods button.
## Unpacked folder mods are also recognized when Developer Mode is enabled
## (toggle in the manager's Mods tab).
## Two-pass architecture: mounts archives at file-scope, optionally restarts to
## prepend mod autoloads before the game's own autoloads via [autoload_prepend].
##
## This file is BUILT from src/*.gd via build.sh -- do not edit modloader.gd
## directly; edit the source fragments and rebuild.
extends Node
