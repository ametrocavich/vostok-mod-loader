# Hooks

The hook system lets mods intercept vanilla method calls -- run code before/after, replace the implementation entirely, or receive a deferred callback. The public API matches tetrahydroc's RTVModLib mod exactly; the implementation under the hood is source rewriting.

## Quick start -- the 95% case

If your mod calls `.hook("controller-jump-pre", my_callback)` directly in its own source, **you don't need any `mod.txt` declaration**. The loader scans your `.gd` files at load time, sees the `.hook()` call, and enrolls `Controller.gd :: jump` in the wrap surface automatically. At pack generation the vanilla `Controller.jump` gets a dispatch wrapper, and your callback fires.

```gdscript
# res://MyMod/Main.gd
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
    _lib.hook("controller-jump-pre", _on_jump)

func _on_jump(_delta):
    _lib._caller.jumpVelocity = 20.0
```

```ini
# res://MyMod/mod.txt
[mod]
name="Big Jump"
id="big_jump"
version="1.0.0"

[autoload]
BigJump="res://MyMod/Main.gd"
```

That's the whole mod. No `[hooks]` section. No framework imports. The scanner does the enrollment.

## Opt-in model

v3.0.1 uses an opt-in model: **a modlist that declares nothing produces no wrap, no rewrite, and no hook pack** -- mods run against byte-identical vanilla scripts. Declarations turn individual subsystems on:

| Trigger | Effect |
|---|---|
| `.hook("stem-method-...")` call in a mod's source | Scanner enrolls that method on `res://Scripts/<Stem>.gd` |
| `ModLoader.add_hook(path, method, cb, before)` from an early autoload's `_init` | Shim translates to a native hook + enrolls path |
| `[hooks]` in `mod.txt` | Manually enroll methods (or `= *` for all) |
| `[registry]` in `mod.txt` | Turn on the registry (see [Registry](Registry)) |
| `[script_extend]` in `mod.txt` | Chain-by-extends overrides |

The rewrite surface equals the union of those triggers. When no user mod declares anything, the loader logs `[RTVCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]) -- user mods run against unmodified vanilla (v2.1.0-equivalent). Pack contains core hooks only.` at boot. User mods' vanilla targets stay byte-identical; the pack contains only a core-owned wrap on `Menu.gd :: _ready` that injects the launcher's "Mods" button into the main menu. When no mods are loaded at all, pack generation is skipped entirely (no file written).

### `[hooks]` escape hatch

Some mods can't get auto-enrolled. Examples:

- `ModLoader.add_hook(path, method, cb, before)` called from a runtime autoload (not `!`-prefixed). Pack generation has already run by then.
- Hook registrations that happen via a callback passed in from a different autoload -- the `.hook()` call site isn't in the registering mod's own source.
- Hooks the mod author wants wrapped but doesn't plan to register until gameplay events fire.

For these, declare the vanilla script path in `mod.txt`:

```ini
[hooks]
res://Scripts/Interface.gd = _ready, update_tooltip   # specific methods
res://Scripts/Controller.gd = *                       # wildcard -- all methods
res://Scripts/Camera.gd =                             # empty value == *
```

Method names in the list are case-insensitive (normalized to lowercase on write). The wildcard leaves the inner mask empty, which the generator reads as "wrap every non-static method."

### `ModLoader.add_hook()` compat

