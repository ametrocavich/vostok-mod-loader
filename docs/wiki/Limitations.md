# Limitations

Things the loader can't do, plus the engine quirks it works around.

## What this means for players

- **Keep a content mod enabled for any save you created with it.** If a save stops loading after you change your mod list, re-enable the mod you removed and try again -- the save itself is not corrupted. Details in the next section.
- **Changing mods requires restarting the game.** Mods can't be added, removed, or reloaded while the game is running.
- **Mods built with Godot 4.7 or newer won't load if they ship as a `.pck` file.** The loader rejects them with a warning that names the Godot version they were exported with. Ask the mod author for a `.zip` version or a Godot 4.6 build.
- **Some badly-packaged `.zip` mods are rejected** because they were zipped with Windows-style backslash paths inside. The loader logs this when it happens; the mod author needs to re-pack the zip (7-Zip packs it correctly).

## Disabling a content mod can break saves that use it

Mods that register game content -- items, recipes, loot, and similar -- add that content through the [registry](Registry) at launch. Mod-registered items live only in the registry's own table; they are **not** merged into the game's built-in master item list. The table is rebuilt from the enabled mods every launch.

That means: if you create a save while a content mod is enabled, then **disable or remove that mod**, loading the save (Continue) can fail or crash -- the content it refers to is no longer registered, so the game can't resolve it.

The save file itself is **not corrupted**. Re-enabling the mod brings the content back and the save loads fully again.

**Guidance**: keep a content mod enabled for any save that was created with it. If a save won't load after you change your mod list, re-enable the mod you removed and try again.

(Mechanism: `src/registry/items.gd` keeps mod items in the registry dict by `file` id and never adds them to vanilla's authoritative list, so a save that references a mod item has nothing to resolve against once the mod is gone.)

---

## For mod authors

Everything below is engine-level detail for people making mods. Most of it was discovered at cost during development -- each section cites the code or Godot bug that surfaced it.

### Mods exported with Godot 4.7+ (.pck pack format v4)

The loader reads `.pck` pack format v2 (Godot 4.0-4.5) and v3 (Godot 4.6) only. Godot 4.7+ exports pack format v4, which neither the loader nor the game's Godot 4.6 engine can read. Both the PCK enumerator and the security scanner reject v4 packs with a warning naming the exporting Godot version (see [`PACK_FORMAT_V4` in src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd)).

**Remedy**: re-export the `.pck` with Godot 4.6.x, or ship the mod as a `.zip` -- zip mods are unaffected by pack format versions.

### Godot bug #83542 -- take_over_path on class_name scripts

**Symptom**: calling `take_over_path` on a script that declares `class_name` corrupts Godot's ScriptServer `class_cache`. The first override may work; the second override (or access through the displaced original) can crash or return wrong behavior. For `class_name WeaponRig`: observed as a crash on knife draw.

**Root cause**: `Resource::set_path` with `p_take_over=true` clears the old cached entry's `path_cache` but `global_name` (the `class_name` string) isn't cleared. ScriptServer ends up with the moved script's `class_name` colliding with the evicted original.

**Mitigations in the loader**:

- **Source-rewrite flow avoids it entirely** -- rewritten scripts ship at the original `res://Scripts/<Name>.gd` path, so there's no `take_over_path` on a class_name script. `class_name` stays intact because the rewritten script inherits the PCK's registration. This is the dominant path.
- **Safety scanner** detects mods calling `take_over_path` on known class_name paths and logs `"DANGER: <file> calls take_over_path on class_name script <path> (<ClassName>) -- this will crash"` -- critical-level.

**Watch out**: mods that do `script.take_over_path(vanilla_path)` on a vanilla `class_name` script bypass the rewrite system and will re-trigger #83542 in certain configurations. The loader can't safely intercept every such call.

### Scripts deliberately not rewritten

Runtime-sensitive scripts in [`RTV_SKIP_LIST` in src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd). Dispatch wrappers break their runtime semantics:

| Script | Reason |
|---|---|
| `TreeRenderer.gd` | `@tool` script -- editor-only, no runtime hooks needed |
| `MuzzleFlash.gd` | 50ms flash effect -- dispatch overhead breaks timing |
| `Hit.gd` | Per-shot instantiated -- overhead compounds under fire |
| `ParticleInstance.gd` | GPUParticles3D -- `set_script` corrupts draw_passes array |
| `Message.gd` | await-based `_ready` -- dispatch wrapper doesn't await super, kills coroutine |
| `Mine.gd` | `queue_free` after detonation -- wrapper lifecycle breaks timing |
| `Explosion.gd` | await + @onready -- coroutine dies, particles don't emit |

Hooks on methods in these scripts won't fire. Mods should hook alternative call sites.

Resource-serialized scripts in [`RTV_RESOURCE_SERIALIZED_SKIP` in src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd) (save data -- `CharacterSave`, `ContainerSave`, `FurnitureSave`, `ItemSave`, `Preferences`, `ShelterSave`, `SlotData`, `SwitchSave`, `TraderSave`, `Validator`, `WorldSave`) aren't rewritten -- `ResourceSaver` embeds the script path into user save files, and wrapping the script would make saves mod-dependent.

Data-resource scripts in [`RTV_RESOURCE_DATA_SKIP` in src/constants.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd) (25 entries: `AIWeaponData`, `AttachmentData`, `ItemData`, `LootTable`, `Recipes`, etc.) aren't rewritten -- they're loaded from `res://` only, have no call sites to intercept. Mods should hook the consumers instead.

### Scene-preload deferred compile

**Problem**: vanilla scripts with module-scope `preload("res://...tscn")` fire their preload chain at parse time. If that happens before mod autoloads run `overrideScript`, the scene bakes Script ext_resources to the pre-override vanilla script. When mods later `take_over_path`, the baked refs go empty-path -- subsequent `instantiate()` produces orphan-scripted nodes.

**Detection**: [`_collect_module_scope_scene_preloads` in src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) scans for column-0 `preload("res://X.tscn|.scn")`. Scripts with such preloads are added to `_scripts_with_scene_preloads`.

**Workaround**: the activator in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) skips eager compile for these scripts -- VFS mount precedence (`.gd` + `.gd.remap` + empty `.gdc`) still serves the rewrite when game code lazy-loads them AFTER mod overrides run.

