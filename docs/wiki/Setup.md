# Setup -- declarative plans

`lib.setup(plan)` runs an ordered list of `[verb, ...args]` entries that map to the existing registry and hook APIs. It's designed for mods whose `_ready` is mostly administrative -- one line per hook, one per registration. With `setup`, the entire installation phase becomes one literal that can sit at module scope or be built locally in `_ready`.

```gdscript
const PLAN = [
    ["register", lib.Registry.ITEMS,   {...}],
    ["patch",    lib.Registry.ITEMS,   {...}],
    ["append",   lib.Registry.ITEMS, "compatible", {...}],
    ["hooks",    {...}],
    ["when", _is_hardcore_mode, [
        ["patch", lib.Registry.ITEMS, {...}],
    ]],
]

func _ready() -> void:
    var lib = Engine.get_meta("RTVModLib")
    await lib.frameworks_ready
    lib.setup(PLAN)
```

`setup` doesn't introduce new behavior -- it dispatches each entry to the existing public verbs. Anything you can do with `register` / `override` / `patch` / `append` / `prepend` / `remove_from` / `revert` / `remove` / `hook_many` you can do here, plus a meta verb `when` for conditional sub-plans.

## Verb shapes

| Entry | Maps to |
|---|---|
| `["register", reg, {id: data, ...}]` | `register_many` |
| `["override", reg, {id: data, ...}]` | `override_many` |
| `["patch", reg, {id: fields, ...}]` | `patch_many` |
| `["append", reg, field, {id: values, ...}]` | `append_many` (de-dup default) |
| `["append", reg, field, {id: values, ...}, true]` | `append_many(allow_duplicates=true)` |
| `["prepend", reg, field, {id: values, ...}]` | `prepend_many` |
| `["prepend", reg, field, {id: values, ...}, true]` | `prepend_many(allow_duplicates=true)` |
| `["remove_from", reg, field, {id: values, ...}]` | `remove_from_many` |
| `["revert", reg, {id: fields_array, ...}]` | `revert_many` (empty array = full revert of that id) |
| `["remove", reg, [id, id, ...]]` | `remove_many` |
| `["hooks", {hook_name: callback, ...}]` | `hook_many` |
| `["when", predicate, sub_plan]` | Recurse into `sub_plan` if `predicate` is truthy |

## Predicates for `when`

Predicates accept three shapes:

```gdscript
["when", _hardcore_mode, [...]]                     # plain bool (member var)
["when", _has_global_economy, [...]]                # named Callable
["when", func(): return OS.has_feature("debug"), [...]]  # lambda
```

Evaluated when `setup` traverses the entry. A plan built in `_ready` can use runtime state freely. A `const PLAN = [...]` with non-Callable predicates evaluates them at script-parse time -- fine for compile-time constants but wrong for runtime state, so prefer Callable predicates in `const` plans.

A skipped `when` (predicate false) returns `ok=true` -- it succeeded by not running anything.

Nested `when` works as expected: the inner sub-plan only runs when both predicates evaluate truthy. There's no `unless` or `else` verb -- compose two `when` entries with negated predicates if you need branching.

## Order matters

Entries run in the order written. Insertion order is the source of truth. If you `register` an item and then `patch` it, write `register` first; the patch sees the just-registered entry. If you reverse the order the patch fails (no such id yet), and the register lands afterward unaffected.

The same applies across registries. If a recipe references an item, register the item first. If you mix `revert` and `remove` after registers/patches, those run last and cleanly undo.

## Failure isolation

A bad entry (malformed shape, unknown verb, validation failure inside a verb) produces an `ok=false` result for that entry but **doesn't stop the next entry from running**. This matches the singular-verb and `_many` behavior. Mods that want fail-fast can inspect the result list themselves.

## Return shape

```gdscript
{
    "ok": bool,                # true only if every executed entry succeeded
    "results": Array,          # one entry per top-level plan entry, in order
}
```

Each item in `results` is a per-entry dict matching the verb:

- Data verbs: `{verb, ok, results: {id: bool}}`
- `hooks`: `{verb, ok, results: {hook_name: hook_id_or_-1}}`
- `when`: `{verb, ok, evaluated, results?}` -- `results` present only when `evaluated=true`
- Malformed: `{verb, ok: false, error: "..."}`

Top-level `ok` is `true` only when every executed entry succeeded. A skipped `when` doesn't break this -- nothing failed because nothing ran.

```gdscript
var result: Dictionary = lib.setup(plan)
if not result.ok:
    for i in result.results.size():
        var r: Dictionary = result.results[i]
        if not bool(r.get("ok", false)):
            push_warning("[mymod] entry %d (%s) failed: %s" \
                    % [i, r.get("verb", "?"), r.get("error", "see log")])
```

## Comprehensive example

A plan exercising every verb shape and predicate variant:

```gdscript
extends Node

const _PotionScript := preload("res://Scripts/ItemData.gd")
const _RecipeScript := preload("res://Scripts/RecipeData.gd")

var _hardcore_mode: bool = false
var _lib

func _ready() -> void:
    _lib = Engine.get_meta("RTVModLib")
    await _lib.frameworks_ready

    var my_potion: ItemData = _build_potion()
    var my_grenade: ItemData = _build_grenade()
    var my_recipe: RecipeData = _build_recipe(my_potion)
    var ak12_mag: Resource = load("res://Items/Weapons/AK-12/AK-12_Magazine.tres")
    var aks74u_mag: Resource = load("res://Items/Weapons/AKS-74U/AKS-74U_Magazine.tres")

    var plan: Array = [
        # --- register: add brand-new entries ------------------------------
        # Order across entries matters: the recipe references my_potion, so
        # register the potion first.
        ["register", _lib.Registry.ITEMS, {
            "my_mod_potion":  my_potion,
            "my_mod_grenade": my_grenade,
        }],
        ["register", _lib.Registry.RECIPES, {
            "my_mod_potion_recipe": {"recipe": my_recipe, "category": "consumables"},
        }],

        # --- override: replace a vanilla entry wholesale ------------------
        ["override", _lib.Registry.SCENES, {
            "Potato": preload("res://my_mod/scenes/golden_potato.tscn"),
        }],

        # --- patch: scalar field updates, multi-id, multi-registry --------
        ["patch", _lib.Registry.ITEMS, {
            "res://Items/Weapons/AKM/AKM.tres":  {"damage": 45.0, "weight": 3.2},
            "res://Items/Weapons/AK74/AK74.tres": {"damage": 40.0},
        }],
        ["patch", _lib.Registry.RESOURCES, {
            "res://Resources/GameData.tres": {"walk_speed": 5.5},
        }],

        # --- append: add to an Array field, dedup default -----------------
        # Single value or Array on the right side; both forms work.
        ["append", _lib.Registry.ITEMS, "compatible", {
            "res://Items/Weapons/AKM/AKM.tres":   [ak12_mag, aks74u_mag],
            "res://Items/Weapons/AK-12/AK-12.tres": aks74u_mag,
        }],

        # --- append with allow_duplicates=true ----------------------------
        # Rare: when you genuinely want repeats (weighted lists, etc.).
        ["append", _lib.Registry.ITEMS, "compatible", {
            "res://Items/Weapons/AK-12/AK-12.tres": ak12_mag,
        }, true],

        # --- prepend: insert at the front ---------------------------------
        ["prepend", _lib.Registry.SOUNDS, "audio", {
            "footsteps_dirt": preload("res://my_mod/sounds/squelch.ogg"),
        }],

        # --- remove_from: drop matching entries ---------------------------
        # Removes ALL occurrences. Idempotent if nothing matches.
        ["remove_from", _lib.Registry.ITEMS, "compatible", {
            "res://Items/Weapons/AKM/AKM.tres": ak12_mag,
        }],

        # --- hooks: batched hook registration -----------------------------
        ["hooks", {
            "interface-getmagazine":     _replace_get_mag,
            "ai-_physics_process-pre":   _on_phys_pre,
            "interface-close-post":      _on_close_post,
            "loader-loadscene-callback": _on_scene_loaded,
        }],

        # --- when: plain bool predicate -----------------------------------
        ["when", _hardcore_mode, [
            ["patch", _lib.Registry.ITEMS, {
                "res://Items/Weapons/AKM/AKM.tres": {"damage": 30.0},
            }],
        ]],

        # --- when: named Callable predicate -------------------------------
        ["when", _has_global_economy, [
            ["patch", _lib.Registry.RESOURCES, {
                "res://my_mod/Configs/scarcity.tres": {"enabled": true},
            }],
        ]],

        # --- when: lambda predicate ---------------------------------------
        ["when", func(): return OS.has_feature("debug"), [
            ["hooks", {
                "loader-loadscene-pre": _debug_logger,
            }],
        ]],

        # --- nested when --------------------------------------------------
        # Outer + inner predicates AND together.
        ["when", _has_global_economy, [
            ["when", _hardcore_mode, [
                ["patch", _lib.Registry.ITEMS, {
                    "res://Items/Misc/Sticks/Sticks.tres": {"value": 500},
                }],
            ]],
        ]],

        # --- revert: undo a previous patch (per-field or full) ------------
        ["revert", _lib.Registry.ITEMS, {
            "res://Items/Weapons/AK74/AK74.tres":  ["damage"],   # one field only
            "res://Items/Weapons/AKM/AKM.tres":    [],            # full revert
        }],

        # --- remove: undo a previous register() ---------------------------
        # Vanilla ids need revert; this only removes mod-registered entries.
        ["remove", _lib.Registry.RECIPES, ["my_mod_potion_recipe"]],
    ]

    var result: Dictionary = _lib.setup(plan)

    # Per-entry diagnostics if something failed.
    if not result.ok:
        for i in result.results.size():
            var r: Dictionary = result.results[i]
            if not bool(r.get("ok", false)):
                push_warning("[mymod] plan entry %d (%s) failed: %s" \
                        % [i, r.get("verb", "?"), r.get("error", "see log")])


# Predicate helpers used in `when` entries.
func _has_global_economy() -> bool:
    return _lib.has_mod("global-economy")


# Hook bodies referenced in the `hooks` entry.
func _replace_get_mag(_weaponData, _weaponSlot, _swapMag) -> bool:
    return false

func _on_phys_pre(_delta: float) -> void: pass
func _on_close_post() -> void: pass
func _on_scene_loaded(_scene_name) -> void: pass
func _debug_logger(_scene_name) -> void: print("[mymod] loading scene")
```

