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

[script_overrides]
"res://Scripts/SomeVanilla.gd"="res://MyMod/MyOverride.gd"

[rtvmodlib]
needs=["Controller", "Camera"]
```

### `[mod]` section

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | filename | Display name in the UI |
| `id` | string | filename | Unique id. Duplicates after the first loaded mod are skipped |
| `version` | string | `""` | Used by the Updates tab to compare against ModWorkshop |
| `priority` | int | 0 (or parsed from filename prefix) | Higher loads later, wins file conflicts. Clamped to `-999..999` |

**VostokMods compat**: if the archive filename matches `^(-?\d+)-(.*)`, the numeric prefix is used as a fallback priority when `[mod] priority` isn't set. Example: `100-BetterAI.vmz` loads with `priority=100`. See [mod_discovery.gd:73-85](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L73).

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

Version compare uses [mod_discovery.gd:138 `compare_versions`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L138) -- splits on `.`, strips `v`/`V` prefix, pads shorter side with `"0"`, lexicographic int comparison.

### `[script_overrides]` section

```
"<vanilla_res_path>"="<mod_res_path>"
```

Full script replacement. The mod script is expected to `extends "<vanilla_res_path>"`. Applied by [mod_loading.gd:199 `_apply_script_overrides`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L199):

1. Sort pending overrides by priority ascending.
2. For each: `load(mod_path)` -> read `source_code` -> fresh `GDScript.new()` -> assign `source_code` -> `reload()` -> `take_over_path(vanilla_path)`.

Processing in priority order means each subsequent override's `extends` resolves to the previous one, forming a natural chain `ModC -> ModB -> ModA -> vanilla`.

**Interaction with the hook system**: if a script listed in `[script_overrides]` is also a hook target (most vanilla scripts are), the override displaces the rewrite at that path. Hooks won't fire for nodes using the override. The loader warns: `"[RTVCodegen] <path> is rewritten and also overridden by <mods> -- override displaces the rewrite, hooks won't fire for that path"` ([hook_pack.gd:175-177](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L175)).

### `[rtvmodlib]` section

```ini
[rtvmodlib]
needs=["Controller", "Camera"]
```

Declares which vanilla "frameworks" (class_name scripts) the mod wants hooks into. **No-op under source-rewrite** -- the loader already rewrites every hookable vanilla script regardless of `needs=`. Kept for compatibility with tetrahydroc's standalone RTVModLib mod.

The loader logs `"[RTVModLib] [rtvmodlib] needs declarations are no-op under source-rewrite (%d frameworks requested; all hookable scripts already dispatched via hook pack)"` when mods declare this.

See [framework_wrappers.gd:49](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/framework_wrappers.gd#L49) for the dead-code note.

## mod.txt validity states

Tracked per-entry in `_last_mod_txt_status` (see [fs_archive.gd:147 `read_mod_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd#L147)):

| Status | Meaning | UI warning |
|---|---|---|
| `ok` | Parse succeeded | -- |
| `none` | No mod.txt at archive root | "Invalid mod -- may not work correctly. Try re-downloading." |
| `nested:<path>` | `mod.txt` exists but not at root (e.g. in `SubFolder/mod.txt`) -- bad packaging | "Invalid mod -- packaged incorrectly. Try re-downloading." |
| `parse_error` | ConfigFile.parse failed | "Invalid mod -- may not work correctly. Try re-downloading." |
| `pck` | N/A (PCK skips mod.txt read) | -- |

UTF-8 BOM is stripped before parsing ([fs_archive.gd:192](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd#L192)) so files saved from Windows editors don't trip ConfigFile.

## Archive packaging gotchas

### Windows backslash paths

Zips repacked via `ZipFile.CreateFromDirectory()` on Windows often write entries with backslash separators (`MyMod\Main.gd` instead of `MyMod/Main.gd`). Godot mounts the pack but can't resolve those paths. Detected during scan ([mod_loading.gd:243-254](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L243)):

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

See [mod_loading.gd:296-302](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd#L296). Mods should generally use [`lib.register` / `lib.override`](Hooks#database-registry-flow) instead of shipping a full Database replacement.

## File-conflict resolution

When multiple mods claim the same `res://` path, the one with highest priority wins (last to mount, `replace_files=true`). Conflicts are logged to the dev-mode conflict summary (see [Developer-Mode](Developer-Mode)):

```
--- Conflicted Paths (last loader wins) ---
CONFLICT: res://Scripts/SomeFile.gd
    [1] ModA via ModA.vmz
    [2] ModB via ModB.vmz <-- wins
```

Within equal priority, load order is stable: mod_name ascii-lowercase, then filename. See [mod_discovery.gd:127 `_compare_load_order`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L127).
