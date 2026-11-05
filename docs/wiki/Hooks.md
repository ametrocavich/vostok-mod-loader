# Hooks

Hooks run your code around a vanilla method: before it (`-pre`), after it (`-post`), instead of it (replace), or deferred until it returns (`-callback`). You register a callback against a hook name such as `"controller-jump-pre"`, and it fires whenever vanilla `Controller.jump()` runs. The loader rewrites the vanilla script with a dispatch wrapper to make that work ([Hook-Pack](Hook-Pack) has the machinery); you write one `.hook()` call.

Use hooks to react to or change vanilla behavior. To add or change data (items, loot, scenes, recipes), use the [Registry](Registry). To find out whether another mod is loaded, see `has_mod` below and [Dependencies](Dependencies).

## Quick start

A hook mod needs an `[autoload]` entry in `mod.txt` and a literal `.hook("...")` call in its own source. The loader scans your `.gd` files for literal `.hook("<stem>-<method>[-pre|-post|-callback]")` strings and wraps those vanilla methods; no `[hooks]` section is needed.

Package `BigJump.vmz` (a renamed `.zip`) with `mod.txt` at the root and the script at `BigJump/Main.gd`, which mounts as `res://BigJump/Main.gd`. `mod.txt` at the root is what makes the archive a mod; inside a subfolder the loader rejects it as packaged incorrectly. Everything else mounts verbatim at `res://`, which the game shares, so keep your code in a folder named after your mod.

```gdscript
# res://BigJump/Main.gd
extends Node

var _lib

func _ready():
    _lib = Engine.get_meta("RTVModLib")
    _lib.hook("controller-jump-pre", _on_jump)

func _on_jump(_delta):
    _lib._caller.jumpVelocity = 20.0   # _caller = the node whose method is running
```

```ini
[mod]
name="Big Jump"
id="big_jump"
version="1.0.0"

[autoload]
BigJump="res://BigJump/Main.gd"
```

The scanner sees `.hook("controller-jump-pre", ...)`, resolves `controller` to `res://Scripts/Controller.gd` and wraps `jump`. Your callback receives the arguments the vanilla method received. Two rules:

