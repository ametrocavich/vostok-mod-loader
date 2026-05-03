# Native / GDExtension Mods

Optional native-code support. A mod can ship a `.gdextension` file plus its compiled libraries, and the loader hands it to `GDExtensionManager.load_extension()` after archive mount and before the mod's bridge autoload runs.

This is an unofficial experimental fork feature. **Native mods can execute arbitrary machine code and cannot be sandboxed by this loader.** The launcher pops a confirmation gate every time you launch with a native mod enabled. Only enable native mods from authors you trust.

## When to use it

Most gameplay tweaks should stay in GDScript. It's faster to iterate on, the source-rewrite hook system catches more, and the loader's opt-in wrap surface composes naturally across mods.

Reach for `[gdextension]` only when GDScript can't reasonably do what you need: heavy per-frame numerical work, integration with native libraries (audio engines, physics solvers, networking stacks), or existing C++ code you don't want to port.

If you're carrying an existing GDScript mod that's pegging the frame budget on hot paths, see [VMZ-to-CPP](VMZ-to-CPP) for a step-by-step walkthrough of what changes.

## `[gdextension]` schema

```ini
[gdextension]
BetterBallistics="res://BetterBallistics/bin/better_ballistics.gdextension"
```

| Field | Meaning |
|---|---|
| key | Symbolic name shown in the launcher and log lines. No functional meaning |
| value | Quoted `res://` path to a `.gdextension` file inside the mod archive |

You can declare multiple entries under one mod. Each materializes and loads independently -- one failing doesn't block the others.

### Path validation

Each value must:

- Begin with `res://`
- End with `.gdextension`
- Have no `..` segments, no leading slash, no drive letter (`C:`), no UNC (`//server/share`), no backslashes

Invalid entries get an orange warning on the mod row and inside the `native code` modal. The remaining valid entries still load.

## Packaging layout

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

The `.gdextension` file is a standard Godot `ConfigFile` -- Godot parses it for `[configuration]` and `[libraries]`. Library entries inside it should reference the compiled binaries by either:

- Absolute `res://` path inside the same archive (`res://BetterBallistics/bin/windows/better_ballistics.dll`), or
- Path relative to the `.gdextension` file's own directory (`windows/better_ballistics.dll`).

Library entries that resolve outside the mod archive, or that contain unsafe path segments, fail materialization and the extension is not loaded.

## Bridge autoload pattern

A native mod needs a small GDScript autoload to wire its native methods into the hook system. The loader can't scan compiled C++ for `.hook(...)` calls, so the bridge is what actually registers the callbacks.

`mod.txt`:

```ini
[autoload]
BetterBallisticsBridge="res://BetterBallistics/bridge.gd"

[hooks]
res://Scripts/WeaponRig.gd = shoot, reload
res://Scripts/Projectile.gd = *
```

`BetterBallistics/bridge.gd`:

```gdscript
extends Node

func _ready():
    var lib = Engine.get_meta("RTVModLib")
    if not lib._is_ready:
        await lib.frameworks_ready

    var native = BetterBallisticsNative.new()
    lib.hook("weaponrig-shoot-pre", Callable(native, "on_shoot_pre"))
    lib.hook("projectile-update-post", Callable(native, "on_projectile_update_post"))
```

`BetterBallisticsNative` is a `GDCLASS`-registered class exported by your `.gdextension`. It's available on the GDScript side once `GDExtensionManager.load_extension(...)` has run, which the loader does before instantiating any normal `[autoload]` declared by the mod.

**The bridge has to be a normal `[autoload]`, not an early autoload (`!`-prefixed).** Early autoloads land in `override.cfg`'s `[autoload_prepend]` and run during engine boot, which is before the loader's `_ready` calls `GDExtensionManager.load_extension`. A native class referenced from an early-autoload bridge won't be found.

## `[hooks]` is required for native hook surfaces

The opt-in hook system in v3.0.1 enrolls a vanilla method in the wrap surface only when:

- A mod calls `.hook("stem-method-variant", cb)` in its **GDScript** source -- the source-rewrite scanner picks the call up at pack generation time, OR
- The mod declares the path in `[hooks]` in `mod.txt`.

Native mods can't satisfy the first rule -- the call lives inside a `.dll` / `.so` / `.dylib` and is invisible to a source scanner. So **every vanilla method a native mod intends to hook MUST be listed in `[hooks]`**, by name or via `*`:

```ini
[hooks]
res://Scripts/WeaponRig.gd = shoot, reload    # named methods
res://Scripts/Projectile.gd = *                # whole script
```

Without the declaration, the dispatch wrappers don't exist, the bridge registers a hook name nothing calls, and your callback never fires.

## Native cache layout

The loader copies each `.gdextension` and every referenced library into a per-mod cache:

```text
user://modloader_native/<safe_id>/<version_or_mtime>/
```

`<safe_id>` is `mod_id` lowercased with anything outside `[a-z0-9_-.]` replaced by `_`. `<version_or_mtime>` is the mod's declared version when present, otherwise `mtime<N>` from the source archive. A re-packaged mod with the same version still gets a fresh cache because the mtime branch falls back automatically when the version dir already exists.

