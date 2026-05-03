# Converting a `.vmz` Mod to C++ / GDExtension

This page walks through taking an existing GDScript `.vmz` mod and porting all or part of it to C++ via Godot 4.6's GDExtension. It assumes you already have a working GDScript mod, you've read [Native-Mods](Native-Mods), and you accept that native code can't be sandboxed and runs with the full privileges of the game process.

Most mods don't need this. The opt-in hook system is fast enough for almost everything you'd want to do at the GDScript layer. If you're considering a port for "cleanliness," stop -- the loader has none of the cross-mod composition guarantees for native code that it has for GDScript, and you'll trade a friendly source-scan workflow for a build-and-redistribute-binaries workflow. Port when GDScript is genuinely the bottleneck, not before.

## When porting is worth it

Reasonable reasons:

- **Hot per-frame numerical work.** Trajectory integration, large array transforms, dense physics math that profiles consistently as the dominant cost.
- **Existing C++ you already have.** Audio engines, physics solvers, networking stacks, game-logic libraries you don't want to re-implement in GDScript.
- **Tight bindings to native APIs.** OS-level features Godot doesn't expose, hardware access, etc.

Bad reasons:

- "GDScript is slower." It is, but in most mod hot paths the slowness is caller-driven (calling `lib.hook` 10k times a frame is the problem, not the language). Profile first.
- "C++ is more professional." It's also more crashy, more annoying to redistribute, and harder for anyone but you to debug.
- "I want to hide my source." `.gdc` bytecode + an obfuscated archive layout already makes casual inspection annoying. A native lib still shows symbols and string tables.

## What carries over unchanged

The archive (`.vmz`), the `mod.txt` schema, your `[hooks]` declarations, your `[autoload]` block, your `[script_extend]` overrides, and your `[registry]` data all behave exactly the same after a port. The native lib slots in alongside them; it doesn't replace them.

In particular, you keep:

- The `.vmz` extension and the rest of the existing packaging.
- Every line of `mod.txt` you already had.
- Any GDScript files you don't choose to port -- they keep working as autoloads, overrides, and so on.
- The hook system. Native methods register through the same `Engine.get_meta("RTVModLib").hook(...)` API.

What you add:

- A `[gdextension]` section pointing at your new `.gdextension` file.
- The compiled `.dll` / `.so` / `.dylib` for whatever platforms you're shipping.
- A small GDScript "bridge" autoload that constructs the native class and registers its methods as hook callbacks.

## Walkthrough -- a worked example

Starting point: `BetterBallistics.vmz`, a GDScript mod that recomputes projectile drop in `_post` after `Projectile.update`. The hot path is the math; everything else (configuration, UI, save/load) is fine in GDScript.

### Original `.vmz` layout

```text
BetterBallistics.vmz
  mod.txt
  BetterBallistics/
    main.gd
    config.gd
```

`mod.txt`:

```ini
[mod]
name="Better Ballistics"
id="better_ballistics"
version="1.0.0"

[autoload]
BetterBallistics="res://BetterBallistics/main.gd"
```

`main.gd`:

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
    _lib.hook("projectile-update-post", _on_projectile_update)

func _on_projectile_update(delta):
    var p = _lib._caller
    # 60+ lines of position integration, drag, wind, ...
```

The scanner sees `_lib.hook("projectile-update-post", ...)` in `main.gd` and auto-enrolls `Projectile.gd :: update`. No `[hooks]` section needed.

### Step 1: install godot-cpp

Clone the matching godot-cpp branch for your engine version. Road to Vostok ships on Godot 4.6, so:

```bash
git clone --branch 4.6 https://github.com/godotengine/godot-cpp
cd godot-cpp
scons platform=windows target=template_release
```

If you've never touched godot-cpp before, start at the [official GDExtension docs](https://docs.godotengine.org/en/stable/contributing/development/core_and_modules/custom_modules_in_cpp.html) and the godot-cpp README. This page won't reproduce that setup -- it picks up after you have a working godot-cpp checkout building.

### Step 2: write the native class

Inside a separate working directory (NOT inside the eventual `.vmz`), set up a small SCons project that links against godot-cpp. The native class:

```cpp
// src/better_ballistics_native.h
#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

class BetterBallisticsNative : public RefCounted {
    GDCLASS(BetterBallisticsNative, RefCounted)

protected:
    static void _bind_methods();

public:
    void on_projectile_update_post(double delta);
};

}
```

```cpp
// src/better_ballistics_native.cpp
#include "better_ballistics_native.h"
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

void BetterBallisticsNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("on_projectile_update_post", "delta"),
                         &BetterBallisticsNative::on_projectile_update_post);
}

