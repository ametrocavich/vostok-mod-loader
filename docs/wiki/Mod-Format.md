# Mod Format

A mod is an archive (`.vmz`, `.zip`, or `.pck`; unpacked folders too in developer mode). The archive contents mirror the game's `res://` tree: a file at `MyMod/foo.gd` inside the archive is `res://MyMod/foo.gd` after mounting.

## Archive types

| Extension | Mount mechanism | mod.txt | Autoloads | Update checking |
|---|---|---|---|---|
| `.vmz` | Copied to `user://vmz_mount_cache/<name>.zip`, then `ProjectSettings.load_resource_pack` | Yes | Yes | Yes |
| `.zip` | `ProjectSettings.load_resource_pack` directly | Yes | Yes | Yes |
| `.pck` | `ProjectSettings.load_resource_pack` directly | No | No | No: the check needs a readable `mod.txt` for the installed version |
| folder | Zipped to `user://vmz_mount_cache/<name>_dev.zip`, then mounted. The folder's contents sit at the archive root, so it mounts like the zip you would ship (see [Folder mode layout](#folder-mode-layout)). Developer mode only | Yes | Yes | No: a downloaded archive would land beside the folder as a duplicate |

`.vmz` is the historical community convention. `ProjectSettings.load_resource_pack` picks its reader by file extension and refuses `.vmz` (ZIPReader, which the loader uses to read `mod.txt`, opens it fine), so the loader copies it to `<name>.zip` in the cache dir first ([fs_archive.gd `_static_vmz_to_zip`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)). The copy carries a `.src` sidecar holding the source's mtime and size; when either changes, or the sidecar is missing, the copy is redone. `.zip` archives skip the cache and mount directly.

### Packaging layout

`mod.txt` must sit at the root of the archive. An archive whose `mod.txt` is
buried in a subfolder is rejected as packaged incorrectly. This is the single
most common packaging mistake, and it happens when you zip the folder that holds
the mod instead of the mod's contents.

Everything else mounts verbatim, so put your code in a subfolder named after your
mod. `res://` is shared with the game and every other mod, and a bare
`res://Main.gd` invites a collision.

```
MyMod.vmz                    Resulting res:// paths after mount
  mod.txt                    (read at the root; not a path you reference)
  MyMod/Main.gd              res://MyMod/Main.gd
  MyMod/data/items.json      res://MyMod/data/items.json
```

A matching `mod.txt` autoload entry: `MyModMain="res://MyMod/Main.gd"`.

### Folder mode layout

A dev-mode folder mod uses the same layout and the same `mod.txt`. The
folder's contents are zipped at the archive root, so `<game>/mods/MyMod/` holding
`mod.txt` and `MyMod/Main.gd` mounts exactly like the `.zip` above. Work on the
folder, zip its contents, upload it. No path changes at any step.

```
mods/MyMod/                  Resulting res:// paths after mount
  mod.txt                    (read at the root; not a path you reference)
  MyMod/Main.gd              res://MyMod/Main.gd
  MyMod/data/items.json      res://MyMod/data/items.json
```

A folder mod's entries mount at `res://` exactly as the zip's do, so nothing
changes when the mod is zipped and shipped; a namespace comes from a real
subfolder inside the mod, same as in a zip. A stale path is not silent: the
loader logs `Autoload path not found: <path>` along with the similar paths it
did find. Folder mode is dev-only, gated behind the developer-mode toggle.

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
source="vostokmods:019ff1f0-00ac-76a9-a23f-7151e4531131"

[dependencies]
required=["mod_configuration_menu"]
optional=["some_soft_integration"]

[hooks]
res://Scripts/Interface.gd = "Close, CalculateDeal"

[script_extend]
res://Scripts/Camera.gd = "res://MyMod/MyCamera.gd"

