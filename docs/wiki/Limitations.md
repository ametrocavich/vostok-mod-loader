# Limitations

What the loader cannot do, and the engine quirks it works around.

## What this means for players

- Keep a content mod enabled for any save you created with it. If a save stops loading after you change your mod list, re-enable the mod you removed and try again. The save itself is fine; the next section explains.
- Changing mods means restarting the game. Mods cannot be added, removed or reloaded while the game runs.
- After a game update, some mods may do nothing until the loader is updated. When the loader's changes to a game script no longer fit the new build, it leaves them out: the game runs normally, and the launcher names the scripts in a red banner on the next start.
- Mods built with Godot 4.7 or newer will not load when shipped as a `.pck`. The loader rejects them with a warning that names the Godot version they were exported with. Ask the author for a `.zip` or a Godot 4.6 build.
- Some `.zip` mods are rejected because they were zipped with Windows-style backslash paths inside. The loader logs `BAD ZIP` when it happens; the author needs to re-pack ([Mod-Format](Mod-Format) has the details).

## Disabling a content mod can break saves that use it

Mods that add game content (items, recipes, loot and so on) register it through the [registry](Registry) at launch. Mod items live only in the registry's own table, rebuilt from the enabled mods every launch; they are never merged into the game's built-in item list (`src/registry/items.gd`).

So a save created while a content mod was enabled can fail or crash on Continue once that mod is disabled or removed: the content it refers to is no longer registered. The save file is not corrupted. Re-enable the mod and it loads again.

## Modpacks

- A pack imported from Vostok Mods carries at most 32 mod settings files under `MCM/`, each at most 64 KiB, of type `.ini`, `.json` or `.cfg`. A pack over the count or the size is not imported, and the error says which limit it broke; an entry of another type or with an unsafe path is skipped and logged, and the rest imports. Apply holds every pack file to the count and size limits: files past them are left out and named in the log, and the rest applies.
- Packs come from Vostok Mods only. **Refresh** and the pack part of **Check for updates** reach only packs that came from there; a pack made by hand is never checked for changes.
- The details of a pack in Your packs name each mod by its key in the pack (the slug, for a pack from the site), because the pack file stores no mod names. The details of a pack on the site show the names.

## For mod authors

Each section names the code or the Godot bug behind it.

### Mods exported with Godot 4.7+ (.pck pack format v4)

The loader reads `.pck` pack format v2 (Godot 4.0-4.5) and v3 (Godot 4.6) only. Godot 4.7+ exports format v4, which neither the loader nor the game's Godot 4.6 engine can read. The PCK enumerator rejects v4 packs with a warning naming the exporting Godot version (`PACK_FORMAT_V4` in [src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)). Re-export with Godot 4.6.x, or ship a `.zip`, which has no pack format version.

### Godot bug #83542: take_over_path on class_name scripts

Calling `take_over_path` on a script that declares `class_name` corrupts Godot's ScriptServer `class_cache`: `Resource::set_path` with `p_take_over=true` clears the old entry's `path_cache` but not its `global_name`, so the moved script's `class_name` collides with the evicted original. The first override may work; the second, or access through the displaced original, can crash. For `class_name WeaponRig` it crashed on knife draw.

The hook rewrite avoids it: rewritten scripts ship at the original `res://Scripts/<Name>.gd`, so the `class_name` registration from the PCK still applies ([Hook-Pack](Hook-Pack)). A mod that calls `script.take_over_path(vanilla_path)` on a vanilla `class_name` script bypasses that and can hit the bug; the loader logs a critical `DANGER: <file> calls take_over_path on class_name script` when it finds such a call in a mod's source, but cannot intercept every one.

### Scripts deliberately not rewritten

Three lists in [src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd) keep scripts out of the hook pack, each list with its reason in a comment above it and `RTV_SKIP_LIST` with one beside every entry. `RTV_SKIP_LIST` holds runtime-sensitive scripts a dispatch wrapper breaks or that are not verified under one (`MuzzleFlash.gd`, `Hit.gd`, `ParticleInstance.gd`, `Message.gd`, `Explosion.gd` and others). `RTV_RESOURCE_SERIALIZED_SKIP` holds save-data classes (`CharacterSave`, `ItemSave`, `Preferences` and others): `ResourceSaver` embeds the script path in save files, so wrapping one would make saves depend on the mod. `RTV_RESOURCE_DATA_SKIP` holds data resources (`AIData`, `ItemData`, `LootTable` and others) that have no call sites to intercept.

Hooks on these scripts never fire, and a mod that declares one gets a warning naming it. Hook a caller or consumer instead.

### Scene-preload deferred compile

A vanilla script with a module-scope `preload("res://...tscn")` runs that preload chain when it compiles. Compiled before mod autoloads call `overrideScript`, the scenes bake their script references to pre-override vanilla; when the mod later calls `take_over_path`, those references go empty and `instantiate()` produces nodes with no script.

