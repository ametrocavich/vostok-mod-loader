# In-game check for the 3.5.0 LTS loader

Two throwaway test mods and a throwaway modpack. One launch to the main
menu checks, in the real game, what the 3.5.0 cleanup touched: the mod API,
dependency ordering, the registry verbs, the launcher window, profiles,
modpacks and the Vostok Mods download path. Every check prints one
`[LTSTEST] PASS|FAIL|INFO <ID> <title>: <detail>` line to the game log and
to a flushed progress file, and `evaluate.py` grades both. Nothing here is
tied to one game build: the grader reads the Godot version from `RTV.pck`,
and the mods touch no vanilla method except `Menu._ready` and only the data
the loader's own registry code already depends on.

After a game update, run `bash tests/ingame/rehearse_build.sh` first. It
proves the loader's rewrites still fit the new build without launching it.

## Run it (about five minutes)

```bash
bash tests/ingame/lts/install.sh
```

It copies `mod_config.cfg`, its `.bak`, `MCM/` and `.profile_snapshots/` from
the user data folder into `ltstest_backup/` beside them, and unloads an
applied modpack for the run.

Launch Road to Vostok from Steam. The loader window opens on the `LTSTest`
profile with the two test mods enabled and nothing else; click **Launch**.
The game restarts once and reaches the main menu. The tests then run by
themselves: the loader window opens, flips through its tabs, opens and
cancels a dialog, and closes again. Do not touch it. Wait about 30 seconds
after it closes (the network checks download one small mod), quit from the
menu, then:

```bash
python tests/ingame/lts/evaluate.py
```

`PASS` on every line and `0 failed` is the result. Afterwards, whatever the
result:

```bash
bash tests/ingame/lts/restore.sh
```

puts those four back exactly as they were, so your profile, your mod
settings and an applied modpack come back with them, then removes the three
zips, the progress files and `ltstest_backup/`. `install.sh` refuses to run
while the game is running, while `ltstest_backup/` holds an earlier run's
backup (run `restore.sh` first) or when you already have a profile named
`LTSTest` or `LTSTemp`; `restore.sh` with no backup does nothing. They take
`GAME` and `USERDATA` from the environment when the game is not in the
default Steam folder.

## What it proves

Boot phase, inside `LTSTestCore`'s autoload `_ready()`:

| ID | Check |
|---|---|
| D0 | `LTSTestDep`'s `_ready` ran (its own progress file) |
| L0 | `Engine.get_meta("RTVModLib")` is the loader, version `3.x` |
| D1 | the required dependency's autoload ran before its dependent's |
| D2 | `has_mod` with and without a minimum version, and for a mod that is not there |
| D3 | `mod_info` carries the documented keys; `loaded_mods` lists the dependency first |
| D4 | an id named under both `required` and `optional` stays required, and the dependency's optional back-edge is not reported as a cycle (the cycle half is graded from the log) |
| A1 | `active_profile()` is the profile the game booted with |
| G1 | recipes: register, patch, override the same handle, full revert: the patch goes back onto the original entry, the original is back in `Recipes.tres`, the override's entry is gone; `remove` then ends the handle |
| G2 | `trader_pools`: two handles on one item and trader keep the flag until the last one is removed |
| G3 | `resources`: two patches land on one Resource instance, and revert restores the original |
| G4 | `keys` / `has` / `list` on scenes and recipes, in the documented id shape |
| G5 | refused verbs return false; `register_many` and `remove_many` return the documented shapes |
| G6 | `setup()` runs a register/patch/revert/remove plan; a malformed step reports an error |
| H1 | the `menu-_ready-post` hook registers at boot and fires at the main menu |

Menu phase, from that hook (the launcher first, so nothing is pending when
it closes):

