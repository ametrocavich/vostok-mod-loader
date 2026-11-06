# Hook surface

The wrap surface is the set of vanilla methods the hook pack wraps. A hook fires only on a wrapped method, so this page says what enters the surface, what cannot, how to declare a target by hand and how the boot log reports the result. [Hooks](Hooks) covers registering callbacks.

## What enters the surface

The surface is fixed once per launch, when the hook pack is generated, before any mod autoload's `_ready` runs. It is the union of:

1. `[hooks]` sections in any enabled mod's `mod.txt` (below).
2. Literal `.hook("<stem>-<method>...")` calls the source scan finds in a mod's own `.gd` files, in either quote style.
3. `add_hook()` calls that run before generation, which means from a `!` early autoload's `_init`.
4. The loader's own wrap of `Menu.gd`'s `_ready`, for the main-menu Mods button.
5. When any mod declares `[registry]`: every method of the six registry targets, `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd` and `Compiler.gd` ([Registry](Registry#opting-in)).

A hook name built at runtime, a `hook_many` key and a `["hooks", {...}]` entry in a [setup plan](Setup-Plans) are not `.hook("...")` literals, so the scan does not see them; declare their scripts in `[hooks]`. With nothing declared, the boot log says `No user opt-in declarations ([hooks] / .hook() / [registry]); core hooks only` and every other vanilla script runs unmodified. A wrapped method nobody hooks runs vanilla after a few flag checks.

## What cannot be hooked

- Paths outside `res://Scripts/*.gd`. The report marks them `LOST` with `non-vanilla path -- only res://Scripts/*.gd is hookable`.
- Static functions, `@rpc` methods, methods with a rest parameter (`...args`) and methods whose declaration spans several lines. Each declared one warns `Hook on <file>::<method> will NEVER fire:` followed by the reason.
- Scripts the game ships as zero-byte files.
- Scripts on the loader's skip lists: runtime-sensitive scripts such as `MuzzleFlash.gd`, and save and data resource classes such as `ItemData.gd`. A hook declared on one warns and is reported `LOST`; [Limitations](Limitations#scripts-deliberately-not-rewritten) lists them.
- A script whose rewrite does not compile against the current game build ([Hooks](Hooks#compile-probe-before-packing)).

## Declaring targets in `[hooks]`

Declare vanilla paths in `mod.txt` when the scan cannot see your registration: `add_hook()` from a normal autoload (generation has already run), a `.hook()` call that is not in your mod's own source, names built at runtime, or methods you will only hook later on gameplay events.

```ini
[hooks]
res://Scripts/Interface.gd = "Close, CalculateDeal"    # these methods
res://Scripts/Controller.gd = "*"                       # every method
res://Scripts/Camera.gd = ""                            # empty means *
```

- Quote the value. `ConfigFile` parses it as a Variant literal, so an unquoted list or bare `*` is a parse error; the loader quote-wraps unquoted values and strips inline `#` and `;` comments, but quoted is the portable form.
- Method names match vanilla names case-insensitively.
- `*` mixed with named methods in one value: `*` wins, with a warning.
- A wildcard from one mod widens every other mod's method list for that path; a per-method entry cannot narrow it.
- A value with no method names (only commas) is ignored with a warning.

## `ModLoader.add_hook()` compat

Mods written for [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) call `add_hook(script_path, method_name, callback, is_before)`. The shim builds `<stem>-<method>-pre` or `-post` (lowercased), adds the method to the wrap surface and calls `hook(name, cb, 100)`. Two traps:

- Timing. The surface is fixed before normal autoloads run, so `add_hook()` from a regular autoload's `_ready` registers a hook that never fires. Call it from a `!` early autoload's `_init` (`Name="!res://MyMod/Early.gd"` in `[autoload]`, see [Mod-Format](Mod-Format)) or declare the path in `[hooks]`.
- Paths. A bare file name becomes `res://Scripts/<file>`. Anything elsewhere needs its full `res://` path, or the enrollment matches nothing.

## The reconciliation report

The last thing hook-pack generation logs is a ledger of every declared script target.

- All wrapped: `Hook reconciliation OK: N/N declared script target(s) wrapped`.
- A target not in the pack: a critical header, then one `LOST <file> :: <methods> (declared by <mod> via <source>) -- <reason>` line per target.
- A script wrapped with some declared methods missing: `PARTIAL <file> (declared by <mod>): wrapped, but missing: <method>`, next to a `will NEVER fire: no such method in vanilla` warning. Declared names are checked even when `[registry]` widened the script to every method.
- A `.hook()` literal whose stem matches no vanilla script warns `no vanilla script matches prefix '<stem>'` at load time.

The hook status record keeps missing targets, skipped targets (skip list, data classes, a failed probe) and partially wrapped scripts apart, and the next launcher shows each class on its own warning line. After a game update, a `will NEVER fire` warning on a hook that worked before the update means the game renamed or removed the method; [Build-2-Migration](Build-2-Migration) walks through finding the new name.

## Related

- [Hooks](Hooks): hook names, the API, replace and post semantics
- [Hook-Pack](Hook-Pack): how the surface becomes rewritten scripts
- [Mod-Format](Mod-Format): the rest of `mod.txt`
