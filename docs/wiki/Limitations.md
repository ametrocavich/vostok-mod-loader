# Limitations

Godot quirks and design constraints the loader works around or can't work around. Most of these were discovered at cost during development -- each section cites the session or bug that surfaced it.

## Godot bug #83542 -- take_over_path on class_name scripts

**Symptom**: calling `take_over_path` on a script that declares `class_name` corrupts Godot's ScriptServer `class_cache`. The first override may work; the second override (or access through the displaced original) can crash or return wrong behavior. For `class_name WeaponRig`: observed as a crash on knife draw.

**Root cause**: `Resource::set_path` with `p_take_over=true` clears the old cached entry's `path_cache` but `global_name` (the `class_name` string) isn't cleared. ScriptServer ends up with the moved script's `class_name` colliding with the evicted original.

**Mitigations in the loader**:

- **Source-rewrite flow avoids it entirely** -- rewritten scripts ship at the original `res://Scripts/<Name>.gd` path, so there's no `take_over_path` on a class_name script. `class_name` stays intact because the rewritten script inherits the PCK's registration. This is the dominant path ([rewriter.gd:309-312](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L309)).
- **Legacy `_register_override`** ([framework_wrappers.gd:105](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/framework_wrappers.gd#L105)) guards against this explicitly: if the parent script has a `get_global_name()`, it skips `take_over_path` and falls back to `node_added` swapping. Dead code in practice (see [Modules](Modules)) but the guard is there.
- **Safety scanner** ([mod_loading.gd:409-414](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L409)) detects mods calling `take_over_path` on known class_name paths and logs `"DANGER: <file> calls take_over_path on class_name script <path> (<ClassName>) -- this will crash"` -- critical-level.

**Watch out**: mods that do `script.take_over_path(vanilla_path)` on a vanilla `class_name` script bypass the rewrite system and will re-trigger #83542 in certain configurations. The loader can't safely intercept every such call.

## Scripts deliberately not rewritten

Runtime-sensitive scripts in `RTV_SKIP_LIST` at [constants.gd:47-55](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L47). Dispatch wrappers break their runtime semantics:

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

Resource-serialized scripts at [constants.gd:59-64](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L59) (save data -- `CharacterSave`, `ContainerSave`, `FurnitureSave`, `ItemSave`, `Preferences`, `ShelterSave`, `SlotData`, `SwitchSave`, `TraderSave`, `Validator`, `WorldSave`) aren't rewritten -- `ResourceSaver` embeds the script path into user save files, and wrapping the script would make saves mod-dependent.

Data-resource scripts at [constants.gd:68-77](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L68) (25 entries: `AIWeaponData`, `AttachmentData`, `ItemData`, `LootTable`, `Recipes`, etc.) aren't rewritten -- they're loaded from `res://` only, have no call sites to intercept. Mods should hook the consumers instead.

## Scene-preload deferred compile

**Problem**: vanilla scripts with module-scope `preload("res://...tscn")` fire their preload chain at parse time. If that happens before mod autoloads run `overrideScript`, the scene bakes Script ext_resources to the pre-override vanilla script. When mods later `take_over_path`, the baked refs go empty-path -- subsequent `instantiate()` produces orphan-scripted nodes.

**Detection**: [pck_enumeration.gd:137 `_collect_module_scope_scene_preloads`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd#L137) scans for column-0 `preload("res://X.tscn|.scn")`. Scripts with such preloads are added to `_scripts_with_scene_preloads`.

**Workaround**: the activator ([hook_pack.gd:438](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L438)) skips eager compile for these scripts -- VFS mount precedence (`.gd` + `.gd.remap` + empty `.gdc`) still serves the rewrite when game code lazy-loads them AFTER mod overrides run.

**Exception**: registry targets (currently `Database.gd`) MUST force-activate so the injected `_rtv_mod_scenes` / `_rtv_override_scenes` / `_get()` are live on the autoload instance when mods call `lib.register`. Registry targets don't have the ext_resource staleness problem because mods don't `take_over_path` them -- they use the registry API instead.

See [hook_pack.gd:194-209](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L194).

## Direct const access bypasses `_get()`

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

Inline comment at [registry.gd:104-105](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd#L104): "Vanilla game code doing `Database.get(name)` hits the injected `_get()` and resolves through the mod dicts before falling back to vanilla constants."

## CRLF / LF mixing

GDScript rejects files mixing `\r\n` and `\n` line endings with a misleading `"Expected indented block after 'X' block"` error (the real issue is the inconsistent endings, not indentation).

ImmersiveXP ships CRLF-encoded source; the loader's appended wrappers use LF only. Before rewriting, [rewriter.gd:342-343](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L342) strips all CR:

```gdscript
var src = source.replace("\r\n", "\n").replace("\r", "\n")
```

## Tabs vs spaces

GDScript also rejects mixed tabs and spaces in one file. IXP uses 4-space indent, vanilla RTV uses tabs. The dispatch wrapper has to match the file's existing style.

[rewriter.gd:561 `_detect_indent_style`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L561) scans the first indented non-empty non-comment line and returns `"\t"` or `" ".repeat(n)`. Dispatch wrappers are generated with that indent.

## Bodyless blocks

Godot 4's parser rejects `if X:` with no indented body (a no-op the author got away with in Godot 3). Common in real-world RTV mods (e.g. AI Overhaul's `AwarenessSystem.gd`).

Autofix: [rewriter.gd:652-676](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L652) scans for block headers (`if`/`elif`/`else`/`for`/`while`/`match`/`func`/`class`/`static func`). If the next non-blank non-comment line isn't indented deeper, injects a `pass` at `header_indent + indent_unit`:

```gdscript
if some_condition:
	pass  # [Autofix] injected -- original block had no body
```

Also migrates `tool` -> `@tool`, `onready var` -> `@onready var`, `export var` -> `@export var`. Does NOT touch `export(Type) var` -- that needs type-annotation transform (left for a future pass).

## `super()` rewriting

When the rewriter renames `func CheckVersion():` to `func _rtv_vanilla_CheckVersion():` and the body contains bare `super()`, Godot's strict reload looks for `_rtv_vanilla_CheckVersion` on the parent -- which vanilla doesn't have. Result: reload failure.

[rewriter.gd:517 `_rewrite_bare_super`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L517) rewrites bare `super(` to `super.<orig_name>(` inside renamed bodies. `super.OtherMethod()` passes through untouched (already explicit).

## Windows backslash zip paths

`ZipFile.CreateFromDirectory()` on Windows writes entries with backslash separators. Godot mounts the pack but can't resolve the paths.

Detection at [mod_loading.gd:243-254](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L243):

```
BAD ZIP: <n> entries use Windows backslash paths.
  Re-pack with 7-Zip. Example bad entry: 'MyMod\Main.gd'
```

Not auto-fixed -- users re-pack with 7-Zip or similar.

## Mod-shadowed global_script_class_cache

If a mod ships its own `res://.godot/global_script_class_cache.cfg` (e.g. MCM does), mounting it shadows the game's version with a 1-entry cache. [pck_enumeration.gd:21-26](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd#L21) detects this via a `size() < 10` heuristic and falls back to the hardcoded 58-entry class map.

## Zero-byte PCK entries

Base game ships some `.gd` entries as zero bytes (e.g. `CasettePlayer.gd` in RTV 4.6.1). Detokenize returns empty silently for these paths -- recorded in `_pck_zero_byte_paths` during PCK enumeration ([pck_enumeration.gd:214-223](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd#L214)). Not a loader failure; these files can't be hooked regardless.

## `reload()` doesn't re-parse bytecode

For scripts originally compiled from `.gdc` bytecode (Camera, WeaponRig -- pre-compiled during engine startup because they're referenced by the initial scene graph), mutating `script.source_code` and calling `reload()` doesn't re-parse from the new source -- `reload()` re-reads bytecode instead.

Fallback at [hook_pack.gd:538-566](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L538): after `reload()`, verify the compiled method list has `_rtv_vanilla_*` entries. If not, `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` + `take_over_path(path)` -- `CACHE_MODE_IGNORE` goes through `_path_remap -> our .gd` with a fresh source compile.

## `load_resource_pack` dedupes by path

`ProjectSettings.load_resource_pack(same_path, true)` called twice in one session is a no-op the second time -- Godot dedupes by path. Used by the loader:

- [boot.gd:554-568](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L554): `modloader.gd` mtime is in the state hash, so rebuilding the loader forces a restart. Without this, the new hook pack would be written but the old mount would serve its stale file offsets.
- [lifecycle.gd:190-203](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd#L190): dev-mode test-pack re-apply copies the pack to a unique filename each time, because re-mounting the same path does nothing.

## Class_name collision

Mods that re-declare an existing game `class_name` at a different path trigger a fatal Godot error (`"Class X hides a global script class"`). Scanner at [mod_loading.gd:401-408](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L401) detects this and critical-logs:

```
CONFLICT: <mod_file> re-declares class_name <ClassName> (game has it at <path>)
```

Mod authors: don't use `class_name` names already defined in vanilla RTV. See the 58-entry hardcoded class map at [pck_enumeration.gd:33](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd#L33) for the conflict list.

## FileAccess vs ResourceLoader inconsistency

`FileAccess.file_exists()` can return false for `.gd` files inside mounted archives while `ResourceLoader.exists()` returns true for the same path. This is a Godot 4.6 quirk.

Loader consistently uses `ResourceLoader.exists` for resource existence checks and `FileAccess.get_file_as_string` / `FileAccess.get_file_as_bytes` for reading bytes (bypasses ResourceLoader's caching).

## autoload_prepend reverse-insertion

`[autoload_prepend]` with multiple entries: **LAST listed loads FIRST** (reverse insertion). Non-obvious; trips people reading the config for the first time.

The loader always puts `ModLoader="*res://modloader.gd"` last in `[autoload_prepend]` so it loads first. Mod early-autoloads listed above it load after. See [boot.gd:470-479](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L470) for the rationale.

## Heartbeat timing window

There's a narrow window where Pass 1 has written the heartbeat but the OS hasn't flushed to disk yet -- if the process force-quits in that window, the next launch won't see the heartbeat and won't know to recover. Unavoidable without `fsync` (which Godot doesn't expose via GDScript). Not worked around; rare enough in practice to not matter.

## Hook pack file handle invalidation

When a previous session's hook pack is mounted via `ProjectSettings.load_resource_pack`, Godot holds a `FileAccessZIP` handle to the file. `ZIPPacker.open` on the same path opens it for writing; on Windows, this invalidates the read handle once writes flush. VFS reads routing through the mount then fail at `file_access_zip.cpp:137` with "Cannot open file".

Workaround ([hook_pack.gd:30-38](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L30)): the regen path doesn't delete the old pack file first (deletion would invalidate the handle immediately) -- `ZIPPacker.open` replaces atomically on save. Also: mod sibling reads happen BEFORE `ZIPPacker.open` is called on the new pack.

## What's NOT supported

- Scripts that call `take_over_path` on themselves to replace a non-class_name vanilla script generally work, but `class_name` vanillas are risky even after the engine bug #83542 warnings.
- Hot-reload of mods without a full restart.
- `export(Type) var` -> `@export var X: Type` auto-migration (the autofix doesn't handle typed exports).
- Mods that add new `class_name` declarations that collide with vanilla.
- Calling `lib.hook` before `frameworks_ready` from a mod that isn't an autoload -- mod scene scripts can't register hooks until the tree is up.
