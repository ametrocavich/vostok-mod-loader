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
| `[rtvmodlib]` | `needs=Controller,Camera,...` to opt in to framework wrappers. See [Hooks](#hooks). |
| `[updates] modworkshop` | ModWorkshop ID for update checking |

Mods without `mod.txt` still mount as resource packs. Their files override vanilla resources, but no autoloads run.

## Hooks

The hook system uses tetrahydroc's exact RTVModLib API. The wrapper generation pattern and the examples in this section are his design and work. A mod loader should provide a stable hook layer for mods to build on, so the codegen and runtime are bundled into this loader's baseline. The same hook code works against either implementation.

Mods opt in per-script via `[rtvmodlib] needs=` in mod.txt and register callbacks at runtime through `Engine.get_meta("RTVModLib")`.

### How it works

At launch the loader detokenizes every `res://Scripts/*.gd`, generates a `Framework<Name>.gd` wrapper for each method, and zips them into `user://modloader_hooks/framework_pack.zip` mounted at `res://modloader_hooks/`. Each wrapper extends the vanilla script and emits dispatch calls (pre / post / replace / deferred-callback) around every instance method.

Wrappers are inert until a mod requests them. A wrapper is only applied to its vanilla script if at least one enabled mod declares `[rtvmodlib] needs=<ScriptName>`. Application uses `take_over_path()` for non-class_name scripts and a `node_added` swap for class_name scripts.

If `RTVModLib.vmz` (tetrahydroc's standalone mod) is enabled, the loader stands down so the two don't double-swap. The API surface is the same in both, so mods don't need to know which is active.

### Opting in

Add a `[rtvmodlib]` section to `mod.txt`:

```ini
[rtvmodlib]
needs="controller,camera,door"
```

Names are case-insensitive and match the script filename without `.gd`. Only requested scripts get wrapped; everything else stays vanilla.

### Registering hooks

`Engine.get_meta("RTVModLib")` returns the hook registry once the modloader has registered itself. The wrappers aren't applied until later in the same frame, so connect to `frameworks_ready` (or call your handler directly if `_is_ready` is already true):

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

func _on_jump_pre():
    _lib._caller.jumpVelocity = 20.0
```

### Hook names

Format: `<scriptname>-<methodname>[-suffix]`, all lowercase. The script name is the filename without `.gd`. The method name is the original, lowercased, including any leading underscore.

| Suffix | Behavior |
|--------|----------|
| `-pre` | Before the original. Stackable across mods. |
| `-post` | After the original. Stackable. |
| `-callback` | After the original via `call_deferred`. Stackable. |
| (none) | Replace. First-registered owns it; later registrations return `-1`. |

Examples: `pickup-_ready-post`, `controller-jump-pre`, `door-interact-callback`, `hitbox-applydamage` (replace).

### API

All members live on the meta object returned by `Engine.get_meta("RTVModLib")`.

| Member | Type | Purpose |
|--------|------|---------|
| `frameworks_ready` | signal | Emitted once after wrappers are mounted and applied. |
| `_is_ready` | bool | True once `frameworks_ready` has emitted. |
| `_caller` | Node | The instance dispatching the current hook. Valid only inside a callback. |
| `_skip_super` | bool | Set by `skip_super()` during a replace hook. |
| `hook(name, callback, priority=100)` | int | Register. Returns hook id, or `-1` if a replace hook is already owned. Lower priority runs first (default 100). |
| `unhook(id)` | void | Remove by id. |
| `has_hooks(name)` | bool | Any registrations at this name. |
| `has_replace(name)` | bool | Replace hook registered at this bare name. |
| `get_replace_owner(name)` | int | Owner id, or `-1` if none. Lets a mod detect a conflict and fall back to `-pre` / `-post`. |
| `skip_super()` | void | Inside a replace hook, prevents the original method from running. |
| `seq()` | int | Monotonic dispatch counter (debug). |

### Callback signatures

Callbacks receive the same argument list as the wrapped method. The source instance is in `_caller`:

```gdscript
func _on_movement_pre(delta: float) -> void:
    var ctrl = Engine.get_meta("RTVModLib")._caller
    ctrl.walkSpeed = 10.0
```

For zero-arg methods (like `_ready`), the callback takes no arguments:

```gdscript
func _on_ready_post() -> void:
    var pickup = Engine.get_meta("RTVModLib")._caller
    pickup.gravity_scale = 0.5
```

### Replace hooks

```gdscript
_lib.hook("hitbox-applydamage", _god_mode)

func _god_mode(damage):
    _lib.skip_super()  # original ApplyDamage won't run
```

Only one replace per name. `hook()` returns `-1` if another mod already owns the slot. Use `get_replace_owner()` or check the return value and fall back to a `-pre` or `-post` hook so two mods can coexist.

### Examples

The three examples below are tetrahydroc's, copied from his RTVModLib README.

#### AI Kill Tracker

```gdscript
extends Node

# Tracks AI kills and prints a summary

var _lib = null
var _kills: Dictionary = {}  # ai_type -> count

func _ready():
    if Engine.has_meta("RTVModLib"):
        var lib = Engine.get_meta("RTVModLib")
        if lib._is_ready:
            _on_lib_ready()
        else:
            lib.frameworks_ready.connect(_on_lib_ready)

func _on_lib_ready():
    _lib = Engine.get_meta("RTVModLib")
    _lib.hook("ai-death-post", _on_ai_death, 50)
    print("Kill Tracker: Loaded")

func _on_ai_death(direction = null, force = null):
    # AI.Death(direction, force) was called -- an AI just died
    _kills["total"] = _kills.get("total", 0) + 1
    print("Kills: " + str(_kills["total"]))
```

`mod.txt`:

```ini
[mod]
name="Kill Tracker"
id="kill-tracker"
version="1.0.0"

[autoload]
KillTracker="res://KillTracker/Main.gd"

[rtvmodlib]
needs="ai"
```

#### Custom Trader Prices

```gdscript
extends Node

# Doubles all trader prices

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
    _lib.hook("interface-calculatedeal-post", _modify_prices)

func _modify_prices():
    # Runs after CalculateDeal -- modify the displayed values
    var scene = get_tree().current_scene
    var interface = scene.get_node_or_null("Core/UI/Interface")
    if interface and interface.requestValue:
        var current = int(interface.requestValue.text)
        interface.requestValue.text = str(current * 2)
```

#### Replace Hook with Fallback

```gdscript
extends Node

# Custom loot generation that falls back to vanilla if conditions aren't met

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
    var id = _lib.hook("lootcontainer-generateloot", _custom_loot)
    if id == -1:
        # Another mod already owns this replace hook
        print("MyMod: GenerateLoot replace hook rejected, using pre/post instead")
        _lib.hook("lootcontainer-generateloot-post", _modify_loot_after)

func _custom_loot():
    if some_condition:
        _lib.skip_super()  # Skip vanilla loot gen
        # Generate custom loot...
    # If skip_super() not called, vanilla GenerateLoot runs normally
```

### Limitations

- **Wrappers only over methods the script defines**. Inherited methods aren't wrapped.
- **Static methods aren't wrapped**.
- **Source reconstruction**: scripts are detokenized from binary tokens. Comments and exact formatting are not preserved. Covers Godot 4.0-4.6.
- **Resource / data scripts skipped**: `*Data.gd` files (SlotData, ItemData, etc) and serialized resources aren't wrapped.
- **No `ClassName.new()` interception**: class_name scripts are swapped via `node_added`, which catches scene-instantiated nodes but not direct `Foo.new()` constructions.

### Hook troubleshooting

- **`hook()` returns `-1`**: another mod owns the replace slot. Use `get_replace_owner()` to detect, then fall back to `-pre` or `-post`.
- **Callback never fires**: either the framework isn't requested in `[rtvmodlib] needs=`, or you registered before `frameworks_ready` emitted. Always `await lib.frameworks_ready` if `_is_ready` is false.
- **`_caller` is null**: read outside a callback, or in a `-callback` (deferred) hook after the source was freed. Snapshot `_caller` synchronously and reference the snapshot.
- **Hook name doesn't match anything**: format is `<scriptname>-<methodname>[-suffix]` lowercase. Underscore-prefixed methods keep the underscore: `pickup-_ready-post`, not `pickup-ready-post`.
- **`hooked but also replaced by ...`**: another mod replaces the same vanilla script via `[script_overrides]`. The wrapper's `super()` flows into the override, not vanilla.

Hook cache: `%APPDATA%\Road to Vostok\modloader_hooks\`
The cache is regenerated every launch. To force a clean state, delete the `modloader_hooks` folder.

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
- **Prefer hooks over file replacement** when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't. Declare the scripts you need in `[rtvmodlib] needs=`.
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
