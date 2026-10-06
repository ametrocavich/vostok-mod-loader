# Limitations

What the loader cannot do, and the engine quirks it works around.

## What this means for players

- Keep a content mod enabled for any save you created with it. If a save stops loading after you change your mod list, re-enable the mod you removed and try again. The save itself is fine. Details in the next section.
- Changing mods means restarting the game. Mods cannot be added, removed or reloaded while the game runs.
- After a game update, some mods may do nothing until the loader is updated. When the loader's changes to a game script no longer fit the new build, it leaves them out: the game runs normally, and the launcher names the scripts in a red banner on the next start.
- Mods built with Godot 4.7 or newer will not load when shipped as a `.pck`. The loader rejects them with a warning that names the Godot version they were exported with. Ask the author for a `.zip` or a Godot 4.6 build.
- Some `.zip` mods are rejected because they were zipped with Windows-style backslash paths inside. The loader logs this when it happens; the author needs to re-pack (7-Zip does it correctly).

## Disabling a content mod can break saves that use it

Mods that register game content (items, recipes, loot, and so on) add it through the [registry](Registry) at launch. Mod-registered items live only in the registry's own table; they are not merged into the game's built-in item list, and the table is rebuilt from the enabled mods every launch.

So if you create a save while a content mod is enabled and then disable or remove that mod, loading the save (Continue) can fail or crash. The content it refers to is no longer registered and the game cannot resolve it.

The save file is not corrupted. Re-enable the mod and it loads again.

Mechanism: `src/registry/items.gd` keeps mod items in the registry dict by `file` id and never adds them to vanilla's authoritative list, so a save that references a mod item has nothing to resolve against once the mod is gone.

## For mod authors

Engine-level detail for people making mods. Most of it cost a session to find; each section names the code or the Godot bug behind it.

### Mods exported with Godot 4.7+ (.pck pack format v4)

The loader reads `.pck` pack format v2 (Godot 4.0-4.5) and v3 (Godot 4.6) only. Godot 4.7+ exports format v4, which neither the loader nor the game's Godot 4.6 engine can read. Both the PCK enumerator and the security scanner reject v4 packs with a warning naming the exporting Godot version (`PACK_FORMAT_V4` in [src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)).

Remedy: re-export with Godot 4.6.x, or ship the mod as a `.zip`. Zip mods do not care about pack format versions.

### Godot bug #83542: take_over_path on class_name scripts

Symptom: calling `take_over_path` on a script that declares `class_name` corrupts Godot's ScriptServer `class_cache`. The first override may work; the second, or access through the displaced original, can crash or misbehave. For `class_name WeaponRig` it showed up as a crash on knife draw.

Root cause: `Resource::set_path` with `p_take_over=true` clears the old entry's `path_cache` but not its `global_name`, so the moved script's `class_name` collides with the evicted original.

What the loader does about it:

- The source-rewrite flow avoids it. Rewritten scripts ship at the original `res://Scripts/<Name>.gd`, so there is no `take_over_path` on a class_name script and the `class_name` registration from the PCK still applies. This is the path nearly everything takes.
- The safety scanner logs a critical `DANGER: <file> calls take_over_path on class_name script <path> (<ClassName>) -- this will crash` for mods that do it anyway.

A mod that runs `script.take_over_path(vanilla_path)` on a vanilla `class_name` script bypasses the rewrite system and will hit #83542 in some configurations. The loader cannot intercept every such call.

### A replacement script loses to a hook rewrite at the same path

If a mod replaces a vanilla script through `[script_extend]` or `[script_overrides]` and that same path is in the hook wrap surface (some mod declared `[hooks]` on it, calls `.hook()` on it, or it is a registry target with `[registry]` declared), the rewrite wins when the loader activates that script up front. Activation reloads the vanilla path with the rewritten source, so the replacement's code never runs that session. A script deferred to lazy compile (one with a module-scope scene preload, such as `Interface.gd`; the boot log lists them under `DEFER`) is not reloaded: it compiles after the overrides, the replacement extends the rewrite, and both run.

The loader says so twice, naming the mod: once during generation (`[RTVCodegen] <path> is rewritten for hooks and also replaced by <mod> -- the rewrite wins at that path ...`) and again at activation (`[RTVCodegen] activate <path>: replacing the script installed by <mod> with the rewritten vanilla script ...`). Both are warnings in `hook_pack.gd`.