**Exception**: registry targets (currently `Database.gd`, see `REGISTRY_TARGETS` in src/hook_pack.gd) MUST force-activate so the injected `_rtv_mod_scenes` / `_rtv_override_scenes` / `_get()` are live on the autoload instance when mods call `lib.register`. Registry targets don't have the ext_resource staleness problem because mods don't `take_over_path` them -- they use the registry API instead.

### Direct const access bypasses `_get()`

The registry relies on Godot's `Node.get(name)` falling through to a script's `_get()` override when the name isn't a declared property. For `Database`:

```gdscript
# Rewriter converts these:
const Potato = preload("res://path/Potato.tscn")
# Into entries in _rtv_vanilla_scenes dict.

# These calls route through the injected _get() (mod overrides applied):
Database.get("Potato")
Database["Potato"]

# This one does NOT:
Database.Potato
```

Direct property-syntax access to a `const` is resolved at compile time and bypasses `_get()`. Mods must use `Database.get(name)` to pick up registry overrides.

Header comment in [src/registry/scenes.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/scenes.gd): "Vanilla game code doing `Database.get(name)` hits the injected `_get()` and resolves through the mod dicts before falling back to vanilla constants."

### CRLF / LF mixing

GDScript rejects files mixing `\r\n` and `\n` line endings with a misleading `"Expected indented block after 'X' block"` error (the real issue is the inconsistent endings, not indentation).

ImmersiveXP ships CRLF-encoded source; the loader's appended wrappers use LF only. Before rewriting, [src/rewriter.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd) strips all CR:

```gdscript
var src = source.replace("\r\n", "\n").replace("\r", "\n")
```

### Tabs vs spaces

GDScript also rejects mixed tabs and spaces in one file. ImmersiveXP uses 4-space indent, vanilla RTV uses tabs. The dispatch wrapper has to match the file's existing style.

[`_detect_indent_style` in src/rewriter.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd) scans the first indented non-empty non-comment line and returns `"\t"` or `" ".repeat(n)`. Dispatch wrappers are generated with that indent.

### Bodyless blocks

Godot 4's parser rejects `if X:` with no indented body (a no-op the author got away with in Godot 3). Common in real-world RTV mods (e.g. AI Overhaul's `AwarenessSystem.gd`).

Autofix: [`_rtv_autofix_legacy_syntax` in src/rewriter.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd) scans for block headers (`if`/`elif`/`else`/`for`/`while`/`match`/`func`/`class`/`static func`). If the next non-blank non-comment line isn't indented deeper, injects a `pass` at `header_indent + indent_unit`:

```gdscript
if some_condition:
	pass  # [Autofix] injected -- original block had no body
```

Also migrates `tool` -> `@tool`, `onready var` -> `@onready var`, `export var` -> `@export var`. Does NOT touch `export(Type) var` -- that needs type-annotation transform (left for a future pass).

### `super()` rewriting

When the rewriter renames `func CheckVersion():` to `func _rtv_vanilla_CheckVersion():` and the body contains bare `super()`, Godot's strict reload looks for `_rtv_vanilla_CheckVersion` on the parent -- which vanilla doesn't have. Result: reload failure.

[`_rewrite_bare_super` in src/rewriter.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd) rewrites bare `super(` to `super.<orig_name>(` inside renamed bodies. `super.OtherMethod()` passes through untouched (already explicit).

### Windows backslash zip paths

`ZipFile.CreateFromDirectory()` on Windows writes entries with backslash separators. Godot mounts the pack but can't resolve the paths.

Detection in [src/mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd):

```
BAD ZIP: <n> entries use Windows backslash paths.
  Re-pack with 7-Zip. Example bad entry: 'MyMod\Main.gd'
```

