# Road to Vostok -- Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game window for installing mods, managing load order and profiles, applying modpacks, and checking for updates.

Docs live on the [Wiki](https://github.com/ametrocavich/vostok-mod-loader/wiki): setup, Browse, modpacks, the mod format, hook internals, stability canaries, limitations.

Changing the loader itself? Start with [CONTRIBUTING](CONTRIBUTING.md) and the
[development map](docs/wiki/Development.md).

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz`, `.zip` or `.pck`. Unpacked folders work in Developer Mode.

## Installation

1. Download `override.cfg` and `modloader.gd` from the [latest release](https://github.com/ametrocavich/vostok-mod-loader/releases/latest). (Or run `windows-installer.bat` / `linux-installer.sh` from the same release; they fetch and place both files for you.)
2. Copy both files into the game folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
3. Create a `mods` folder there if it doesn't exist.
4. Drop `.vmz` files into `mods/`, or leave it empty and install mods from the launcher.
5. Launch the game. The mod loader window appears before the main menu.

## Launcher UI

Three tabs:

- **Mods**: detected mods with checkboxes and a priority spinbox. Higher priority loads later and wins file conflicts. The load-order preview on the right updates as you edit. Profiles, the Developer Mode toggle, dependency handling and **Check for updates** live here too; a mod with a newer version on its site is listed under **Updates available** with an Update button. See the [Mods wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mods).
- **Browse**: search and install mods from [VostokMods](https://vostokmods.net), or switch the source menu to [ModWorkshop](https://modworkshop.net). Each site has a landing view plus search, sort and category filters. **Download** installs into your `mods/` folder; downloads queue and run one at a time. See the [Browse wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Browse).
- **Modpacks**: apply a setup published on [VostokMods](https://vostokmods.net). A modpack is a small `.zip` listing which mods to enable (plus their settings), not the mod files themselves. Apply downloads any missing mods and switches you to the author's setup; Unload restores your prior profile and MCM settings. Only one modpack can be active at a time. See the [Modpacks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Modpacks).

Dependencies are handled inline on the Mods tab. A mod with `[dependencies] required=[...]` in `mod.txt` shows an orange `won't load -- needs ...` line when a requirement is missing or disabled, with **Enable dependency** and **Load anyway** buttons beside it, and the loader skips mods whose required dependencies are not loadable.

Click the launch button or close the window to start. It reads **Launch modded** when at least one enabled mod will load, **Launch unmodded (N blocked)** when every enabled mod is blocked by a missing dependency, and **Launch** when nothing is enabled. If you reopen the window from the main menu's **Mods** button and change the active mod selection, load order or installed mods, closing it restarts the game into the new mod set. Renaming a profile alone does not restart.

### Guardrails

The launcher does a static scan of every mod's source for a small set of patterns seen in actual malicious mods (obfuscated string decoding paired with process spawning, anti-debug crashes, ransomware-setup calls). Mods that match get a red `suspicious code` tag in the list; click it to see what matched.

This is not a virus scanner. It catches lazy copy-paste attacks; anyone with the loader source can write around the patterns. Loading is never blocked; the tag is information, not a gate. The scanner exists to slow down the obvious cases. Install mods from sources you trust.

## Authoring a Mod

Package your mod as a `.vmz` archive (rename a `.zip` to `.vmz`) with a `mod.txt` at the root. All string values must be quoted.

Zip the mod's contents, not the folder that holds them. `mod.txt` has to be at the top level of the archive; a `mod.txt` buried one folder down is the most common reason a mod is rejected as packaged incorrectly. Put your code in a subfolder beside it, named after your mod, so your `res://` paths can't collide with the game or another mod:

```
MyMod.vmz
  mod.txt              <- at the root
  MyMod/Main.gd        <- mounts as res://MyMod/Main.gd
```

Developer Mode folders use the same layout and the same `mod.txt`. A folder's contents mount at `res://` the same way the zip's do, so nothing changes when you package it up.

```ini
[mod]
name="My Mod"
id="my_mod"
version="1.0.0"
priority=0

[autoload]
MyModMain="res://MyMod/Main.gd"

[updates]
source="vostokmods:my-mod"

[dependencies]
required=["mod_configuration_menu"]
optional=["some_soft_integration"]
```

| Field | Description |
|---|---|
| `name` | Display name in the UI |
| `id` | Unique ID. Duplicate IDs keep the newest version, then the newest file modification time. `.pck` files are exempt from deduplication; see [Mod-Format](docs/wiki/Mod-Format.md). |
| `version` | Used by the update check to compare against the mod's site |
| `priority` | Higher loads later, wins file conflicts. Default 0 |
| `[autoload]` | `Name="res://path.gd"` (or `.tscn`). Prefix the value with `!` to load before the game's own autoloads |
| `[updates] source` | Where the mod is hosted: `"vostokmods:<slug>"` or `"modworkshop:<id>"`. The older `modworkshop=<id>` form still works |
| `[dependencies] required/optional` | Godot string arrays of mod IDs. Required deps must be installed, enabled, and load before the dependent mod |

Mods without `mod.txt` still mount as resource packs. Their files override vanilla resources, but no autoloads run.

### Opt-in hook declarations

The loader uses an opt-in model (since v3.0.1): a mod list that declares nothing runs the game's scripts as shipped. The one exception is the loader's own wrap of `Menu.gd :: _ready`, which adds the main-menu **Mods** button whenever at least one mod loaded. Declarations turn on specific parts of the system.

Most mods don't need any declaration. If your mod calls `.hook("controller-jump-pre", cb)` directly in its source, the scanner finds it and enrolls `Controller.gd :: jump` for you. That covers every mod written against the native hook API.

```ini
[script_extend]
res://Scripts/Camera.gd = "res://MyMod/MyCamera.gd"

[registry]
; declaring this section is enough to enable lib.register() / lib.override()
```

- `[script_extend]`: a full-script replacement that chains via Godot's `extends` resolution. Multiple mods can extend the same vanilla script; take_over_path runs in priority order, and each override's `extends` resolves to the prior chain tip. `[script_overrides]` is kept as a legacy alias.
- `[registry]`: declaring this section enables `lib.register()` / `lib.override()` on Database.gd. Without it, the registry helpers never get injected and those calls return `false`.

The escape hatch is `[hooks]`. The scanner can't find every hook. If your mod registers via `ModLoader.add_hook(path, method, cb, before)` from an autoload's `_ready`, or passes a hook callback through a second autoload so the `.hook()` call site isn't in the mod's own source, list the vanilla script path:

```ini
[hooks]
res://Scripts/Interface.gd = "_ready, update_tooltip"   # specific methods
res://Scripts/Controller.gd = "*"                       # or wrap all methods
```

Quote the value. ConfigFile parses the right-hand side as a Variant literal, so an unquoted method list or a bare `*` raises "Unexpected identifier" and the entire `mod.txt` fails to parse. This loader wraps unquoted `[hooks]` values in quotes before parsing, but a quoted `mod.txt` is more portable.

`*` (or an empty value, written as `""`) wraps every hookable method in the script. Use it when you don't know up front which methods you'll hook, or the list is long enough that enumerating it is noise.

Full schema, including the `!` prefix semantics and packaging gotchas: [Mod-Format wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mod-Format).

### Migrating from v3.0.0

v3.0.0 inferred the wrap surface from `extends`, `take_over_path`, and a pinned list, then rewrote mod source to auto-fire hooks even when a mod replaced a method without calling `super()`. v3.0.1 removed the inference and the mod-source rewrite. If your mod relied on either, declare intent:

- If your mod calls `.hook(...)` directly in its source: no change. The scanner picks up the call and enrolls the method.
- If your override replaced a vanilla method fully and expected hooks to fire via the old rewrite: add `super.method(...)` at the start of the override, or add a `[hooks]` entry for the wrapped methods.
- If your mod used `lib.register()` / `lib.override()` without declaring `[registry]`: add the `[registry]` section.
- If your mod registers hooks indirectly (`add_hook` from a runtime autoload, or callbacks passed through another autoload): add `[hooks] <path> = "*"` so the wrap happens statically.

### Migrating from v2.1.0

If you stayed on v2.1.0 because v3.0.0 broke your loadout, upgrade directly. v3.0.1 and later behave like v2.1.0 for undeclared mods: no declarations means no rewriting beyond the loader's own `Menu.gd` wrap for the **Mods** button, and your mods run against unmodified vanilla scripts.

Declare only the features you use:

- A `.hook(...)` call in your source: the scanner enrolls the method; nothing to declare.
- `lib.register()` / `lib.override()`: add `[registry]`.
- `ModLoader.add_hook(path, method, cb, before)` (godot-mod-loader style): the compat shim translates to the native hook API. Register from a `!`-prefixed early autoload, or declare `[hooks] <path> = "*"` so the wrap happens at pack generation regardless of when your autoload runs.

## Hooks

Mods intercept vanilla methods via the meta API. Minimal example:

```gdscript
extends Node

var _lib = null

func _ready():
    if Engine.has_meta("RTVModLib"):
        var lib = Engine.get_meta("RTVModLib")
        if lib._is_ready:
            _on_lib_ready()
        else:
            lib.frameworks_ready.connect(_on_lib_ready)

func _on_lib_ready():
    _lib = Engine.get_meta("RTVModLib")
    _lib.hook("controller-jump-pre", _on_jump_pre)

func _on_jump_pre(_delta):
    # Callback args match the wrapped method.
    _lib._caller.jumpVelocity = 20.0
```

Hook name format: `<scriptname>-<methodname>[-pre|-post|-callback]`, lowercase. A bare name (no suffix) is a replace hook; the first registration wins.

The API is drop-in compatible with [tetrahydroc's RTVModLib mod](https://github.com/tetrahydroc/rtv-mod-lib) (`hook` / `unhook` / `_caller` / `skip_super` / `frameworks_ready`, same signatures). Mod code written against RTVModLib runs unchanged here.

Full API reference, dispatch semantics, and the three-entry pack recipe: [Hooks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Hooks).

## Troubleshooting

From the UI: click **Launch vanilla** in the pre-launch window to start the game once with no mods. Your mods and settings are untouched.

If the game crashes or won't launch:

- Wait it out. After 2 crashed launches in a row, the loader stops restarting and boots in a single pass: the launcher opens as usual, so you can disable the mod that crashes.
- Force-disable: create an empty file named `modloader_disabled` (no extension) in the game folder. On the next launch the loader mounts nothing and the game boots vanilla. Delete the file to re-enable. Use this when the loader itself is broken and you can't reach the UI.
- Safe-mode reset: create an empty file named `modloader_safe_mode` (no extension) in the game folder. On the next launch the loader resets its files to a clean state, then deletes the safe-mode file so it only runs once.

The [Troubleshooting wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Troubleshooting) has the longer version, including the reset steps after an update. Recovery internals (heartbeat, restart counter, crashed-Pass-2 dirty marker): [Stability-Canaries wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Stability-Canaries).

## Best Practices (for mod authors)

- Package as `.vmz` with forward-slash paths. Use 7-Zip, not .NET `ZipFile.CreateFromDirectory()`, which writes backslashes and breaks mounting.
- Include a `mod.txt` at the archive root. Without it, autoloads won't run.
- Use `super()` in lifecycle methods (`_ready`, `_process`, etc.) when overriding vanilla scripts. Skipping it breaks hook composition for other mods that hooked that method.
- Declare `[hooks]` or call `.hook(...)` on the vanilla methods you care about. Since v3.0.1, only declared methods get dispatch wrappers.
- Prefer hooks over file replacement when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't.
- Test with other mods installed and check the conflict report (Developer Mode).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: edit files in `src/`, run `./build.sh`, open PRs against `development` with Conventional Commit titles (`feat:`, `fix:`, `docs:`, etc.). Release-please handles version bumps from the commit history.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder. The `mods/` folder can be removed separately.

- Settings file: `%APPDATA%\Road to Vostok\mod_config.cfg`
- Conflict log (Developer Mode only): `%APPDATA%\Road to Vostok\modloader_conflicts.txt`
- Hook pack cache: `%APPDATA%\Road to Vostok\modloader_hooks\` (regenerated when needed)

Every config file, the profile key format, sentinel files, and what's safe to delete: [Config-Files wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Config-Files).

## License

MIT. See [LICENSE](LICENSE).
