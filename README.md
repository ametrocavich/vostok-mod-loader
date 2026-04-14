# Road to Vostok - Community Mod Loader

Mod loader for Road to Vostok (Godot 4.6). Adds a pre-game UI for managing mods, load order, and updates.

## Requirements

- Road to Vostok (PC, Steam)
- Mods packaged as `.vmz` files

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

`.pck` files also work but have no mod.txt metadata, autoloads, or update checking.

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
| `[autoload]` | `Name="res://path.gd"` - instantiated as a Node after mods mount |
| `[hooks]` | Declares methods to hook. See [Hooks](#hooks). |
| `[updates] modworkshop` | ModWorkshop ID for update checking |

Mods without `mod.txt` still mount as resource packs. Their files override vanilla resources, but no autoloads run.

## Hooks

Hooks let you intercept methods on vanilla `class_name` scripts without replacing the whole file. Multiple mods can hook the same method.

### How it works

1. Declare which methods you want to hook in `mod.txt`.
2. At launch, the mod loader reads the game's binary-tokenized scripts, reconstructs the source, and rewrites the target methods with dispatch wrappers.
3. Your autoload calls `ModLoader.add_hook()` to register callbacks.

Rewritten scripts are applied via `take_over_path()`. Vanilla source is cached between launches. The cache auto-invalidates when the game executable changes.

### Declaring hooks

Add a `[hooks]` section to `mod.txt`. Keys are `res://` script paths, values are comma-separated method names:

```ini
[hooks]
"res://Scripts/Controller.gd"="Movement, Gravity"
"res://Scripts/Door.gd"="_ready, Interact"
```

Rules:
- The script needs a `class_name` declaration.
- Only methods the script defines can be hooked. Inherited methods that aren't overridden (like an un-overridden `_ready`) can't be hooked.
- Typos in method names produce a warning in the log.
- You need an `[autoload]` to call `add_hook()` at runtime.

### add_hook()

Call this from your autoload's `_ready()`:

```gdscript
ModLoader.add_hook(
    script_path: String,   # must match the key in [hooks]
    method_name: String,   # must match a declared method
    callback: Callable,    # your function
    before: bool = true    # true = before hook, false = after hook
)
```

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

[hooks]
"res://Scripts/Door.gd"="_ready"

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

[hooks]
"res://Scripts/Controller.gd"="Gravity"

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

### Limitations

- Only methods the script defines can be hooked. If a script doesn't override `_ready()`, you can't hook it.
- Hooking methods called every frame (from `_physics_process`) adds minor overhead from the dispatch wrapper.
- Source is reconstructed from Godot's binary token format. Original comments are not preserved.

### Troubleshooting

- **"add_hook() for undeclared script"** - `script_path` doesn't match any key in your `[hooks]` section.
- **"add_hook() for undeclared method"** - method name wasn't declared in `mod.txt`. The wrapper wasn't generated.
- **"Method not found in script"** - the method doesn't exist in the vanilla script. Check spelling.
- **"hooked but also replaced by..."** - another mod replaces the same script file. Hooks wrap the modded version.

Errors go to `%APPDATA%\Road to Vostok\modloader_conflicts.txt`.

## Early Autoloads

Prefix an autoload with `!` to load it before the game's own autoloads:

```ini
[autoload]
EarlySetup="!res://MyMod/EarlySetup.gd"
```

This triggers a two-pass launch. The mod loader writes the autoload to `override.cfg`, restarts the game, and your node is in the scene tree before the game's autoloads run.

Regular autoloads (without `!`) load after all mods mount.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder.

Settings: `%APPDATA%\Road to Vostok\mod_config.cfg`
Conflict log: `%APPDATA%\Road to Vostok\modloader_conflicts.txt`
