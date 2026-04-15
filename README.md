# Road to Vostok - Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game UI for managing mods, load order, and updates.

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz` or `.pck` files

## Installation

1. Copy `override.cfg` and `modloader.gd` into the game folder:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\
   ```

2. Create a `mods` folder if it doesn't exist:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Road to Vostok\mods\
   ```

3. Drop `.vmz` mod files into `mods/`.

4. Launch the game. The mod loader UI appears before the main menu.

## Installing Mods

Drop `.vmz` files into the `mods` folder. They show up automatically on next launch.

`.pck` files also work but have no mod.txt metadata, autoloads, or update checking. If a mod was distributed as a `.zip`, rename it to `.vmz`.

| Format | Notes |
|--------|-------|
| `.vmz` | Road to Vostok's native mod format (renamed zip) |
| `.pck` | Godot PCK - mount only, no mod.txt or autoloads |

## Launcher UI

The mod loader opens with two tabs:

**Mods** - Lists detected mods with checkboxes and a priority spinbox. Higher priority loads later and wins file conflicts. The load order panel on the right updates in real time.

**Updates** - If mods include ModWorkshop info in `mod.txt`, you can check for and download updates here.

Click **Launch Game** or close the window to start.

## mod.txt

Mods can include a `mod.txt` at the root of their archive. All string values need to be quoted.

```ini
[mod]
name="My Mod"
id="my_mod"
version="1.0.0"
priority=0

[autoload]
MyModMain="res://MyModMain/Main.gd"

[updates]
modworkshop=12345
```

