# Hooks

The hook system lets mods intercept vanilla method calls -- run code before/after, replace the implementation entirely, or receive a deferred callback. The public API matches tetrahydroc's RTVModLib mod exactly; the implementation under the hood is different.

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

Hook names follow this convention (documented at [constants.gd:102-103](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L102)):

```
<scriptname>-<methodname>[-pre|-post|-callback]
```

Both `scriptname` and `methodname` are lowercased. `scriptname` is the `.gd` filename without extension. For example, `res://Scripts/Controller.gd`'s `_physics_process` method lowercases to `controller-_physics_process`.

Suffixes:

| Suffix | Fires | Args | Return? |
|---|---|---|---|
| `-pre` | Before vanilla body (or before replace) | Same as the vanilla method | Ignored |
| (none) | In place of vanilla. **First registration wins, subsequent registrations are rejected** (returns -1). Within a replace callback, call `lib.skip_super()` to suppress vanilla | Same as vanilla | Return value becomes the method's return |
| `-post` | After vanilla (or after replace if no `skip_super`) | Same as vanilla | Ignored |
| `-callback` | Deferred via `Callable.bindv(args).call_deferred()` | Same as vanilla | Ignored |

## Dispatch semantics

The dispatch wrapper template lives at [rewriter.gd:766](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L766). For every hookable vanilla method, the rewriter emits roughly this structure:

```
func <name>(args):
    # Dispatch-live probes (increment Engine meta counters)
    ...

    var _lib = Engine.get_meta("RTVModLib") if Engine.has_meta("RTVModLib") else null
    if !_lib:
        return _rtv_vanilla_<name>(args)

    # Global short-circuit: if no mod has ever called hook(), skip everything
    if not _lib._any_mod_hooked:
        return _rtv_vanilla_<name>(args)

    # Re-entry guard: don't double-dispatch if a mod's wrapper calls super()
    # into vanilla's wrapper
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

- **Null-lib fallback**: if `RTVModLib` meta isn't set (loader not finished initializing, or loader failed), the wrapper calls the vanilla body directly. Increments `Engine.get_meta("_rtv_dispatch_no_lib")` counter.
- **Global short-circuit** ([rewriter.gd:817](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L817)): `_lib._any_mod_hooked` is a sticky bool flipped true by the first `hook()` call. Dispatch wrappers skip every dict/function call when no mod has registered anything. Same approach as godot-mod-loader's `_ModLoaderHooks.any_mod_hooked`.
- **Re-entry guard** ([rewriter.gd:819-821](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L819)): when a mod subclass's rewritten wrapper fires, its body calls `super()` into vanilla's rewritten wrapper. Without the guard, the vanilla wrapper would dispatch hooks again. The guard flips `_wrapper_active[hook_base]` = true on entry; nested re-entry at the same `hook_base` skips dispatch and runs the body directly. One dispatch per logical call regardless of chain depth.

Void methods, coroutines (`await`), and engine lifecycle methods (`_ready` et al.) use structurally similar templates with appropriate adjustments -- `await` prepended to vanilla calls for coroutines, no `_result` for void, etc.

## Hook registration, step-by-step

Source: [hooks_api.gd:42-65](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L42).

1. Detect replace vs. aspect: `is_replace = not (name ends_with "-pre/-post/-callback")`.
2. If replace and `_hooks[name]` is non-empty: debug-log the rejection, return `-1`. (Debug-level, not warning -- rejection is normal API behavior per the comment at [hooks_api.gd:49-53](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L49). Promoting to `push_warning` spammed stderr for expected conflicts.)
3. Create entry `{callback, priority, id}`, append to `_hooks[name]`, sort by priority ascending.
4. Set `_any_mod_hooked = true` (sticky).
5. Return `id`, increment `_next_id`.

## Dispatch internals

Source: [hooks_api.gd:101-122](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L101).

```gdscript
func _dispatch(hook_name: String, args: Array) -> void:
    if not _hooks.has(hook_name):
        return
    var entries: Array = (_hooks[hook_name] as Array).duplicate()
    for entry in entries:
        _seq += 1
        entry["callback"].callv(args)
