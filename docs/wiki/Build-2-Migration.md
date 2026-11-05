# Updating your mod for Build 2

Road to Vostok's Build 2 ("Nomads") rewrote the AI, renamed most sounds and
added and removed some scripts. Some mods keep working and some break; this page
finds out which yours is and fixes it, with the current Metro Mod Loader installed.

## Does this affect my mod?

A mod that only adds items, recipes, events or scenes, hooks player-side code
(the controller, camera, inventory, traders) or changes item stats with `patch`
is probably **fine**; trader registrations keep working, and `Driver` and
`Hunter` are new traders. A mod probably **needs work** if it:

- hooks anything in `AI.gd` or `AISpawner.gd`, or calls into them from its own code
- uses the `ai_loadouts`, `ai_types` or `sounds` registries
- replaces a whole game script, scene or resource file with its own copy

## Step 1: Launch once and look at the log

1. In the mod loader window, enable only your mod. Launch. The game restarts itself once (that is normal), then reaches the main menu. Quit.
2. Open `%APPDATA%\Road to Vostok\logs` (paste it into the Explorer address bar). On Linux it is the `logs` folder inside the game's user data folder.
3. A modded launch is two processes with a log each. The first builds the hooks and restarts the game; its log is the **newest dated file**. The second runs your mod's code; its log is `godot.log`. Open both.
4. Search each for these:

| Search for | In which log | What it means | Go to |
|---|---|---|---|
| `will NEVER fire` | the newest dated file | One of your hooks points at a game function that no longer exists. The line names it. | Step 2 |
| `[Registry]` | `godot.log` | One of your `lib.register` / `override` / `patch` calls was refused. The line says why. | Step 3 |
| `SCRIPT ERROR` | `godot.log` | Your own code tried to use something the game no longer has. | Step 4 |

None of the three? Your code is fine; check replaced files in Step 5, then test
in Step 6. Otherwise each line is one thing to fix.

## Step 2: A hook says `will NEVER fire`

A line such as `Hook on AISpawner.gd::spawnwanderer will NEVER fire: no such
method in vanilla. Check the spelling, or the game update renamed/removed it.`
means your hook waits for `SpawnWanderer`, which Build 2 renamed. Nothing
crashes; your code just never runs. The hook report further down repeats it as
`PARTIAL AISpawner.gd (declared by My Mod): wrapped, but missing: spawnwanderer`,
also when another mod's registry use makes the loader wrap the whole script.

Find the new name below (or in the last section of this page), change the hook
name in your code (`scriptname-functionname-pre` or `-post`, all lowercase, so
`aispawner-spawnwanderer-post` becomes `aispawner-spawnenemy-post`), and change
it in your `mod.txt` `[hooks]` section too if it is listed there.

| Old function | What to use now |
|---|---|
| `SpawnWanderer` | `SpawnEnemy`. Nomads are spawned separately by `SpawnNomad`. |
| `DestroyAllAI` | `Deactivate`. It removes every enemy and nomad, and also stops new ones spawning until the spawner restarts. |
| `ShowPoints`, `HidePoints`, `ShowGizmos`, `HideGizmos`, `ForceState`, `AIHide`, `AIShow` | Removed. There is one `Debug(toggle)` function now. |

Two functions changed their parameters, which a hook callback receives too:
`SpawnBoss(spawnPosition)` is now `SpawnBoss(boss, state, spawnPosition, currentPoint)`
and `CreateHotspot(location, relay)` is now `CreateHotspot(location)`.

## Step 3: A registry call was refused

A refusal reads like `[Registry] override('sounds', 'knifeSlash'): no vanilla
AudioLibrary field with that name (register can't be overridden; revert the
register first). Current names: ambientMenu, ambientWind, ...`; the text after
the colon says what went wrong.

**"unknown ai_type"** (from `ai_loadouts`). The categories are now `Nomad`,
`Bandit`, `Guard`, `Military`, `Boss`, `Punisher`, `Bogeyman`. `Bandit`,
`Guard`, `Military` and `Punisher` work as before; `Nomad` is the new
wanderers, `Boss` both bosses, `Bogeyman` the second boss. Add them, as in
`"ai_types": ["Bandit", "Nomad"]`, if those AI should get your weapon.

**"no vanilla AudioLibrary field with that name"** (from `sounds`). Most sounds
were renamed: `vostokEnter` is now `vostok`, `firemodeSemi` is `semi`,
`firemodeAuto` is `auto`, `footstepSnowSoft` is `footstepSnow`. Removed with no
replacement: `knifeDraw`, `knifeSlash`, `knifeStab`, `knifeHolster`, everything
starting with `grenade` or `rod`, and `doorMetal`, `doorWood`, `doorUnlock`. The
airdrop, grenade bounce and fishing lure sounds now live inside `CASA.gd`,
`Grenade.gd` and `Lure.gd`, out of the `sounds` registry's reach; hook the
script that plays them instead.