Remedy: hook the methods instead (`[hooks]` or `.hook()`), or drop the replacement. There is no merge.

### Scripts deliberately not rewritten

Runtime-sensitive scripts in `RTV_SKIP_LIST` ([src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)). A dispatch wrapper breaks them:

| Script | Reason |
|---|---|
| `TreeRenderer.gd` | `@tool` script, editor-only, no runtime hooks needed |
| `MuzzleFlash.gd` | 50ms flash effect; dispatch overhead breaks the timing |
| `Hit.gd` | Instantiated per shot; overhead compounds under fire |
| `ParticleInstance.gd` | GPUParticles3D; `set_script` corrupts the draw_passes array |
| `Message.gd` | await-based `_ready`. The wrapper awaits a coroutine body, but this script has not been verified in game under it, so it stays off the wrap surface |
| `Mine.gd` | `queue_free` after detonation; wrapper lifecycle breaks the timing |
| `Explosion.gd` | await plus @onready; same as `Message.gd`, not verified under the coroutine-aware wrapper |

Hooks on these scripts never fire. A mod that declares one gets a warning naming it at generation time. Hook another call site.

Resource-serialized scripts in `RTV_RESOURCE_SERIALIZED_SKIP` (save data: `CharacterSave`, `ContainerSave`, `FurnitureSave`, `ItemSave`, `Preferences`, `ShelterSave`, `SlotData`, `SwitchSave`, `TraderSave`, `Validator`, `WorldSave`) are not rewritten either. `ResourceSaver` embeds the script path in user save files; wrapping the script would make saves depend on the mod.

Data-resource scripts in `RTV_RESOURCE_DATA_SKIP` (25 entries: `AIData`, `AttachmentData`, `ItemData`, `LootTable`, `Recipes`, ...) are loaded from `res://` only and have no call sites to intercept. Hook the consumers.

### Scene-preload deferred compile

Problem: a vanilla script with a module-scope `preload("res://...tscn")` fires that preload chain at parse time. If it happens before mod autoloads run `overrideScript`, the scene bakes its Script ext_resources to the pre-override vanilla script. When the mod later calls `take_over_path`, the baked references go empty-path and `instantiate()` produces nodes with no script.

Detection: `_collect_module_scope_scene_preloads` in [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) scans for column-0 `preload("res://X.tscn|.scn")`. Matching scripts go into `_scripts_with_scene_preloads`.