```

The `.duplicate()` is load-bearing ([hooks_api.gd:104-108](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L104)): hooks that call `hook()` or `unhook()` mid-dispatch would otherwise mutate the live array during iteration. Snapshotting means new hooks registered during dispatch don't fire in the current dispatch -- they join the next one.

`_dispatch_deferred` uses `callback.bindv(args).call_deferred()` instead, for `-callback` suffix hooks.

## How the code generation works

The loader does source rewriting. For each hookable vanilla script it:

1. Detokenizes the `.gdc` bytecode to reconstructed source (see [GDSC-Detokenizer](GDSC-Detokenizer))
2. Parses the source with [rewriter.gd:75 `_rtv_parse_script`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L75)
3. Normalizes line endings (CRLF -> LF)
4. Runs [rewriter.gd:625 `_rtv_autofix_legacy_syntax`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L625) -- bodyless blocks get `pass`, `tool`/`onready var`/`export var` get `@` annotations
5. For Database.gd: calls [rewriter.gd:477 `_rtv_rewrite_database_constants`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L477) to convert `const X = preload(...)` entries into a `_rtv_vanilla_scenes` dict
6. **Pass 1** ([rewriter.gd:380-404](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L380)): rename top-level `func <name>(` to `func _rtv_vanilla_<name>(`, and within renamed bodies rewrite bare `super(` to `super.<orig_name>(`
7. **Pass 2** ([rewriter.gd:406-414](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L406)): append dispatch wrappers at end-of-file, one per hookable method
8. For vanilla rewrites (not mod subclasses): call [rewriter.gd:430 `_rtv_registry_injection`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L430) -- currently only adds `_rtv_mod_scenes` / `_rtv_override_scenes` / `_get()` to Database.gd

`_detect_indent_style` ([rewriter.gd:561](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L561)) inspects the source's first indented line to decide whether to emit the wrappers with tabs or spaces. GDScript rejects mixing tabs and spaces in one file; IXP uses 4-space indent, vanilla RTV uses tabs.

## Three-entry pack recipe

Each rewritten vanilla script ships as three zip entries ([hook_pack.gd:212-245](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L212)):

| Entry | Purpose |
|---|---|
| `Scripts/<Name>.gd` | Rewritten source |
| `Scripts/<Name>.gd.remap` | `[remap]\npath="res://Scripts/<Name>.gd"` -- overrides the PCK's `.gd.remap -> .gdc` redirect before GDScript loader runs |
| `Scripts/<Name>.gdc` | Zero bytes -- Godot prefers a sibling `.gdc` at the same base path even after our remap; an empty `.gdc` can't parse, silently falls back to our `.gd` |

This entire recipe lives in the hook pack zip at `user://modloader_hooks/framework_pack.zip`. The pack mounts with `replace_files=true`, which makes our entries win over the PCK's same-path entries in Godot's VFS layering.

Mod subclass scripts ship **only** as `.gd` (no `.remap`, no `.gdc` shadow). Rationale at [hook_pack.gd:292-304](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L292): the shadow tricks are there to defeat the base game PCK's redirect; mod archives ship source-only, so shadows only change the load pathway from `(direct .gd compile)` to `(bytecode-fail -> .gd fallback)`. The latter triggers stricter re-parse that cascades into the mod's sibling preloads -- breaks mods whose code is valid under lenient first-compile but sloppy under strict (Gotcha #5 in [Limitations](Limitations)).

## Mod subclasses (Step C)

Mods that extend vanilla by path get the same treatment. [rewriter.gd:886 `_scan_mod_extends_targets`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L886) walks each enabled mod archive, looking for `.gd` files whose first non-trivial line is `extends "res://Scripts/<X>.gd"` where `<X>` is a vanilla script already being rewritten.

Each match gets:

- Parsed using the **vanilla** filename so `hook_base` is `"controller-*"` not `"immersivexp/controller-*"` (single hook namespace per vanilla)
- Rewritten with `_rtv_mod_` prefix (not `_rtv_vanilla_`) -- keeps the mod's renamed body from shadowing vanilla's via virtual dispatch
- Shipped at the mod's own `res://` path in the hook pack overlay

The re-entry guard in the dispatch template is what makes the mod-wrapper-calls-super-into-vanilla-wrapper chain fire only once.

## Database registry flow

Source: [registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd) + [rewriter.gd:439 `_rtv_inject_database_registry`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/rewriter.gd#L439).

1. Rewriter converts `const X = preload(...)` in vanilla Database.gd into `_rtv_vanilla_scenes["X"] = preload(...)` entries.
2. Rewriter injects `_rtv_mod_scenes` + `_rtv_override_scenes` + a `_get(property)` override on Database.
3. `_get()` lookup order: `_rtv_override_scenes` -> `_rtv_mod_scenes` -> `_rtv_vanilla_scenes` -> null.
4. At runtime, mods call `lib.register(lib.Registry.SCENES, "my_item", scene)` or `lib.override(lib.Registry.SCENES, "Potato", better_scene)`.
5. Vanilla game code calling `Database.get("Potato")` hits the injected `_get()` and resolves through the mod layer before falling back to vanilla.

**Limitation**: direct constant access (`Database.Potato` property syntax) bypasses `_get()`. Mods must use `Database.get("Potato")`.

After activation, the loader runs a registry smoke probe ([hook_pack.gd:721-745](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L721)) that loads Database, checks `_rtv_vanilla_scenes` is populated, and verifies `db.get(first_key) is PackedScene`.

## Activation + fallback

[hook_pack.gd:438 `_activate_rewritten_scripts`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L438) force-activates each rewritten script in Godot's ResourceCache.

Scripts fall into one of three buckets:

1. **Already live** -- static-init preload put our rewrite into the cache. Skip reload (would error with `"Cannot reload script while instances exist"` for autoload-backed Database / GameData / Inputs / Loader / Menu).
2. **Pinned with source** -- GDScriptCache has our text but compiled methods are vanilla. Mutate `source_code` + `reload()`.
3. **Pinned tokenized** -- PCK .gdc cached, static-init preload missed. After the `reload()` attempt fails verification, fall back to `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` + `take_over_path(path)`.

Why the fallback matters ([hook_pack.gd:538-545](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L538)): for scripts originally compiled from `.gdc` bytecode (Camera, WeaponRig -- pre-compiled by the engine during startup because they're referenced by the initial scene graph), `reload()` doesn't re-parse from the mutated `source_code` -- it re-reads bytecode. `CACHE_MODE_IGNORE` goes through `_path_remap -> our .gd` with a fresh source compile.

Scripts with module-scope `preload("res://...tscn|.scn")` are deferred from eager compile (the `_scripts_with_scene_preloads` set). VFS mount precedence still serves the rewrite when game code lazy-loads these paths after mod overrides have run -- this avoids baking Script ext_resources in scenes to the pre-override vanilla. See [Limitations](Limitations).

## Worked examples

The three examples below are adapted from tetrahydroc's RTVModLib README.

### AI Kill Tracker

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
    # AI.Death(direction, force) was called -- an AI just died.
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

### Custom Trader Prices

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
    # Runs after CalculateDeal -- modify the displayed values.
    var scene = get_tree().current_scene
    var interface = scene.get_node_or_null("Core/UI/Interface")
    if interface and interface.requestValue:
        var current = int(interface.requestValue.text)
        interface.requestValue.text = str(current * 2)
```

### Replace hook with fallback

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

- [Stability-Canaries](Stability-Canaries) -- runtime probes that alarm when the dispatch chain breaks
- [Limitations](Limitations) -- bug #83542, skip-listed scripts, scene preload deferral
- [Mod-Format](Mod-Format) -- `[rtvmodlib] needs=` (no-op under source-rewrite), `[script_overrides]`