Mods written against [`godot-mod-loader`](https://github.com/GodotModding/godot-mod-loader) call `ModLoader.add_hook(script_path, method_name, callback, is_before)`. The loader provides a compat shim at [hooks_api.gd:80](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L80) that:

1. Builds the native hook name: `<stem>-<method>-<pre|post>` (all lowercase).
2. Enrolls `script_path` into `_hooked_methods` so the wrap surface picks it up.
3. Calls `hook(hook_name, callback, 100)`.

**Timing gotcha**: the shim enrolls the path *when called*, but `_generate_hook_pack` reads `_hooked_methods` at the top of Pass 1 (or Pass 2 in the restart flow). `add_hook()` calls from a mod's runtime autoload arrive too late -- the hook is registered, but there's no wrapper to dispatch it. To get wrapped, either:

- Call `add_hook()` from a `!`-prefixed early autoload's `_init` (runs before pack generation).
- Declare the path in `[hooks]` with `= *` in `mod.txt` so the wrap mask is populated statically regardless of when the autoload runs.

## Public API

Mods reach the loader via `Engine.get_meta("RTVModLib")`. Source: [src/hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd).

```gdscript
var lib = Engine.get_meta("RTVModLib")

# Wait until all mod autoloads finished overrideScript calls.
await lib.frameworks_ready

var id = lib.hook("controller-_physics_process-pre", func(delta): print(delta), 100)
lib.unhook(id)

if lib.has_replace("weaponrig-shoot"):
    print("another mod already replaced shoot")
```

### Methods

| Method | Purpose |
|---|---|
| `hook(name, callback, priority=100) -> int` | Register a callback, return its id. Replace hooks are single-owner (returns -1 if already taken) |
| `unhook(id) -> void` | Remove a hook by id (linear scan across all hook names) |
| `add_hook(path, method, cb, before=true) -> int` | godot-mod-loader compat wrapper around `hook()` + wrap-mask enrollment |
| `has_hooks(name) -> bool` | Any callbacks registered at this name? |
| `has_replace(name) -> bool` | Is a replace hook registered at this bare name? |
| `get_replace_owner(name) -> int` | Returns id of the current replace owner, or -1 |
| `skip_super() -> void` | Inside a replace callback: prevent the vanilla body from running on return |
| `seq() -> int` | Monotonic dispatch counter, useful for tests |
| `static version() -> String` | `MODLOADER_VERSION` |
| `static major_version() -> int` | Parse major from `MODLOADER_VERSION` |
| `static minor_version() -> int` | Same, minor |
| `static patch_version() -> int` | Same, patch |

### Signal

- `frameworks_ready` -- emitted once after all mod autoloads finished. Mods that depend on overrideScript completion should `await` this.

## Hook names

Hook names follow this convention:

```
<scriptname>-<methodname>[-pre|-post|-callback]
```

Both `scriptname` and `methodname` are lowercased. `scriptname` is the `.gd` filename without extension. `Controller.gd`'s `_physics_process` method becomes `controller-_physics_process`.

Suffixes:

| Suffix | Fires | Args | Return? |
|---|---|---|---|
| `-pre` | Before vanilla body (or before replace) | Same as the vanilla method | Ignored |
| (none) | In place of vanilla. **First registration wins, subsequent registrations are rejected** (returns -1). Within a replace callback, call `lib.skip_super()` to suppress vanilla | Same as vanilla | Return value becomes the method's return |
| `-post` | After vanilla (or after replace if no `skip_super`) | Same as vanilla | Ignored |
| `-callback` | Deferred via `Callable.bindv(args).call_deferred()` | Same as vanilla | Ignored |

## Dispatch semantics

The dispatch wrapper template lives at [rewriter.gd:1023 `_rtv_dispatch_inline_src`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L1023). For every hookable vanilla method, the rewriter emits roughly this structure:

```
func <name>(args):
    var _lib = Engine.get_meta("RTVModLib") if Engine.has_meta("RTVModLib") else null
    if !_lib:
        return _rtv_vanilla_<name>(args)

    # Global short-circuit: if no mod has ever called hook(), skip everything
    if not _lib._any_mod_hooked:
        return _rtv_vanilla_<name>(args)

    # Re-entry guard: don't double-dispatch if a chained subclass wrapper
    # calls super() into vanilla's wrapper
    if _lib._wrapper_active.has("<hook_base>"):
        return _rtv_vanilla_<name>(args)
    _lib._wrapper_active["<hook_base>"] = true

    _lib._caller = self
    _lib._dispatch("<hook_base>-pre", [args])

    var _result
    var _repl = _lib._get_hooks("<hook_base>")
    if _repl.size() > 0:
        var _prev_skip = _lib._skip_super
        _lib._skip_super = false
        var _replret = _repl[0].callv([args])
        var _did_skip = _lib._skip_super
        _lib._skip_super = _prev_skip
        if _did_skip:
            _result = _replret
        else:
            _result = _rtv_vanilla_<name>(args)
    else:
        _result = _rtv_vanilla_<name>(args)

    _lib._dispatch("<hook_base>-post", [args])
    _lib._dispatch_deferred("<hook_base>-callback", [args])
    _lib._wrapper_active.erase("<hook_base>")
    return _result
```

Three performance / correctness features:

- **Null-lib fallback**: if `RTVModLib` meta isn't set (loader not finished initializing, or loader failed), the wrapper calls the vanilla body directly.
- **Global short-circuit**: `_lib._any_mod_hooked` is a sticky bool flipped true by the first `hook()` call. Dispatch wrappers skip every dict/function call when no mod has registered anything. Same approach as godot-mod-loader's `_ModLoaderHooks.any_mod_hooked`.
- **Re-entry guard**: when a mod script that extends wrapped vanilla calls `super()`, control lands back in the vanilla wrapper. Without the guard, the vanilla wrapper would dispatch hooks again. The guard flips `_wrapper_active[hook_base]` = true on entry; nested re-entry at the same `hook_base` skips dispatch and runs the body directly. One dispatch per logical call regardless of chain depth.

Void methods, coroutines (`await`), and engine lifecycle methods (`_ready` et al.) use structurally similar templates with appropriate adjustments -- `await` prepended to vanilla calls for coroutines, no `_result` for void, etc.

## Hook registration, step-by-step

Source: [hooks_api.gd:42-65](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L42).

1. Detect replace vs. aspect: `is_replace = not (name ends_with "-pre/-post/-callback")`.
2. If replace and `_hooks[name]` is non-empty: debug-log the rejection, return `-1`.
3. Create entry `{callback, priority, id}`, append to `_hooks[name]`, sort by priority ascending.
4. Set `_any_mod_hooked = true` (sticky).
5. Return `id`, increment `_next_id`.

## Dispatch internals

Source: [hooks_api.gd:131](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L131).

```gdscript
func _dispatch(hook_name: String, args: Array) -> void:
    if not _hooks.has(hook_name):
        return
    var entries: Array = (_hooks[hook_name] as Array).duplicate()
    for entry in entries:
        _seq += 1
        entry["callback"].callv(args)
```

The `.duplicate()` is load-bearing: hooks that call `hook()` or `unhook()` mid-dispatch would otherwise mutate the live array during iteration. Snapshotting means new hooks registered during dispatch don't fire in the current dispatch -- they join the next one.

`_dispatch_deferred` uses `callback.bindv(args).call_deferred()` instead, for `-callback` suffix hooks.

## How the code generation works

For every vanilla script in the opt-in wrap surface, [hook_pack.gd:`_generate_hook_pack`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) produces a rewritten `.gd`. The rewriter:

1. Detokenizes the `.gdc` bytecode to reconstructed source (see [GDSC-Detokenizer](GDSC-Detokenizer))
2. Parses the source via [rewriter.gd:`_rtv_parse_script`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd) -- extracts function signatures, params, return types, coroutine markers.
3. Normalizes line endings (CRLF -> LF).
4. Runs `_rtv_autofix_legacy_syntax` -- bodyless blocks get `pass`, `tool`/`onready var`/`export var` get `@` annotations, bare `base(args)` is rewritten to `super.<enclosing>(args)`, `base().method(x)` is rewritten to `super.method(x)`.
5. **Per-method wrap mask**: for paths declared via `[hooks]` / `.hook()` / `add_hook()`, only listed methods get wrapped. For paths declared via `[registry]` (Database.gd, Loader.gd, AISpawner.gd, FishPool.gd), every method is wrapped because registry injection needs whole-script access.
6. **Rename pass**: top-level `func <name>(` -> `func _rtv_vanilla_<name>(`. Inside renamed bodies, bare `super(` -> `super.<orig_name>(` so strict-reload can resolve the parent method.
7. **Append dispatch wrappers**: one per hookable method, at the original name, calling `_rtv_vanilla_<name>(...)` internally.
8. **Registry injection** (Database.gd / Loader.gd / AISpawner.gd / FishPool.gd only): see [Registry](Registry).

`_detect_indent_style` inspects the source's first indented line to decide whether to emit the wrappers with tabs or spaces. GDScript rejects mixing tabs and spaces in one file; IXP uses 4-space indent, vanilla RTV uses tabs.

## Three-entry pack recipe

Each rewritten vanilla script ships as three zip entries in the hook pack:

| Entry | Purpose |
|---|---|
| `Scripts/<Name>.gd` | Rewritten source |
| `Scripts/<Name>.gd.remap` | `[remap]\npath="res://Scripts/<Name>.gd"` -- overrides the PCK's `.gd.remap -> .gdc` redirect before GDScript loader runs |
| `Scripts/<Name>.gdc` | Zero bytes -- Godot prefers a sibling `.gdc` at the same base path even after our remap; an empty `.gdc` can't parse, silently falls back to our `.gd` |

This entire recipe lives in `user://modloader_hooks/framework_pack.zip`. The pack mounts with `replace_files=true`, which makes our entries win over the PCK's same-path entries in Godot's VFS layering.

Under the cutover, pack generation is skipped entirely when no mods are loaded. When mods are loaded but none opt into the hook surface, the pack still ships -- but it contains only the core-owned wrap on `Menu.gd :: _ready` for the launcher's main-menu "Mods" button. `hook_pack_wrapped_paths` in pass state narrows to just `res://Scripts/Menu.gd`, so next session's static-init preempt touches that single script and nothing else. User mods' targets stay unmodified.

## Activation + fallback

[hook_pack.gd:`_activate_rewritten_scripts`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd) force-activates each rewritten script in Godot's ResourceCache.

Scripts fall into one of three buckets:

1. **Already live** -- static-init preload put our rewrite into the cache. Skip reload (would error with `"Cannot reload script while instances exist"` for autoload-backed Database / GameData / Inputs / Loader / Menu).
2. **Pinned with source** -- GDScriptCache has our text but compiled methods are vanilla. Mutate `source_code` + `reload()`.
3. **Pinned tokenized** -- PCK .gdc cached, static-init preempt missed. After the `reload()` attempt fails verification, fall back to `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` + `take_over_path(path)`.

Scripts with module-scope `preload("res://...tscn|.scn")` are deferred from eager compile (the `_scripts_with_scene_preloads` set). VFS mount precedence still serves the rewrite when game code lazy-loads these paths after mod overrides have run -- this avoids baking Script ext_resources in scenes to the pre-override vanilla. See [Limitations](Limitations).

## Composing with `[script_extend]`

Mods that replace a vanilla script wholesale declare `[script_extend] res://Scripts/<Vanilla>.gd = res://MyMod/MyOverride.gd` (see [Mod-Format](Mod-Format)). The override is a standalone `.gd` that `extends "res://Scripts/<Vanilla>.gd"` and `take_over_path`'s into place at runtime.

When the same path is in the hook wrap surface:

- The hook pack rewrites vanilla's source. The rewritten source ships at `res://Scripts/<Vanilla>.gd` and is what Godot compiles.
- The mod's override `extends` that rewritten vanilla. Godot's native extends resolution means the override sees the dispatch wrappers as its parent methods.
- `super.method(...)` calls from the override land in the vanilla dispatch wrapper, which fires hooks (via the re-entry guard: once per logical call, not per chain link).

The mod's own source is **not** rewritten. This is the main departure from v3.0.0's behavior: v3.0.0's "Step C" rewrote mod subclasses to use `_rtv_mod_` prefixes. That entire pipeline was removed in v3.0.1 -- Godot's native resolution handles chain composition correctly once the vanilla parent carries the wrappers.

Chain ordering with multiple mods: `take_over_path` runs in priority order (lowest first). Each override's `extends` resolves to the prior chain tip, producing `ModC -> ModB -> ModA -> rewritten_vanilla`. Hooks fire exactly once per logical call regardless of chain depth.

## Worked examples

Adapted from tetrahydroc's RTVModLib README.

### AI Kill Tracker

```gdscript
extends Node

var _lib = null
var _kills: Dictionary = {}

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
    _kills["total"] = _kills.get("total", 0) + 1
    print("Kills: " + str(_kills["total"]))
```

```ini
[mod]
name="Kill Tracker"
id="kill-tracker"
version="1.0.0"

[autoload]
KillTracker="res://KillTracker/Main.gd"
```

No `[hooks]` section -- scanner sees `_lib.hook("ai-death-post", ...)` in Main.gd and enrolls `AI.gd :: death`.

### Custom Trader Prices

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
    _lib.hook("interface-calculatedeal-post", _modify_prices)

func _modify_prices():
    var scene = get_tree().current_scene
    var interface = scene.get_node_or_null("Core/UI/Interface")
    if interface and interface.requestValue:
        var current = int(interface.requestValue.text)
        interface.requestValue.text = str(current * 2)
```

### Replace hook with fallback

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
    var id = _lib.hook("lootcontainer-generateloot", _custom_loot)
    if id == -1:
        # Another mod already owns this replace hook.
        print("MyMod: GenerateLoot replace hook rejected, using pre/post instead")
        _lib.hook("lootcontainer-generateloot-post", _modify_loot_after)

func _custom_loot():
    if some_condition:
        _lib.skip_super()  # Skip vanilla loot gen
        # Generate custom loot...
    # If skip_super() not called, vanilla GenerateLoot runs normally.
```

## Related

- [Registry](Registry) -- `lib.register`, `lib.override`, `lib.patch` for data-driven content (items, loot, scenes, recipes)
- [Mod-Format](Mod-Format) -- full `mod.txt` schema including `[hooks]`, `[script_extend]`, `[registry]`
- [Stability-Canaries](Stability-Canaries) -- runtime probes that alarm when the dispatch chain breaks
- [Limitations](Limitations) -- bug #83542, skip-listed scripts, scene-preload deferral
