# Mod Format

A mod is a zip archive (`.vmz` or `.pck`, plus unpacked folders in developer mode). The archive contents mirror the game's `res://` tree -- a file at `MyMod/foo.gd` inside the zip ends up at `res://MyMod/foo.gd` after mounting.

## Archive types

| Extension | Mount mechanism | mod.txt | Autoloads | Update checking |
|---|---|---|---|---|
| `.vmz` | Copied to `user://vmz_mount_cache/<name>.zip` then `ProjectSettings.load_resource_pack` | Yes | Yes | Yes |
| `.pck` | `ProjectSettings.load_resource_pack` directly | No | No | No |
| folder | Zipped to `user://vmz_mount_cache/<name>_dev.zip` then mounted. **Developer mode only** | Yes | Yes | Yes |
| `.zip` | **Rejected.** UI forces the checkbox off and warns "Rename this file from .zip to .vmz to use it" | | | |

`.vmz` is the community convention -- Godot's ZIPReader won't open files with `.vmz` extension directly, so the loader copies them to `<name>.zip` in the cache dir first (see [fs_archive.gd:9 `_static_vmz_to_zip`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd#L9)). Re-extraction triggers when the source `.vmz` mtime is newer than the cache.

## mod.txt

A ConfigFile-format file at the root of the archive. All string values must be quoted (ConfigFile requires it).

```ini
[mod]
name="My Mod"
id="my_mod"
version="1.0.0"
priority=0

[autoload]
MyModMain="res://MyMod/Main.gd"
EarlyNode="!res://MyMod/Early.gd"

[updates]
modworkshop=12345

[hooks]
res://Scripts/Interface.gd = _ready, update_tooltip

[script_extend]
res://Scripts/Camera.gd = res://MyMod/MyCamera.gd

[registry]
; empty section is enough -- presence enables the registry API
```

Only `[mod]` is required. `[autoload]`, `[updates]`, `[hooks]`, `[script_extend]`, `[registry]` are all optional; use the ones your mod needs.

### `[mod]` section

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | filename | Display name in the UI |
| `id` | string | filename | Unique id. Duplicates after the first loaded mod are skipped |
| `version` | string | `""` | Used by the Updates tab to compare against ModWorkshop |
| `priority` | int | 0 (or parsed from filename prefix) | Higher loads later, wins file conflicts. Clamped to `-999..999` |

**VostokMods compat**: if the archive filename matches `^(-?\d+)-(.*)`, the numeric prefix is used as a fallback priority when `[mod] priority` isn't set. Example: `100-BetterAI.vmz` loads with `priority=100`. See [mod_discovery.gd:119-131](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L119).

### `[autoload]` section

```
<autoload_name>="<path>"
```

Same shape as Godot's project-settings autoloads. Keys become node names in `/root/<name>`, values point to a `.gd` script or `.tscn` scene. Values may have a `*` prefix (deprecated Godot-3 syntax, stripped).

**The `!` prefix** -- value starting with `!` marks the autoload as **early**:

```ini
[autoload]
LateNode="res://MyMod/Late.gd"
EarlyNode="!res://MyMod/Early.gd"
```

Early autoloads go into `override.cfg`'s `[autoload_prepend]` section, which means Godot loads them BEFORE the game's own autoloads. Late autoloads are instantiated by the loader after mounts land. The loader always puts itself (`ModLoader="*res://modloader.gd"`) last in `[autoload_prepend]`, and reverse-insertion order means it loads first.

Early-autoload `.gd` scripts that only exist inside a mounted archive are extracted to `user://modloader_early/<path>` so Godot can find them before the restart completes its static-init mount. Scenes (`.tscn`) resolve via the file-scope mount directly. See [boot.gd:410 `_ensure_early_autoload_on_disk`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd#L410).

Duplicate autoload names are logged and skipped (first wins). Paths not present in the archive's file set are logged as `"  Autoload path not found in archive"` with similar-path suggestions to help debug case/typo mistakes.

### `[updates]` section

| Key | Type | Meaning |
|---|---|---|
| `modworkshop` | int | ModWorkshop mod id. Enables the Updates tab for this mod |

Version compare uses [mod_discovery.gd:195 `compare_versions`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L195) -- splits on `.`, strips `v`/`V` prefix, pads shorter side with `"0"`, lexicographic int comparison.

### `[hooks]` section

Enrolls specific vanilla methods (or whole scripts) in the rewrite surface so your hook callbacks can fire. **Most mods don't need this** -- if your mod calls `.hook("stem-method-variant", cb)` directly in its own source, the scanner picks the call up and enrolls the method automatically. See [Hooks#opt-in-model](Hooks#opt-in-model).

Use `[hooks]` when auto-enrollment can't see your registration:

- Mods using `ModLoader.add_hook(path, method, cb, before)` from a runtime autoload (the shim runs after pack generation).
- Mods registering hooks via callbacks passed in from a different autoload (`.hook()` call site isn't in the mod's own source).
- Mods that want a whole script wrapped up front without enumerating methods.

Format:

```ini
[hooks]
res://Scripts/Interface.gd = _ready, update_tooltip   # specific methods
res://Scripts/Controller.gd = *                       # wildcard -- all methods
res://Scripts/Camera.gd =                             # empty == *
```

Method names are case-insensitive (normalized to lowercase on write to match the rewriter's comparison). The wildcard leaves the inner mask empty; the generator reads that as "wrap every non-static method."

Declaring `[hooks]` in one mod is enough to enroll that path for every mod. Other mods that extend or override the same vanilla script compose naturally via Godot's `extends` resolution -- they see the wrapped parent, `super.method(...)` lands on the dispatch wrapper, hooks fire.

### `[script_extend]` section

Full-script replacement that chains via Godot's `extends` resolution.

```ini
[script_extend]
res://Scripts/Camera.gd = res://MyMod/MyCamera.gd
```

The mod script is expected to `extends "res://Scripts/Camera.gd"`. Applied in priority order (lowest first). Each subsequent override's `extends` resolves to the previous chain tip, forming `ModC -> ModB -> ModA -> (rewritten_)vanilla`.

Processing, per [mod_loading.gd `_apply_script_overrides`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd):

1. Sort pending overrides by priority ascending.
2. For each: `load(mod_path)` -> read `source_code` -> fresh `GDScript.new()` -> assign `source_code` -> `reload()` -> `take_over_path(vanilla_path)`.

The legacy-syntax autofix runs on each chain script before `reload()` (fixes `base()` -> `super.<method>()`, bodyless `if`, `onready var` -> `@onready var`, etc.), so chain scripts written against Godot 3 conventions compile cleanly.

**Interaction with the hook system**: if the vanilla path is also in the hook wrap surface (via `[hooks]` or a mod calling `.hook()` on one of its methods), the rewritten vanilla ships at the original path and the override's `extends` resolves to the wrapped version. `super.method(...)` lands on the dispatch wrapper; hooks fire. See [Hooks#composing-with-script_extend](Hooks#composing-with-script_extend).

`[script_overrides]` is kept as a legacy alias for backward compatibility with mods written pre-v3.0.1. New mods should use `[script_extend]`.

### `[registry]` section

Opt-in gate for the registry API (`lib.register`, `lib.override`, `lib.patch`, `lib.remove`, `lib.revert`). See [Registry](Registry) for the full surface.

```ini
[registry]
; empty body -- presence is sufficient
```

Declaring an empty `[registry]` section tells the loader to wrap `Database.gd`, `Loader.gd`, `AISpawner.gd`, and `FishPool.gd` with the injected fields the registry API needs. Without the declaration these scripts stay vanilla and registry calls no-op (`push_warning` logged).

You don't enumerate what you'll register here -- the section's presence alone enables the subsystem. Use the runtime API to add/override/patch individual entries.

### `[rtvmodlib]` section

```ini
[rtvmodlib]
needs=["Controller", "Camera"]
```

Historical declaration from tetrahydroc's standalone [rtv-mod-lib](https://github.com/tetrahydroc/rtv-mod-lib) mod, which used it to pick which framework subclass scripts to generate. **No-op under v3.0.1** -- the loader's opt-in wrap surface is driven by `[hooks]`, `.hook()` call scanning, and `[registry]`, not by `needs=`. Kept for backward compatibility so mods declaring it don't error out.

The loader logs `"[RTVModLib] [rtvmodlib] needs declarations are no-op under source-rewrite"` when mods declare this. If you're shipping a new mod, use `[hooks]` or rely on the `.hook()` scanner instead.

### `[script_overrides]` section (legacy alias)

Deprecated alias for `[script_extend]`. Both parse identically; `[script_extend]` is the preferred name going forward.

```ini
[script_overrides]
"res://Scripts/SomeVanilla.gd"="res://MyMod/MyOverride.gd"
```

## mod.txt validity states

Tracked per-entry in `_last_mod_txt_status` (see [fs_archive.gd:147 `read_mod_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd#L147)):

| Status | Meaning | UI warning |
|---|---|---|
| `ok` | Parse succeeded | -- |
| `none` | No mod.txt at archive root | "Invalid mod -- may not work correctly. Try re-downloading." |
| `nested:<path>` | `mod.txt` exists but not at root (e.g. in `SubFolder/mod.txt`) -- bad packaging | "Invalid mod -- packaged incorrectly. Try re-downloading." |
| `parse_error` | ConfigFile.parse failed | "Invalid mod -- may not work correctly. Try re-downloading." |
| `pck` | N/A (PCK skips mod.txt read) | -- |

UTF-8 BOM is stripped before parsing ([fs_archive.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)) so files saved from Windows editors don't trip ConfigFile. Non-UTF8 bytes elsewhere in `mod.txt` (or any `.gd` inside the archive) produce a Godot C++ warning `"Unicode parsing error, some characters were replaced with U+FFFD"` -- the loader logs `[ModScan] inspecting <file>` immediately before the decode so you can match the warning to the mod.

## Archive packaging gotchas

### Windows backslash paths

Zips repacked via `ZipFile.CreateFromDirectory()` on Windows often write entries with backslash separators (`MyMod\Main.gd` instead of `MyMod/Main.gd`). Godot mounts the pack but can't resolve those paths. Detected during scan:

```
BAD ZIP: <n> entries use Windows backslash paths.
  Re-pack with 7-Zip. Example bad entry: 'MyMod\Main.gd'
```

### Nested mod.txt

If `mod.txt` isn't at the archive root, packaging is wrong -- the archive probably has an unnecessary wrapper folder. The loader refuses to treat this as a valid mod.

### Database.gd collision

Mods that ship their own `res://Scripts/Database.gd` are flagged:

- First mod wins -- `"  DATABASE OVERRIDE: <mod> replaces Database.gd"`
- Subsequent mods -- `"  DATABASE COPY: <mod> bundles a private Database.gd at <path>"` + `"    Hardcoded preload() paths may break if companion mods aren't present."`

Mods should generally use [`lib.register` / `lib.override`](Registry) instead of shipping a full Database replacement.

## File-conflict resolution

When multiple mods claim the same `res://` path, the one with highest priority wins (last to mount, `replace_files=true`). Conflicts are logged to the dev-mode conflict summary (see [Developer-Mode](Developer-Mode)):

```
--- Conflicted Paths (last loader wins) ---
CONFLICT: res://Scripts/SomeFile.gd
    [1] ModA via ModA.vmz
    [2] ModB via ModB.vmz <-- wins
```

Within equal priority, load order is stable: mod_name ascii-lowercase, then filename. See [mod_discovery.gd `_compare_load_order`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).
