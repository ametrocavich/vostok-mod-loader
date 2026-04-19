# Road to Vostok -- Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game UI for managing mods, load order, and updates.

**Developer docs**: [Wiki](https://github.com/ametrocavich/vostok-mod-loader/wiki) -- architecture, hook internals, mod format schema, stability canaries, limitations.

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz` or `.pck`. Unpacked folders work in Developer Mode.

## Installation

1. Copy `override.cfg` and `modloader.gd` into the game folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```
2. Create a `mods` folder there if it doesn't exist.
3. Drop `.vmz` files into `mods/`.
4. Launch the game. The mod loader UI appears before the main menu.

## Launcher UI

Two tabs:

- **Mods** -- detected mods with checkboxes and a priority spinbox. Higher priority loads later and wins file conflicts. Load-order preview on the right updates in real time.
- **Updates** -- for mods with `[updates] modworkshop=<id>` in `mod.txt`, check for and download updates from ModWorkshop.

Click **Launch Game** or close the window to start.

## Authoring a Mod

Package your mod as a `.vmz` archive (rename a `.zip` to `.vmz`) with a `mod.txt` at the root. All string values must be quoted.

```ini
[mod]
name="My Mod"
id="my_mod"
version="1.0.0"
priority=0

[autoload]
MyModMain="res://MyMod/Main.gd"

[updates]
modworkshop=12345
```

| Field | Description |
|---|---|
| `name` | Display name in the UI |
| `id` | Unique ID. Duplicate IDs after the first loaded mod are skipped |
| `version` | Used by the Updates tab to compare against ModWorkshop |
| `priority` | Higher loads later, wins file conflicts. Default 0 |
| `[autoload]` | `Name="res://path.gd"` (or `.tscn`). Prefix value with `!` to load before the game's own autoloads |
| `[updates] modworkshop` | ModWorkshop mod ID |

Mods without `mod.txt` still mount as resource packs -- their files override vanilla resources, but no autoloads run.

Full schema (including `[script_overrides]`, `[rtvmodlib] needs=`, the `!` prefix semantics, and packaging gotchas): see the [Mod-Format wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mod-Format).

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

Hook name format: `<scriptname>-<methodname>[-pre|-post|-callback]` lowercase. Bare name (no suffix) is a replace hook -- first registration wins.

The API is drop-in compatible with [tetrahydroc's RTVModLib mod](https://github.com/tetrahydroc/rtv-mod-lib) (`hook` / `unhook` / `_caller` / `skip_super` / `frameworks_ready`, same signatures). Mod code written against RTVModLib runs unchanged here.

Full API reference, dispatch semantics, three-entry pack recipe, mod subclass rewriting, and worked examples: [Hooks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Hooks).

## Troubleshooting

**From the UI**: click **Reset to Vanilla** in the pre-launch window. Wipes mod state (hook pack, override.cfg, pass state), unchecks every mod, restarts clean. Your mods stay in `mods/`.

**If the game crashes or won't launch**:

- **Wait it out** -- after 2 failed launches, the loader auto-resets to clean state.
- **Force-disable**: create an empty file named `modloader_disabled` (no extension) in the game folder. On next launch, the loader sits idle (no mounts, no UI, no autoloads). Delete the file to re-enable. Use when the loader itself is broken and you can't reach the UI.
- **Safe-mode reset**: create an empty file named `modloader_safe_mode` (no extension) in the game folder. On next launch, the loader resets `override.cfg`, deletes pass state, clears the heartbeat, then deletes the safe-mode file.

More recovery detail (heartbeat, restart counter, crashed-Pass-2 dirty marker): [Stability-Canaries wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Stability-Canaries).

## Best Practices (for mod authors)

- **Package as `.vmz`** with forward-slash paths. Use 7-Zip, not .NET `ZipFile.CreateFromDirectory()` (writes backslashes, breaks mounting).
- **Include a `mod.txt`** at the archive root. Without it, autoloads won't run.
- **Use `super()` in lifecycle methods** (`_ready`, `_process`, etc.) when overriding vanilla scripts. Skipping it breaks other mods that override the same class.
- **Prefer hooks over file replacement** when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't. Every vanilla script is hooked automatically -- just register callbacks.
- **Test with other mods installed** and check the conflict report (Developer Mode).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: edit files in `src/`, run `./build.sh`, open PRs against `development` with Conventional Commit titles (`feat:`, `fix:`, `docs:`, etc.). Release-please handles version bumps automatically from the commit history.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder. The `mods/` folder can be removed separately.

- Settings file: `%APPDATA%\Road to Vostok\mod_config.cfg`
- Conflict log (Developer Mode only): `%APPDATA%\Road to Vostok\modloader_conflicts.txt`
- Hook pack cache: `%APPDATA%\Road to Vostok\modloader_hooks\` (regenerated on each launch)

## License

MIT. See [LICENSE](LICENSE).