What the example demonstrates, top to bottom:

| Section | Feature |
|---|---|
| `register` × 2 | Multiple registries, register-before-reference order |
| `override` | Whole-entry replace on scenes |
| `patch` × 2 | Multi-id, multi-registry, items + resources together |
| `append` | Multi-id with mixed single-value and Array values, default dedup |
| `append` (5-arg) | `allow_duplicates=true` form |
| `prepend` | Insert-at-front on a different registry (sounds) |
| `remove_from` | Drop matching values from an Array field |
| `hooks` | Batched hook registration mixing pre/post/replace/callback variants |
| `when` (bool) | Plain bool predicate from a member variable |
| `when` (named) | Callable referencing a method by name |
| `when` (lambda) | Inline closure |
| `when` (nested) | Predicates compose; inner runs only if both are truthy |
| `revert` | Per-id field arrays; mixed per-field and full-revert in one call |
| `remove` | Undo a `register` from earlier in the plan |

One subtlety: the **`remove` entry at the end removes the recipe registered at the top of the same plan**. That works because entries run in sequence; the recipe exists by the time the remove runs. Failure isolation means each entry stands alone, but order determines which ones land.

## When not to use setup

`setup` is for installation-phase work that runs once. Mods doing any of these still want imperative code in `_ready`:

- Connecting to signals, scheduling timers, spawning UI nodes
- File I/O or network requests
- Long-running async work
- Anything that needs to react to runtime events after the initial setup

Use `setup` for the static, declarative slice and write whatever else you need around it.

## See also

- [Registry](Registry) -- the underlying verbs `setup` dispatches to
- [Hooks](Hooks) -- hook registration, the `["hooks", {...}]` entry maps to `hook_many`