[registry]
; empty section is enough; presence enables the registry API
```

Only `[mod]` is required. `[autoload]`, `[updates]`, `[dependencies]`, `[hooks]`, `[script_extend]` and `[registry]` are optional; use the ones your mod needs. A section name the loader does not know gets one info line in the boot log (`mod.txt section(s) [foo] not recognized by this loader -- ignored`) and nothing else happens.

### `[mod]` section

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | filename | Display name in the UI |
| `id` | string | filename | Unique id (case-insensitive). If two installed archives declare the same id, only one loads: highest `version` wins, then newer file mtime, then the alphabetically lower filename. The others are hidden with a logged warning and an `older version hidden:` line on the winner's row. Mods with no `id` are grouped by filename stem instead (`CoolMod_v1.2.zip` and `CoolMod-1.3.zip` count as one mod). `.pck` files are never grouped: every `.pck` loads |
| `version` | string | `""` | Used by the update check to compare against the mod's site, and as the version a modpack pins |
| `priority` | int | 0 (or parsed from filename prefix) | Higher loads later, wins file conflicts. Clamped to `-999..999` |
| `author` | string | `""` | Shown as `by <author>` on the mod's row and in its detail view |
| `provides` | string array | `[]` | Rename aliases: old ids this mod still satisfies for other mods' dependencies. See below |

Compatibility with the older VostokMods injector (Ryhon0's loader, not the vostokmods.net site): if the archive filename matches `^(-?\d+)-(.*)`, the numeric prefix is the fallback priority when `[mod] priority` is not set, and the rest of the stem is the default name and id. `100-BetterAI.vmz` loads with `priority=100`. See [mod_discovery.gd `_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).

A mod without `id=` is identified by its filename. In developer mode the row notes it: a new file whose name differs only by a trailing version (`CoolMod_v1.2.zip` to `CoolMod_v1.3.zip`) keeps its enabled state and load order, any other rename loses them, and two copies cannot be told apart. Declare an id.

### `[dependencies]` section

Declares other mods by their `[mod] id`. Required dependencies load before your mod automatically and block it (with an explanation and fix-it buttons in the Mods tab) when missing; optional ones affect load order only. The full behavior, including automatic ordering, cycles, skip rules and the blocked-row UI, is on [Dependencies](Dependencies).

```ini
[dependencies]
required=["mod_configuration_menu", "rtv_shared_lib"]
optional=["happy_fireplace"]
```

| Key | Type | Meaning |
|---|---|---|
| `required` | string array | Mods that must be installed and enabled. If any required dependency is unmet, this mod is skipped. |
| `optional` | string array | Soft integrations: ordered before yours when present; absence never blocks. |