1. A hook name is a literal string, all lowercase. A name built at runtime registers but never fires, because the scanner only enrolls literals (see [Wrap surface](#wrap-surface----why-hook-alone-is-not-enough)). A mixed-case name enrolls the wrap but never matches at runtime.
2. Register from `_ready` or later. The loader sets the `RTVModLib` meta before any mod autoload's `_ready` runs, `!` early autoloads included; an early autoload's `_init` runs before that and reaches the loader through the `ModLoader` singleton. Code that needs every other mod's autoload finished (`has_mod`, registry-backed state) waits for `frameworks_ready`: `await lib.frameworks_ready`, or check `lib._is_ready` and connect the signal when it is false.

An unpacked folder in [Developer-Mode](Developer-Mode) uses the same layout: `mods/BigJump/` holds `mod.txt` and `BigJump/Main.gd`. If the mod loads but nothing happens, look for `Autoload path not found: <path>` in the log. The launcher usually flags the row before launch (`Autoload "X" points at ..., which is not in this mod`).

## Hook names

A name is `<scriptname>-<methodname>[-pre|-post|-callback]`, both parts lowercase. `<scriptname>` is the vanilla file name without `.gd`: `Controller.gd`'s `_physics_process` is `controller-_physics_process`. Only scripts under `res://Scripts/` are hookable.

| Name form | Fires | Args | Return |
|---|---|---|---|
| `controller-jump-pre` | Before the vanilla body | Same as vanilla | Ignored |
| `controller-jump` (bare) | Replace slot, before vanilla; see [Replace hooks](#replace-hooks) | Same as vanilla | Used only after `skip_super()` |
| `controller-jump-post` | After vanilla (or after replace) | Same as vanilla, plus a trailing result for non-void methods | Non-null replaces the result |
| `controller-jump-callback` | Deferred (`call_deferred`) after the method returns | Same as vanilla | Ignored |

Per call the order is pre, then replace-or-vanilla, then post, then the deferred callback.

A name with two or more hyphens and no known suffix (`controller-jump-per`) is filed as a replace hook that never fires, and `hook()` warns: `unrecognized suffix '-per', filed as a replace hook that never fires`.

## API reference

The loader registers itself as `Engine.get_meta("RTVModLib")` before any mod autoload runs; the source is `src/hooks_api.gd`.

| Member | Purpose |
|---|---|
| `frameworks_ready` (signal) | Emitted once, after every mod autoload's `_ready()`. Safe to `await` |
| `_is_ready: bool` | True once `frameworks_ready` has emitted |
| `_caller: Object` | The object whose wrapped method is dispatching: a node, or a `Resource` for `GameData.gd`. Meaningful only inside a callback; saved and restored around nested calls |
| `hook(name, callback, priority=100) -> int` | Register; returns the id, or -1 when the bare replace name already has an owner |
| `hook_many({name: callback, ...}, priority=100) -> Dictionary` | Batched `hook`; returns `{ok, results}` with an id or -1 per name. A non-Callable value warns and reports -1 |
| `unhook(id) -> void` | Remove a hook by id |
| `add_hook(path, method, cb, is_before=true) -> int` | godot-mod-loader shim; see [its caveats](Hook-Surface#modloaderadd_hook-compat) |
| `has_hooks(name) -> bool` | Any live callback at this exact name |
| `has_replace(name) -> bool` | A replace hook owns this bare name |
| `get_replace_owner(name) -> int` | The replace owner's id, or -1 |
| `skip_super() -> void` | Inside a replace callback: suppress vanilla and use your return value |
| `seq() -> int` | Dispatch counter, for tests and debugging |
| `has_mod(id, min_version="") -> bool` | A mod with that id is loaded, at `min_version` or later |
| `mod_info(id) -> Dictionary` | `{mod_id, mod_name, version, file_name, priority, required_dependencies, optional_dependencies}`, a deep copy, or `{}` |
| `loaded_mods() -> Array[String]` | Loaded mod ids, in no set order |
| `active_profile() -> String` | The launcher profile this session's mods came from |
| `static version() -> String` | Loader version string |
| `static major_version() / minor_version() / patch_version() -> int` | Numeric parts, for feature gates |

`min_version` compares dotted numbers; a non-numeric part counts as 0 and a mod without `version=` is 0.0.0. `has_mod` and `mod_info` match the real `id` only, not `provides=` aliases ([Dependencies](Dependencies)). `active_profile()` is `modpack__<name>` while a modpack is applied and `""` until the mods have loaded, so an early autoload reads it after `frameworks_ready`; it cannot change mid-session, because switching profiles restarts the game. Older loaders lack it: check `lib.has_method("active_profile")`. `hook_many` is also a `["hooks", {...}]` entry in [Setup-Plans](Setup-Plans).

## Replace hooks

A bare hook name is a single-owner slot. Your callback runs before vanilla, not instead of it: without `skip_super()` vanilla runs afterwards and its return value wins. Call `lib.skip_super()` inside the callback to suppress vanilla and make your return value the result.

The first registration wins, even against your own second one. Later ones get -1, logged at debug level only, so check the id or probe with `has_replace()` / `get_replace_owner()` and fall back to a post hook:

```gdscript
if _lib.hook("lootcontainer-generateloot", _custom_loot) == -1:
    _lib.hook("lootcontainer-generateloot-post", _modify_loot_after)
```

Your replace callback is awaited only when the vanilla method is a coroutine, so suspend inside it only in that case. If vanilla is synchronous and your callback awaits, the method returns a coroutine state object instead of its declared type, and a typed call site in vanilla code (`var n: int = obj.Method()`) throws. For async work behind a synchronous method, return a plain value and use `call_deferred` or a `-callback` hook.

## Post hooks and result mutation

For a non-void method, a post hook that declares one parameter more than vanilla receives the running result; returning non-null replaces it, returning null passes it through. Post hooks chain in ascending priority, each seeing the result the earlier ones produced, so two mods compose without knowing about each other:

```gdscript
lib.hook("item-value-post", func(r): return r + 100, 50)        # vanilla 50 -> 150
lib.hook("item-value-post", func(r): return min(r, 200), 100)   # 150 -> 150
```

- A callback with only the vanilla arguments runs as an observer; its return is ignored and the loader warns once per callback: `post hook '<name>': legacy 1-arg callback; add a trailing _result param (2)` (the counts are the callback's and the expected parameters).
- Null is the pass-through value; a post hook cannot set the result to null.
- A post hook that awaits cannot change the result: the wrapper has returned by the time it resumes. The loader warns once (`post hook '<name>' awaits, so its return cannot replace the result`) and the value passes through.
- Void methods have no result. That includes the engine lifecycle methods (`_ready`, `_process`, `_physics_process`, `_input`, `_unhandled_input`, `_unhandled_key_input`, `_enter_tree`, `_exit_tree`, `_notification`), whatever their annotations say.

## Priorities and dispatch order

Callbacks on one name run in ascending `priority` (default 100). Ties have no guaranteed order, so give callbacks whose order matters distinct priorities.

`hook()` and `unhook()` from inside a callback affect later dispatches only: a dispatch iterates a snapshot. A callback whose owner was freed is unhooked the next time its name dispatches, or when another mod asks for the replace slot it held.

Hooks fire once per logical call across `extends` chains: a mod script that extends wrapped vanilla and calls `super()` does not dispatch twice. A mod override that does not call `super()` suppresses dispatch for that method.

That re-entry guard is per instance and per hook, and on a coroutine it is held across the `await`. A second call to the same wrapped coroutine on the same node while the first is suspended runs vanilla with no hooks; the next call after the first finishes dispatches normally. To observe every call, hook a synchronous method the coroutine calls, or a `-callback` on its caller.

## Wrap surface -- why `hook()` alone is not enough

Registering a hook does not wrap anything. The set of wrapped methods is fixed when the hook pack is generated, before your autoload's `_ready`, from `[hooks]` sections, literal `.hook("...")` calls found by the source scan, early `add_hook()` calls, the six registry target scripts when any mod declares `[registry]`, and the loader's own wrap of `Menu.gd`'s `_ready`. A name built at runtime, a `hook_many` key or a setup-plan entry is invisible to the scan: declare its script in `[hooks]`. [Hook-Surface](Hook-Surface) lists what cannot be wrapped, the `[hooks]` syntax and the boot report that says what was wrapped.

### Compile probe before packing

Each rewrite is compiled before it is packed. When a game update renames a member the loader's registry code names, the script ships with hooks but without registry code, or, when no rewritten form compiles, runs vanilla and its hooks never fire. The log shows a `[STABILITY]` critical right below the engine's `Parse Error` line, the boot report marks the script `PARTIAL` or `LOST`, and the next launcher shows a red banner naming it. The fix is a loader update. [Stability-Canaries](Stability-Canaries#pre-ship-compile-probe) has when the probe runs and what it logs.

## Composing with `[script_extend]`

A mod can replace a vanilla script through `[script_extend]` (or its alias `[script_overrides]`; see [Mod-Format](Mod-Format)), by shipping its own file at `res://Scripts/<Name>.gd`, or with a runtime `take_over_path`. When that path is also in the wrap surface, the replacement loses: the loader applies overrides before it generates the hook pack, and activating the pack reloads the vanilla path with the rewritten source. Vanilla methods still dispatch hooks; the replacement's own code does not run that session. The loader warns twice, naming the mod (`is rewritten for hooks and also replaced by`, then `is replaced by the rewrite this session`).

A script deferred to lazy compile (one with a module-scope scene preload, listed under `DEFER` in the boot log; see [Limitations](Limitations#scene-preload-deferred-compile)) is the exception: it compiles after the overrides, the replacement extends the rewrite and both run. For any other hooked script, hook the methods you need instead of replacing the script.

## Related

- [Hook-Surface](Hook-Surface): what gets wrapped, `[hooks]`, `add_hook`, the reconciliation report
- [Hook-Pack](Hook-Pack): the generated wrapper and how the pack is built and activated
- [Mod-Format](Mod-Format): the full `mod.txt` schema
- [Build-2-Migration](Build-2-Migration): fixing a hook after a game update renamed its method
