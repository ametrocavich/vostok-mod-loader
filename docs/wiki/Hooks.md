# Hooks

Hooks let your mod run code around a vanilla method: before it (`-pre`), after it (`-post`), instead of it (replace), or deferred until after it returns (`-callback`). You register a callback against a hook name like `"controller-jump-pre"`, and the loader arranges for it to fire whenever vanilla `Controller.jump()` runs. Under the hood the loader rewrites the vanilla script with a dispatch wrapper, but you never touch that machinery -- you write one `.hook()` call.

Use hooks when you want to react to or change vanilla *behavior*. If you want to add or change *data* (items, loot, scenes, recipes), use the [Registry](Registry) instead. If you need to know whether another mod is loaded, see the mod-discovery API below and [Dependencies](Dependencies).

## Quick start -- the 90% case

A working hook mod needs exactly two things: an `[autoload]` entry in `mod.txt`, and a literal `.hook("...")` call in your own source. No `[hooks]` section, no framework import. The loader scans your `.gd` files for literal `.hook("<stem>-<method>[-pre|-post|-callback]")` strings and wraps those vanilla methods automatically.

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
    _lib._caller.jumpVelocity = 20.0   # _caller = the node whose method is running
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

That's the whole mod. The scanner sees `.hook("controller-jump-pre", ...)`, resolves `controller` to `res://Scripts/Controller.gd`, and wraps `jump`. Your callback receives the same arguments the vanilla method received.

Two rules to keep out of trouble:

1. **Hook names must be a literal string, fully lowercase.** A name built at runtime (concatenation, variable) registers fine but never fires, because the scanner can only enroll literal strings (see [Wrap surface](#wrap-surface----why-hook-alone-is-not-enough)). Mixed-case names enroll the wrap but the runtime key never matches -- write them lowercase.
2. **Register from `_ready` or later** using the readiness pattern above. Calling `hook()` from `_ready` directly also works (the API exists before mod autoloads run); waiting for `frameworks_ready` additionally guarantees every other mod's autoload has finished, which you need for peer integration (`has_mod`) and registry-backed state. You can also just `await Engine.get_meta("RTVModLib").frameworks_ready`.

## Hook names

```
<scriptname>-<methodname>[-pre|-post|-callback]
```

Both parts lowercase. `<scriptname>` is the vanilla `.gd` filename without extension: `Controller.gd`'s `_physics_process` becomes `controller-_physics_process`. Only scripts directly under `res://Scripts/` are hookable.

| Name form | Fires | Args | Return |
|---|---|---|---|
| `controller-jump-pre` | Before the vanilla body | Same as vanilla | Ignored |
| `controller-jump` (bare) | Replace slot -- **single-owner, first registration wins** (later ones get -1). Runs before vanilla; call `skip_super()` to suppress vanilla and use your return value instead | Same as vanilla | Used **only if** you called `skip_super()`; otherwise vanilla runs after your callback and vanilla's result wins |
| `controller-jump-post` | After vanilla (or after replace) | Same as vanilla, plus a trailing `_result` param for non-void methods if your callback declares it | Non-void methods: return non-null to replace the result; null = pass-through. Void methods: ignored |
| `controller-jump-callback` | Deferred (`call_deferred`) after the method returns | Same as vanilla | Ignored |

Per call, the order is: pre -> replace-or-vanilla -> post -> deferred callback.

## Getting the library

The loader registers itself as `Engine.get_meta("RTVModLib")` before any mod autoload runs. Public state on it:

| Member | Meaning |
|---|---|
| `frameworks_ready` (signal) | Emitted once, after all mod autoloads have finished `_ready()`. Safe to `await` |
| `_is_ready: bool` | True once `frameworks_ready` has emitted (public despite the underscore) -- use it for the check-then-connect pattern so you don't miss the signal |
| `_caller: Node` | The node whose wrapped method is currently dispatching. Only meaningful inside a hook callback; the wrapper saves/restores it around nested calls, so it is always the correct node for the hook that is firing |

## API reference

All calls on `Engine.get_meta("RTVModLib")`. Source: `src/hooks_api.gd`.

| Method | Purpose |
|---|---|
| `hook(name, callback, priority=100) -> int` | Register a callback, return its id. Returns **-1** if `name` is a bare replace name that already has an owner (any earlier registration, even your own) -- this is logged at debug level only, so **check the return value**. Callbacks run in ascending priority order; ties are NOT guaranteed to run in registration order (`sort_custom` is not stable) -- use distinct priorities when ordering matters |
| `hook_many({name: callback, ...}, priority=100) -> Dictionary` | Batched register. Returns `{ok, results}` where `results[name]` is the hook id or -1; `ok` is false if any registration failed |
| `unhook(id) -> void` | Remove a hook by id |
| `add_hook(path, method, cb, is_before=true) -> int` | godot-mod-loader compat shim; see [add_hook compat](#modloaderadd_hook-compat) for its timing and path caveats |
| `has_hooks(name) -> bool` | Any callbacks registered at this exact name? |
| `has_replace(name) -> bool` | Is a replace hook registered at this bare name? |
| `get_replace_owner(name) -> int` | Id of the current replace owner, or -1 -- lets you detect an occupied slot and fall back to pre/post |
| `skip_super() -> void` | Inside a replace callback only: suppress the vanilla body; your callback's return becomes the method's result |
| `seq() -> int` | Monotonic dispatch counter, useful for tests/debug |
| `has_mod(id, min_version="") -> bool` | True if a mod with that id is loaded. `min_version` does a numeric dotted-version compare (`>=`); non-numeric components compare as 0, and mods without a `version=` field compare as 0.0.0 |
| `mod_info(id) -> Dictionary` | `{mod_id, mod_name, version, file_name, priority, required_dependencies, optional_dependencies}` for a loaded mod, `{}` if absent. Returns a deep copy -- mutate freely |
| `loaded_mods() -> Array[String]` | All loaded mod ids. Order not guaranteed |
| `static version() -> String` | Loader version string (e.g. `"3.3.0"`) |
| `static major_version() / minor_version() / patch_version() -> int` | Numeric components, for feature gating: `if lib.major_version() >= 3:` |

Note: `provides=` rename aliases (see [Mod-Format](Mod-Format)) satisfy dependency resolution but are NOT matched by `has_mod()`/`mod_info()` -- these match only the mod's real `id`. Check both ids if you need to detect a renamed peer. See [Dependencies](Dependencies).

For mods that install hooks alongside registry mutations as one step, `hook_many` is also available as a `["hooks", {name: callback, ...}]` entry inside `lib.setup(plan)`; the plan result entry is `{"verb": "hooks", "ok": bool, "results": {name: id_or_-1}}`. See [Setup-Plans](Setup-Plans).

```gdscript
var lib = Engine.get_meta("RTVModLib")
await lib.frameworks_ready

var id = lib.hook("controller-_physics_process-pre", func(delta): print(delta), 100)
lib.unhook(id)

if lib.has_replace("weaponrig-shoot"):
    print("another mod already replaced shoot")

lib.hook_many({
    "controller-_physics_process-pre":  _on_phys_pre,
    "interface-getmagazine":            _replace_get_mag,
    "interface-close-post":             _on_close_post,
})
```

## Replace hooks

A bare hook name is the single-owner replace slot. Semantics that surprise people:

- **Your callback runs BEFORE vanilla, not instead of it, unless you call `skip_super()`.** If you don't call `skip_super()`, vanilla runs after your callback and **vanilla's return value wins** -- your return is discarded. Call `lib.skip_super()` inside the callback to suppress vanilla and make your return value the method's result.
- **First registration wins.** A second `hook("lootcontainer-generateloot", ...)` returns -1 with only a debug-level log. Check for -1, or probe first with `has_replace()` / `get_replace_owner()` and fall back to pre/post:

```gdscript
var id = _lib.hook("lootcontainer-generateloot", _custom_loot)
if id == -1:
    # Another mod owns the replace slot -- observe instead.
    _lib.hook("lootcontainer-generateloot-post", _modify_loot_after)

func _custom_loot():
    if some_condition:
        _lib.skip_super()   # skip vanilla loot gen; our return value is the result
        # generate custom loot ...
    # if skip_super() not called, vanilla GenerateLoot runs normally after this
```

### `await` inside a replace hook

Only suspend (`await` something that actually waits) inside a replace callback when the vanilla method you replaced is itself a coroutine. The wrapper always `await`s your replace callback -- free for synchronous callbacks -- but if vanilla is synchronous and your callback suspends, the wrapper suspends too, and the vanilla call site (which does not `await`) receives a coroutine state object instead of the declared type. Any typed call site (`var n: int = obj.Method()`) then throws a runtime error in vanilla code you cannot fix from a mod. For async work behind a synchronous hook, use `call_deferred` or a `-callback` hook and return a plain value.

## Post hooks and result mutation

For **non-void** wrapped methods, post hooks can transform the return value. Two callback shapes:

```gdscript
# Preferred: declare a trailing _result param (arity = vanilla args + 1).
# Return non-null to replace the result; return null to pass through.
func _on_value_post(current_result: int):
    return current_result + 100

# Legacy: vanilla args only. Still runs (read-only observer), return ignored,
# one-shot deprecation warning per callback. Will be removed in a future
# major version.
func _on_value_post_legacy() -> void:
    print("Item.Value() ran")
```

The dispatcher detects which form you wrote by argument count. Multiple post hooks chain in ascending priority order -- each sees the running result after all earlier post hooks transformed it, and the final value is what the caller receives:

```gdscript
# Vanilla Item.Value() returns an int
lib.hook("item-value-post", func(r): return r + 100, 50)        # runs first
lib.hook("item-value-post", func(r): return min(r, 200), 100)   # runs second

# vanilla returns 50 -> hook@50 makes it 150 -> hook@100 makes it min(150,200)=150
```

Limitations:

- **Returning null is the pass-through sentinel** -- you cannot set the result to literal null through a post hook.
- **Void methods have no result to mutate**; their post hooks are fire-and-forget. This includes every engine lifecycle method (`_ready`, `_process`, `_physics_process`, `_input`, `_unhandled_input`, `_unhandled_key_input`, `_enter_tree`, `_exit_tree`, `_notification`), which the loader forces void regardless of source annotations.

## Priorities and dispatch order

- Within one hook name, callbacks run in ascending `priority` (default 100). **Ties are not stable** -- if the order between two of your callbacks (or yours and a peer mod's) matters, use distinct priorities.
- `hook()`/`unhook()` called from inside a callback affect only FUTURE dispatches: the in-flight dispatch iterates a snapshot, so a hook registered mid-dispatch joins the next dispatch, and an unhooked one still finishes the current pass.
- Hooks fire **exactly once per logical call** even across `extends` chains: if a mod script extends wrapped vanilla and calls `super()`, a re-entry guard prevents double dispatch. Conversely, a mod override method that does NOT call `super()` suppresses hook dispatch for that method entirely -- that is the documented contract.

## Wrap surface -- why `hook()` alone is not enough

Registering a hook does NOT wrap the vanilla method. The wrap surface is fixed once, at pack-generation time (before your autoload's `_ready` runs), from exactly four sources:

1. `[hooks]` sections in any mod's `mod.txt`
2. **Literal** `.hook("...")` string calls found by the source scan of your mod's `.gd` files
3. `add_hook()` calls that run early enough (see below)
4. The loader's own core seed (`Menu.gd :: _ready`, for the main-menu Mods button)

A `hook()` call whose name is built at runtime registers fine but never fires unless the target method was wrapped by one of those declarations. If you need dynamic hook names, declare the target in `[hooks]`.

This is an opt-in model: when no user mod declares anything, vanilla scripts run byte-identical to vanilla -- no wrap, no dispatch overhead (boot log: "No user opt-in declarations..."). Other constraints on the surface:

- Only `res://Scripts/*.gd` is hookable. Other paths in `[hooks]` are ignored with a warning.
- `static func`s are never hookable.
- Zero-byte PCK scripts (the base game ships a few, e.g. `CasettePlayer.gd`) are not hookable.
- A declared path that matches no vanilla script, or declared methods not found in the vanilla source, log a warning and no-op. A `.hook()` call whose stem resolves to no vanilla script also warns at boot ("no vanilla script matches prefix ...") -- watch the log for typos.
- The six registry target scripts (`Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd`, `Compiler.gd`) enter the surface automatically when any mod declares `[registry]`. See [Registry](Registry).

### `[hooks]` escape hatch

Declare vanilla paths in `mod.txt` when auto-enrollment cannot see your call:

- `add_hook()` from a normal (runtime) autoload -- pack generation has already read the mask by then.
- Hook registrations via indirection -- the `.hook()` call site is not in your mod's own source.
- Hook names built at runtime (concatenation, variables, loops over a list).
- Methods you want wrapped now but will only register hooks for later, on gameplay events.

```ini
[hooks]
res://Scripts/Interface.gd = "_ready, update_tooltip"   # specific methods
res://Scripts/Controller.gd = "*"                       # wildcard -- all methods
res://Scripts/Camera.gd = ""                            # empty value == *
```

Semantics:

- **Quote the value.** ConfigFile parses the right-hand side as a Variant literal, so an unquoted method list or bare `*` is a parse error. The loader auto-quotes unquoted values (and strips inline `#`/`;` comments) for backward compat, but quoted is the portable form.
- Method names are case-insensitive (matched lowercased against vanilla names).
- `*` mixed with named methods in one value: `*` wins, with a warning.
- A wildcard from one mod widens earlier per-method lists for the same path across all mods; a later per-method entry cannot narrow an earlier wildcard.
- A value that is junk (only commas) is ignored with a warning.

### `ModLoader.add_hook()` compat

Mods written against [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) call `add_hook(script_path, method_name, callback, is_before)`. The shim builds the native name `<stem>-<method>-pre|post` (lowercased), enrolls the path into the wrap mask, and calls `hook(name, cb, 100)`. Two traps:

- **Timing:** pack generation reads the wrap mask before normal autoloads run, so `add_hook()` from a regular autoload's `_ready` registers the hook but never gets a wrapper. Fix: call it from a `!`-prefixed early autoload's `_init` (`Name="!res://MyMod/Early.gd"` in `[autoload]` -- see [Mod-Format](Mod-Format)), or declare the path in `[hooks]`.
- **Paths:** a bare filename normalizes to `res://Scripts/<file>`. If the target lives anywhere else, pass a fully-qualified `res://` path -- otherwise the enrollment silently matches nothing.

## Gotchas checklist

- Hook names: literal strings, fully lowercase, or they never fire.
- Replace slot: check for -1; rejection is silent at default log level.
- Replace return value only counts if you called `skip_super()`; otherwise vanilla runs after you and wins.
- Never suspend inside a replace hook on a synchronous vanilla method.
- Post-result mutation: non-void methods only; null = pass-through, not "set to null"; engine lifecycle methods are always void.
- Priority ties are unordered -- use distinct priorities.
- `hook()`/`unhook()` mid-dispatch only affect the next dispatch.
- `_caller` is only meaningful during a dispatch.
- A whole-script replacement at the same path -- a mod shipping its own file at the wrapped `res://Scripts/` path, or `take_over_path` from a script that does not extend it -- displaces the rewrite; hooks will not fire for nodes using that script. Chain-by-`extends` via `[script_extend]` (or its parse-identical legacy alias `[script_overrides]`) composes through `super()` (see below). Either way, the loader warns at boot when a wrapped path also carries an override claim.
- A mod override that skips `super()` suppresses hook dispatch for that method.

## Worked examples

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

No `[hooks]` section -- the scanner sees `_lib.hook("ai-death-post", ...)` in Main.gd and enrolls `AI.gd :: death`.

### Post-hook mutator chain

Two mods transform the same return value without knowing about each other. `Item.Value()` returns an `int`; Mod A bumps prices, Mod B caps them.

```gdscript
# Mod A: Trader Inflation -- adds +50 to every item value
func _register():
    _lib = Engine.get_meta("RTVModLib")
    _lib.hook("item-value-post", _bump_value, 50)     # priority 50: early in the chain

func _bump_value(current_result: int) -> int:
    return current_result + 50
```

```gdscript
# Mod B: Price Cap -- caps every item value at 1000
func _register():
    _lib = Engine.get_meta("RTVModLib")
    _lib.hook("item-value-post", _cap_value, 100)     # priority 100: after Mod A

func _cap_value(current_result: int):
    if current_result > 1000:
        return 1000
    return null  # null = pass-through, leaves the result unchanged
```

For a vanilla item with `value=970`:
1. Vanilla `Item.Value()` returns 970
2. Mod A fires with `current_result=970`, returns 1020
3. Mod B fires with `current_result=1020`, returns 1000
4. The caller receives 1000

For `value=500`: A makes it 550; B returns null; the caller receives 550. A third mod registering at priority 75 slots between them with no code changes anywhere.

### Reading UI state from a post hook

```gdscript
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

---

# Internals

Everything below is implementation detail. You do not need it to write hook mods; it is here for debugging and for understanding boot warnings.

## Dispatch semantics

The dispatch wrapper template lives in `src/rewriter.gd` (`_rtv_dispatch_inline_src`). For every wrapped vanilla method, the rewriter emits roughly:

```
func <name>(args):
    var _lib = Engine.get_meta("RTVModLib") if Engine.has_meta("RTVModLib") else null
    if !_lib:
        return _rtv_vanilla_<name>(args)

    # Global short-circuit: if no mod has ever called hook(), skip everything
    if not _lib._any_mod_hooked:
        return _rtv_vanilla_<name>(args)

    # Per-hook-base short-circuit: no hooks registered on THIS method
    if not _lib._hooked_bases.has("<hook_base>"):
        return _rtv_vanilla_<name>(args)

    # Re-entry guard: don't double-dispatch when a subclass wrapper calls
    # super() into vanilla's wrapper. Keyed per instance.
    var _rtv_wa_key: String = str(get_instance_id()) + ":<hook_base>"
    if _lib._wrapper_active.has(_rtv_wa_key):
        return _rtv_vanilla_<name>(args)
    _lib._wrapper_active[_rtv_wa_key] = true

    var _rtv_prev_caller = _lib._caller
    _lib._caller = self
    _lib._dispatch("<hook_base>-pre", [args])

    var _result
    var _repl = _lib._get_hooks("<hook_base>")
    if _repl.size() > 0:
        var _prev_skip = _lib._skip_super
        _lib._skip_super = false
        var _replret = await _repl[0].callv([args])
        var _did_skip = _lib._skip_super
        _lib._skip_super = _prev_skip
        if _did_skip:
            _result = _replret
        else:
            _result = _rtv_vanilla_<name>(args)
    else:
        _result = _rtv_vanilla_<name>(args)

    # Re-set _caller: nested wrapped calls inside the body may have
    # clobbered it, and post hooks should see the correct caller.
    _lib._caller = self

    # Non-void wrapper: chained post dispatch with arity detection.
    _result = _lib._dispatch_post("<hook_base>-post", [args], _result)

    _lib._dispatch_deferred("<hook_base>-callback", [args])
    _lib._wrapper_active.erase(_rtv_wa_key)
    _lib._caller = _rtv_prev_caller
    return _result
```

Notes:

- **Void methods** use a structurally similar template but fire `_dispatch("<hook_base>-post", ...)` (return ignored) instead of `_dispatch_post`.
- **Coroutines**: `await` is prepended to the vanilla call only when the vanilla body itself contains `await`. The replace callback is always awaited.
- The dispatch helpers (`_dispatch`, `_dispatch_post`, `_dispatch_deferred` in `src/hooks_api.gd`) iterate a `.duplicate()` snapshot of the entry array -- that is what makes mid-dispatch `hook()`/`unhook()` safe.
- `_skip_super` is saved/restored around the replace call, so nested wrapped calls are safe.
- The legacy-post deprecation warning is one-shot per (hook name, callback object, callback method), so hot-path methods do not spam the log.
- The `_hooked_bases` refcount (maintained by `hook()`/`unhook()`) is why wrapped-but-unhooked methods cost almost nothing at runtime.

## How the code generation works

For every vanilla script in the opt-in wrap surface, `src/hook_pack.gd` (`_generate_hook_pack`) produces a rewritten `.gd`:

1. Detokenize the `.gdc` bytecode to reconstructed source (see [GDSC-Detokenizer](GDSC-Detokenizer)).
2. Parse the source (`_rtv_parse_script` in `src/rewriter.gd`) -- signatures, params, return types, coroutine markers.
3. Normalize line endings, autofix legacy syntax (bodyless blocks get `pass`, `tool`/`onready var`/`export var` get `@` annotations, `base(...)` forms become `super.` calls).
4. Apply the per-method wrap mask: paths declared via `[hooks]`/`.hook()`/`add_hook()` wrap only listed methods; registry targets wrap every method (injection needs whole-script access).
5. Rename pass: `func <name>(` -> `func _rtv_vanilla_<name>(`.
6. Append one dispatch wrapper per wrapped method, at the original name.
7. Registry injection for the registry targets: appendix helpers for `Database.gd`/`Loader.gd`/`AISpawner.gd`/`AI.gd`, plus function-body preludes for `Loader.gd`/`FishPool.gd`/`AI.gd`/`Compiler.gd` (see [Registry](Registry)).

Indent style (tabs vs spaces) is detected from the source so the emitted wrappers match.

## Three-entry pack recipe

Each rewritten vanilla script ships as three zip entries in the hook pack:

| Entry | Purpose |
|---|---|
| `Scripts/<Name>.gd` | Rewritten source |
| `Scripts/<Name>.gd.remap` | `[remap]` pointing back at the `.gd` -- overrides the PCK's `.gd.remap -> .gdc` redirect |
| `Scripts/<Name>.gdc` | Zero bytes -- Godot prefers a sibling `.gdc`; an empty one cannot parse and silently falls back to our `.gd` |

The pack lives at `user://modloader_hooks/framework_pack_<timestamp>.zip` (a fresh filename per generation; stale packs are cleaned at boot) and mounts with `replace_files=true` so its entries win over the PCK. When no mods are loaded, pack generation is skipped entirely; when mods are loaded but none opt into the hook surface, the pack contains only the core `Menu.gd :: _ready` wrap for the launcher's Mods button.

## Activation + fallback

`_activate_rewritten_scripts` (`src/hook_pack.gd`) force-activates each rewritten script in Godot's ResourceCache. Scripts fall into three buckets: already live from static-init preload (skip reload), pinned with our source but vanilla-compiled (mutate `source_code` + `reload()`), or pinned tokenized (fall back to `ResourceLoader.load(..., CACHE_MODE_IGNORE)` + `take_over_path`). Scripts with module-scope scene `preload()`s are deferred from eager compile; VFS mount precedence still serves the rewrite on lazy load. See [Limitations](Limitations).

## Composing with `[script_extend]`

Mods that extend a vanilla script declare it under `[script_extend]` as `res://Scripts/<Vanilla>.gd = "res://MyMod/MyOverride.gd"` -- quote the value; unlike `[hooks]`, these values are not auto-quoted (see [Mod-Format](Mod-Format)). `[script_overrides]` is a parse-identical legacy alias for the same section. When the same path is in the hook wrap surface:

- The rewritten vanilla ships at `res://Scripts/<Vanilla>.gd` and is what Godot compiles.
- The mod's override `extends` that rewritten vanilla, so it sees the dispatch wrappers as its parent methods.
- `super.method(...)` from the override lands in the dispatch wrapper, which fires hooks -- once per logical call, thanks to the re-entry guard, regardless of chain depth.
- The mod's own source is never rewritten. Chain ordering with multiple mods follows load priority (lowest first): `ModC -> ModB -> ModA -> rewritten_vanilla`.

By contrast, a whole-script replacement at a wrapped path -- a mod shipping its own file at the vanilla `res://Scripts/` path inside its archive, or taking over the path with a script that does not extend the wrapped vanilla -- displaces the rewrite entirely: no extends chain reaches the wrappers, so hooks do not fire for nodes using that script.

The loader warns at boot whenever a wrapped path also carries an override claim of either kind (archive file claim or `[script_extend]`/`[script_overrides]` entry): `"<path> is rewritten and also overridden by <mods> -- override displaces the rewrite, hooks won't fire for that path"`. For a chained (extends-based) override the warning is conservative -- inherited methods and overridden methods that call `super()` still dispatch -- but any method your override redefines *without* calling `super()` really does stop dispatching, so treat the warning as a prompt to check your override's `super()` coverage.

## Related

- [Registry](Registry) -- `lib.register`, `lib.override`, `lib.patch` for data-driven content (items, loot, scenes, recipes)
- [Dependencies](Dependencies) -- `required=`/`optional=`/`provides=`, load ordering, and how they interact with `has_mod()`
- [Mod-Format](Mod-Format) -- full `mod.txt` schema including `[hooks]`, `[autoload]` (and the `!` early-autoload prefix), `[script_extend]`, `[registry]`
- [Setup-Plans](Setup-Plans) -- the declarative `lib.setup(plan)` form, including the `["hooks", {...}]` verb
- [Stability-Canaries](Stability-Canaries) -- runtime probes that alarm when the dispatch chain breaks
- [Limitations](Limitations) -- skip-listed scripts, scene-preload deferral, engine bug workarounds
