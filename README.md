# Archive: PCK Hooks Engineering

**Status: ARCHIVED — This approach was superseded by the node_added architecture.**

This branch preserves the PCK binary modification code that was developed to handle
scripts where `take_over_path()` alone appeared insufficient (Item, Grid, WeaponRig).

## Why It Was Built

We observed failures when subclassing certain scripts (Item, Grid, WeaponRig) and
incorrectly attributed them to typed array validation rejecting subclass instances.
This led to building a pipeline that modifies the game's .pck file to inject hook
scripts before Godot's `init_cache()` runs.

## Why It's Not Needed

The real issue was **pre-cached PackedScenes** — Database.gd preloads 323 items at
engine init, and those scenes hold direct pointers to original scripts. The fix is
simply catching nodes via `SceneTree.node_added` and swapping scripts at runtime with
property preservation. This was proven by tetra's RTVModLib (132 scripts, 2500 hooks,
pure GDScript, no PCK editing).

Confirmed from Godot 4.6.1 C++ source:
- `is ClassName` works for subclasses (pointer walk via `get_base_script()`)
- `Array[ClassName]` accepts subclasses (`inherits_script()` walks base chain)
- UID references resolve to `res://` paths first — take_over_path catches them

## What's In Here

- `modloader.gd` — contains the PCK modification pipeline (~700 lines), GDSC binary
  tokenizer, PCK v3 format reader/writer, in-place hook preprocessing
- `override.cfg` — standard override config

## The One Real Limitation

`ClassName.new()` for Resource-extending classes (SlotData, save classes) bypasses
both ResourceCache and the scene tree. This is the only case where PCK modification
would actually help. See the `feature/pck-hooks` branch history for details.