Library paths inside the cached `.gdextension` get rewritten to `user://` paths into the cache. The original file inside the mounted archive is not what `dlopen` ends up loading -- it's the cache copy.

The cache is regenerated on every launch. Wiping it manually (`rm -rf %APPDATA%\Road to Vostok\modloader_native`) is safe; the next launch re-materializes everything.

`[icon]` sections get dropped during materialization. They're editor-only and frequently reference paths outside the mod archive.

## Load order

1. `_mount_previous_session()` (static-init): re-mounts archives from prior pass-state.
2. `load_all_mods()`: mounts mod archives, parses each `mod.txt`, queues autoloads, builds the hook wrap mask.
3. `_register_rtv_modlib_meta()` + `_generate_hook_pack()`: register `Engine.get_meta("RTVModLib")` and emit the dispatch wrappers.
4. **`_load_native_extensions_for_enabled_mods()`**: for each enabled mod with a non-empty `[gdextension]`, materialize files into the cache and call `GDExtensionManager.load_extension(<cache_path>)`.
5. `_instantiate_autoload(...)` per queued normal autoload: bridge `_ready` runs, awaits `frameworks_ready`, registers hooks via `lib.hook(...)`.
6. `_emit_frameworks_ready()`.

State-hash inputs include each native extension's `mod_id`, name, declared `res://` path, and the source archive's mtime. Toggling a native mod on or off changes the hash and triggers a Pass-2 restart so the freshly-materialized cache is the one the next engine session loads, not whatever Pass 1 saw.

## Recovery and safe mode

The existing recovery paths cover native mods:

- **Reset to Vanilla** (UI button) wipes `override.cfg`, pass state, and the hook cache, then restarts. Native cache files persist on disk but no `load_extension` call fires for them on the next clean launch.
- **`modloader_safe_mode` sentinel file**: same effect as Reset.
- **`modloader_disabled` sentinel file**: skips the entire loader, including native materialization. The game starts vanilla.
- **Crash recovery**: after `MAX_RESTART_COUNT` (2) crashes, the loader auto-resets state. A native binary that segfaults inside its own code can take down the process before this counter ticks; in practice the next launch still resets because `override.cfg` already references the broken setup.

A native binary that segfaults inside its own code can crash the process before any of this fires. The loader can detect *broken materialization* (missing files, parse failures, unsafe paths -- all graceful) but cannot detect *broken native code*.

## Diagnostics

Boot log lines worth grepping for when debugging a native mod:

| Line | Meaning |
|---|---|
| `[NativeExt] <mod> declares N native extension(s)` | Section parsed, at least one entry validated |
| `[NativeExt] Loaded <name> -> <user_path>` | `load_extension` returned `LOAD_STATUS_OK` |
| `[NativeExt] cannot read .gdextension via VFS: <res_path>` | Archive mount worked but the file inside is missing or empty |
| `[NativeExt] failed to parse .gdextension: <res_path>` | Bad INI / not a real `.gdextension` file |
| `[NativeExt] <res> [libraries] <key>: unsafe ...` | Path validation rejected a library entry |
| `[NativeExt] <res> [libraries] <key>: library not packaged` | Feature-tag library missing on disk -- skipped, won't load |
| `[NativeExt] needs an engine restart to fully activate` | `LOAD_STATUS_NEEDS_RESTART` -- the next Pass-2 cycle satisfies it |
| `[NativeExt] GDExtensionManager.load_extension(...) returned status N` | Engine refused the load. N is a `GDExtensionManager.LoadStatus` enum value |

Per-entry validation errors also show up on the mod row in the launcher (orange warning text) and inside the `native code` modal.

## Known limitations

- **No sandboxing.** Native code runs with the full privileges of the game process.
- **No binary hook scanning.** Hook surfaces have to be declared in `[hooks]`; the loader can't read compiled C++.
- **Bridges can't be early autoloads.** A `!`-prefixed bridge runs before `GDExtensionManager.load_extension` and won't be able to construct native classes.
- **Process-level crashes are not catchable.** A segfault inside a native lib terminates the process. Restart-loop recovery eventually clears state but can't rescue an in-flight crash.
- **Windows is the primary tested target.** Linux and macOS support hinges on the mod packaging the right platform binaries; the loader skips missing platform libraries (logged at debug level) rather than erroring out, but a Windows-only pack won't run anywhere else.
- **`reloadable=true` extensions still cause a restart on toggle.** State-hash inputs treat any `[gdextension]` change as significant and force a Pass-2 restart.

## Author checklist

- `mod.txt` has both `[gdextension]` and a normal `[autoload]` bridge declaration
- Bridge is **not** `!`-prefixed
- Every vanilla method the native code touches is listed in `[hooks]`
- Compiled libraries live inside the mod archive at the path the `.gdextension` references
- No `..` / absolute / drive-letter / UNC paths anywhere inside the `.gdextension`
- Launching pops the native-code warning before the game starts -- if it doesn't, the section didn't parse