Workaround: the activator in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) skips eager compile for these scripts. VFS precedence (`.gd` plus `.gd.remap` plus empty `.gdc`) still serves the rewrite when game code lazy-loads them after mod overrides have run. A 60-second watchdog checks that it did ([Stability-Canaries](Stability-Canaries#defer-verify-watchdog)).

Exception: the six `REGISTRY_TARGETS` (`Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd`, `Compiler.gd`) are activated eagerly, so the injected `_rtv_mod_scenes` / `_rtv_override_scenes` / `_get()` and the other preludes are live on the autoload instances when mods call `lib.register`. `AISpawner.gd` is the one registry target that keeps the deferral (`REGISTRY_TARGETS_DEFERRABLE`, decided by `_defers_scene_preloads`): its injected resolver reads Engine meta at call time, so nothing needs the script live, and its module-scope preloads are the AI scenes (six on Build 2) and an audio instance scene. Compiled eagerly, it baked `res://Scripts/AI.gd` into those scenes before any mod autoload ran, so a mod's `overrideScript` of `AI.gd` was orphaned whenever `AISpawner.gd` was in the wrap surface, which is any mod set that declares `[registry]` or hooks `AISpawner.gd`. That held from 3.0.0 until 3.4.0.

The remaining eager targets can still bake a scene early. `AI.gd` and `Loader.gd` preload a few scenes and `Database.gd` preloads hundreds, so a mod that calls `overrideScript` on a script one of those scenes carries can meet the same orphaning. The supported route for those is the registry, not `take_over_path`.

### A game update can outdate the registry code

Problem: the code injected into the registry targets names vanilla members (`weapons` and `variant` in `AI.gd`, or `weapons`, `boss` and `AISpawner` on a game before Build 2, chosen from the source; `Zone` and the `enemy =` assignments in `AISpawner.gd`; `shelters` and the `LoadScene` locals in `Loader.gd`, `species` in `FishPool.gd`, `spawnTarget` in `Compiler.gd`). A game update that renames one leaves a rewrite that does not compile. The pack serves its `.gd` over the game's bytecode, so until 3.4.0 that broke the vanilla script itself.

Detection: every rewrite is probe-compiled before it is packed (`_hook_pack_vet_rewrite` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)).

Result: the failure is now confined to the loader's side. The script ships with hooks only and the registries that depend on it are inert, or, when no rewritten form compiles, the script runs vanilla and hooks on it do not fire. The game itself is unaffected. One `[STABILITY]` critical per script, a `demoted` record for the launcher banner, and `false` from the affected registry verbs. The fix is a loader update. See [Stability-Canaries](Stability-Canaries#pre-ship-compile-probe).

A transform that merely finds no anchor (the pattern moved, nothing renamed) still compiles; that case is caught by the registry marker check and reported `PARTIAL` by reconciliation. Build 2 did both at once: `AI.gd` lost `boss` (a compile failure, so `AI.gd` shipped wrap-only under 3.4.0) and `AISpawner.gd` renamed `agent =` to `enemy =` (a missing anchor, so `ai_types` was inert, with only a log critical and a `PARTIAL` reconciliation line to show for it). 3.4.1 handles both shapes.

### Direct const access bypasses `_get()`

The registry relies on `Node.get(name)` falling through to a script's `_get()` when the name is not a declared property. For `Database`:

```gdscript
# The rewriter turns these:
const Potato = preload("res://path/Potato.tscn")
# into entries in the _rtv_vanilla_scenes dict.

# These calls route through the injected _get() (mod overrides applied):
Database.get("Potato")
Database["Potato"]

# This one does not:
Database.Potato
```

Property-syntax access to a `const` resolves at compile time. Use `Database.get(name)` to see registry overrides. The header of [src/registry/scenes.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/scenes.gd) says the same thing.

### CRLF / LF mixing

Godot 4.6 compiles CRLF source, and source that mixes `\r\n` and `\n`, without help. Mod scripts are never touched: they run from the mod's own archive exactly as shipped, CRLF included.

The loader normalizes one thing, the vanilla source it rewrites. The wrappers it appends are LF, so `_rtv_rewrite_vanilla_source` in [src/rewriter_rewrite.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_rewrite.gd) first runs

```gdscript
source.replace("\r\n", "\n").replace("\r", "\n")
```

so the emitted file has one line ending throughout.

### Tabs vs spaces

GDScript rejects tabs and spaces mixed in one file's indentation. Vanilla RTV uses tabs, but the generated wrapper has to match whatever the file it lands in uses.

`_detect_indent_style` in [src/rewriter_rewrite.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter_rewrite.gd) reads the first indented, non-empty, non-comment line of the vanilla source and returns `"\t"` or `" ".repeat(n)`. The wrappers use that unit.

### `super()` rewriting

When the rewriter renames `func CheckVersion():` to `func _rtv_vanilla_CheckVersion():` and the body contains a bare `super()`, Godot's reload looks for `_rtv_vanilla_CheckVersion` on the parent, which does not exist, and the reload fails.

`_rewrite_bare_super` in rewriter_rewrite.gd rewrites bare `super(` to `super.<orig_name>(` inside renamed bodies. An explicit `super.OtherMethod()` passes through untouched.

### Windows backslash zip paths

`ZipFile.CreateFromDirectory()` on Windows writes entries with backslash separators. Godot mounts the pack but cannot resolve the paths.

Detection in `scan_and_register_archive_claims` ([src/mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd)):

```
BAD ZIP: <n> entries use Windows backslash paths.
  Re-pack with 7-Zip. Example bad entry: 'MyMod\Main.gd'
```

Not auto-fixed. Re-pack with 7-Zip or similar.

### Mod-shadowed global_script_class_cache

If a mod ships its own `res://.godot/global_script_class_cache.cfg` (Mod Configuration Menu does), mounting it shadows the game's cache with a one-entry version. `_build_class_name_lookup` in [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) treats fewer than 10 entries as shadowing and falls back to the 59-entry `_get_hardcoded_class_map` (a Build 2 snapshot).

### Zero-byte PCK entries

Some game builds ship a `.gd` entry as zero bytes (`CasettePlayer.gd` before Build 2; Build 2 has none). PCK enumeration records them in `_pck_zero_byte_paths` and the detokenizer returns empty for them without logging. Not a loader failure; these files cannot be hooked, and a `[hooks]` declaration on one is reported as lost by the reconciliation.

### `reload()` does not re-parse bytecode

For scripts originally compiled from `.gdc` (Camera, WeaponRig: pre-compiled at engine startup because the initial scene graph references them), setting `script.source_code` and calling `reload()` does not re-parse the new source. `reload()` re-reads the bytecode.

Fallback in `_activate_rewritten_scripts` ([src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)): after `reload()`, check the compiled method list for `_rtv_vanilla_*`. If missing, `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` plus `take_over_path(path)`; `CACHE_MODE_IGNORE` goes through `_path_remap` to our `.gd` and compiles from source.

### `load_resource_pack` dedupes by path

`ProjectSettings.load_resource_pack(same_path, true)` called twice in one session is a no-op the second time. How the loader sidesteps it:

- Each `_generate_hook_pack` call writes a new uniquely named zip, `framework_pack_<ticks>.zip`, so a fresh mount always has fresh file offsets. `modloader.gd`'s own mtime is also folded into the state hash (`_compute_state_hash`, [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)), so rebuilding the loader forces a restart even with the mod set unchanged.

### Class_name collision

A mod that re-declares an existing game `class_name` at a different path triggers a fatal Godot error (`Class X hides a global script class`). `_check_class_name_safety` in [src/mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) detects it and logs a critical:

```
CONFLICT: <mod_file> re-declares class_name <ClassName> (game has it at <path>)
```

Do not reuse a `class_name` vanilla RTV defines. The 59-entry `_get_hardcoded_class_map` in [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) is the list.

### FileAccess vs ResourceLoader inconsistency

`FileAccess.file_exists()` can return false for a `.gd` inside a mounted archive while `ResourceLoader.exists()` returns true for the same path. Godot 4.6 quirk.

The loader uses `ResourceLoader.exists` for resource existence and `FileAccess.get_file_as_string` / `get_file_as_bytes` for reading bytes, which bypasses ResourceLoader's cache.

### autoload_prepend reverse insertion

With several entries in `[autoload_prepend]`, the last one listed loads first. It trips everyone the first time.

The loader always writes `ModLoader="*res://modloader.gd"` last in `[autoload_prepend]` so it loads first; mod early autoloads listed above it load after. The reasoning is in `_write_override_cfg` ([src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)).

### Heartbeat timing window

There is a small window where Pass 1 has written the heartbeat but the OS has not flushed it to disk. A force quit in that window leaves the next launch with no heartbeat and no idea it should recover. Unavoidable without `fsync`, which Godot does not expose to GDScript. Left alone; it is rare.

### Hook pack file handle invalidation

While a previous session's hook pack is mounted, Godot holds a `FileAccessZIP` handle to it. Deleting or rewriting that file invalidates the handle, and VFS reads through the mount then fail at `file_access_zip.cpp:137` with "Cannot open file".

Workaround in `_generate_hook_pack`: each generation writes a new uniquely named zip, so the mounted pack is never deleted or rewritten during the session. Stale packs are swept at the next launch's static init, before any mount.

### What is not supported

- Replacing a `class_name` vanilla script with `take_over_path`: Godot bug #83542 can crash, and the safety scanner flags it. Replacing a script without `class_name` this way works but is discouraged; prefer hooks or `[script_extend]`.
- A `[script_extend]` / `[script_overrides]` replacement on a path in the hook wrap surface that is activated up front: the rewrite wins, see above.
- Hot reload of mods without a full restart.
- `export(Type) var` to `@export var X: Type` migration.
- New `class_name` declarations that collide with vanilla.
- Calling `lib.hook` before `frameworks_ready` from a mod that is not an autoload. Scene scripts cannot register hooks until the tree is up.
