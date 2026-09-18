# Troubleshooting

What to do when the game will not start, a mod does nothing, or you want the loader out of the way for a launch. Every step here is reversible.

## Start once without mods

Click **Launch vanilla** in the launcher. The game starts with nothing mounted; your mods and profiles are untouched, and the next launch is modded again.

## The game crashes or will not launch

- Wait it out. After two crashed launches in a row the loader stops restarting and boots in a single pass: the launcher opens as usual, so you can disable the mod that crashes.
- Force-disable the loader: create an empty file named `modloader_disabled` (no extension) in the game folder. On the next launch the loader mounts nothing and the game boots vanilla. Delete the file to re-enable. Use this when the loader itself is broken and you cannot reach the launcher.
- Reset the loader's files once: create an empty file named `modloader_safe_mode` (no extension) in the game folder. On the next launch the loader restores a clean `override.cfg`, deletes its boot state and the crash heartbeat, then deletes the safe-mode file so it runs only once. The launcher still opens, so you can change profiles or disable a bad mod before the next modded boot.

On Windows: right-click inside the game folder, choose New, then Text Document, and rename the file to `modloader_disabled` with no extension. Or open a command prompt in the game folder and run:

```
echo. > modloader_disabled
```

## A mod is enabled but nothing changed in the game

- Look at its row on the [Mods](Mods) tab. An orange `won't load -- needs ...` line means a required mod is missing or off. A red warning means the archive is packaged wrong; [Mod-Format](Mod-Format) has the rules.
- A red banner at the top of the Mods tab saying hooks did not work means the game was probably updated and the loader needs an update too. Click **Check for loader update**.
- A mod that ships only files (no `mod.txt`) still mounts and overrides vanilla files, but runs no code of its own.

## The launcher does not appear

The loader is registered through `override.cfg` in the game folder. If that file is missing or was overwritten by another tool, copy it from the release again. If the game shows a black screen at start, delete `override.cfg`, launch once, then copy a fresh one back; a damaged file stops Godot from loading its autoloads.

## Everything broke after an update

1. Delete `mod_config.cfg` and `mod_config.cfg.bak` in the user folder ([Config-Files](Config-Files) has the path). This resets profiles and settings to fresh-install state. With only the first file gone the launcher restores your profiles from the backup.
2. Delete `mod_pass_state.cfg` in the same folder to force a rebuild of the boot state.
3. Delete the `modloader_hooks` folder there to force the hook pack to regenerate.
4. If the game will not launch at all, create `modloader_disabled` in the game folder, launch vanilla, then remove the file and launch again. The loader rebuilds from scratch.

## Where the loader writes

If you disable all mods and see **Could not launch without mods**, the loader could not remove its old boot state or clean `override.cfg`. The dialog names the failed file. Check its permissions or close the program holding it, then choose **Retry**. **Quit** cancels the launch. The loader does not restart with stale mod state.

The mounts that happen before the launcher opens are logged to `modloader_filescope.log` in the user folder. [Config-Files](Config-Files) lists the files the loader writes, what is safe to delete, and how to back up or reset your profiles. [Stability-Canaries](Stability-Canaries) explains the crash recovery in detail: the heartbeat, the restart counter and the sentinel files.
