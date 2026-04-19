## Metro Mod Loader -- community mod loader for Road to Vostok (Godot 4.6+).
## Loads .vmz/.pck archives from <game>/mods/ via a pre-game config window.
## Two-pass architecture: mounts archives at file-scope, optionally restarts to
## prepend mod autoloads before the game's own autoloads via [autoload_prepend].
##
## This file is BUILT from src/*.gd via build.sh -- do not edit modloader.gd
## directly; edit the source fragments and rebuild.
extends Node
