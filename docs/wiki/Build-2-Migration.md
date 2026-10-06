# Updating your mod for Build 2

Road to Vostok's Build 2 update ("Nomads") changed a lot inside the game: the AI was rewritten, most sound names changed, and some scripts were added or removed. Some mods keep working. Some break. This page helps you find out which one yours is, and fix it.

Plan for about half an hour. You need Metro Mod Loader 3.4.1 or newer installed.

## Does this affect my mod?

Quick check. Your mod is probably **fine** if all it does is:

- add new items, recipes, events or scenes
- hook player-side things (the controller, the camera, the inventory, the traders)
- change item stats with `patch`

Your mod probably **needs work** if it does any of these:

- hooks anything in `AI.gd` or `AISpawner.gd`
- gives AI new weapons with `ai_loadouts`, or swaps AI with `ai_types`
- changes sounds with the `sounds` registry
- replaces a whole game script, scene or resource file with its own copy
- calls into the AI or spawner from its own code

Not sure? Do Step 1. It takes five minutes and gives you a definite answer.

## Step 1: Launch once and look at the log

The game writes a text log every time it runs. The mod loader writes into that log too, and it tells you exactly what broke.

1. In the mod loader window, enable only your mod. Launch. The game restarts itself once (that is normal), then reaches the main menu. Quit.
2. Open this folder in Windows Explorer: `%APPDATA%\Road to Vostok\logs`. (Paste that into the address bar.) On Linux it is the `logs` folder inside the game's user data folder.
3. A modded launch is two processes, and each writes its own log. The first process builds the hooks and restarts the game; its log is the **newest dated file**. The second process is the one that runs your mod's code; its log is `godot.log`. Open both in a text editor.
4. Press Ctrl+F and search for each of these:

| Search for | In which log | What it means | Go to |
|---|---|---|---|
| `will NEVER fire` | the newest dated file | One of your hooks points at a game function that no longer exists. The line names it. | Step 2 |
| `[Registry]` | `godot.log` | One of your `lib.register` / `override` / `patch` calls was refused. The line says why. | Step 3 |
| `SCRIPT ERROR` | `godot.log` | Your own code tried to use something the game no longer has. | Step 4 |

Found none of the three? Your mod's code is fine. Jump to Step 5 to check replaced files, then Step 6 to test.

Found some? Keep the logs open. Each line is one thing to fix, and the steps below tell you how.

## Step 2: A hook says `will NEVER fire`

You will see a line like this:

```
Hook on AISpawner.gd::spawnwanderer will NEVER fire: no such method in vanilla. Check the spelling, or the game update renamed/removed it.
```

It means: your hook waits for a function called `SpawnWanderer` in `AISpawner.gd`, and Build 2 renamed it. Nothing crashes. Your code just never runs. A few lines further down, the hook report repeats it in one line per script:

```
PARTIAL AISpawner.gd (declared by My Mod): wrapped, but missing: spawnwanderer
```

You get both lines even when another installed mod uses the registry, which makes the loader wrap every function in that script.

**How to fix it**

1. Find the new name. The most common ones are in the table below. If yours is not there, see "Reading the game's current scripts" at the bottom of this page.
2. Change the hook name in your code. Hook names are `scriptname-functionname-pre` (or `-post`), all lowercase.
3. If the function is also listed in the `[hooks]` section of your `mod.txt`, change it there too.

Before:

```gdscript
lib.hook("aispawner-spawnwanderer-post", _on_spawn)
```

After:

```gdscript
lib.hook("aispawner-spawnenemy-post", _on_spawn)
```

| Old function | What to use now |
|---|---|
| `SpawnWanderer` | `SpawnEnemy`. Nomads (new in Build 2) are spawned separately by `SpawnNomad`. |
| `DestroyAllAI` | `Deactivate`. It removes every enemy and nomad, but also stops new ones spawning until the spawner restarts. |
| `ShowPoints`, `HidePoints`, `ShowGizmos`, `HideGizmos`, `ForceState`, `AIHide`, `AIShow` | Removed. There is one `Debug(toggle)` function now. |

Two functions kept their name but changed what they take. That matters because your hook callback receives the same arguments as the function:

- `SpawnBoss(spawnPosition)` is now `SpawnBoss(boss, state, spawnPosition, currentPoint)`
- `CreateHotspot(location, relay)` is now `CreateHotspot(location)`

If you hook either one, update your callback's parameters to match.

## Step 3: A registry call was refused

A `[Registry]` line looks like this:

```
[Registry] override('sounds', 'knifeSlash'): no vanilla AudioLibrary field with that name (register can't be overridden; revert the register first). Current names: ambientMenu, ambientWind, ...
```

The bit after the colon says what went wrong. Here is each kind and its fix.

**"unknown ai_type"** (from `ai_loadouts`)

The list of AI categories changed. It is now: `Nomad`, `Bandit`, `Guard`, `Military`, `Boss`, `Punisher`, `Bogeyman`.

The good news: `Bandit`, `Guard`, `Military` and `Punisher` still work exactly as before. The new ones are `Nomad` (the wanderers Build 2 added), `Boss` (both bosses at once) and `Bogeyman` (the second boss). Add them if you want those AI to get your weapon.

```gdscript
"ai_types": ["Bandit", "Nomad"],   # bandits and the new nomads
```

**"no vanilla AudioLibrary field with that name"** (from `sounds`)

Build 2 renamed most sounds. Whatever name your mod uses, the game does not have it any more. Common renames:

| Old name | New name |
|---|---|
| `vostokEnter` | `vostok` |
| `firemodeSemi` | `semi` |
| `firemodeAuto` | `auto` |
| `footstepSnowSoft` | `footstepSnow` |

Removed entirely, no replacement: `knifeDraw`, `knifeSlash`, `knifeStab`, `knifeHolster`, everything starting with `grenade` or `rod`, and `doorMetal`, `doorWood`, `doorUnlock`.

A few sounds are no longer in the sound library at all. The airdrop sounds, the grenade bounce sounds and the fishing lure sounds now live inside `CASA.gd`, `Grenade.gd` and `Lure.gd`. The `sounds` registry cannot change those. If you need to, hook the script that plays them instead.

For every other sound, the refusal line itself is the list: everything after `Current names:` is a field the game has right now. `patch` and the array verbs on an unknown id are refused the same way (`no sound with that id. Current names: ...`). If your mod never calls the `sounds` registry and only reads `audioLibrary.<name>` in its own code, print the list yourself once:

```gdscript
for p in load("res://Resources/AudioLibrary.tres").get_property_list():
    print(p.name)
```

`knifeHitFleshSlash` is one that still exists, if you want a safe example to test with.

**"unknown table"** (from `loot`)

The airdrop and Punisher loot tables have numbers on the end. Use `LT_Airdrop_01`, `LT_Airdrop_02`, `LT_Airdrop_03`, `LT_Punisher_01` to `_03`, or the new `LT_Bogeyman_01`. Plain `LT_Airdrop` and `LT_Punisher` never worked; older loaders just failed more quietly.

**"unknown zone"** (from `ai_types`)

Zones are `Area05`, `BorderZone`, `Vostok`, and new in Build 2, `Debug`. One thing to know: your override replaces the zone's ordinary enemies only. Nomads and bosses come from their own separate pools and are not affected. If your mod counted on replacing every AI in an area, it no longer does.

**"name already in shelters list"** or **"name collides with a vanilla scene const"** (from `shelters` / `maps`)

Build 2 added a shelter called `Garage` and maps called `Bridge` and `Airfield`. If your mod registered one under those names, pick a different name.

**Traders**: nothing to fix. `Driver` and `Hunter` are new and work alongside `Generalist`, `Doctor` and `Gunsmith`.

## Step 4: A `SCRIPT ERROR` in your own code

This is your code calling something that is gone. The line tells you the file, the line number, and usually something like `Invalid call. Nonexistent function 'SpawnWanderer'` or `Invalid get index 'boss'`.

The usual culprits:

**Calling a renamed spawner function.** Same fix as Step 2's table, just in your own call instead of a hook name.

**Reading `ai.boss`.** That field is gone. Each AI now carries a `variant`, and the variant knows its faction and name:

```gdscript
# Before
if ai.boss:

# After
if ai.variant.faction == AIData.Faction.Boss:
# or, for one specific boss:
if ai.variant.name == "Punisher":
```

**Reading an old sound name**, like `audioLibrary.knifeSlash`. Use the rename table from Step 3.

**`extends Grenade`.** Build 2 removed the `Grenade` class name (the script still exists). Extend it by path instead:

```gdscript
# Before
extends Grenade

# After
extends "res://Scripts/Grenade.gd"
```

**Your own class is named `AIData`, `AimModifier` or `ImpulseModifier`.** Those are now names the game uses, so yours collides. Rename yours. And `AIWeaponData` is gone from the game, so any code that mentions it fails.