So the activator leaves such scripts to lazy compile. `_collect_module_scope_scene_preloads` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) finds column-0 scene preloads; the boot log lists the deferred scripts under `DEFER`. VFS precedence still serves the rewrite when game code loads them after the overrides have run, and a 60-second watchdog checks that it did ([Stability-Canaries](Stability-Canaries#defer-verify-watchdog)).

The registry targets (`Database.gd`, `Loader.gd`, `AI.gd`, `FishPool.gd`, `Compiler.gd`) are the exception and compile eagerly, so their injected fields are live when mods call `lib.register`. `AISpawner.gd` is a registry target that keeps the deferral (`filename == "AISpawner.gd"` in `_defers_scene_preloads`): its injected resolver reads Engine meta at call time, and compiling it eagerly would bake `res://Scripts/AI.gd` into its preloaded AI scenes before any mod could override `AI.gd`.

The eager targets can still bake a scene early: `AI.gd` and `Loader.gd` preload a few scenes and `Database.gd` hundreds, so `overrideScript` on a script one of those scenes carries can meet the same orphaning. The supported route there is the registry, not `take_over_path`.

### A game update can outdate the registry code

The code injected into the registry targets names vanilla members (`weapons` and `variant` in `AI.gd`, or `boss` and `AISpawner` in its older field shape; `Zone` and the `enemy =` assignments in `AISpawner.gd`; `shelters` and the `LoadScene` locals in `Loader.gd`; `species` in `FishPool.gd`; `spawnTarget` in `Compiler.gd`). A game update that renames one leaves a rewrite that does not compile, and since the pack serves its `.gd` over the game's bytecode, shipping it would break the vanilla script itself.

Every rewrite is therefore probe-compiled before packing. A failure ships the script with hooks only, its registries inert and their verbs returning `false`, or leaves it vanilla when no rewritten form compiles. The game is unaffected; the fix is a loader update. [Stability-Canaries](Stability-Canaries#pre-ship-compile-probe) has the details. A transform that merely finds no anchor still compiles; the marker check reports it `PARTIAL` in the reconciliation report.

### Direct const access bypasses `_get()`

The registry relies on `Node.get(name)` falling through to a script's `_get()` when the name is not a declared property. The rewriter turns `Database.gd`'s `const Potato = preload(...)` lines into entries in a dictionary that `_get()` serves:

```gdscript
Database.get("Potato")   # registry overrides applied
Database["Potato"]       # registry overrides applied
Database.Potato          # resolved at compile time: vanilla only
```

Use `Database.get(name)`. The comment above `_database_consts_to_dict` in [src/rewriter_registry_inject.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_registry_inject.gd) says the same.

### Mod-shadowed class cache

A mod that ships its own `res://.godot/global_script_class_cache.cfg` (Mod Configuration Menu does) shadows the game's cache once mounted. `_build_class_name_lookup` in [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) treats fewer than 10 entries as shadowing, logs `Class cache has only N entries` at every launch and falls back to the 59-entry `_get_hardcoded_class_map`, a snapshot of the game's own list. The mod works.

### Class_name collision

A mod that re-declares a game `class_name` at a different path triggers a fatal Godot error (`Class X hides a global script class`). `_check_class_name_safety` in [src/mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) logs a critical `CONFLICT: <mod_file> re-declares class_name <ClassName>` first. Do not reuse a `class_name` the game defines; `_get_hardcoded_class_map` is the list.

### FileAccess vs ResourceLoader

In Godot 4.6, `FileAccess.file_exists()` can return false for a `.gd` inside a mounted archive while `ResourceLoader.exists()` returns true for the same path. The loader uses `ResourceLoader.exists` for existence and `FileAccess.get_file_as_string` / `get_file_as_bytes` to read bytes, which bypasses ResourceLoader's cache.

### autoload_prepend reverse insertion

With several entries in `[autoload_prepend]`, the last one listed loads first. The loader writes `ModLoader="*res://modloader.gd"` last so it loads before the mod early autoloads listed above it (`_write_override_cfg` in [src/pass_state.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pass_state.gd)).

### Smaller limits

Each of these is cosmetic or has a cheap workaround.

- **Check for updates asks one site**, the one a mod was installed from. [Mods](Mods#updates) says what that means for a mod that moved sites: reinstall it from Vostok Mods.
- **A post hook that awaits cannot change the result.** [Hooks](Hooks#post-hooks-and-result-mutation) explains why and what to do instead.
- **A mod download has a five-minute limit for the whole transfer.** A very large archive on a slow connection fails with the connection-error message; download it from the mod's page and put it in `mods/` by hand.
- **A mod with no `id=` in `mod.txt` is keyed by file name.** An update moves its profile settings to the new file name; a file you rename by hand keeps them only when just the extension or a trailing version changed ([Profile-Format](Profile-Format#profile-key-format)).
- **A `!` early autoload that writes its settings file on exit** may write the outgoing profile's values once after a profile switch made from the main menu: the swap happens at the restart, but the previous game's early autoloads are still up when it quits.
- **A force quit right after the Pass 1 heartbeat is written** can leave the next launch without it, since Godot does not expose `fsync` to GDScript. Crash recovery then does not trigger for that one launch.

### What is not supported

- Replacing a `class_name` vanilla script with `take_over_path` (bug #83542 above). Replacing a script without `class_name` this way works but is discouraged; prefer hooks or `[script_extend]`.
- A `[script_extend]` or `[script_overrides]` replacement of a hooked script that is activated up front: the rewrite wins ([Hooks](Hooks#composing-with-script_extend)).
- Hot reload of mods without a full restart.
- Migrating `export(Type) var` to `@export var X: Type`.
- New `class_name` declarations that collide with vanilla.
- Calling `lib.hook` before `frameworks_ready` from a script that is not an autoload. Scene scripts cannot register hooks until the tree is up.
