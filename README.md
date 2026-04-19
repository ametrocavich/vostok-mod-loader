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
| `[updates] modworkshop` | ModWorkshop ID for update checking |

Mods without `mod.txt` still mount as resource packs. Their files override vanilla resources, but no autoloads run.

## Hooks

The hook system preserves tetrahydroc's exact RTVModLib API surface -- `hook()` / `unhook()` / `_caller` / `skip_super()` / `frameworks_ready`, hook-name format, callback signatures. Mod code written against RTVModLib runs unchanged here.

The implementation under the hood is different. Rather than generating `Framework<Name>.gd` subclasses of vanilla and applying them via `take_over_path`, the loader rewrites vanilla source directly and ships it AT the vanilla `res://` path. Mod scripts that subclass vanilla get the same rewrite treatment shipped at their own path. Both rewrites land in a single hook pack mounted with `replace_files=true`; nothing on disk is modified.

Mods that don't use RTVModLib at all also work unchanged. Because dispatch lives inside the vanilla script, a mod that just does `extends Camera` (or uses `take_over_path`, `[script_overrides]`, etc.) inherits hook dispatch for free -- the mod author doesn't need to know the loader exists.

### Why source-rewrite instead of extends-wrapper

Both approaches aim at the same end state: hooks fire reliably regardless of whether an overhaul mod calls `super()`. They get there differently.

**The extends-wrapper approach** (tetrahydroc's RTVModLib standalone, and this loader's earlier generations) builds a subclass `FrameworkController extends Controller`, puts hook dispatch in the wrapper's method overrides, then `take_over_path`s the wrapper onto `res://Scripts/Controller.gd`. When a mod like ImmersiveXP also `take_over_path`s the same vanilla path, the framework wrapper gets applied AFTER the mod and ends up on top of the chain. Wrapper's `Movement(delta)` dispatches, then `super()` calls into the mod's `Movement`, which may or may not call `super()` to vanilla. Hooks fire regardless of the mod's super() call because the wrapper's dispatch is above both.

