# Troubleshooting

What to do when the game will not start, a mod does nothing, or you want the loader out of the way for a launch. Every step here is reversible.

## Start once without mods

Click **Launch vanilla** in the launcher. The game starts with nothing mounted; your mods and profiles are untouched, and the next launch is modded again.

## The game crashes or will not launch

- Wait it out. After two crashed launches in a row the loader stops restarting and boots in a single pass: the launcher opens as usual, so you can disable the mod that crashes, and a banner says what happened.
- Force-disable the loader when you cannot reach the launcher: create an empty file named `modloader_disabled` (no extension) in the game folder. The game boots vanilla until you delete it.
- Reset the loader's files once: create an empty file named `modloader_safe_mode` in the game folder. The launcher still opens, so you can disable a bad mod before the next modded boot.

[Config-Files](Config-Files#sentinel-files-escape-hatches) lists every sentinel file and how to create one on Windows.

## A mod is enabled but nothing changed in the game

- Look at its row on the [Mods](Mods) tab. An orange `won't load -- needs ...` line means a required mod is missing or off. A red warning means the archive is packaged wrong; [Mod-Format](Mod-Format) has the rules.
- Read the banner at the top of the Mods tab, if there is one (below).
- A mod that ships only files (no `mod.txt`) still mounts and overrides vanilla files, but runs no code of its own.
- A mod that stopped working right after a game update with no banner may rely on something it registers rather than hooks. That is the mod's side, not the loader's; its author can follow [Build-2-Migration](Build-2-Migration).

## Banners on the Mods tab

A banner names the problem the last session recorded. Mods still load. A red hook banner has a **Check for loader update** button that opens the release page. A game update on its own shows nothing: the loader rebuilds its script cache, and a banner appears only when that session then records a failure.

| Banner starts with | Color | Meaning and what to do |
|---|---|---|
| `The game crashed N time(s) in a row while starting with mods` | red | Two launches crashed in a row, so the last launch skipped the restart and loaded mods in a single pass. Use **Launch vanilla** to check whether a mod is the cause, then disable the one you added or updated last. Shown once. |
| `The last N launch(es) with mods did not reach the game` | orange | A crash streak is building. At 1, one more failure makes the next launch skip the restart and load mods in a single pass; at 2, the launch you start now already does. |
| `Last time the game ran, hooks did not work on <scripts>` | red | Mods that change those scripts did nothing, usually after a game update. Update the loader. |
| `Last time the game ran, none of the loader's N script rewrites took effect` | red | No hook-based mod did anything. Update the loader. |
| `Last time the game ran, the loader could not build or mount its hook pack` | red | Check the free disk space; if it repeats, update the loader. |
| `The loader's changes to <scripts> do not fit this version of Road to Vostok` | red | A game update changed those scripts and the loader left its changes out. The game and your saves are fine; mods that hook or register against those scripts do nothing until the loader is updated. The banner clears after a session in which every change fit. |
| `The loader could not read this version of Road to Vostok's scripts correctly` | red | Hooks and the registry do nothing until the loader is updated. |
| `This version of Road to Vostok stores its scripts in a format` | red | Same as above: the game's script format is newer than the loader. |
| `Last time the game ran, N hook target(s) a mod asked for were not found` | orange | A game update renamed a method the named mod hooks. The mod's other hooks still work; update that mod. |
| `Last time the game ran, the loader skipped N hook target(s)` | orange | The loader does not rewrite those scripts (skip list, empty script, a rewrite that does not compile, or a disk write failure); each entry names the reason. The mod's other hooks still work. |
| `Last time the game ran, N hooked script(s) wrapped only part of what a mod asked for` | orange | Each entry names what did not wrap: methods, whose hooks did nothing, or the registry transform, so that script's registry features do not work. Hooks on the script's other methods still work. |

## The launcher does not appear

The loader is registered through `override.cfg` in the game folder. If that file is missing or was overwritten by another tool, copy it from the release again. If the game shows a black screen at start, delete `override.cfg`, launch once, then copy a fresh one back; a damaged file stops Godot from loading its autoloads.

## Could not launch without mods

If you disable all mods and see **Could not launch without mods**, the loader could not remove its old boot state or clean `override.cfg`. The dialog names the failed file. Check its permissions or close the program holding it, then choose **Retry**. **Quit** cancels the launch; the loader never restarts with stale mod state.

## Everything broke after an update

1. Delete `mod_config.cfg` and `mod_config.cfg.bak` in the user folder ([Config-Files](Config-Files) has the path). This resets profiles and settings to fresh-install state. With only the first file gone the launcher restores your profiles from the backup.
2. Delete `mod_pass_state.cfg` in the same folder to force a rebuild of the boot state.
3. Delete the `modloader_hooks` folder there to force the hook pack to regenerate.
4. If the game will not launch at all, create `modloader_disabled` in the game folder, launch vanilla, then remove the file and launch again. The loader rebuilds from scratch.

The mounts that happen before the launcher opens are logged to `modloader_filescope.log` in the user folder. [Config-Files](Config-Files) lists every file the loader writes and what is safe to delete.
