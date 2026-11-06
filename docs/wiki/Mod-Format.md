# Mod Format

A mod is an archive (`.vmz`, `.zip` or `.pck`; unpacked folders too in developer mode). The archive mirrors the game's `res://` tree: `MyMod/foo.gd` inside the archive is `res://MyMod/foo.gd` after mounting.

## Archive types

| Extension | Mounted as | mod.txt and autoloads | Update check |
|---|---|---|---|
| `.vmz` | a copy in `user://vmz_mount_cache/<name>.zip` | yes | yes |
| `.zip` | itself | yes | yes |
| `.pck` | itself | no | no: the check needs a readable `mod.txt` |
| folder | a zip of its contents in `user://vmz_mount_cache/<name>_dev.zip` | yes | no |

Godot picks a pack reader by file extension and refuses `.vmz`, so the loader copies it to `.zip` first ([fs_archive.gd `_static_vmz_to_zip`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd)); a `.src` sidecar holds the source's mtime and size, and the copy is redone when either changes. Folder mods load only with [Developer-Mode](Developer-Mode) on.

### Packaging layout

`mod.txt` sits at the root of the archive. Zipping the folder that holds the mod, instead of the mod's contents, buries `mod.txt` in a subfolder and the archive is rejected. Everything else mounts verbatim, so put your files in a subfolder named after your mod: `res://` is shared with the game and every other mod. A folder mod uses the same layout and mounts exactly like the zip, so nothing changes when you zip its contents and ship them.

```
MyMod.vmz                    res:// path after mount
  mod.txt                    (read at the root; not a path you reference)
  MyMod/Main.gd              res://MyMod/Main.gd
  MyMod/data/items.json      res://MyMod/data/items.json
```

## mod.txt

A Godot `ConfigFile` at the archive root. String values must be quoted.

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

[registry]
```

Only `[mod]` is required. A section the loader does not know gets one info line in the boot log (`mod.txt section(s) [foo] not recognized by this loader`) and is ignored. `[rtvmodlib]` is accepted and ignored without that line.

### `[mod]` section

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | filename stem | Display name |
| `id` | string | filename stem | Identity, case-insensitive; see below |
| `version` | string | `""` | Compared by the update check; the version a modpack pins |
| `priority` | int | 0, or the filename prefix | Higher loads later and wins file conflicts; clamped to `-999..999` |
| `provides` | string array | `[]` | Old ids this mod still satisfies; see [Dependencies](Dependencies#renaming-your-mod-provides) |

`author` is not read; the `by <author>` line on a row comes from the mod's host page.

**Identity.** When two installed archives declare the same `id`, one loads: the highest `version`, then the newer file, then the alphabetically lower filename. The others are hidden with a logged warning and an `older version hidden:` line on the winner's row. A mod without `id` is identified by its filename and grouped by filename stem (`CoolMod_v1.2.zip` and `CoolMod-1.3.zip` are one mod); [Profile-Format](Profile-Format#profile-key-format) says which renames keep its state. `.pck` files are never grouped. Declare an id.

A filename matching `^(-?\d+)-(.*)` (the older VostokMods injector's convention) gives the numeric prefix as the fallback priority and the rest of the stem as the default name and id: `100-BetterAI.vmz` loads with `priority=100`. See [mod_discovery.gd `_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).

### `[dependencies]` section

Lists other mods by their `[mod] id`. A required dependency loads before your mod and blocks it when missing; an optional one only affects order. Use `ConfigFile` string arrays: bare CSV (`required=a, b`) fails the whole `mod.txt`. Ordering, cycles, the blocked row and the accepted [value syntax](Dependencies#value-syntax-required-optional-provides) are on [Dependencies](Dependencies).

### `[autoload]` section

`<name>="<path>"`, the shape of Godot's project autoloads: each key becomes `/root/<name>`, each value a `.gd` script or `.tscn` scene. A value may start with `*` (Godot's instantiate marker, stripped) and `!`, in either order.

A `!` value is an early autoload. It is written into `override.cfg`'s `[autoload_prepend]`, so Godot loads it before the game's own autoloads; the others are instantiated by the loader after the mounts and the hook pack. An early `.gd` that exists only inside an archive is extracted to `user://modloader_early/<path>` so Godot finds it at startup ([pass_state.gd `_ensure_early_autoload_on_disk`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pass_state.gd)). An early autoload whose name is not an identifier, or whose path holds a quote, backslash or newline, is skipped with a warning.