Use Godot `ConfigFile` string arrays. Bare CSV (`required=a, b`) is not valid `ConfigFile` syntax and fails the whole `mod.txt` parse. Accepted value shapes: [Dependencies#value-syntax](Dependencies#value-syntax-required-optional-provides).

### Renaming a mod: `[mod] provides`

If you change your mod's `id`, every mod that lists the old id in `[dependencies]` breaks. Declare the old id (or ids) in `provides` and those requirements stay satisfied:

```ini
[mod]
name="Better AI"
id="better_ai"
provides=["betterai_legacy", "old_better_ai"]
```

Ship the alias in the same release that renames the id, and keep it; dependents update on their own schedule. Resolution rules (shadowing, duplicate aliases, malformed values) are on [Dependencies#renaming-your-mod-provides](Dependencies#renaming-your-mod-provides).

### `[autoload]` section

```
<autoload_name>="<path>"
```

Same shape as Godot's project-settings autoloads. Keys become node names in `/root/<name>`, values point to a `.gd` script or `.tscn` scene. A value may carry two leading markers in either order: `*` (Godot's own "instantiate as a node" marker, accepted and stripped) and `!`, described next.

A value starting with `!` marks the autoload as early:

```ini
[autoload]
LateNode="res://MyMod/Late.gd"
EarlyNode="!res://MyMod/Early.gd"
```

Early autoloads go into `override.cfg`'s `[autoload_prepend]` section, so Godot loads them before the game's own autoloads. Late autoloads are instantiated by the loader after mounts land and the hook pack is generated. The loader always writes itself (`ModLoader="*res://modloader.gd"`) last in `[autoload_prepend]`; Godot loads that section in reverse insertion order, so the loader comes up first.

Early-autoload `.gd` scripts that only exist inside a mounted archive are extracted to `user://modloader_early/<path>` so Godot can find them before the restart completes its static-init mount. Scenes (`.tscn`) resolve through the file-scope mount directly. See [boot.gd `_ensure_early_autoload_on_disk`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/boot.gd). An early autoload whose name is not a plain identifier, or whose path contains a quote or newline, is skipped with a warning instead of written into `override.cfg`.

Duplicate autoload names are logged and skipped (first wins). A path that exists nowhere (not in the archive, not in another mod, not in the game) is skipped at boot with `Autoload path not found: <path>` plus a `Similar paths in archive:` line listing files with the same name at another path. The launcher catches the common case earlier: when the same filename exists elsewhere in the archive, the row warns `Autoload "<name>" points at <path>, which is not in this mod -- did you mean <other path>?` before you launch.

### `[updates]` section

| Key | Type | Meaning |
|---|---|---|
| `source` | String | Where this mod is hosted, as `"<provider>:<id>"`. Enables the update check and modpack auto-download. Preferred over `modworkshop`. |
| `modworkshop` | int | Legacy ModWorkshop mod id. Still read, no sunset planned; equivalent to `source="modworkshop:<id>"`. |

`source` is the provider-qualified form. The provider is a known host token: `vostokmods` (the id is the mod's UUID, which the site writes into the file; the slug, the last part of the page URL, also works) or `modworkshop` (the numeric mod id). The provider is matched case-insensitively. A value with no colon is rejected, not guessed, so `source="12345"` is an error, not a ModWorkshop id; in developer mode the row carries the note `mod.txt has an unrecognized [updates] source=...`. A malformed `source=` falls through to `modworkshop=` when both are present.

For a Vostok Mods mod you normally write nothing: the site adds the line to every `mod.txt` it serves, with the mod's UUID as the id. Writing it yourself is fine too, with the UUID or the slug (the last part of the mod's page URL, `vostokmods.net/mod/<slug>`); every site route resolves either:

```
[updates]
source="vostokmods:019ff1f0-00ac-76a9-a23f-7151e4531131"
```

For a ModWorkshop mod, declare BOTH keys during the compatibility window:

```
[updates]
source="modworkshop:12345"
modworkshop=12345
```

The `modworkshop=` line keeps older loaders working; the `source=` line is what newer loaders read first. A mod hosted anywhere other than ModWorkshop must declare only `source=` and must not add a `modworkshop=` line, because an older loader would treat that number as a ModWorkshop id and download an unrelated mod.

Declaring a source also makes the mod auto-downloadable when someone applies a modpack that includes it. The loader records the source plus `[mod] version` and fetches it on the recipient's machine. Mods with no source must be installed by hand by modpack recipients.

A mod downloaded through the Browse tab is remembered by the launcher (in `mod_config.cfg` `[mod_sources]`) even when its `mod.txt` declares nothing, so the update check and modpacks still know where it came from on that machine. Declaring `source=` is what makes that knowledge travel with the mod.

Quote your `[mod] version`. An unquoted `version = 1.10` is read as the number 1.1 and the trailing zero is lost, which corrupts the exact version a modpack pins. In developer mode the row notes when a sourced mod has an unquoted version.

Version compare is [mod_identity.gd `compare_versions`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_identity.gd): strip a `v`/`V` prefix and any `+build` tail, split the part before the first `-` on `.`, pad the shorter side with `0`, and compare component by component as ints (a non-numeric component counts as 0). On a tie, a `-suffix` is a semver prerelease: `1.0.0-beta.1` ranks below `1.0.0`, and two suffixes compare identifier by identifier (`beta.2` below `beta.10`).

### `[hooks]` section

Enrolls specific vanilla methods (or whole scripts) in the rewrite surface so your hook callbacks can fire. Most mods do not need this: if your mod calls `.hook("stem-method-variant", cb)` with a literal string in its own source, the scanner picks the call up and enrolls the method. See [Hooks#wrap-surface](Hooks#wrap-surface----why-hook-alone-is-not-enough).

Use `[hooks]` when auto-enrollment cannot see your registration:

- `ModLoader.add_hook(path, method, cb, before)` called from a runtime autoload (the shim runs after pack generation).
- Hooks registered through callbacks passed in from a different autoload, so the `.hook()` call site is not in your mod's own source.
- A whole script wrapped up front without enumerating methods.

Format:

```ini
[hooks]
res://Scripts/Interface.gd = "Close, CalculateDeal"    # specific methods
res://Scripts/Controller.gd = "*"                       # wildcard: all methods
res://Scripts/Camera.gd = ""                            # empty == *
```

Quote the value (right-hand side). ConfigFile parses the RHS as a Variant literal, so an unquoted method list like `Close, CalculateDeal` or a bare `*` is rejected as "Unexpected identifier". This loader quote-wraps unquoted `[hooks]` values (and strips inline `#`/`;` comments) for backward compat, but a mod is more portable (other loaders, raw `ConfigFile.parse()`) when written quoted from the start.

Method names are case-insensitive (lowercased on write to match the rewriter's comparison). The wildcard leaves the inner mask empty, and the generator reads that as "wrap every non-static method".

Declaring `[hooks]` in one mod enrolls that path for every mod. A full-script replacement of that same vanilla script (`[script_extend]` / `[script_overrides]`) composes with it only when the loader defers that script to lazy compile (scripts with a module-scope scene preload, such as `Interface.gd`; the boot log lists them under `DEFER`): the replacement then extends the rewrite and both run. A script activated up front is reloaded with the rewritten source, the replacement's code does not run that session, and the loader logs a `[RTVCodegen]` warning naming the mod. If a script you replace is hooked by any loaded mod and is not deferred, hook its methods instead.

### `[script_extend]` section

Full-script replacement that chains through Godot's `extends` resolution.

```ini
[script_extend]
res://Scripts/Camera.gd = "res://MyMod/MyCamera.gd"
```

Quote the value. ConfigFile parses the RHS as a Variant, and an unquoted `res://...` tokenizes as the identifier `res` and errors. Unlike `[hooks]`, `[script_extend]` values are not quote-wrapped by the loader, so quoting here is mandatory. An entry with an empty key or value is skipped with `Empty [script_extend] entry -- skipped`.

The mod script is expected to `extends "res://Scripts/Camera.gd"`. Entries apply in priority order (lowest first; ties in declaration order). Each subsequent override's `extends` resolves to the previous chain tip, forming `ModC -> ModB -> ModA -> vanilla`.

Processing, per [mod_loading.gd `_apply_script_overrides`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd):

1. Sort pending overrides by priority ascending.
2. For each: `load(mod_path)`, read `source_code`, fresh `GDScript.new()`, assign `source_code`, `reload()`, `take_over_path(vanilla_path)`.

The source is compiled unchanged: the loader does not edit a chain script, so it has to be valid Godot 4 GDScript. A script that fails to compile is skipped with `[Overrides] Compile failed for <path>`.

Interaction with the hook system: if the vanilla path is also in the hook wrap surface (through `[hooks]` or a mod calling `.hook()` on one of its methods), what happens depends on when the loader compiles that script. A script deferred to lazy compile (one with a module-scope scene preload; the boot log lists them under `DEFER`) composes: the replacement extends the rewrite and both run. A script activated up front loses the replacement for that session: overrides are applied before the hook pack is generated, and activating the pack reloads the vanilla path with the rewritten source. The loader logs a `[RTVCodegen]` warning naming your mod at both points in that case. Until activation is reordered so a replacement chains onto every rewrite, hook the methods you need instead of replacing a hooked script that is not deferred. See [Hooks#composing-with-script_extend](Hooks#composing-with-script_extend).

`[script_overrides]` is the legacy alias, kept for mods written before v3.0.1. New mods should use `[script_extend]`.

### `[registry]` section

Opt-in gate for the registry API (`lib.register`, `lib.override`, `lib.patch`, `lib.remove`, `lib.revert`). See [Registry](Registry) for the full surface.

```ini
[registry]
; empty body; presence is sufficient
```

An empty `[registry]` section tells the loader to wrap `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd` and `Compiler.gd` with the injected fields the registry API needs. Without the declaration these scripts stay vanilla (unless a mod hooks one of them, which wraps that script and carries the registry code with it), and a registry call finds no injected fields, warns (`Database.gd is missing injected scene fields (rewriter didn't fire). Does your mod.txt include a [registry] section?`), and returns false.

You do not enumerate what you will register here. The section's presence alone enables the subsystem. Use the runtime API to add, override or patch individual entries. Mods that call `Loader.add_shelter` / `Loader.add_map` (the B_Loader style) are treated as if they had declared `[registry]`, so they work without a mod.txt edit.

### `[rtvmodlib]` section

```ini
[rtvmodlib]
needs=["Controller", "Camera"]
```

Historical declaration from tetrahydroc's standalone [rtv-mod-lib](https://github.com/tetrahydroc/rtv-mod-lib) mod, which used it to pick which framework subclass scripts to generate. The current loader does not read it. The section is on the known-section list, so it does not even trigger the unrecognized-section line; it parses as a normal ConfigFile section and nothing consumes it. The wrap surface is driven by `[hooks]`, `.hook()` call scanning and `[registry]`, not by `needs=`.

### `[script_overrides]` section (legacy alias)

Deprecated alias for `[script_extend]`. Both parse identically; `[script_extend]` is the preferred name.

```ini
[script_overrides]
"res://Scripts/SomeVanilla.gd"="res://MyMod/MyOverride.gd"
```

## mod.txt validity states

The `status` of the record [fs_archive.gd `read_mod_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd) returns, kept on each entry as `mod_txt_status`:

| Status | Meaning | UI warning |
|---|---|---|
| `ok` | Parse succeeded | none |
| `none` | No mod.txt at archive root | `Invalid mod -- may not work correctly. Try re-downloading.` |
| `nested:<path>` | `mod.txt` exists but not at root (e.g. `SubFolder/mod.txt`); bad packaging | `Invalid mod -- mod.txt is in a subfolder, not at the zip root. Re-zip so mod.txt is at the root.` |
| `parse_error` | `ConfigFile.parse` failed, or the file is empty | `mod.txt parse error at <line N [section]: text>`, or `Invalid mod -- mod.txt failed to parse. Try re-downloading.` for an empty file, the one case with no line to name |
| `pck` | Not applicable (a `.pck` carries no readable mod.txt) | none |

A UTF-8 BOM is stripped before parsing so files saved from Windows editors do not trip ConfigFile. Non-UTF8 bytes elsewhere in `mod.txt` (or in any `.gd` inside the archive) produce a Godot warning, `Unicode parsing error, some characters were replaced with U+FFFD`. In developer mode the loader logs `[ModScan] inspecting <file>` at debug level right before the decode so you can match the warning to the mod.

## Archive packaging gotchas

### Windows backslash paths

Zips repacked with `ZipFile.CreateFromDirectory()` on Windows often write entries with backslash separators (`MyMod\Main.gd` instead of `MyMod/Main.gd`). Godot mounts the pack but cannot resolve those paths. The scan reports it:

```
BAD ZIP: <n> entries use Windows backslash paths.
  Re-pack with 7-Zip. Example bad entry: 'MyMod\Main.gd'
```

### `.remap` files

A mod can ship Godot `.remap` files, which redirect a scene, texture or script path to another file in the archive. Mounting loads nothing: the engine follows a mounted `.remap` itself the first time that path is loaded, also when the game has no file at the path. An archive that carries an export bake (`.gd.remap` entries next to a `.godot/exported/` folder) runs the compiled copies, not the `.gd` files beside them; in developer mode the row notes it (`Ships N pre-compiled script(s) ...`).

### Nested mod.txt

If `mod.txt` is not at the archive root, packaging is wrong. The archive probably has an unnecessary wrapper folder. The loader refuses to treat it as a valid mod.

### Database.gd collision

Mods that ship their own `res://Scripts/Database.gd` are flagged:

- The first mod wins: `DATABASE OVERRIDE: <mod> replaces Database.gd`
- Later mods: `DATABASE COPY: <mod> bundles a private Database.gd at <path>` followed by `Hardcoded preload() paths may break if companion mods aren't present.`

Use [`lib.register` / `lib.override`](Registry) instead of shipping a full Database replacement.

## File-conflict resolution

When several mods claim the same `res://` path, the one with the highest priority wins (it mounts last, with `replace_files=true`). Developer mode prints the conflicts in the boot summary (see [Developer-Mode](Developer-Mode)):

```
--- Conflicted Paths (last loader wins) ---
CONFLICT: res://Scripts/SomeFile.gd
    [1] ModA via ModA.vmz
    [2] ModB via ModB.vmz <-- wins
```

Within equal priority, load order is stable: lowercased mod name, then filename. See [mod_dependencies.gd `_compare_load_order`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_dependencies.gd).