That works in theory. In practice it trips [Godot bug #83542](https://github.com/godotengine/godot/issues/83542) for class_name scripts that a mod has already taken over: `Resource::set_path(take_over=true)` clears `ResourceCache` but not `ScriptServer::global_classes`, so `extends "res://Scripts/Controller.gd"` compiles against the orphaned class-name registration and emits `Could not find class "Controller"`. With IXP enabled that broke four framework wrappers (Controller, Camera, Door, WeaponRig) -- the four IXP overrides. Hooks on those scripts silently stopped working.

**This loader's source-rewrite approach** avoids ever triggering #83542 by not using `extends "res://Scripts/X.gd"` at the loader level. The rewritten vanilla ships at the vanilla path itself, with `class_name` intact, so the class registry stays consistent with what's actually at the path. The class_name-swap crash path (`Resource::set_path` not clearing `global_name`) is also moot because nothing is being moved off its canonical path by the loader.

Mod-subclass rewriting plays the same role as "apply framework wrapper on top of mod via `take_over_path`": it puts hook dispatch above the mod's body so hooks fire whether or not the mod calls `super()`. The difference is that it's achieved by rewriting the mod's source file in the hook pack rather than by a runtime `take_over_path`, which keeps #83542 out of the picture even when the mod IS a class_name script.

### Scope of this approach

- **Every vanilla method gets dispatch.** No `[rtvmodlib] needs=` opt-in. The rewrite generator ships wrappers for every hookable vanilla script under `res://Scripts/` (126 in the tested RTV build, minus the skip lists for runtime-sensitive and serialized-resource scripts).
- **Mods that subclass vanilla get rewritten too.** Any `.gd` file in an enabled mod's archive whose first non-trivial line is `extends "res://Scripts/<X>.gd"` (where `<X>` is a vanilla we hook) gets the same rename+dispatch transform shipped at the mod's own path.
- **Timing.** The hook pack is mounted with `replace_files=true` at ModLoader's class-level static init, before any game autoload runs. Mod autoloads that do `load(...).take_over_path(...)` on our rewritten files inherit our wrappers via their `extends` chain.
- **Scene-preloaded vanilla deferred to lazy-compile.** Some vanilla scripts (e.g. `AISpawner.gd`) have module-scope `preload()` of PackedScenes whose `ext_resource` references other vanilla scripts (e.g. `AI_Bandit.tscn` referencing `AI.gd`). Compiling those vanillas eagerly would fire their scene preloads before mod autoloads run, baking ext_resource Script references against the pre-override cache. `take_over_path` then clears those references' paths to empty (per `Resource::set_path`), and scene instances spawn with orphan scripts. To avoid this, vanilla scripts with module-scope scene preloads are skipped from eager compile. They lazy-compile via VFS mount precedence after mod overrides have run, so scenes resolve ext_resources against the post-override cache.
- **Legacy-GDScript autofix.** Mod sibling scripts (non-subclass `.gd` files in the archive, typically preloaded from subclasses) are scanned for Godot-3-era patterns -- bodyless `if`/`elif`/`else` blocks, `tool` / `onready var` / `export var` -- and rewritten to strict-parser-compatible Godot 4 form. The fixed source lands in the hook pack overlay; the mod's `.vmz` stays untouched. Necessary because `script.reload()` inside a mod's `overrideScript` cascades strict re-parse through preloaded siblings, rejecting patterns that Godot's lenient first-compile would have tolerated.
- **Post-ready `take_over_path` not covered.** If a mod does `take_over_path` on a vanilla script AFTER `frameworks_ready` has emitted (rather than during its autoload), we rely on the incoming script's own `extends` chain to route through our rewrite. If the mod's replacement script is a file-backed subclass of the vanilla we hook, it's already been rewritten in the hook pack. If it's a fully runtime-constructed script, it won't have dispatch.
- **`RTVModLib.vmz` coexistence.** If tetrahydroc's standalone RTVModLib mod is enabled, this loader stands down so the two don't double-swap. The `Engine.get_meta("RTVModLib")` API surface is the same in both, so mods don't need to branch on which is active.

### How it works

At launch the loader walks `RTV.pck`'s file table, detokenizes every `res://Scripts/*.gd` from its compiled bytecode, and rewrites each one:

```gdscript
# Vanilla Controller.gd (simplified)
func Movement(delta):
    velocity.x = move_x * walkSpeed
    move_and_slide()

# Rewritten Controller.gd shipped in the hook pack
func _rtv_vanilla_Movement(delta):           # original body, renamed
    velocity.x = move_x * walkSpeed
    move_and_slide()

func Movement(delta):                        # new dispatch wrapper
    var _lib = Engine.get_meta("RTVModLib", null)
    if !_lib: return _rtv_vanilla_Movement(delta)
    if _lib._wrapper_active.has("controller-movement"):
        return _rtv_vanilla_Movement(delta)   # re-entry guard
    _lib._wrapper_active["controller-movement"] = true
    _lib._caller = self
    _lib._dispatch("controller-movement-pre", [delta])
    var _repl = _lib._get_hooks("controller-movement")
    if _repl.size() > 0:
        _repl[0].callv([delta])
        if !_lib._skip_super: _rtv_vanilla_Movement(delta)
    else:
        _rtv_vanilla_Movement(delta)
    _lib._dispatch("controller-movement-post", [delta])
    _lib._dispatch_deferred("controller-movement-callback", [delta])
    _lib._wrapper_active.erase("controller-movement")
```

Each rewritten script ships as THREE zip entries in `user://modloader_hooks/framework_pack.zip`:

| Entry | Purpose |
|-------|---------|
| `Scripts/Name.gd` | The rewritten source. `class_name` preserved. |
| `Scripts/Name.gd.remap` | Self-referencing `[remap]\npath="res://Scripts/Name.gd"`. Overrides the PCK's `.gd.remap -> .gdc` redirect so Godot loads our source. |
| `Scripts/Name.gdc` | Zero bytes. Shadows the PCK's compiled bytecode so Godot's GDScript loader falls back to our `.gd`. |

The pack is mounted via `ProjectSettings.load_resource_pack(zip, replace_files=true)` at ModLoader's class-level static init -- before any game autoload runs. Godot's VFS layering plus the three-entry recipe make our `res://Scripts/Camera.gd` win over the PCK's without modifying `RTV.pck` or any `.vmz` on disk.

### Mod subclass rewriting

Mods like IXP ship scripts that `extends "res://Scripts/Camera.gd"` and override a subset of methods. The loader also rewrites those at codegen time:

- Scan every enabled mod's `.vmz`. Find `.gd` files whose first non-trivial line is `extends "res://Scripts/<X>.gd"` where `<X>` is a vanilla we hook.
- Apply the same rename+dispatch transform, but with a distinct prefix (`_rtv_mod_<name>` instead of `_rtv_vanilla_<name>`) so the mod body doesn't shadow vanilla's via virtual dispatch.
- Ship the rewritten mod script at its own path (e.g. `ImmersiveXP/Camera.gd`) in the same hook pack with `replace_files=true`. The mod's `.vmz` is never modified.
- When IXP's autoload calls `load("res://ImmersiveXP/Camera.gd")`, mount precedence returns our rewritten version. IXP's existing `overrideScript()` logic then `take_over_path`s our rewritten IXP Camera onto the vanilla path. Dispatch fires from IXP's wrapper regardless of whether IXP's body calls `super()`.

A re-entry guard (`_wrapper_active[hook_base]`) prevents double dispatch when the mod body DOES call `super()` into vanilla's wrapper -- vanilla sees the guard set, skips dispatch, and just runs the vanilla body. One dispatch per logical call regardless of chain depth.

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
- **Resource / data scripts skipped**: `*Data.gd` files (SlotData, ItemData, etc) and serialized resources aren't wrapped to avoid breaking save files.
- **Mod rewriting is literal `extends` only**: a mod's `.gd` file gets rewritten only if its first non-trivial line is `extends "res://Scripts/X.gd"`. Computed / class-name extends aren't detected.
- **Autofix scope is narrow**: legacy-GDScript autofix handles bodyless `if`/`elif`/`else` blocks and `tool` / `onready var` / `export var` annotations. Not handled: `setget`, typed `export(Type) var`, and other Godot 3 specifics. Mods using those patterns in preloaded sibling scripts may still hit strict-reload failures.

### Hook troubleshooting

- **`hook()` returns `-1`**: another mod owns the replace slot. Use `get_replace_owner()` to detect, then fall back to `-pre` or `-post`.
- **Callback never fires**: you registered before `frameworks_ready` emitted. Always `await lib.frameworks_ready` if `_is_ready` is false. All hookable scripts are wrapped by default, so no opt-in is needed.
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

**From the mod loader UI:** click **Reset to Vanilla** in the pre-launch window. Wipes the hook pack, pass state, override.cfg mod entries, and unchecks every mod; restarts into a clean vanilla run. Your mods stay in `mods/`.

**If the game crashes or gets stuck:**

- **Wait it out.** After 2 failed launches, the mod loader automatically resets to a clean state.
- **Disable ModLoader entirely:** Create an empty file named `modloader_disabled` (no extension) in the game folder. On next launch, the mod loader skips all work -- no archives mount, no UI shows, no autoloads run. Delete the file to re-enable. Use this when ModLoader itself is broken and you can't reach the UI.
- **Manual safe-mode reset:** Create an empty file named `modloader_safe_mode` (no extension) in the game folder. On next launch, the mod loader resets state and deletes the file.
- **Full reset:** Delete `override.cfg` from the game folder and replace it with a fresh copy from the mod loader release.

**Crash-safe recovery:** If the game is killed during the two-pass restart phase (before Pass 2 finishes applying the hook pack), ModLoader leaves a `user://modloader_pass2_dirty` marker. Next cold boot detects it and force-wipes hook pack + override.cfg + pass state before retrying -- so a half-written hook pack can't poison the next launch.

## Conflict Report

With Developer Mode enabled, a copy of the runtime log is written to `%APPDATA%\Road to Vostok\modloader_conflicts.txt` after each launch. Look for these markers:

| Message | Meaning |
|---------|---------|
| **CONFLICT: `<path>`** | Two or more mods ship the same `res://` path. Later loader wins. Adjust priorities to pick a winner. |
| **CONFLICT: re-declares class_name** | Two scripts share a `class_name`. Usually a mod bundled its own `.godot/global_script_class_cache.cfg`. |
| **DATABASE OVERRIDE** | A mod replaced `Scripts/Database.gd`. Normal for overhauls, may block other mods' scene overrides. |
| **BAD ZIP** | Backslash file paths in the archive. Re-pack with 7-Zip. |

The summary block also lists how many framework overrides the loader applied this run and which hooks had registrations.

## Best Practices

- **Package as `.vmz`** with forward-slash paths. Use 7-Zip, not .NET `ZipFile.CreateFromDirectory()` (writes backslashes).
- **Include a `mod.txt`** at the archive root. Without it, autoloads won't run.
- **Use `super()` in lifecycle methods.** Skipping it breaks other mods that override the same class.
- **Prefer hooks over file replacement** when you only need to modify a few methods. Hooks compose across mods; file replacement doesn't. All vanilla scripts are hooked automatically, just register callbacks through `Engine.get_meta("RTVModLib")`.
- **If you replace Database.gd**, every `preload()` path must exist or the game breaks.
- **`UpdateTooltip()` is inventory-only.** World-item tooltips come from `HUD._physics_process` reading `gameData.tooltip`.
- **Test with other mods installed** and check the conflict report.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch model, Conventional Commit format, and build instructions. The short version: edit files in `src/`, run `./build.sh`, open PRs against the `development` branch with titles like `feat: ...` or `fix: ...`.

## Uninstalling

Delete `override.cfg` and `modloader.gd` from the game folder. The `mods` folder and its contents can be removed separately.

Settings: `%APPDATA%\Road to Vostok\mod_config.cfg`
Conflict log: `%APPDATA%\Road to Vostok\modloader_conflicts.txt`

---

## Recovery (Technical Details)

- **Heartbeat file:** `user://modloader_heartbeat.txt` is written at launch and deleted on success. If it persists, the mod loader increments a crash counter. After 2 crashes, it wipes `override.cfg` and all two-pass state.
- **Pass 2 dirty marker:** `user://modloader_pass2_dirty` is written at the start of Pass 2 and deleted when Pass 2 finishes. If present on next cold boot, Pass 2 was interrupted (force-quit, crash, power loss) and the hook pack may be half-written. Static init detects the marker and force-wipes state before ModLoader runs.
- **Disabled flag:** An empty `modloader_disabled` file in the game folder makes ModLoader sit idle for that session. Static init resets override.cfg, pass state, and the hook pack, then returns immediately. The UI never shows. Delete the file to re-enable.
- **Safe mode flag:** An empty `modloader_safe_mode` file triggers a one-shot full reset on next launch, then is deleted.
- **State files:** `user://mod_pass_state.cfg` stores archive paths + hook pack path for the two-pass restart. Cleared by the Reset button, the disabled flag, by entering zero-mod state via the UI, or by a Pass 2 crash.

---

## Engine Compatibility

Tested against Godot 4.6.1. Reviewed against the Godot 4.7 milestone as of April 2026 (feature freeze imminent, dev snapshot 5 released) -- no breaking changes identified within Road to Vostok's first-party mod support window.

If a future Godot version changes how `res://` paths resolve inside mounted resource packs, the hook pack's mount-precedence recipe (`.gd` + `.remap` + empty `.gdc`) will stop winning over the PCK. The `[STABILITY] VFS canary FAILED` alarm trips on first launch and the loader logs a critical error. Users can fall back to tetrahydroc's standalone `RTVModLib` mod, which uses the extends-wrapper approach (`Framework<Name>.gd` subclasses applied at runtime via `take_over_path`). The fallback handles the typical case, but has a known issue with overhaul mods like ImmersiveXP that extend vanilla via `class_name` (Godot [#83542](https://github.com/godotengine/godot/issues/83542)) -- the exact bug our current in-place rewrite sidesteps.

The three specific engine behaviors that would trigger the fallback:

1. **`load_resource_pack(replace_files=true)`** stops letting later mounts override earlier ones at the same `res://` path.
2. **`.gd.remap`** resolution order changes so a self-referencing remap no longer preempts the PCK's redirect to compiled `.gdc`.
3. **Empty `.gdc`** stops silently falling back to compiling the sibling `.gd`.

Everything else in the loader -- mod discovery, autoload ordering via `[autoload_prepend]`, the hook API, crash recovery, the pre-game UI -- is unaffected by either scenario.

---

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