A duplicate autoload name is skipped (first wins). A path found nowhere is skipped at boot with `Autoload path not found: <path>` and a `Similar paths in archive:` line; when the file exists elsewhere in the archive the row warns before launch (see [row warnings](#modtxt-validity-and-row-warnings)).

### `[updates]` section

| Key | Type | Meaning |
|---|---|---|
| `source` | string | `"<provider>:<id>"`: where the mod is hosted. Enables the update check and modpack downloads |
| `modworkshop` | int | Legacy ModWorkshop id; same as `source="modworkshop:<id>"` |

The provider is `vostokmods` (the id is the mod's UUID or its slug, the last part of `vostokmods.net/mod/<slug>`) or `modworkshop` (the numeric id), matched case-insensitively. A value without a colon is rejected, not guessed. A rejected `source=` falls through to `modworkshop=` when both are present.

Vostok Mods writes the `source=` line, with the UUID, into every `mod.txt` it serves, so a mod hosted there needs nothing. A ModWorkshop mod declares both `source="modworkshop:12345"` and `modworkshop=12345`. A mod hosted anywhere else declares only `source=`: a loader that predates `source=` reads `modworkshop=` and would download an unrelated mod with that number. A mod installed through Browse is remembered in `mod_config.cfg` `[mod_sources]` even without the line ([Config-Files](Config-Files)); declaring `source=` is what makes the host travel with the mod, so modpack recipients can download it.

Quote `version`: an unquoted `version = 1.10` reads as the number 1.1, which corrupts the version a modpack pins. Version compare is [mod_identity.gd `compare_versions`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_identity.gd): a leading `v` and a `+build` tail are ignored, dot components compare by leading number, a letter tail ranks above the bare number (`1.0.1b` > `1.0.1`) and a prerelease word below it (`1.2rc1`, `1.2beta` < `1.2`), and a `-suffix` is a semver prerelease (`1.0.0-beta.2` < `1.0.0-beta.10` < `1.0.0`). `has_mod()` uses a plainer compare where a non-numeric component counts as 0.

### `[hooks]` section

Enrolls vanilla methods, or whole scripts, in the rewrite surface. Most mods do not need it: a literal `.hook("stem-method-variant", cb)` in your own source is found by the scanner. Use it when the registration is not visible there (`ModLoader.add_hook()`, callbacks passed in from another autoload, a whole script wrapped up front). See [Hooks](Hooks#wrap-surface----why-hook-alone-is-not-enough).

```ini
[hooks]
res://Scripts/Interface.gd = "Close, CalculateDeal"
res://Scripts/Controller.gd = "*"
```

Quote the value; the loader quotes an unquoted list for you, but other `ConfigFile` readers do not. Method names are case-insensitive; `"*"` or `""` wraps every non-static method. A declaration enrolls that path for every mod.

### `[script_extend]` section

Full-script replacement through Godot's `extends` chain. `[script_overrides]` is an alias that parses the same way.

```ini
[script_extend]
res://Scripts/Camera.gd = "res://MyMod/MyCamera.gd"
```

Quote the value; unlike `[hooks]` it is not quoted for you. The mod script `extends "res://Scripts/Camera.gd"`. Entries apply in priority order, lowest first, and each one's `extends` resolves to the previous tip (`ModC -> ModB -> ModA -> vanilla`); see [mod_loading.gd `_apply_script_overrides`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd). The source compiles unchanged, so it must be valid Godot 4 GDScript; a failure logs `[Overrides] Compile failed for <path>`. A replaced script that some mod also hooks keeps the replacement only when it is deferred to lazy compile: [Hooks](Hooks#composing-with-script_extend).

### `[registry]` section

An empty `[registry]` section enables the registry API (`lib.register`, `lib.override`, `lib.patch` and the rest). What it wraps and the warning you get without it are on [Registry](Registry#opting-in).

## mod.txt validity and row warnings

[fs_archive.gd `read_mod_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/fs_archive.gd) returns a status; the scan gives a `.pck` the status `pck`. Every player sees these warnings on the mod's row:

| Status | Meaning | Row warning |
|---|---|---|
| `ok` | parsed | none, or `Autoload "<name>" points at <path>, which is not in this mod -- did you mean <other>?` |
| `none` | no `mod.txt` at the root | `Invalid mod -- may not work correctly. Try re-downloading.` |
| `nested:<path>` | `mod.txt` in a subfolder | `Invalid mod -- mod.txt is in a subfolder, not at the zip root. Re-zip so mod.txt is at the root.` |
| `parse_error` | `ConfigFile` failed | `mod.txt parse error at line N [section]: <text>`; an empty file gives `Invalid mod -- mod.txt failed to parse. Try re-downloading.` |
| `pck` | no readable `mod.txt` | none |

A folder mod gets only the parse error. With developer mode on, an archive's row also carries notes for its author, each naming the fix: `Ships N pre-compiled script(s)` (an export bake whose compiled copies run instead of the `.gd` files), `No id= in mod.txt`, `mod.txt has an unrecognized [updates] source=`, `mod.txt [updates] modworkshop="..." is not a valid ModWorkshop id`, and `mod.txt [mod] version is unquoted` (on a mod with a source).

A UTF-8 BOM is stripped before parsing. Other non-UTF-8 bytes give Godot's `Unicode parsing error` warning; developer mode logs `[ModScan] inspecting <file>` just before, to name the mod.

## Packaging gotchas

- **Backslash paths.** Zips written by Windows `ZipFile.CreateFromDirectory()` can store `MyMod\Main.gd`; Godot mounts them but cannot resolve the paths. The boot log says `BAD ZIP: <n> entries use Windows backslash paths.` Re-pack with 7-Zip.
- **`.remap` files** mount as they are and the engine follows them on first load. An archive carrying an export bake (`.gd.remap` beside `.godot/exported/`) runs the compiled copies.
- **Database.gd.** A mod shipping `res://Scripts/Database.gd` is logged as `DATABASE OVERRIDE` (the first) or `DATABASE COPY` (later ones). Use [`lib.register` / `lib.override`](Registry) instead.

## File-conflict resolution

When several mods ship the same `res://` path, the highest priority wins: it mounts last, with `replace_files=true`. Equal priorities order by lowercased mod name, then filename ([mod_dependencies.gd `_compare_load_order`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_dependencies.gd)). Developer mode lists the conflicts in the boot log and the conflict report ([Developer-Mode](Developer-Mode)).