| ID | Check |
|---|---|
| U1 | `reopen_mod_ui()` opens the launcher with the Mods, Browse and Modpacks tabs |
| U2 | every tab renders when selected |
| U3 | the New profile dialog opens and Cancel frees it |
| U4 | rebuilding the Mods tab keeps it on screen |
| U5 | "Back to game" closes the launcher without a restart and the menu stays |
| P1 | creating a profile after boot records an MCM swap and does not change what loads |
| P2 | switching back to the booted profile cancels the swap |
| P3 | deleting the active profile removes its sections and snapshot slot and lands on another profile |
| K1 | applying `LTSTestPack.zip` downloads nothing, keeps the session's profile and records the pack and the swap for the restart |
| K2 | unloading it puts `LTSTest` back as the active profile |
| N0 | the Vostok Mods listing answers (offline or rate limited: `INFO N0 offline` and N1-N3 are skipped) |
| N1 | the mod detail of the smallest not-installed downloadable mod among the first few |
| N2 | that mod downloads into the mods folder and the Mods tab's Remove path deletes it again |
| N3 | its cover image loads |

`evaluate.py` adds the loader's own health lines from the log: the
detokenizer and VFS stability lines, every rewrite active, no probe
demotion, no `[Critical]`, no `SCRIPT ERROR`, the Mods button in the menu,
and the load order. `lts_core` has the lower priority, so priority order
alone would load it first: D1, D3 and the load order pass only because the
dependency hoist moved `lts_dep` up, and the grader also requires its
`Load order adjusted` line in the log.

The mods clean up after themselves even when a check fails: every `lts_*`
registration is reverted and removed before the menu, `LTSTemp` and the
pack never stay active, and the downloaded mod is deleted. `INFO CLEANUP`
lines say when a cleanup had something to do. The progress files are
`ltstest_core_progress.txt` and `ltstest_dep_progress.txt` in the user data
folder; the last line of the core one is `menu tests done`.

## What it does not prove

- Rendering: the window and dialogs are checked as nodes, not as pixels.
  Look at the launcher yourself when something seems off.
- Crash recovery and the restart loop breaker: the run never crashes on
  purpose.
- A real post-boot restart: the profile and pack checks record the MCM swap
  a restart would perform and then cancel it, so the restart itself and
  `_complete_pending_mcm_switch` do not run.
- Gameplay: no map loads, so hooks and registry entries are never seen by
  the game's own code in a level. The build2 kit's optional map section
  covers the AI side.
- Third-party mods: the kit only loads its own two mods. For a run with real
  mods use `python tests/ingame/build2/loader_health.py`.

## Reading a FAIL

Each `FAIL` line names the check and quotes what it saw; the detail lists
the intermediate results, so the step that went wrong is visible without the
log. "the check stopped before reporting" means a script error inside the
check: search the game log for the `SCRIPT ERROR` just before it. When the
game log is cut short (this machine's RTV.exe crashes on exit), the progress
files still hold every line, and the last `step <ID>` line in
`ltstest_core_progress.txt` names the check that was running.

If U5 fails with "_post_boot_restart_needed() is true", the launcher is left
open on purpose: closing it restarts the game. Quit the game instead.

If a run stopped during N2, the `N2 downloaded <path>` line in
`ltstest_core_progress.txt` names the mod file it fetched: delete it by hand
if it is still there; `restore.sh` does not know its name.

The core mod is `mods/LTSTestCore/LTSTestCore/Main.gd` (the boot, launcher,
profile and pack checks) on top of `Kit.gd` (output, cleanup and the network
checks). Both call loader internals by their `src/` names on the untyped
`RTVModLib` meta, so a rename there fails only in game: grep `tests/ingame`
before renaming.

`evaluate.py` grades the newest launch only: the newest log, plus the
rotated Pass 1 log before it when the newest is that launch's Pass 2
(Pass 1 logged `Preparing two-pass restart`). `Logs read:` names the files
it used. `--logs <file>` (repeatable) grades exactly those files, and
`--minutes N` reads every log changed in the last N minutes instead.
