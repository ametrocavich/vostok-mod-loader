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

### Guardrails

The launcher does a static scan of every mod's source for a small set of patterns that have been seen in actual malicious mods (obfuscated string decoding paired with process spawning, anti-debug crashes, ransomware-setup calls). Mods that match get a small red "suspicious code" tag in the list, and clicking **Launch Game** with one enabled pops a confirmation dialog before the game starts.

This is **not** a virus scanner. It catches lazy / copy-paste attacks; a determined attacker with the modloader source can write around the patterns. Loading is never silently blocked -- you can confirm and launch any mod. The scanner exists to slow down the obvious cases, nothing more. Always install mods from sources you trust.

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

### Opt-in hook declarations

v2.4.0 uses an opt-in model: a modlist that declares nothing loads byte-identical to a vanilla setup (no wrap, no rewrite, no hook pack). Declarations turn on specific parts of the system.

```ini
[hooks]
res://Scripts/Interface.gd = _ready, update_tooltip
res://Scripts/Controller.gd = Movement

[script_extend]
res://Scripts/Camera.gd = res://MyMod/MyCamera.gd

[registry]
; declaring this section is enough to enable lib.register() / lib.override()
```

- **`[hooks]`** -- list methods by vanilla script path. Those methods get dispatch wrappers at runtime so your `.hook(...)` callbacks fire. Only declared methods are wrapped; everything else in the script stays vanilla. Scanning `.hook(...)` calls in your source also enrolls the corresponding method.
- **`[script_extend]`** -- a full-script replacement that chains via Godot's `extends` resolution. Multiple mods can extend the same vanilla script; take_over_path runs in priority order, each override's `extends` resolves to the prior chain tip. `[script_overrides]` is kept as a legacy alias.
- **`[registry]`** -- declaring this section enables `lib.register()` / `lib.override()` on Database.gd. Without it, the registry helpers never get injected and those calls return `false`.

Full schema (including `[rtvmodlib] needs=`, the `!` prefix semantics, and packaging gotchas): see the [Mod-Format wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Mod-Format).

### Migrating from v3.0.0

v3.0.0 inferred the wrap surface from `extends`, `take_over_path`, and a pinned list, then rewrote mod source to auto-fire hooks even when mods replaced a method without calling `super()`. v2.4.0 removes the inference and the mod-source rewrite. If your mod relied on either, you need to declare intent:

- If your mod calls `.hook(...)` but never declared a `[hooks]` section: no change needed -- scanner picks up the `.hook()` call.
- If your mod's override replaced a vanilla method fully and expected hooks to fire via the old rewrite: add `super.method(...)` at the start of the override, OR add a `[hooks]` entry for that method.
- If your mod used `lib.register()` / `lib.override()` without declaring `[registry]`: add the `[registry]` section.

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

Full API reference, dispatch semantics, and three-entry pack recipe: [Hooks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Hooks).

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
- **Use `super()` in lifecycle methods** (`_ready`, `_process`, etc.) when overriding vanilla scripts. Skipping it breaks hook composition for other mods that hooked that method.
- **Declare `[hooks]` or call `.hook(...)`** on the vanilla methods you care about. In v2.4.0, only declared methods get dispatch wrappers -- there's no auto-wrap surface anymore.
- **Prefer hooks over file replacement** when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't.
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