void BetterBallisticsNative::on_projectile_update_post(double delta) {
    // The hook system stashes the receiver in lib._caller. Pull it back
    // through the registered Engine meta so we can mutate it.
    Variant lib_v = Engine::get_singleton()->get_meta("RTVModLib");
    if (lib_v.get_type() != Variant::OBJECT) return;
    Object *lib = Object::cast_to<Object>(lib_v);
    if (!lib) return;
    Object *p = Object::cast_to<Object>(lib->get("_caller"));
    if (!p) return;

    // ... the same math the GDScript version did, but in C++ ...
}
```

`_bind_methods` is the part that makes `on_projectile_update_post` callable from a `Callable(native, "on_projectile_update_post")` on the GDScript side. Forget it and your hook will register but never fire.

Build it:

```bash
scons platform=windows target=template_release
# produces e.g. bin/windows/better_ballistics.dll
```

### Step 3: write the `.gdextension` descriptor

```ini
; bin/better_ballistics.gdextension
[configuration]
entry_symbol = "better_ballistics_library_init"
compatibility_minimum = "4.4"

[libraries]
windows.x86_64 = "windows/better_ballistics.dll"
linux.x86_64   = "linux/libbetter_ballistics.so"
macos          = "macos/libbetter_ballistics.dylib"
```

Library values can be paths relative to this file's directory (preferred -- the loader's path validator is happiest with these) or absolute `res://` paths inside the same archive. The loader rejects anything with `..`, drive letters, leading slashes, UNC paths, or backslashes; see [Native-Mods#path-validation](Native-Mods#path-validation).

The library `.gdextension` always references at registration time is the platform-tag match for your build, so a Windows-only release packaging only the `windows/` subdir is valid. The loader skips missing platform binaries with a debug-level log line; it does not error.

### Step 4: write the bridge autoload

The native class doesn't exist on the GDScript side until `GDExtensionManager.load_extension` has run. The loader runs that call after archive mount and **before** any normal `[autoload]` instantiates, so a normal autoload's `_ready` can `BetterBallisticsNative.new()` cleanly. Early autoloads (the `!`-prefixed ones) run too early -- the native class won't be there yet and the bridge will fail.

`bridge.gd`:

```gdscript
extends Node

var _native: RefCounted = null

func _ready():
    var lib = Engine.get_meta("RTVModLib")
    if not lib._is_ready:
        await lib.frameworks_ready

    _native = BetterBallisticsNative.new()
    lib.hook("projectile-update-post", Callable(_native, "on_projectile_update_post"))
```

Hold a strong reference to the native instance in a script-level var. `RefCounted` instances die the moment nothing references them, and a `Callable` does not count as a strong reference. If you only keep the native object alive through the `Callable`, your hook will fire once or twice and then start producing freed-instance errors.

### Step 5: rewrite `mod.txt`

```ini
[mod]
name="Better Ballistics"
id="better_ballistics"
version="2.0.0"

[gdextension]
BetterBallistics="res://BetterBallistics/bin/better_ballistics.gdextension"

[autoload]
BetterBallisticsBridge="res://BetterBallistics/bridge.gd"

[hooks]
res://Scripts/Projectile.gd = update
```

Three things changed from the original:

- New `[gdextension]` block points at the descriptor inside the mod.
- The autoload now points at `bridge.gd` (which is tiny) instead of `main.gd` (which had all the logic).
- `[hooks]` is now mandatory. The original mod was auto-enrolled because the scanner saw `lib.hook("projectile-update-post", ...)` in `main.gd`. The compiled `.dll` is opaque to the scanner, so `Projectile.gd :: update` won't be wrapped unless you list it here.

### Step 6: repackage

```text
BetterBallistics.vmz
  mod.txt
  BetterBallistics/
    bridge.gd
    bin/
      better_ballistics.gdextension
      windows/
        better_ballistics.dll
      linux/
        libbetter_ballistics.so
      macos/
        libbetter_ballistics.dylib
```