Not auto-fixed -- users re-pack with 7-Zip or similar.

### Mod-shadowed global_script_class_cache

If a mod ships its own `res://.godot/global_script_class_cache.cfg` (e.g. Mod Configuration Menu (MCM) does), mounting it shadows the game's version with a 1-entry cache. [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd) detects this via a `size() < 10` heuristic and falls back to the hardcoded 58-entry class map (`_get_hardcoded_class_map`).

### Zero-byte PCK entries

Base game ships some `.gd` entries as zero bytes (e.g. `CasettePlayer.gd` in RTV 4.6.1). Detokenize returns empty silently for these paths -- recorded in `_pck_zero_byte_paths` during PCK enumeration ([src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd)). Not a loader failure; these files can't be hooked regardless.

### `reload()` doesn't re-parse bytecode

For scripts originally compiled from `.gdc` bytecode (Camera, WeaponRig -- pre-compiled during engine startup because they're referenced by the initial scene graph), mutating `script.source_code` and calling `reload()` doesn't re-parse from the new source -- `reload()` re-reads bytecode instead.

Fallback in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd): after `reload()`, verify the compiled method list has `_rtv_vanilla_*` entries. If not, `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` + `take_over_path(path)` -- `CACHE_MODE_IGNORE` goes through `_path_remap -> our .gd` with a fresh source compile.

### `load_resource_pack` dedupes by path

`ProjectSettings.load_resource_pack(same_path, true)` called twice in one session is a no-op the second time -- Godot dedupes by path. How the loader sidesteps it:

- Hook packs never re-mount the same path: each `_generate_hook_pack` call writes a NEW uniquely-named zip (`framework_pack_<timestamp>.zip`, see [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)), so a fresh mount always gets fresh file offsets. Additionally, `modloader.gd`'s mtime is folded into the state hash (`_compute_state_hash` in [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd)), so rebuilding the loader itself forces a restart even when the mod set is unchanged.
- Dev-mode test-pack re-apply copies the pack to a unique `user://test_pack_reapply_*` filename each time ([src/lifecycle.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd)), because re-mounting the same path does nothing.

### Class_name collision

Mods that re-declare an existing game `class_name` at a different path trigger a fatal Godot error (`"Class X hides a global script class"`). The scanner in [src/mod_loading.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd) detects this and critical-logs:

```
CONFLICT: <mod_file> re-declares class_name <ClassName> (game has it at <path>)
```

Mod authors: don't use `class_name` names already defined in vanilla RTV. See the 58-entry hardcoded class map (`_get_hardcoded_class_map` in [src/pck_enumeration.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd)) for the conflict list.

### FileAccess vs ResourceLoader inconsistency

`FileAccess.file_exists()` can return false for `.gd` files inside mounted archives while `ResourceLoader.exists()` returns true for the same path. This is a Godot 4.6 quirk.

Loader consistently uses `ResourceLoader.exists` for resource existence checks and `FileAccess.get_file_as_string` / `FileAccess.get_file_as_bytes` for reading bytes (bypasses ResourceLoader's caching).

### autoload_prepend reverse-insertion

`[autoload_prepend]` with multiple entries: **LAST listed loads FIRST** (reverse insertion). Non-obvious; trips people reading the config for the first time.

The loader always puts `ModLoader="*res://modloader.gd"` last in `[autoload_prepend]` so it loads first. Mod early-autoloads listed above it load after. See the override.cfg writer in [src/boot.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd) for the rationale.

### Heartbeat timing window

There's a narrow window where Pass 1 has written the heartbeat but the OS hasn't flushed to disk yet -- if the process force-quits in that window, the next launch won't see the heartbeat and won't know to recover. Unavoidable without `fsync` (which Godot doesn't expose via GDScript). Not worked around; rare enough in practice to not matter.

### Hook pack file handle invalidation

When a previous session's hook pack is mounted via `ProjectSettings.load_resource_pack`, Godot holds a `FileAccessZIP` handle to the file. Deleting or rewriting that file on disk invalidates the handle; VFS reads routing through the mount then fail at `file_access_zip.cpp:137` with "Cannot open file".

Workaround (`_generate_hook_pack` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)): each generation writes a NEW uniquely-named zip (`framework_pack_<timestamp>.zip`), so the previously mounted pack file is never deleted or rewritten during the session. Stale pack files are swept at the next launch's static-init, before any mount.

### What's NOT supported

- `take_over_path` replacement of a `class_name` vanilla script -- unsupported (Godot bug #83542 can crash; the safety scanner flags it). Replacing non-class_name scripts via `take_over_path` works but is discouraged; prefer hooks or `[script_extend]`.
- Hot-reload of mods without a full restart.
- `export(Type) var` -> `@export var X: Type` auto-migration (the autofix doesn't handle typed exports).
- Mods that add new `class_name` declarations that collide with vanilla.
- Calling `lib.hook` before `frameworks_ready` from a mod that isn't an autoload -- mod scene scripts can't register hooks until the tree is up.