**You replaced all of `AI.gd` or `AISpawner.gd`** (with `[script_extend]`, `overrideScript`, or by shipping your own copy of the file). Your copy is the old version of the script, and Build 2 changed almost everything in it. The loader cannot fix that for you. You have two options: rewrite your copy against the new script, or, better, throw the copy away and use hooks for just the functions you change. Hooks keep working across game updates; a copied script never does.

## Step 5: Files that replace game files

Skip this if your mod archive contains only your own folder (`MyMod/...`) and a `mod.txt`.

If your archive contains files at game paths (anything under `Scenes/`, `Resources/`, `Scripts/`, `AI/`, `Traders/`, `Loot/` and so on), each one replaces the game's own file. That worked before. But if Build 2 changed that file, your mod is now quietly putting the old version back, and you get the old behaviour or a crash.

For each such file, ask: did Build 2 change this? Anything under `AI/`, `Traders/`, `Loot/`, the `AudioLibrary.tres` resource, and the new `Garage`, `Bridge` and `Airfield` scenes definitely changed. Rebuild your copy from the Build 2 version of the file, or, better, stop replacing the whole file and use the registry to change only the values you care about (`patch` for resources, `scene_nodes` for scenes). See [Registry](Registry).

## Step 6: Test it

1. Launch with only your mod, reach the main menu, quit, and check both logs again as in Step 1. You want no `will NEVER fire` in the dated file, and no `[Registry]` lines and no `SCRIPT ERROR` in `godot.log`. The dated file should also say `Hook reconciliation OK` if you use hooks.
2. Load a save and walk around Area 05 until an enemy shows up. Most AI code only runs once an enemy exists, so a clean menu is not enough for AI mods.
3. Launch once more with the other mods you normally play with.

## Step 7: Release it

- Bump `version` in your `mod.txt`.
- On your mod's Vostok Mods or ModWorkshop page, set the game version to Build 2, and say in the changelog whether the old build still works. Players on both builds read the same page.

## Reading the game's current scripts

You do not need a decompiler. After any launch, the loader saves a plain-text copy of every game script your mod hooks here:

```
%APPDATA%\Road to Vostok\modloader_hooks\vanilla\Scripts\
```

Open the script in a text editor and look at the lines starting with `func`. That is the current list of functions, with their parameters.

Need a script your mod does not hook? Add it to `mod.txt` for one launch:

```ini
[hooks]
res://Scripts/AISpawner.gd = "*"
```

Launch once, and the file appears in that folder. Then take the line out again before you release; a `*` hooks every function in the script and you do not want that shipping.

Some scripts never appear there, because the loader skips them before it reads their text: the data and save resource scripts (`AudioLibrary.gd`, `ItemData.gd`, `AIData.gd`, everything else ending in `Data.gd` or `Save.gd`) and a few timing-sensitive ones such as `MuzzleFlash.gd`. A `[hooks]` line on one of those is reported as lost. For sound names use the refusal message or the print snippet in Step 3; [Limitations](Limitations) lists the skipped scripts.

## What changed in Build 2, in one table

For when you want the summary rather than the steps.

| Area | Before Build 2 | Build 2 |
|---|---|---|
| AI type | each AI had a `boss` flag; the type came from the zone | each AI has a `variant` with a faction (`Nomad`, `Bandit`, `Guard`, `Military`, `Boss`) and a name (`Punisher`, `Bogeyman`, or the faction name) |
| Spawner | `SpawnWanderer`; enemies assigned with `agent = ...` | `SpawnEnemy` and `SpawnNomad`; enemies assigned with `enemy = ...`; separate nomad and boss pools; new `Debug` zone |
| Scripts removed | `AIWeaponData`, `Actions`, `CasettePlayer`, `DynamicAmbient` | |
| Scripts added | | `AIData`, `AimModifier`, `BoneFinder`, `Bus`, `Calendar`, `Camo`, `DebugLine`, `ImpulseModifier`, `NomadAnim`, `RagdollDebug`, `Sensor` |
| Class names | `Grenade` and `AIWeaponData` existed | both gone; `AIData`, `AimModifier`, `ImpulseModifier` added |
| Sounds | | most renamed or removed; airdrop, grenade and lure sounds moved into their own scripts |
| Traders | Generalist, Doctor, Gunsmith | plus Driver and Hunter |
| Loot tables | | plus `LT_Bogeyman_01` |
| Shelters and maps | | plus shelter `Garage`, maps `Bridge` and `Airfield` |
| Engine | Godot 4.6.2 | Godot 4.6.3 |

Stuck? [Open an issue](https://github.com/ametrocavich/vostok-mod-loader/issues) and paste the log lines and the code they point at.