| Field | Description |
|---|---|
| `name` | Display name in the UI |
| `id` | Unique ID. Duplicates are skipped. |
| `version` | Version string for update comparison |
| `priority` | Load order weight. Higher = loads later = wins conflicts. Default 0. |
| `[autoload]` | `Name="res://path.gd"` - instantiated as a Node after mods mount. Prefix with `!` for [early autoloads](#early-autoloads). |
| `[hooks]` | Optional. See [Hooks](#hooks). |
| `[updates] modworkshop` | ModWorkshop ID for update checking |

Mods without `mod.txt` still mount as resource packs. Their files override vanilla resources, but no autoloads run.

## Hooks

Hooks let you intercept methods on vanilla `class_name` scripts without replacing the whole file. Multiple mods can hook the same method.

### How it works

At startup the mod loader detokenizes every `class_name` script in the game, wraps each method with a dispatch imposter, and applies the result via `take_over_path()`. Mods just call `add_hook()` from their autoload. No `[hooks]` section in mod.txt needed.

Unhooked methods have a fast-path that skips the dispatch entirely (single dictionary lookup, no array allocation). Only methods with active hooks pay the full dispatch cost.

Vanilla source is cached between launches. The cache rebuilds automatically when the game updates or the modloader version changes.

### add_hook()

Call this from your autoload's `_ready()`:

```gdscript
ModLoader.add_hook(
    script_path: String,   # res:// path to the script
    method_name: String,   # name of the method to hook
    callback: Callable,    # your function
    before: bool = true    # true = before hook, false = after hook
)
```

The script must have a `class_name` and the method must be defined in that script (not just inherited).

### Before hooks

Fires before the vanilla method. Receives the instance and an args array:

```gdscript
func my_hook(instance: Object, args: Array) -> Variant:
    # instance - the object (null for static methods)
    # args - [arg0, arg1, ...] matching the method's parameters
    #
    # Mutate args in-place to change what vanilla receives:
    #   args[0] = new_value
    #
    # Return true to skip the vanilla method entirely.
    pass
```

### After hooks

Fires after the vanilla method. Gets the instance, args, and a result wrapper:

```gdscript
func my_hook(instance: Object, args: Array, result: Array) -> void:
    # result - [return_value] or [] for void methods
    # Mutate result[0] to change the return value.
    pass
```

### Example: faster doors

Makes doors open 10x faster by changing `openSpeed` after vanilla `_ready` runs.

**mod.txt:**
```ini
[mod]
name="Fast Doors"
id="fast_doors"
version="1.0.0"

[autoload]
FastDoors="res://FastDoors/Main.gd"
```

**FastDoors/Main.gd:**
```gdscript
extends Node

func _ready() -> void:
    ModLoader.add_hook(
        "res://Scripts/Door.gd",
        "_ready",
        _on_door_ready,
        false  # after hook
    )

func _on_door_ready(instance: Object, args: Array, result: Array) -> void:
    if instance and "openSpeed" in instance:
        instance.openSpeed = 40.0  # default is 4.0
```

### Example: low gravity

Halves gravity by mutating the delta argument on every physics frame.

**mod.txt:**
```ini
[mod]
name="Low Gravity"
id="low_gravity"
version="1.0.0"

[autoload]
LowGravity="res://LowGravity/Main.gd"
```

**LowGravity/Main.gd:**
```gdscript
extends Node

func _ready() -> void:
    ModLoader.add_hook(
        "res://Scripts/Controller.gd",
        "Gravity",
        _low_gravity,
        true  # before hook
    )

func _low_gravity(instance: Object, args: Array) -> void:
    if args.size() > 0:
        args[0] = args[0] * 0.5
```

### Skipping vanilla

Return `true` from a before hook to prevent the original method from running:

```gdscript
func _skip_loot(instance: Object, args: Array) -> bool:
    return true  # vanilla GenerateLoot won't run
```

Be careful with skip hooks on methods that manage game state (like `Jump` or `Movement`). Skipping a method that other code depends on can cause side effects.

### Multiple mods on the same method

- Before hooks run in load order (by `priority`). If one returns `true`, later before hooks, the vanilla method, and after hooks are all skipped.
- When nothing skips, all after hooks run in order.
- Registering the same Callable twice is a no-op.

### Hooks vs file replacement

| | Hooks | File replacement |
|---|---|---|
| Multiple mods per script | Yes | Last loaded wins |
| Survives game updates | Yes, cache rebuilds | May break |
| Scope | Per-method | Whole file |

### Backwards compatibility

The `[hooks]` section in mod.txt is still recognized but no longer required. If present, entries are logged as hints. Mods using the old format continue to work without changes.

### Limitations

- **Typed arrays**: Scripts whose `class_name` is used as a typed array element type (`Array[SlotData]`, `Array[ItemData]`, etc) can't be wrapped. `take_over_path()` breaks Godot's internal type identity check for typed arrays ([godotengine/godot#97433](https://github.com/godotengine/godot/issues/97433)). The modloader detects these automatically and skips them. Currently 9 class names are excluded, mostly data/save classes. If a future game update adds typed array references to a gameplay script, hooks on that script would stop firing.
- **Own methods only**. If a script doesn't override `_ready()`, you can't hook it. Only methods the script defines (not inherited) are wrapped.
- **Per-frame overhead**. Unhooked methods cost one dictionary lookup per call. Methods with active hooks do the full dispatch (array allocation, callable iteration). On 314 wrapped methods with zero hooks active, there's no measurable performance impact.
- **Source reconstruction**. Scripts are reconstructed from Godot's binary token format. Original comments and formatting are not preserved. The detokenizer handles Godot 4.0-4.6 token formats.

### Hook troubleshooting

- **"add_hook() for unwrapped script"** - the script path isn't a wrapped `class_name` script. Check the path and that the script has a `class_name` declaration.
- **"Cannot assign contents of Array[Object] to Array[Object]"** - a script whose `class_name` is used in typed arrays was wrapped. Shouldn't happen with auto-detection. Report an issue if it does.
- **"hooked but also replaced by..."** - another mod replaces the same script file. Hooks wrap the modded version, not vanilla.
- **Hook doesn't fire** - make sure you're calling `add_hook()` from `_ready()` in an autoload, not from a scene script. The hook needs to be registered before the method gets called.
- **"Compiler bug: unresolved assign"** - Godot engine bug during compilation of certain scripts (e.g. KnifeRig.gd). Non-fatal, the script still works.

Hook cache: `%APPDATA%\Road to Vostok\modloader_hooks\`
To force a full rebuild, delete the `modloader_hooks` folder and `mod_pass_state.cfg`.

## Early Autoloads

Prefix an autoload with `!` to load it before the game's own autoloads:

```ini
[autoload]
EarlySetup="!res://MyMod/EarlySetup.gd"
```

This triggers a two-pass launch. The mod loader writes the autoload to `override.cfg`, restarts the game, and your node is in the scene tree before the game's autoloads run.

Regular autoloads (without `!`) load after all mods mount. Only use `!` when your mod genuinely needs to run before game autoloads.

## Troubleshooting

If the game crashes or gets stuck after enabling mods:

- **Wait it out.** After 2 failed launches, the mod loader automatically resets to a clean state.
- **Manual reset:** Create an empty file named `modloader_safe_mode` (no file extension) in the game folder. On next launch, the mod loader resets and deletes the file.
- **Full reset:** Delete `override.cfg` from the game folder and replace it with a fresh copy from the mod loader release.

## Conflict Report

With Developer Mode enabled, a full conflict log is written to `%APPDATA%\Road to Vostok\modloader_conflicts.txt` after each launch.

| Message | Meaning |
|---------|---------|
| **CONFLICT** | Two mods ship the same file. Last-loaded wins. Adjust priorities. |
| **SCRIPT CONFLICT** | Two mods both `take_over_path()` the same script. Hard incompatibility. |
| **CHAIN OK / CHAIN BROKEN** | Override chain via `super()`. OK means mods stack cleanly, BROKEN means one skips `super()`. |
| **DATABASE OVERRIDE** | A mod replaced `Database.gd`. Normal for overhauls, may block other mods' scene overrides. |
| **OVERHAUL** | 5+ core script overrides. Likely incompatible with other overhaul mods. |
| **NO SUPER** | Lifecycle method override without `super()`. Breaks other mods in the chain. |
| **BAD ZIP** | Backslash file paths in the archive. Re-pack with 7-Zip. |

## Best Practices

- **Package as `.vmz`** with forward-slash paths. Use 7-Zip, not .NET `ZipFile.CreateFromDirectory()` (writes backslashes).
- **Include a `mod.txt`** at the archive root. Without it, autoloads won't run.
- **Use `super()` in lifecycle methods.** Skipping it breaks other mods that override the same class.
- **Prefer hooks over file replacement** when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't.
- **If you replace Database.gd**, every `preload()` path must exist or the game breaks.
- **`UpdateTooltip()` is inventory-only.** World-item tooltips come from `HUD._physics_process` reading `gameData.tooltip`.
- **Test with other mods installed** and check the conflict report.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder. The `mods` folder and its contents can be removed separately.

Settings: `%APPDATA%\Road to Vostok\mod_config.cfg`
Conflict log: `%APPDATA%\Road to Vostok\modloader_conflicts.txt`

---

## Recovery (Technical Details)

- **Heartbeat file:** `user://modloader_heartbeat.txt` is written at launch and deleted on success. If it persists, the mod loader increments a crash counter. After 2 crashes, it wipes `override.cfg` and all two-pass state.
- **Safe mode:** An empty `modloader_safe_mode` file in the game folder triggers a full reset on next launch.
- **State files:** `user://mod_pass_state.cfg` stores archive paths for the two-pass restart. Deleted after successful Pass 2.

---

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