For any other sound the refusal is the list: everything after `Current names:`
exists now (`patch` and the array verbs say `no sound with that id. Current
names: ...`). If you only read `audioLibrary.<name>` in your own code, print the
list once with
`for p in load("res://Resources/AudioLibrary.tres").get_property_list(): print(p.name)`.

**"unknown table"** (from `loot`). The airdrop and Punisher tables are numbered:
`LT_Airdrop_01` to `_03`, `LT_Punisher_01` to `_03`, and the new
`LT_Bogeyman_01`. Plain `LT_Airdrop` and `LT_Punisher` are not tables.

**"unknown zone"** (from `ai_types`). Zones are `Area05`, `BorderZone`,
`Vostok` and the new `Debug`. An override replaces a zone's ordinary enemies
only; nomads and bosses come from their own pools and are not affected.

**"name already in shelters list"** or **"name collides with a vanilla scene
const"** (from `shelters`, `maps` or `scene_paths`). Build 2 added the shelter
`Garage` and the maps `Bridge` and `Airfield`; pick another name.

## Step 4: A `SCRIPT ERROR` in your own code

The line names the file and line, usually with something like `Invalid call.
Nonexistent function 'SpawnWanderer'` or `Invalid get index 'boss'`.

- **A renamed spawner function** or **an old sound name** (`audioLibrary.knifeSlash`). See Steps 2 and 3.
- **`ai.boss`.** The field is gone; each AI has a `variant` with a faction and a
  name: `if ai.variant.faction == AIData.Faction.Boss:`, or for one boss
  `if ai.variant.name == "Punisher":`.
- **`extends Grenade`.** The class name is gone (the script is not): write `extends "res://Scripts/Grenade.gd"`.
- **A class of yours named `AIData`, `AimModifier` or `ImpulseModifier`.** The game uses those names now; rename yours.
- **A removed script.** `AIWeaponData`, `Actions`, `CasettePlayer` and `DynamicAmbient` no longer exist.
- **A replacement of all of `AI.gd` or `AISpawner.gd`** (through
  `[script_extend]`, `overrideScript` or a shipped copy). Your copy is the old
  script and Build 2 changed almost all of it. Rewrite it against the new one
  or, better, drop it and hook only the functions you change: hooks survive game
  updates, a copied script does not.

## Step 5: Files that replace game files

Skip this if your archive holds only your own folder (`MyMod/...`) and `mod.txt`.

A file at a game path (`Scenes/`, `Resources/`, `Scripts/`, `AI/`, `Loot/`
and so on) replaces the game's own, so if Build 2 changed it your mod puts the
old version back. Everything under `AI/`, `Traders/` and `Loot/`,
`AudioLibrary.tres`, and the `Garage`, `Bridge` and `Airfield` scenes changed.
Rebuild your copy from the Build 2 file or, better, change only the values you
need through the [Registry](Registry) (`patch`, `scene_nodes`).

## Step 6: Test it

1. Launch with only your mod, reach the main menu, quit, and check both logs as in Step 1: no `will NEVER fire` in the dated file, no `[Registry]` and no `SCRIPT ERROR` in `godot.log`, and `Hook reconciliation OK` in the dated file if you use hooks.
2. Load a save and walk around Area 05 until an enemy shows up; most AI code runs only once an enemy exists.
3. Launch once more with the mods you normally play with.

## Step 7: Release it

Bump `version` in `mod.txt`. On your mod's Vostok Mods or ModWorkshop page, set
the game version to Build 2 and say whether the old build still works.

## Reading the game's current scripts

After any launch the loader keeps a plain-text copy of every game script a mod
hooks in `%APPDATA%\Road to Vostok\modloader_hooks\vanilla\Scripts\`; the `func`
lines are the current functions and parameters. For a script your mod does not
hook, add `res://Scripts/AISpawner.gd = "*"` (with that script's path) under
`[hooks]` in `mod.txt` for one launch, then remove it before release: `*` hooks
every function. Data and save scripts (names ending in `Data.gd` or `Save.gd`,
`AudioLibrary.gd`) and a few timing-sensitive ones never appear, and a `[hooks]`
line on one is reported as lost ([Limitations](Limitations)).

Stuck? [Open an issue](https://github.com/ametrocavich/vostok-mod-loader/issues) with the log lines and the code they point at.