Pack the directory the way you packed your original `.vmz`. On Windows, do not use the built-in "Send to compressed folder" or `ZipFile.CreateFromDirectory()` -- they write entries with `\` separators that Godot can't resolve. Use 7-Zip. See [Mod-Format#archive-packaging-gotchas](Mod-Format#archive-packaging-gotchas).

Drop the `.vmz` into your mods folder, launch, click through the native-code confirmation dialog, and look for these lines in the boot log:

```
[NativeExt] Better Ballistics declares 1 native extension(s)
[NativeExt] Loaded BetterBallistics -> user://modloader_native/better_ballistics/2.0.0/better_ballistics.gdextension [Better Ballistics]
```

If you don't see the confirmation dialog at launch, your `[gdextension]` section didn't parse -- check the mod row for an orange validation error.

## Iterate loop

Editing native code is slower than editing GDScript by a factor of a build step. The cycle that scales:

1. Edit C++.
2. `scons platform=windows target=template_release`.
3. Replace the `.dll` inside your unpacked mod source tree.
4. Repack `.vmz`. (Or: enable [Developer-Mode](Developer-Mode) and run from an unpacked folder; skip the repack.)
5. Restart the game. Bump the mod version any time you ship -- `<version>` keys the cache dir, and unbumped reloads still get a fresh tree because the loader falls back to source-archive mtime.

If you're iterating in developer mode, rebuilds of the same `.dll` get picked up automatically because the mtime fallback covers the case where `version` didn't change. The cache layout is documented at [Native-Mods#native-cache-layout](Native-Mods#native-cache-layout).

## What to leave in GDScript

A blanket "rewrite everything to C++" is the wrong shape. The hot path is one or two methods; the rest of the mod is configuration, UI, save/load glue, debug commands, and so on. All of those are easier to maintain in GDScript and don't profile out as bottlenecks.

A reasonable split for the BetterBallistics example:

| Concern | Language |
|---|---|
| Per-frame trajectory math | C++ |
| Configuration parsing (read a `.ini` once at boot) | GDScript |
| Optional debug HUD overlay | GDScript |
| Save/load slot integration | GDScript |
| Update checking (`[updates]` ModWorkshop block) | GDScript -- handled by the loader, no code needed |

You can have multiple GDScript autoloads in the same mod alongside the bridge. Native code talks back to them through `Engine.get_singleton()` lookups by autoload name, the same way it talks to vanilla.

## Common pitfalls

**The bridge fires a freed-instance error after a few frames.** The native class is `RefCounted` and you only kept a reference through a `Callable`. Hold the instance in a script-level var on the bridge node.

**Hook registers but the callback never fires.** Either the method isn't in `[hooks]` (the source scanner can't see your `.dll`), or `_bind_methods` doesn't expose the method, or your hook name is misspelled. Hook names are lowercase: `<scriptname>-<methodname>[-pre|-post|-callback]`. See [Hooks#hook-names](Hooks#hook-names).

**Bridge is `!`-prefixed.** Early autoloads run before `GDExtensionManager.load_extension`, so the native class isn't registered yet when the bridge's `_init` / `_ready` runs. Strip the `!`. If you need something to happen at engine boot before mods finish loading, that thing has to stay in GDScript.

**`load_extension` returns `LOAD_STATUS_NEEDS_RESTART`.** Some extensions can't be hot-loaded into an already-running engine. The two-pass restart flow already handles this: toggling the mod on changes the state hash, the loader restarts, and on Pass 2 the lib comes up clean. Users hit the warning once, not every launch.

**The launcher doesn't show the native-code confirmation dialog, and the mod row has no badge.** The `[gdextension]` section didn't parse. Check `entry["gdextension_errors"]` -- they appear inline as orange warnings on the mod row. Common causes: forgot to quote the value (ConfigFile requires it), backslash in the path, missing `.gdextension` suffix.

**Crash with no log line at the moment a hook fires.** The native lib is segfaulting inside its own code. The loader can detect *broken materialization* (missing files, bad paths, parse failures) but not *broken native code*. Run the game from a debugger or attach one post-hoc. After two crashes the loader auto-resets state via `MAX_RESTART_COUNT`, so you'll get a clean next-launch even from a hard fault loop.

**Hooks silently stop firing on Linux/macOS even though the binaries are packaged.** Library entries inside the `.gdextension` are case-sensitive on those platforms. `Linux.x86_64` and `linux.x86_64` are different keys. Match the casing godot-cpp's example uses (`linux.x86_64`, `macos`, etc.).

## Cross-platform builds

The loader will skip platform binaries it can't find rather than failing the whole load. If you ship Windows-only:

```ini
[libraries]
windows.x86_64 = "windows/better_ballistics.dll"
```

That's a valid `.gdextension`. Linux and macOS users will see the mod row, the badge, and the launch warning, but the native `[libraries]` entries simply won't resolve and the bridge's `BetterBallisticsNative.new()` will fail. Either gate the bridge body on `ClassDB.class_exists("BetterBallisticsNative")` and degrade gracefully, or document the platform limitation in your mod description.

To ship cross-platform you compile godot-cpp on each target OS (Windows native, Linux native, macOS native) and produce a binary per platform. There's no realistic shortcut -- WSL works for Linux, but macOS builds genuinely need a Mac. Build farms / CI runners are the usual answer for serious mods.

## Related

- [Native-Mods](Native-Mods) -- schema, validation, cache layout, recovery
- [Mod-Format](Mod-Format) -- full `mod.txt` schema, packaging gotchas
- [Hooks](Hooks) -- hook names, dispatch semantics, the public API surface your bridge talks to
- [Limitations](Limitations) -- known issues that affect both GDScript and native paths
