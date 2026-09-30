# In-game check for Road to Vostok Build 2

Two throwaway test mods that verify, in the real game, everything the loader
changed for Build 2 (Nomads): the AI loadout categories, the AISpawner
resolver, the new traders, loot table names, shelters, Database routing,
sounds, hooks from a second mod, and the report for a hook target the game
removed. Every check prints one `[B2TEST] PASS|FAIL` line to the game log
and `evaluate.py` grades the log. One launch to the main menu is enough; no
map has to load.

The mods never ship. They register content under `b2test_*` ids and remove
what they can before the menu; the rest lives only in memory.

## Run it (about three minutes)

```bash
bash tests/ingame/build2/install.sh
```

Launch Road to Vostok from Steam. The loader window opens on the `Build2Test`
profile with the two test mods enabled and nothing else; click **Launch**.
The game restarts once (pass 1 builds the hook pack), reaches the main menu,
and the tests have run. Quit from the menu, then:

```bash
python tests/ingame/build2/evaluate.py
```

`PASS` on every line and `0 failed` is the result. Any `FAIL` names the check
and quotes the log detail. Afterwards:

```bash
bash tests/ingame/build2/restore.sh
```

restores `mod_config.cfg` (your previous profile and selection) and removes
the zips.

## Runs with real mods

`loader_health.py` reports on ANY launch (no test mods needed): mods listed,
`[STABILITY]` lines, the hook reconciliation (LOST / PARTIAL lines verbatim),
script-override reports, every `[Critical]`, `[Warning]`, `SCRIPT ERROR` and
engine `ERROR` line. Select the profile with your real mods in the loader
window, launch to the menu (or into a map), quit, then:

```bash
python tests/ingame/build2/loader_health.py --minutes 10
```

Exit 1 means a `[Critical]`, a probe demotion, or a `SCRIPT ERROR` inside
`modloader.gd`; script errors inside a mod's own files are listed but are
the mod's to fix (a full-script override written for the previous build
fails on Build 2 whatever the loader does).

## Optional: in a map

With the test profile still active, load a save or start a new game into
Area 05, wait until you are in the world, then quit and run `evaluate.py`
again. The test profile overrides Area 05's enemy scene with the Guard
scene, so the grader's `MAP` section shows the spawner using `AI_Guard`,
`AI.SelectWeapon` firing on real AI instances (variant names and the
weapons each picked from), and, when a boss pooled, the injected Makarov.

## What each check covers

| Prefix | Check |
|---|---|
| R1-R2 | `ai_loadouts` accepts Build 2 categories (Boss, punisher) and refuses an unknown one |
| R3 | `ai_types` override on Area05, register on the new Debug zone, refuse an unknown zone |
| R4 | `trader_pools` on Driver and Hunter set and restore `ItemData.driver` / `.hunter` |
| R5 | `loot` resolves `LT_Bogeyman_01` and `LT_Airdrop_03`, refuses the old `LT_Airdrop` alias |
| R6-R8 | `shelters`, `scenes`, `sounds` (patch on a Build 2 field, refuse a pre-Build 2 name) |
| M1-M3 | the live AI.gd is the rewrite; `_rtv_ai_categories()` on real AIData variants; the registered loadout lands in `weapons` for a Boss only |
| M4 | the live AISpawner.gd assigns `enemy = _rtv_resolve_ai_type(zone, bandit)` and the resolver returns the registered scenes per zone |
| M5-M6 | Loader shelters plus the B_Loader shim; `Database.get()` routes a mod scene and still resolves vanilla |
| M7 | `modloader_hook_status.json` says `ok` |
| H0-H1 | a hook-only second mod's `menu-_ready-post` fires |
| log | `[STABILITY]` lines on Godot 4.6.3, VFS canary, all rewrites active, no demotion, no `[Critical]`, no `SCRIPT ERROR`, and the removed `SpawnWanderer` target reported as lost |
