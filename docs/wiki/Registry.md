# Registry

The registry lets your mod add, replace, patch, and remove content in the vanilla game's data stores -- items, loot tables, recipes, sounds, events, trader stock and tasks, input actions, scenes, shelters and maps, AI types and loadouts, fish, arbitrary `.tres` fields, and node properties inside vanilla scenes -- without shipping a rewritten `Database.gd` or editing vanilla files. Every mutation is tracked, so anything you do can be cleanly undone (`register` <-> `remove`, `override`/`patch` <-> `revert`).

Use it whenever your mod changes *game data*. To intercept *game code*, use [Hooks](Hooks) instead.

## Quick start -- the 90% case

Get the API object, then register/patch from your mod's `_ready()`:

```gdscript
var lib = Engine.get_meta("RTVModLib")

func _ready() -> void:
    # Minimal REGISTER: new item + drop it into a loot table
    var elixir: Resource = load("res://mods/mymod/elixir.tres")  # an ItemData .tres
    lib.register(lib.Registry.ITEMS, "mymod_elixir", elixir)
    lib.register(lib.Registry.LOOT, "mymod_elixir_drop", {"item": elixir, "table": "LT_Master"})

    # Minimal PATCH: tweak fields on a vanilla item, revertable
    lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
```

Undo:

```gdscript
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # one field
lib.revert(lib.Registry.ITEMS, "Potato")              # everything on that id
lib.remove(lib.Registry.ITEMS, "mymod_elixir")        # undo a register
```

Two prerequisites:

1. **`mod.txt` must contain a `[registry]` section.** An empty section is enough -- the loader only checks for its presence. Without it, several registries silently or loudly fail; see [Opting in](#opting-in). Full `mod.txt` reference: [Mod-Format](Mod-Format).
2. **Register during your mod's `_ready()`.** Traders, loot containers, the crafting UI, and the event system copy from the shared stores in their own `_ready()` and never re-read. Registering later mutates the store but is invisible in-game. See [Timing](#timing).

If you need hooks or other framework state first, `await lib.frameworks_ready` before registering.

Everything below is reference: [constants and data shapes](#registry-constants), [verb semantics](#verb-semantics), [per-registry details](#per-registry-reference), [aggregator helpers](#aggregator-helpers) (one-call weapon/furniture bundles), [reading](#reading-the-registry), [gotchas](#gotchas).

## Opting in

Mods that use the registry API declare an opt-in section in `mod.txt`:

```ini
[registry]
```

An empty `[registry]` section is enough; the loader only checks for its presence. Adding the section forces the rewriter to wrap `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd`, and `Compiler.gd` with the injected fields the registry API needs (see `REGISTRY_TARGETS` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)).

Without the declaration, the rewriter doesn't inject the machinery several vanilla-backed slots rely on. Behavior splits by slot:

- **Explicit failure with hint.** SCENES and SCENE_PATHS check for the injected fields on the autoload (`_rtv_mod_scenes` on Database, `_rtv_mod_scene_paths` on Loader) and fail with a `push_warning` about the missing injection (the Database messages name the `[registry]` section explicitly; the Loader ones say the rewriter didn't fire). Mod authors see the real cause immediately.
- **Silent no-op.** AI_TYPES, AI_LOADOUTS, and FISH_SPECIES write to `Engine.set_meta(...)` that the rewriter-injected resolver/prelude on AISpawner / AI / FishPool would normally read. Without rewriting, `register` returns true with no warning but vanilla never reads the meta entries, so the override is invisible in-game.
- **Loud failure or warned no-op.** SHELTERS and MAPS need the rewriter to convert vanilla's `const shelters = [...]` to a `var` (so it can be appended to) and to inject the `_rtv_mod_shelters` dict the spawn prelude reads. Without the declaration, a registration that carries a `path` fails through the SCENE_PATHS check above; a path-less registration warns about the missing injection but still returns `true` while doing nothing usable in-game.
- **Works regardless.** ITEMS, LOOT, RECIPES, EVENTS, SOUNDS, INPUTS, TRADER_POOLS, TRADER_TASKS, RANDOM_SCENES, RESOURCES, and SCENE_NODES mutate loaded Resources, `InputMap`, or plain vars (or, for `scene_nodes`, use a `SceneTree.node_added` listener) and track state in the registry's own internal dicts. They don't need any vanilla rewriting.

Add `[registry]` whenever you use the API. It's free if you only touch the last bucket, and necessary for anything else.

## Timing

**Register during your mod's `_ready()`**, before vanilla game systems finish initializing. Several consumers populate local caches once and never re-read:

- Trader stock, `LootContainer`, and `LootSimulation` copy from `LootTable` resources in their own `_ready()`.
- The crafting `Interface` copies recipe arrays in its `_ready()`; `EventSystem` copies events; traders copy tasks.
- `AudioLibrary` fields are read by `@export` binding at autoload time.
- `InputMap` actions registered after gameplay starts work but don't appear in the remapping UI until a scene reload.

Mod autoloads load **after** vanilla autoloads and **before** the first scene, so registering inside your mod's `_ready()` is almost always early enough. If you need hooks to finish first, `await lib.frameworks_ready` before any `register` call.

Runtime re-registration after scene load is invisible to systems that already cached: the registry updates the underlying store, but the cache holds the old snapshot. This is the number-one "my register returned true but nothing changed" cause.

## Public API

Mods reach the loader the same way as the hook system: `Engine.get_meta("RTVModLib")`. Source: [src/registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd).

### Methods

| Method | Purpose |
|---|---|
| `register(registry, id, data) -> bool` | Add a new entry. Fails on id collision with vanilla or prior mod registrations |
| `override(registry, id, data) -> bool` | Replace an existing entry wholesale. Fails if the id doesn't resolve |
| `patch(registry, id, fields) -> bool` | Mutate individual fields on an entry. Original values are stashed for revert |
| `append(registry, id, field, values, allow_duplicates=false) -> bool` | Add to an Array field. De-dups by default. Stash shared with `patch` |
| `prepend(registry, id, field, values, allow_duplicates=false) -> bool` | Same as `append` but inserts at the front |
| `remove_from(registry, id, field, values) -> bool` | Drop matching values from an Array field. Removes all occurrences, idempotent |
| `remove(registry, id) -> bool` | Undo a `register`. Fails on override-backed ids (use `revert`) and vanilla entries |
| `revert(registry, id, fields=[]) -> bool` | Undo an `override` or `patch`. Per-field revert when `fields` is non-empty |
| `register_many(registry, {id: data, ...}) -> Dictionary` | Batched register; returns `{ok, results}` |
| `override_many(registry, {id: data, ...}) -> Dictionary` | Batched override |
| `patch_many(registry, {id: fields, ...}) -> Dictionary` | Batched patch |
| `append_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched append on the same field across many ids |
| `prepend_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched prepend |
| `remove_from_many(registry, field, {id: values, ...}) -> Dictionary` | Batched remove_from |
| `revert_many(registry, {id: fields_array, ...}) -> Dictionary` | Batched revert; per-id `fields_array` (empty `[]` = full revert of that id) |
| `remove_many(registry, [id, ...]) -> Dictionary` | Batched remove (takes an Array of ids, not a dict) |
| `setup(plan) -> Dictionary` | Declarative entry point: list of `[verb, ...args]` entries dispatched in order. See [setup plans](#setup----declarative-plan) |
| `get_entry(registry, id) -> Variant` | Read the current entry (after any registry mutations). Returns `null` if missing |
| `has(registry, id, include_vanilla=true) -> bool` | Membership check. Cheaper than `get_entry(...) != null` |
| `keys(registry, include_vanilla=true) -> Array[String]` | All ids in the registry |
| `list(registry, include_vanilla=true) -> Dictionary` | All `id -> entry` pairs |
| `find(registry, predicate, include_vanilla=true) -> Array` | Filtered iteration; returns `[{id, entry}, ...]` |

Every mutating verb returns a bool indicating success; failures log a `push_warning` with the reason, and an empty id is rejected up front. The read methods (`get_entry`, `has`, `keys`, `list`, `find`) never warn on a missing id; they return empty / null / false. `get_entry` still warns (and returns `null`) when pointed at a registry with no readable entries -- `scene_nodes`, the aggregator-only registries -- or at an unknown registry name.

### Registry constants

Use `lib.Registry.<NAME>` rather than raw strings so typos surface at parse time:

| Constant | String | Underlying store | Verbs supported |
|---|---|---|---|
| `SCENES` | `"scenes"` | `Database.gd` scene consts | register, override, remove, revert |
| `ITEMS` | `"items"` | `ItemData` `.tres` keyed by `file` | register, override, patch, append/prepend/remove_from, remove, revert |
| `LOOT` | `"loot"` | `LootTable.items` arrays | register, override, remove, revert |
| `SOUNDS` | `"sounds"` | `AudioLibrary.tres` `@export` fields | register, override, patch, append/prepend/remove_from, remove, revert |
| `RECIPES` | `"recipes"` | `Recipes.tres` category arrays | register, override, patch, append/prepend/remove_from, remove, revert |
| `EVENTS` | `"events"` | `Events.tres` events array | register, override, patch, append/prepend/remove_from, remove, revert |
| `TRADER_POOLS` | `"trader_pools"` | Per-item trader boolean flags | register, remove, revert (alias of remove) |
| `TRADER_TASKS` | `"trader_tasks"` | `TraderData.tasks` arrays | register, override, patch, append/prepend/remove_from, remove, revert |
| `INPUTS` | `"inputs"` | `InputMap` actions | register, override, patch, remove, revert |
| `SCENE_PATHS` | `"scene_paths"` | Named scene lookup on `Loader.gd` | register, override, patch, remove, revert |
| `SHELTERS` | `"shelters"` | `Loader.shelters` append-only list | register, remove (revert = alias) |
| `MAPS` | `"maps"` | Non-persistent named areas on `Loader`; shares the shelters storage | register, remove (revert = alias) |
| `RANDOM_SCENES` | `"random_scenes"` | `Loader.randomScenes` append-only list | register, remove (revert = alias) |
| `AI_TYPES` | `"ai_types"` | Zone -> agent scene overrides on `AISpawner` | register, override, remove, revert |
| `AI_LOADOUTS` | `"ai_loadouts"` | Per-AI-category weapon injections (`AI.SelectWeapon` prelude) | register, override, remove, revert |
| `FISH_SPECIES` | `"fish_species"` | `FishPool` extra species | register, remove (revert = alias) |
| `RESOURCES` | `"resources"` | Arbitrary `.tres` by absolute `res://` path | patch, append/prepend/remove_from, revert |
| `SCENE_NODES` | `"scene_nodes"` | Property mutations on nodes inside any scene | patch, revert |
| `WEAPONS` | `"weapons"` | Aggregator-only; routes to `register_weapon` | register (collapses to bool) |
| `MAGAZINES` | `"magazines"` | Aggregator-only; routes to `register_magazine` | register (collapses to bool) |
| `ATTACHMENTS` | `"attachments"` | Aggregator-only; routes to `register_attachment` | register (collapses to bool) |

Unsupported verbs return `false` with a guidance warning that points at the right tool (e.g. patch on `loot`: loot entries are ItemData references; patch the ItemData via the `items` registry instead).

Aggregator-only registries (`WEAPONS`, `MAGAZINES`, `ATTACHMENTS`) reject `override`/`patch`/`remove`/`revert` at the standard-verb dispatcher with guidance to use the underlying primitives. They exist so mods that want bool-only routing (e.g. checking `register('weapons', ...)` in a generic loop) get consistent behavior, but the dedicated `register_weapon` / etc. methods are the preferred way to call them since you get the granular result dict.

### Data shapes at a glance

| Registry | `register` data | `override` data | `patch` fields / notes |
|---|---|---|---|
| scenes | `PackedScene` | `PackedScene` | no patch (monolithic) |
| items | `ItemData` Resource (register sets `data.file = id`) | `ItemData` Resource | any declared property; unknown fields warn + skip |
| loot | `{item: ItemData, table: String}` | register shape + `replaces: ItemData` | no patch -- patch the ItemData via `items` |
| sounds | `AudioEvent`, bare `AudioStream`, or `{audioClips, volume, randomPitch}` | same coercion; id must be a real `AudioLibrary` `@export` field | `{audioClips, volume, randomPitch}` subset |
| recipes | `{recipe: RecipeData, category: String}` | register shape + `replaces: RecipeData` | patch by String handle OR direct `RecipeData` ref |
| events | `{event: EventData}` | `{event, replaces: EventData}` | patch by handle OR `EventData` ref |
| trader_pools | `{item: ItemData, trader: String}` | n/a | n/a; remove/revert restore the stashed flag |
| trader_tasks | `{task: TaskData, trader: String}` | register shape + `replaces: TaskData` | patch by handle OR `TaskData` ref |
| inputs | `{display_label?, default_event: InputEvent, deadzone? = 0.5}` -- **the id IS the action name** | same shape | only `display_label` / `default_event` / `deadzone` |
| scene_paths | `{path: String, menu?, shelter?, permadeath?, tutorial?}` | same shape | open dict -- any field accepted |
| shelters / maps | `{path?, transition_text?, exit_spawn?, entrance_spawn?, connected_to?, connected_content?, shelter?}` | n/a | n/a |
| random_scenes | `{path: String}` | n/a | n/a |
| ai_types | `{scene: PackedScene, zone: String}` (zone: Area05 / BorderZone / Vostok) | same shape (forcibly claims the zone) | no patch |
| ai_loadouts | `{weapon_scene: PackedScene or String, ai_types: [String], chance? = 1.0, replace? = false}` | same shape (id must exist) | no patch -- override to replace |
| fish_species | `{scene: PackedScene, pool_id? = "all"}` | n/a | n/a |
| resources | n/a | n/a | id = absolute `res://` path; any declared field |
| scene_nodes | n/a | n/a | id = `"<scene_path>#<node_path>"`; `#` or `#.` targets the scene root |

Details and examples per registry in the [per-registry reference](#per-registry-reference).

## Verb semantics

### register

Adds a genuinely new entry. Fails if:
- The id matches a vanilla const/field name on the underlying store (use `override` instead)
- The id was already registered by a prior mod registration (or prior `register` call this session)
- The payload fails the registry's shape check (wrong type, missing keys)

### override

Replaces an existing entry wholesale. The new payload takes the slot; the original is stashed for revert.

```gdscript
lib.override(lib.Registry.ITEMS, "Potato", my_replacement_item)
var current = lib.get_entry(lib.Registry.ITEMS, "Potato")  # returns my_replacement_item
lib.revert(lib.Registry.ITEMS, "Potato")                    # back to vanilla
```

Most registries reject a second `override` of an already-overridden id ("revert first"): `scenes`, `loot`, `recipes`, `events`, `trader_tasks`, `ai_types`, `ai_loadouts`. The in-place registries (`items`, `sounds`, `inputs`, `scene_paths`) accept it: the second override wins, and the stash keeps the pre-first-override original (first-write-wins), so a full `revert` still restores vanilla. Overrides on mod registrations are allowed (except on `sounds`, which only overrides vanilla field names) -- use this to resolve same-id conflicts between mods without touching the loser's code.

### patch

Mutates specific fields on the current entry (vanilla, override, or prior `register`). Stash-and-restore semantics: the first patch to a field saves its pre-patch value; subsequent patches to the same field don't re-stash, so a full `revert` returns to the true original.

```gdscript
lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # restore just weight
lib.revert(lib.Registry.ITEMS, "Potato")              # restore everything else
```

The `id` is a String for most registries, but `recipes`, `events`, and `trader_tasks` also accept a **direct Resource ref** (`RecipeData` / `EventData` / `TaskData`) so you can patch vanilla entries without registering a handle first.

Registries that don't support patch (loot, scenes, trader_pools, shelters, maps, random_scenes, ai_types, ai_loadouts, fish_species) return `false` with guidance pointing at the right alternative.

**Return-value drift** (documented as-is): `items`/`sounds`/`recipes`/`events`/`trader_tasks` return `true` whenever the id resolves, even if every field was rejected as unknown (each bad field warns and is skipped). `resources` and `inputs` return `false` unless at least one field actually applied. `scene_nodes` validates up front and rejects the whole patch if any field is missing. `scene_paths` entries are open dicts, so any field name is accepted. All handlers return `false` when the id doesn't resolve.

### append / prepend / remove_from

Array-only mutations on a single field. Use these instead of `patch` when you want to **add to** or **subtract from** an existing array (e.g. a weapon's `compatible` list) without overwriting entries other mods may have contributed.

```gdscript
# Add new magazines as compatible options on the AKM, without clobbering vanilla's
# list. Items ids are ItemData.file strings ("AKM"), not .tres paths:
lib.append(lib.Registry.ITEMS, "AKM", "compatible", [magA, magB])

# Single value also works (no need to wrap in an array):
lib.append(lib.Registry.ITEMS, "AKM", "compatible", magC)

# Insert at the front instead of the end:
lib.prepend(lib.Registry.SOUNDS, "knifeSlash", "audioClips", newClip)

# Remove an entry; silent skip if it isn't there.
lib.remove_from(lib.Registry.ITEMS, "AKM", "compatible", oldMag)
```

**Semantics:**
- **Array fields only.** Calling on a non-Array field returns `false` with a "field is not an Array" warning. For scalar fields, use `patch` instead.
- **De-dup on append/prepend by default.** If a value is already in the array, it isn't appended again. Pass `allow_duplicates=true` to permit repeats.
- **`remove_from` removes all matching occurrences,** not just the first. Idempotent -- re-running with the same value is a no-op after the first call.
- **`prepend` preserves argument order:** `prepend(..., [a, b])` on `[c]` yields `[a, b, c]`.
- **`null` values are rejected; an empty values Array is a warned no-op.**
- **Stash is shared with `patch`.** A `patch` on `compatible` followed by `append` to `compatible` keeps the *original* (pre-patch, pre-append) value on first-write-wins. `revert(reg, id, ["compatible"])` restores the true original.
- **Typed-array safety.** Every value is validated against the array's declared type up front; one bad value rejects the whole call before any mutation (all-or-nothing).

**Supported registries:** `items`, `sounds`, `recipes`, `events`, `trader_tasks`, `resources`. Other registries either don't have Array fields (`inputs`, `scene_paths`) or have non-Resource entries (`scenes`, `loot`, `shelters`, etc.); calls return `false` with guidance.

### remove

Reverses a prior `register`. Fails on override-backed ids ("use revert") and on vanilla entries.

### revert

Reverses an `override` or `patch`. Fails if there's nothing to undo (nothing overridden and no field stashes).

- Bare `revert(registry, id)` with no `fields` argument unwinds everything for that id: **patches are restored first, then the override is dropped** (the ordering is load-bearing -- patches were applied on top of the override).
- `revert(registry, id, ["field1", "field2"])` unwinds only those specific patched fields; other patches and the override stay.

On `shelters` / `maps` / `random_scenes` / `fish_species` / `trader_pools`, `revert` is accepted as an alias for `remove`.

### Batched forms (`*_many`)

Every mutation verb has a sibling that takes a Dictionary of ids (or, for `remove_many`, an Array). One call, many entries, single registry. Useful for table-driven mods that already store their data as a dict.

```gdscript
# Patch many items in one call (items ids are ItemData.file strings).
lib.patch_many(lib.Registry.ITEMS, {
    "AKM":   {"damage": 45},
    "AK_12": {"damage": 40},
})

# Append the same field across many ids. NOTE: field comes BEFORE the entries dict.
lib.append_many(lib.Registry.ITEMS, "compatible", {
    "AKM":   [magA, magB],
    "AK_12": [magC],
})

# Per-id field lists for revert. Empty array = full revert of that id.
lib.revert_many(lib.Registry.ITEMS, {
    "AKM":   ["damage", "compatible"],
    "AK_12": [],
})

# Remove a list of mod-registered entries.
lib.remove_many(lib.Registry.ITEMS, ["my_mod_potion", "my_mod_grenade"])
```

**Return shape.** Each `_many` returns `{ok: bool, results: {id: bool, ...}}`. `ok` is true only when every entry succeeded. Failures are isolated -- one bad id doesn't stop the others, and the per-id success bools tell you which ones landed.

```gdscript
var result := lib.patch_many(lib.Registry.ITEMS, {...})
if not result.ok:
    for id in result.results:
        if not result.results[id]:
            push_warning("[mymod] failed to patch %s" % id)
```

**One field per call** for the array verbs. `append_many` / `prepend_many` / `remove_from_many` all take a single `field` arg that applies to every entry in the dict. If you need different fields per id, make multiple calls -- or use `setup` (below), which runs an ordered sequence of verbs in one call.

**`revert_many` values must be Arrays.** `{id: "field"}` is rejected with a warning, not coerced -- pass `["field"]`, or `[]` for a full revert of that id. This is a deliberate typo guard.

### setup -- declarative plan

`setup(plan)` runs an ordered list of `[verb, ...args]` entries that map to the registry verbs above plus `hooks` (batched hook registration), the aggregator helpers, and `when` (conditional sub-plans). One declarative literal replaces the typical pile of administrative `_ready` lines. Order is insertion order, so register-then-patch flows work; failures are isolated per entry.

```
["register",    reg, {id: data, ...}]
["override",    reg, {id: data, ...}]
["patch",       reg, {id: fields_dict, ...}]
["append",      reg, field, {id: values, ...}]        # optional 5th arg true = allow_duplicates
["prepend",     reg, field, {id: values, ...}]        # same
["remove_from", reg, field, {id: values, ...}]
["revert",      reg, {id: fields_array, ...}]         # [] = full revert of that id
["remove",      reg, [id, id, ...]]
["hooks",       {hook_name: callback, ...}]           # routes to hook_many
["register_item",       {id: data, ...}]              # aggregators: no reg arg
["register_weapon",     {id: data, ...}]
["register_magazine",   {id: data, ...}]
["register_attachment", {id: data, ...}]
["register_furniture",  {id: data, ...}]
["register_ai_loadout", {id: data, ...}]
["when",        predicate, sub_plan]                  # predicate: bool | Callable -> bool
```

```gdscript
func _ready() -> void:
    var lib = Engine.get_meta("RTVModLib")
    await lib.frameworks_ready
    lib.setup([
        ["register", lib.Registry.ITEMS, {"mymod_potion": potion_data}],
        ["patch",    lib.Registry.ITEMS, {"AKM": {"damage": 45}}],
        ["append",   lib.Registry.ITEMS, "compatible", {"AKM": [magA]}],
        ["hooks",    {"interface-getmagazine": _replace_get_mag}],
        ["when",     func(): return some_runtime_flag, [
            ["patch", lib.Registry.ITEMS, {"Sticks": {"value": 200}}],
        ]],
    ])
```

Returns `{ok: bool, results: Array}` -- one result per top-level entry: `{"verb": ..., "ok": bool, "results": {...}}`; malformed entries yield `{"verb", "ok": false, "error"}`; `when` yields `{"verb": "when", "evaluated": bool, "ok": bool, "results"?}` (results present only when evaluated). Skipped `when` blocks report `ok = true`.

**`when` predicate caveat:** a Callable is evaluated at `setup()` traversal time; bools and numbers coerce as-is; `null` counts as false; anything else warns and counts as false. In a `const` plan, non-Callable predicates evaluate at *script-parse* time -- use Callables/lambdas for runtime state.

**`hooks` wrap-surface caveat:** hook names in a plan are plain Dictionary keys, not literal `.hook("...")` calls, so the loader's source scanner does not enroll their targets in the wrap surface. Make sure each target is wrapped some other way -- a literal `.hook()` call elsewhere in your source, or a `[hooks]` declaration in `mod.txt`. See [Hooks](Hooks#wrap-surface----why-hook-alone-is-not-enough).

See **[Setup-Plans](Setup-Plans)** for the full verb table, predicate forms, return shape, and an example covering every supported entry.

## Conflict-handling fundamentals

The rules that apply across every registry:

- **`register` on a colliding id fails.** Whether the collision is with vanilla or with an earlier mod's registration, the second caller's `register` returns `false` with a `push_warning`. No silent overwrite.
- **`override` on an already-overridden id fails on the array-swap and slot registries** (`scenes`, `loot`, `recipes`, `events`, `trader_tasks`, `ai_types`, `ai_loadouts`): the second caller must `revert` first. On the in-place registries (`items`, `sounds`, `inputs`, `scene_paths`) the second override succeeds and wins; the stash still holds the true original, so `revert` returns to vanilla.
- **`patch` on the same field stacks.** Both writes apply in call order; last writer's value is visible. The stash preserves the **true vanilla original** (the first patcher's pre-patch value), so a later `revert` returns to vanilla, not to the first patcher's value. Mod A's patch is lost on revert even if Mod A didn't call revert themselves.
- **`patch` on different fields coexists.** Independent stash per field name; both mods' patches are respected simultaneously.
- **Array-based registries (`loot`, `recipes`, `events`, `trader_tasks`) are additive on `register`.** Two mods registering different ids into the same array both succeed; the array just grows.
- **Array `override` (the `replaces:` form) fails if the target is already gone.** If mod A swapped `vanillaX` for `newA`, mod B can't also swap `vanillaX` -- it's no longer in the array. Mod B would have to target `newA` instead (which then silently undoes mod A's swap; avoid this).

---

## Per-registry reference

Each section below has a minimal example per verb and any registry-specific edges.

### SCENES

Scene constants on `Database.gd` (e.g. `Potato`, `Beer`, `Cabin`). Keyed by the const name. Verbs: `register`, `override`, `remove`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var my_scene = preload("res://mymod/scenes/Biscuit.tscn")

# register: add a new scene name
lib.register(lib.Registry.SCENES, "mymod_biscuit", my_scene)

# override: replace the scene a vanilla const resolves to
lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/scenes/GoldenPotato.tscn"))

# remove: undo a register
lib.remove(lib.Registry.SCENES, "mymod_biscuit")

# revert: undo an override
lib.revert(lib.Registry.SCENES, "Potato")
```

**Conflicts.** Two mods overriding the same vanilla scene: second mod fails with `"already overridden (revert first to re-override)"`. First mod's scene is what players see.

### ITEMS

`ItemData` Resources (or subclasses: WeaponData, AttachmentData, etc.) keyed by their `file` property. Ids are `file` strings (`"Potato"`, `"AKM"`), **not** `res://` paths -- to patch a Resource by path, use the [`RESOURCES`](#resources) registry instead. Verbs: all five plus the array verbs.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var elixir = load("res://mymod/items/Elixir.tres")

# register: sets elixir.file = "mymod_elixir" for you (vanilla code reads item.file)
lib.register(lib.Registry.ITEMS, "mymod_elixir", elixir)

# override: replace a vanilla item wholesale
lib.override(lib.Registry.ITEMS, "Potato", load("res://mymod/items/GoldenPotato.tres"))

# patch: mutate specific fields on the current entry
lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})

# get_entry: read current state
var current_potato = lib.get_entry(lib.Registry.ITEMS, "Potato")

# revert per-field
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])

# revert everything for this id (patches + override)
lib.revert(lib.Registry.ITEMS, "Potato")

# remove: undo register
lib.remove(lib.Registry.ITEMS, "mymod_elixir")
```

**Patches are global and persist into saves.** Godot's Resource cache shares one instance program-wide, so patching an item mutates it for every holder -- including what saves serialize (`SlotData` serializes ItemData by value). There is no per-save isolation; `revert` is the only undo.

**Conflicts.**
- Two overrides of the same item: both succeed, the second replaces the first (last write wins). The stash keeps the true original, so a `revert` returns to vanilla, not to the first mod's override.
- Two patches on the **same field**: both calls succeed, second value wins visually. The stash holds vanilla, so any revert on that id returns to vanilla, losing both patches.
- Two patches on **different fields**: both coexist independently.

### LOOT

Adds/swaps `ItemData` entries inside `LootTable.items`. IDs are mod-chosen handles (not tied to any in-game name). Verbs: `register`, `override`, `remove`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var fancy = load("res://mymod/items/FancyBandage.tres")

# register: append to a loot table
lib.register(lib.Registry.LOOT, "mymod_fancy_in_master", {
    "item": fancy,
    "table": "LT_Master",         # known table name or an absolute res:// path
})

# override: swap an existing entry for a new one
var replacement = load("res://mymod/items/ReplacementBandage.tres")
var vanilla_bandage = load("res://Items/Medical/Bandage/Bandage.tres")
lib.override(lib.Registry.LOOT, "mymod_swap_bandage", {
    "item": replacement,
    "table": "LT_Master",
    "replaces": vanilla_bandage,  # must be an ItemData already in the table
})

# remove: pull the registered item out of the table
lib.remove(lib.Registry.LOOT, "mymod_fancy_in_master")

# revert: reinstate the `replaces` item, drop the override
lib.revert(lib.Registry.LOOT, "mymod_swap_bandage")
```

Known table names (`table:` accepts these or an absolute `res://` path): `LT_Master`, `LT_Airdrop`, `LT_Patient_Report`, `LT_Punisher`, `LT_Oil_Sample`, `LT_Weapons_01` .. `LT_Weapons_04`, `LT_Ammo`, `LT_Medical`, `LT_Equipment`, `LT_Armor`, `LT_Grenades`, `LT_Attachments`, `LT_Items`, `Kit_Colt`, `Kit_Glock`, `Kit_MP5K`, `Kit_Makarov`, `Kit_Mosin`, `Kit_Remington`.

**Patch is not supported** on loot; loot entries are whole `ItemData` references, not dicts of fields. Patch returns `false` with guidance: patch the `ItemData` via the `items` registry instead.

**Conflicts.**
- Two `register` calls adding the same item to the same table: rejected as a duplicate (the table would contain the same `ItemData` twice).
- Two `override` calls with the same `replaces:` target: second fails because the first removed `replaces` from the table. Mod B would need to target mod A's new item; avoid this, it silently undoes mod A.

### SOUNDS

`AudioEvent` fields on `AudioLibrary.tres`, plus mod-registered lookup entries. Verbs: all five plus the array verbs.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var custom_event = preload("res://mymod/audio/Footstep.tres")  # AudioEvent

# register: add a new sound id (lookup via get_entry only; vanilla code
# can't reach these ids directly since it hardcodes property names)
lib.register(lib.Registry.SOUNDS, "mymod_custom_footstep", custom_event)

# register via Dictionary shorthand (builds an AudioEvent internally),
# or pass a bare AudioStream (wrapped with volume=0, randomPitch=false)
lib.register(lib.Registry.SOUNDS, "mymod_dict_sound", {
    "audioClips": [],
    "volume": -3.0,
    "randomPitch": true,
})

# override: replace a vanilla AudioLibrary @export field.
# `id` must match a real @export field name on AudioLibrary.tres;
# override rejects mod-registered ids.
lib.override(lib.Registry.SOUNDS, "knifeSlash", custom_event)

# patch: mutate AudioEvent fields (audioClips, volume, randomPitch)
lib.patch(lib.Registry.SOUNDS, "knifeSlash", {"volume": -10.0, "randomPitch": true})

# revert per-field / full / remove
lib.revert(lib.Registry.SOUNDS, "knifeSlash", ["randomPitch"])
lib.revert(lib.Registry.SOUNDS, "knifeSlash")
lib.remove(lib.Registry.SOUNDS, "mymod_custom_footstep")
```

**Only `override` and `patch` affect what vanilla plays.** Vanilla code hardcodes `audioLibrary.propertyName`, so mod-registered ids are unreachable from vanilla code paths -- fetch them yourself via `lib.get_entry` and play them from your own code/hooks. (Registrations live in the registry's own lookup dict, not on the AudioLibrary Resource; `audioLibrary.get("mymod_id")` returns null.)

**Conflicts.** Same rules as items. `register` collisions with vanilla `@export` field names are rejected (use `override`). Override only works on vanilla fields, never on mod-registered ids.

### RECIPES

`RecipeData` Resources in per-category arrays on `Recipes.tres`. Categories: `consumables`, `medical`, `equipment`, `weapons`, `electronics`, `misc`, `furniture`. Verbs: all five plus the array verbs. Patch accepts either a String handle OR a direct `RecipeData` ref.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var my_recipe = load("res://mymod/recipes/CraftElixir.tres")

# register
lib.register(lib.Registry.RECIPES, "mymod_craft_elixir", {
    "recipe": my_recipe,
    "category": "consumables",
})

# override: swap one recipe for another in the same category
var replacement = load("res://mymod/recipes/BetterElixir.tres")
lib.override(lib.Registry.RECIPES, "mymod_swap_elixir", {
    "recipe": replacement,
    "category": "consumables",
    "replaces": my_recipe,
})

# patch by handle
lib.patch(lib.Registry.RECIPES, "mymod_craft_elixir", {"time": 30.0, "shelter": true})

# patch by direct ref (no prior register needed; works on vanilla recipes too)
var vanilla_recipe = some_recipes_category_array[0]
lib.patch(lib.Registry.RECIPES, vanilla_recipe, {"time": 60.0})

# revert by handle or by ref
lib.revert(lib.Registry.RECIPES, "mymod_craft_elixir")
lib.revert(lib.Registry.RECIPES, vanilla_recipe)

# remove
lib.remove(lib.Registry.RECIPES, "mymod_craft_elixir")
```

**Locked crafting tabs unlock automatically.** Vanilla ships the Equipment and Misc crafting tabs disabled/faded because those categories are empty; registering a recipe into `equipment` or `misc` auto-patches the tab buttons clickable via the `scene_nodes` registry. You do not need to do it yourself.

**Conflicts.** Same as loot for `register`/`override`. Patches stack per field.

### EVENTS

`EventData` entries in `Events.tres`. Mirrors recipes exactly: `register`, `override`, `patch`, `remove`, `revert`, plus the array verbs. Patch accepts String handle or direct `EventData` ref.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var my_event = load("res://mymod/events/MeteorShower.tres")

lib.register(lib.Registry.EVENTS, "mymod_meteor", {"event": my_event})

lib.patch(lib.Registry.EVENTS, "mymod_meteor", {"possibility": 75, "day": 5})

# override with 'replaces:' required
var replacement = load("res://mymod/events/SolarFlare.tres")
lib.override(lib.Registry.EVENTS, "mymod_swap_event", {
    "event": replacement,
    "replaces": my_event,
})

lib.revert(lib.Registry.EVENTS, "mymod_meteor")
lib.remove(lib.Registry.EVENTS, "mymod_meteor")
```

**`EventData.function` must exist on `EventSystem`.** The string is resolved as a method name on the vanilla `EventSystem` when the event fires; a name that doesn't exist there makes the event a silent no-op. To run mod code from an event, point `function` at a vanilla method you've intercepted with a [hook](Hooks).

### TRADER_POOLS

Flips a trader's boolean flag on an `ItemData` (e.g. `item.doctor = true` puts the item in the Doctor's pool). Verbs: `register`, `remove`, `revert` (revert is a straight alias for remove).

```gdscript
var lib = Engine.get_meta("RTVModLib")
var potato = load("res://Items/Consumables/Potato/Potato.tres")

# register: enable item for the Doctor trader
lib.register(lib.Registry.TRADER_POOLS, "mymod_potato_doctor", {
    "item": potato,
    "trader": "Doctor",  # Generalist / Doctor / Gunsmith / Grandma; case-insensitive
})

# remove / revert: restore the original flag value
lib.remove(lib.Registry.TRADER_POOLS, "mymod_potato_doctor")
```

**No `override` or `patch`.** Pool membership is binary and ungated. Entries are keyed by the mod handle, not the item; two mods can independently enable the same item for the same trader.

**Conflicts.** Mostly harmless. The underlying flag is idempotent (`true` OR `true` = `true`). Duplicate registrations share the true original: when a second mod registers the same (item, trader) pair, its stash inherits the original value from the already-live handle, so once every handle is removed the flag correctly returns to its vanilla value. The one surprise left: `remove` restores the original immediately, so removing any one handle turns the flag off even while other mods' handles are still registered (last-remove doesn't win). Avoid double-registering the same item/trader pair across mods.

### TRADER_TASKS

`TaskData` entries in per-trader `tasks` arrays. Verbs: all five plus the array verbs. Patch accepts String handle or direct `TaskData` ref. `trader` is `"Generalist"`, `"Doctor"`, `"Gunsmith"`, or an absolute `res://` path to a `TraderData` resource.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var my_task = load("res://mymod/tasks/DeliverPotatoes.tres")

lib.register(lib.Registry.TRADER_TASKS, "mymod_potato_quest", {
    "task": my_task,
    "trader": "Generalist",
})

lib.patch(lib.Registry.TRADER_TASKS, "mymod_potato_quest", {"difficulty": "Hard"})

# override with 'replaces:' required
var replacement = load("res://mymod/tasks/DeliverBetterPotatoes.tres")
lib.override(lib.Registry.TRADER_TASKS, "mymod_swap_quest", {
    "task": replacement,
    "trader": "Generalist",
    "replaces": my_task,
})

lib.revert(lib.Registry.TRADER_TASKS, "mymod_potato_quest")
lib.remove(lib.Registry.TRADER_TASKS, "mymod_potato_quest")
```

**Conflicts.** Same as loot. Two mods trying to `override` the same task: second fails when `replaces` isn't in the array anymore.

### INPUTS

Declares new `InputMap` actions with a default event; lets mods rebind vanilla actions. Verbs: all five. **The registry id IS the InputMap action name** -- namespace it (`"mymod_heal"`, not `"heal"`).

```gdscript
var lib = Engine.get_meta("RTVModLib")
var key_h = InputEventKey.new()
key_h.keycode = KEY_H

# register a new action
lib.register(lib.Registry.INPUTS, "mymod_quick_heal", {
    "display_label": "Quick Heal",
    "default_event": key_h,
    "deadzone": 0.5,  # optional, default 0.5
})

# override an existing action's default event (vanilla or mod-registered)
var key_f = InputEventKey.new()
key_f.keycode = KEY_F
lib.override(lib.Registry.INPUTS, "forward", {
    "display_label": "Move Forward",
    "default_event": key_f,
})

# patch specific fields (display_label, default_event, or deadzone only)
lib.patch(lib.Registry.INPUTS, "mymod_quick_heal", {"display_label": "Heal!"})

lib.revert(lib.Registry.INPUTS, "forward")
lib.remove(lib.Registry.INPUTS, "mymod_quick_heal")
```

Registered actions work immediately via `Input.is_action_pressed("mymod_quick_heal")` in your own code.

**UI caveat.** Vanilla's Settings -> Keybinds panel reads from a hardcoded `inputs` dict inside `Inputs.gd`. Registering an action makes it functional in-game but it **won't appear in the rebind menu** without an additional hook on `inputs-createactions-pre` (hook names are always lowercase). See `src/registry/inputs.gd` for details.

**Conflicts.** Standard register rules. Two mods overriding the same action: both succeed, last write wins; the stash keeps the original event list, so `revert` restores it. InputMap rebinding is visible immediately; in-game key prompts update on next UI refresh.

### SCENE_PATHS

Named scene lookups on `Loader.gd` with optional `gameData` flags (`menu`, `shelter`, `permadeath`, `tutorial`). Verbs: all five. See [src/registry/loader.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/loader.gd).

```gdscript
var lib = Engine.get_meta("RTVModLib")

# register a new scene name
lib.register(lib.Registry.SCENE_PATHS, "mymod_bunker", {
    "path": "res://mymod/scenes/bunker.tscn",
    "shelter": true,
})

# override a vanilla scene const's path
lib.override(lib.Registry.SCENE_PATHS, "Cabin", {
    "path": "res://mymod/scenes/better_cabin.tscn",
    "shelter": true,
})

# patch just the flags (entries are open dicts; any field accepted)
lib.patch(lib.Registry.SCENE_PATHS, "mymod_bunker", {"permadeath": true})

lib.revert(lib.Registry.SCENE_PATHS, "Cabin")
lib.remove(lib.Registry.SCENE_PATHS, "mymod_bunker")
```

**Conflicts.** Vanilla-const collisions on `register` are rejected; use `override`. Two mods overriding the same vanilla scene path: both succeed, last write wins; `revert` (from either) drops the override and vanilla resolution returns.

### SHELTERS

Append-only list of shelter names on `Loader.shelters`. Verbs: `register`, `remove` only (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

# register with path: auto-creates paired scene_paths entry with shelter=true
lib.register(lib.Registry.SHELTERS, "mymod_bunker", {
    "path": "res://mymod/scenes/bunker.tscn",
})

# full registration dict (everything but `path` optional):
lib.register(lib.Registry.SHELTERS, "mymod_apartment", {
    "path": "res://mymod/scenes/apartment.tscn",
    "transition_text": "Apartment",       # loading-screen label; defaults to id
    "exit_spawn": "Door_Apartment_Exit",  # transition node to spawn at on arrival
    "entrance_spawn": "Door_Apartment",   # node in connected_to to spawn at when leaving
    "connected_to": "Map01",              # vanilla map where this shelter's entrance lives
    "connected_content": [                # spawned into /root/Map/Content on entering connected_to
        {"path": "res://mymod/props/door_frame.tscn",
         "position": Vector3(10, 0, 4), "rotation": Vector3(0, 90, 0)},
    ],
    "shelter": true,                      # default true here (false for MAPS)
})

# register without path: the name must already be a scene name resolvable
# by Loader.LoadScene, AND must NOT already be in Loader.shelters. In practice
# you'd only do this to promote a mod-registered SCENE_PATHS entry to a shelter:
lib.register(lib.Registry.SCENE_PATHS, "mymod_cave", {
    "path": "res://mymod/scenes/cave.tscn",
})
lib.register(lib.Registry.SHELTERS, "mymod_cave", {})  # promote to shelter list

# remove strips from Loader.shelters AND cleans up the auto scene_paths entry
lib.remove(lib.Registry.SHELTERS, "mymod_bunker")
```

The registration dict mirrors the B_Loader mod's `add_shelter`/`add_map` shape, so B_Loader-pattern mods migrate by changing one call site. `menu`, `permadeath`, and `tutorial` flags, if present, are forwarded to the auto-created `SCENE_PATHS` entry. Rotations in `connected_content` are degrees.

**No override / patch.** The list is append-only. To swap a shelter's scene, `override` the corresponding `SCENE_PATHS` entry instead.

**Conflicts.** Two mods registering the same shelter name: second fails. Collision with vanilla shelter list also rejected. Ids are shared with the MAPS registry: registering a map and a shelter under the same id fails loud.

### MAPS

Non-persistent named areas on `Loader`. Same registration schema and storage as SHELTERS (entries are kind-tagged), differing only in the `shelter` flag default: `false` for maps. A map doesn't get the `LoadShelter`/`SaveShelter` persistence treatment (furniture, stash); a shelter does. Verbs: `register`, `remove` only (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.MAPS, "mymod_quarry", {
    "path": "res://mymod/scenes/quarry.tscn",
    "connected_to": "Map01",
})

lib.remove(lib.Registry.MAPS, "mymod_quarry")
```

**Conflicts.** Same rules as SHELTERS -- the two registries share one id space, and id collisions across them fail loud. `remove` is cross-surface guarded: `remove('maps', X)` fails if `X` was registered as a shelter, and vice versa; use the registry it was registered under.

### RANDOM_SCENES

Append-only list of `res://` paths on `Loader.randomScenes` (picked by `LoadSceneRandom()`). Verbs: `register`, `remove` only (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone", {
    "path": "res://mymod/scenes/wasteland.tscn",
})

lib.remove(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone")
```

**Conflicts.** Same handle or same path registered twice: second fails.

### AI_TYPES

Zone -> agent scene overrides on `AISpawner`. Valid zones: `"Area05"`, `"BorderZone"`, `"Vostok"`. Verbs: `register`, `override`, `remove`, `revert`. One registration per zone.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var zombie_scene = preload("res://mymod/ai/Zombie.tscn")

# register: claim a zone for this agent type
lib.register(lib.Registry.AI_TYPES, "mymod_zombie_area05", {
    "scene": zombie_scene,
    "zone": "Area05",
})

# override: force replace whoever currently owns that zone
var ghoul = preload("res://mymod/ai/Ghoul.tscn")
lib.override(lib.Registry.AI_TYPES, "mymod_ghoul_forced", {
    "scene": ghoul,
    "zone": "Area05",
})

# revert: restore the displaced registration's scene
lib.revert(lib.Registry.AI_TYPES, "mymod_ghoul_forced")

# remove: drop the registration (zone loses its override)
lib.remove(lib.Registry.AI_TYPES, "mymod_zombie_area05")
```

**No patch.**

**Conflicts.** Two mods registering into the same zone: second fails with `"zone 'Area05' already claimed by 'mymod_zombie_area05'"`. Use `override` to force a swap. The overridden registration is preserved internally; revert restores it.

### AI_LOADOUTS

Injects mod weapons into AI spawn loadouts. Entries from all mods are additive: they're flattened into a list that the rewritten `AI.SelectWeapon` reads when an agent picks its weapon. Verbs: `register`, `override`, `remove`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.AI_LOADOUTS, "mymod_rifle_loadout", {
    "weapon_scene": preload("res://mymod/MyRifle.tscn"),  # PackedScene, or a String id resolvable via Database
    "ai_types": ["Bandit", "Guard"],  # subset of Bandit / Guard / Military / Punisher; case-insensitive
    "chance": 0.5,                    # optional, default 1.0; clamped to 0..1
    "replace": false,                 # optional, default false
})

# override replaces an EXISTING mod entry wholesale (there is no vanilla side)
lib.override(lib.Registry.AI_LOADOUTS, "mymod_rifle_loadout", {
    "weapon_scene": preload("res://mymod/MyRifle.tscn"),
    "ai_types": ["Military"],
})

lib.revert(lib.Registry.AI_LOADOUTS, "mymod_rifle_loadout")  # undo the override
lib.remove(lib.Registry.AI_LOADOUTS, "mymod_rifle_loadout")
```

`ai_types` names are canonicalized to CamelCase; an unknown name fails the whole call with a warning (so a typo surfaces at register time, not at runtime). `chance` values outside 0..1 are clamped with a warning. `replace: true` clears the agent's existing weapon options before adding this one, instead of adding to them (sharp edge: it also wipes weapons added by other mods' entries that ran earlier). The `register_ai_loadout(entries)` helper is a thin batched wrapper over this registry, and `register_weapon` can create an entry for you via its `ai_loadout` field.

**No patch** (entries are flat dicts; use `override` to replace).

### FISH_SPECIES

Append-only list of `PackedScene` + `pool_id` entries on `FishPool`. Verbs: `register`, `remove` (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

# pool_id="all" (default): eligible in every fishing pool
lib.register(lib.Registry.FISH_SPECIES, "mymod_salmon", {
    "scene": preload("res://mymod/fish/Salmon.tscn"),
    "pool_id": "all",
})

# restrict to one pool by FishPool node name
lib.register(lib.Registry.FISH_SPECIES, "mymod_trout_fp2", {
    "scene": preload("res://mymod/fish/Trout.tscn"),
    "pool_id": "FP_2",
})

lib.remove(lib.Registry.FISH_SPECIES, "mymod_salmon")
```

**No override / patch.**

### RESOURCES

Escape hatch: patch arbitrary fields on any `.tres` by absolute path. Verbs: `patch`, `append`/`prepend`/`remove_from`, `revert` only.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# patch any exposed field on the Resource
lib.patch(lib.Registry.RESOURCES, "res://Resources/GameData.tres", {"walk_speed": 5.0})

# revert per-field or full
lib.revert(lib.Registry.RESOURCES, "res://Resources/GameData.tres", ["walk_speed"])
lib.revert(lib.Registry.RESOURCES, "res://Resources/GameData.tres")
```

**No register / override / remove.** This registry is for touching Resources that don't have a dedicated handler. For items specifically, prefer `ITEMS`, which enforces `ItemData`-shape validation; falling back to `RESOURCES` bypasses those checks.

**Conflicts.** Same patch-stacking semantics as items: same-field writes last-wins, revert returns to vanilla regardless of how many mods patched.

### SCENE_NODES

Patch property values on a specific node inside a scene without shipping a full scene override. Verbs: `patch`, `revert` only. Id format: `"<scene_path>#<node_path>"`; `"...tscn#"` or `"...tscn#."` targets the scene root.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# Mutate a button's `disabled` property inside Interface.tscn
lib.patch(lib.Registry.SCENE_NODES,
    "res://UI/Interface.tscn#Tools/Crafting/Types/Margin/Buttons/Equipment",
    {"disabled": false, "modulate": Color(1, 1, 1, 1)})

# Revert
lib.revert(lib.Registry.SCENE_NODES,
    "res://UI/Interface.tscn#Tools/Crafting/Types/Margin/Buttons/Equipment")
```

The loader subscribes to `SceneTree.node_added`. When a scene whose path matches a registered patch instantiates, the loader applies the patch to each matching node **before that node's `_ready` runs**. The PackedScene resource is never mutated; only live instances. Late patches (registered after the scene is already in the tree) scan existing live instances and apply retroactively.

**Validated up front.** The patch is checked against a probe instantiation of the scene; if any field is missing on the target node, the whole patch is rejected (nothing applies).

**Limits.** Property values only -- it cannot add or remove nodes and cannot patch embedded sub-resources. To add nodes or restructure, `override(SCENES, ...)` with a full replacement scene.

**Conflicts.** Multiple mods patching different properties on the same node compose cleanly. Multiple mods patching the **same** property: last call wins; revert restores vanilla.

---

## Aggregator helpers

Six high-level helpers that fan out to multiple primitive registries (items + scenes + loot + trader_pools + tracked patches) in one declarative call. Use them when you're shipping a complete content unit (one weapon, one furniture piece) and want all the registrations + cross-compat patches in one call. Use primitives when you need fine-grained control or you're modifying existing content rather than adding. They're also reachable from [Setup-Plans](Setup-Plans) as `["register_weapon", {...}]` etc.

| Method | Purpose |
|---|---|
| `register_item({id: dict, ...}) -> Dictionary` | Generic item bundle: ItemData + optional scene/icon/loot_tables/trader_pools |
| `register_weapon({id: dict, ...}) -> Dictionary` | Weapon + rig + inline magazines + fits_attachments + loot_tables + optional AI loadout |
| `register_magazine({id: dict, ...}) -> Dictionary` | Magazine + scene + fits_weapons (additive append to weapons' `compatible`) |
| `register_attachment({id: dict, ...}) -> Dictionary` | Attachment + scene + fits_weapons (same shape as magazine; split for readability) |
| `register_furniture({id: dict, ...}) -> Dictionary` | Furniture item + scene + trader_pools (default Generalist) + optional crafting recipe |
| `register_ai_loadout({id: dict, ...}) -> Dictionary` | Batch wrapper over the `ai_loadouts` primitive (per-id result is just `{ok}`) |

**Always take a Dictionary of `{id: data}`** -- even for a single registration. There is no `(id, data)` overload. (If you read `src/registry/aggregators.gd`, the `(id, dict)` signatures in its header comment are the *internal* workers, not the public API.)

```gdscript
# Single registration
lib.register_weapon({"my_ak": {"item_path": ..., "scene_path": ..., "rig_path": ...}})

# Multiple registrations -- same shape, more keys
lib.register_weapon({
    "my_ak": {"item_path": ..., "scene_path": ..., "rig_path": ...},
    "my_m4": {"item_path": ..., "scene_path": ..., "rig_path": ...},
})
```

**Return shape** is uniform: `{ok: bool, results: {id: granular_dict}}`. Top-level `ok` is true only when every entry's per-id `ok` is true; failures are isolated per id. Each per-id dict always includes:
- `ok: bool` -- did this entry's full fan-out succeed
- One bool per fanned-out registry call (e.g. `items`, `scene`, `rig`, `loot_count: int`)
- For helpers with cross-compat fields: `<rel>: [String]` (resolved ids) and `<rel>_failed: [String]` (ids that didn't resolve)

```gdscript
var result := lib.register_weapon({"my_ak": {...}, "my_m4": {...}})
if not result.ok:
    for id in result.results:
        var per: Dictionary = result.results[id]
        if not per.ok:
            push_warning("[mymod] %s failed: items=%s scene=%s rig=%s" \
                    % [id, per.items, per.scene, per.rig])
```

**Generated sub-ids.** The bundles create loot entries under `"<id>_in_<table>"` and trader-pool entries under `"<id>_in_pool_<pool>"`; weapon rigs are registered as scene id `"<weapon_id>_Rig"`, and furniture recipes as `"<id>_recipe"`. You need these handles to `remove` or `get_entry` the pieces individually later.

Aggregators are pure fan-out -- they call existing primitives under the hood. There's no separate storage; undo by removing/reverting the primitives, and mods can drop down to primitives any time. Source: [src/registry/aggregators.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/aggregators.gd).

### register_item

Generic item bundle. Use for content that doesn't fit weapon/mag/attachment/furniture (consumables, keys, tools, ammo).

```gdscript
var result: Dictionary = lib.register_item({
    "MyMedkit": {
        "item_path":    "res://mymod/items/MyMedkit.tres",     # required
        "scene_path":   "res://mymod/items/MyMedkit.tscn",     # optional
        "icon_path":    "res://mymod/icons/MyMedkit.png",      # optional, sets ItemData.icon
        "loot_tables":  ["LT_Master"],                         # optional
        "trader_pools": ["Doctor"],                            # optional; Generalist, Doctor, Gunsmith, Grandma
    },
})
# result.results.MyMedkit = {ok, items, scene, loot_count, trader_pool_count,
#                            trader_pools: [String], trader_pools_failed: [String]}
```

Per-id `scene` defaults to `true` when no `scene_path` is provided (vacuously satisfied). The per-id `ok` requires `items` + `scene` + no failed trader_pools.

### register_weapon

Weapon + first-person rig + optional inline magazines + optional fits_attachments + optional loot tables + optional AI loadout.

```gdscript
var result: Dictionary = lib.register_weapon({
    "MyRifle": {
        "item_path":  "res://mymod/MyRifle.tres",                # required
        "scene_path": "res://mymod/MyRifle.tscn",                # required (world model)
        "rig_path":   "res://mymod/MyRifle_Rig.tscn",            # required (first-person rig)
        "icon_path":  "res://mymod/Icon_MyRifle.png",            # optional
        "magazines": [                                            # optional, mixed array
            {                                                     # inline = new mag registration
                "id": "MyRifle_StdMag",                           # inline dicts must carry an id
                "item_path":  "res://mymod/MyRifle_Mag.tres",
                "scene_path": "res://mymod/MyRifle_Mag.tscn",
                "loot_tables": ["LT_Master"],                     # mag's own loot
            },
            "AK_12_Magazine",                                     # id-string = ref to existing mag
        ],
        "fits_attachments": ["ACOG", "Kobra"],                    # optional
        "loot_tables": ["LT_Master"],                             # optional, weapon's own loot
        "ai_loadout": {"ai_types": ["Bandit"], "chance": 0.5},    # optional, see AI_LOADOUTS
    },
})
# result.results.MyRifle = {ok, items, scene, rig,
#                           magazines: [{id, ok, item_data, ...}, ...],
#                           fits_attachments: [String], fits_attachments_failed: [String],
#                           loot_count: int,
#                           ai_loadout: null|bool}  # null = not requested; bool = requested outcome
```

The `magazines` field auto-populates the weapon's `compatible` array with each magazine's ItemData ref (as a tracked patch). `fits_attachments` resolves vanilla / mod-registered attachment ids and appends them to `compatible` too. The rig is registered as scene id `"<weapon_id>_Rig"`.

Per-id `ok` requires `items` + `scene` + `rig` and zero `fits_attachments` failures. The optional `ai_loadout` dict creates an AI_LOADOUTS entry using the weapon's own scene and id; you supply `ai_types` / `chance` / `replace`. A failed loadout is reported in the per-id `ai_loadout` but does **not** gate `ok` -- the weapon still spawns as loot, it just won't be carried by AI.

### register_magazine

Standalone magazine. Registers item + scene + optional loot. `fits_weapons` patches each target weapon's `compatible` to include this magazine.

```gdscript
var result: Dictionary = lib.register_magazine({
    "MyExtendedMag": {
        "item_path":  "res://mymod/MyExtendedMag.tres",       # required
        "scene_path": "res://mymod/MyExtendedMag.tscn",       # required
        "icon_path":  "res://mymod/Icon_MyMag.png",           # optional
        "fits_weapons": ["AK_12", "AKM"],                     # optional
        "loot_tables": ["LT_Master"],                         # optional
    },
})
# result.results.MyExtendedMag = {ok, items, scene,
#                                 fits_weapons: [String], fits_weapons_failed: [String],
#                                 loot_count: int}
```

### register_attachment

Same per-entry shape and result as `register_magazine`. Vanilla's `compatible` field accepts mags and attachments interchangeably; the API split is for mod-author readability.

```gdscript
var result: Dictionary = lib.register_attachment({
    "MyOptic": {
        "item_path":  "res://mymod/MyOptic.tres",
        "scene_path": "res://mymod/MyOptic.tscn",
        "fits_weapons": ["AK_12", "AKM", "M4A1"],
        "loot_tables": ["LT_Master"],
    },
})
```

### register_furniture

Furniture is structurally an ItemData with `type = "Furniture"` plus a placed world scene. Distinct from `register_item` because furniture has a different obtainment path: it's never loot-pool spawnable, it's bought from traders or crafted, and on purchase vanilla routes it to the catalog grid (not the inventory grid).

```gdscript
var result: Dictionary = lib.register_furniture({
    "MyBed": {
        "item_path":    "res://mymod/MyBed_F.tres",                # required, expects type="Furniture"
        "scene_path":   "res://mymod/MyBed_F.tscn",                # required (placed world scene)
        "icon_path":    "res://mymod/Icon_MyBed.png",              # optional
        "trader_pools": ["Generalist"],                            # optional, defaults to ["Generalist"] with warn
        "recipe": {                                                # optional crafting recipe
            "name":  "My Bed",                                     # display name
            "input": [<ItemData refs>],                            # required if recipe present, non-empty
            "time":  10.0,                                         # default 1.0
            "audio": <AudioEvent ref>,                             # optional
            "workbench": true,                                     # optional proximity flags:
            "shelter": true,                                       # heat, workbench, testbench, shelter
        },
    },
})
# result.results.MyBed = {ok, items, scene, trader_pool_count,
#                         trader_pools: [String], trader_pools_failed: [String],
#                         recipe: null|bool}  # null = not requested; bool = requested outcome
```

**`loot_tables` is rejected with a warning** -- furniture isn't loot-pool spawnable in vanilla. If included, the field is logged as ignored.

**Type validation**: warns (doesn't fail) if `ItemData.type` isn't `"Furniture"`. Vanilla code branches on this string when the player buys the item; a wrong type means the item goes to the inventory grid instead of the catalog.

**Recipe construction**: builds a fresh `RecipeData` with output = the registered item, `category = "furniture"` locked, registered under `"<id>_recipe"`. Mods that just want trader-only furniture skip the `recipe` field entirely.

---

## Reading the registry

Four methods for reads. All but `get_entry` take an optional `include_vanilla: bool = true` -- pass `false` to see only what mods registered.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# Current entry at game-visible precedence (override > register > vanilla)
var potato = lib.get_entry(lib.Registry.ITEMS, "Potato")

# Membership check
if lib.has(lib.Registry.ITEMS, "AK_12"):
    lib.patch(lib.Registry.ITEMS, "AK_12", {"damage": 50})

# All ids in this registry (default: vanilla + mod)
var all_item_ids: Array[String] = lib.keys(lib.Registry.ITEMS)
var only_mod_items: Array[String] = lib.keys(lib.Registry.ITEMS, false)

# Full id -> entry mapping
var all_items: Dictionary = lib.list(lib.Registry.ITEMS)

# Filtered iteration. Predicate signature: func(entry) -> bool
# Returns Array of {id, entry} dicts so callers don't need a separate id lookup
var weapons: Array = lib.find(lib.Registry.ITEMS, func(it):
    return it != null and "type" in it and it.get("type") == "Weapon"
)
for entry in weapons:
    print(entry["id"], " -> ", entry["entry"].get("name"))
```

**`get_entry` semantics by registry.** For handle-based registries (`loot`, `recipes`, `events`, `trader_pools`, `trader_tasks`, `inputs`, `scene_paths`, `shelters`, `maps`, `random_scenes`, `ai_types`, `ai_loadouts`, `fish_species`) it returns the mod-registered payload dict, or `null` if the id isn't a mod registration -- it does not enumerate vanilla content. For `resources` the id is a `res://` path and it returns `load(id)`. `scene_nodes` and the aggregator-only registries warn and return `null`.

**Mod-vs-vanilla precedence** matches `get_entry`: mod entries override vanilla on id collision. So `list(ITEMS)` returns the mod's version when both exist.

**Per-registry vanilla enumeration** (for `keys`/`list`/`find` with `include_vanilla = true`):
- `ITEMS` -- walks `LT_Master.items`, keyed by `.file`
- `SCENES` -- the rewriter-captured `_rtv_vanilla_scenes` dict on Database (falls back to the script const map filtered to `PackedScene` when no rewrite happened)
- `SCENE_PATHS` -- Loader script's const map filtered to `res://` strings
- `SHELTERS` -- vanilla shelter list snapshot
- `RECIPES` -- walks `Recipes.tres` seven category arrays, ids synthesized as `"<category>:<recipe.name>"`. Note this is the only registry whose vanilla keys are in a different namespace than its register ids.
- All other registries (loot, trader_pools, sounds, events, inputs, etc.) -- vanilla side returns empty; these are mod-only registries by nature, the registry primitives only track what mods added

`include_vanilla = false` returns only mod-registered entries for any registry.

---

## Gotchas

The cross-cutting sharp edges, collected. Per-registry edges live in their sections above.

- **Timing is the number-one failure mode.** Traders, loot containers, the crafting UI, and the event system cache in their own `_ready()` and never re-read. Register in your mod's `_ready()`. See [Timing](#timing).
- **A missing `[registry]` section can fail silently.** `scenes`/`scene_paths` warn loudly, but `ai_types`/`ai_loadouts`/`fish_species` return `true` and do nothing in-game. See [Opting in](#opting-in).
- **Aggregator helpers take `{id: data}` dicts only** -- `lib.register_item("my_id", {...})` is wrong; wrap it: `lib.register_item({"my_id": {...}})`.
- **Patches are global and reach saves.** Godot's Resource cache shares one instance program-wide; patched ItemData is what save files serialize. `revert` is the only undo; there is no per-save isolation.
- **`remove` vs `revert`.** `remove` only undoes a mod `register`; it refuses vanilla entries and override-backed ids. `revert` undoes overrides/patches. On append-only registries (`shelters`, `maps`, `random_scenes`, `fish_species`, `trader_pools`) `revert` is just an alias for `remove`.
- **`patch` return values drift by registry** -- see [patch](#patch). Don't treat `true` as "every field applied" on `items`/`sounds`/`recipes`/`events`/`trader_tasks`.
- **Resource-ref ids work only for `recipes`, `events`, `trader_tasks`.** Passing a `RecipeData`/`EventData`/`TaskData` directly to `patch`/`revert`/array verbs is how you touch vanilla entries without a handle. Every other registry requires String ids.
- **`revert_many` values must be Arrays** (`[]` for full revert); bare strings are rejected, not coerced.
- **Full `revert` restores patches first, then drops the override.** Relevant if you inspect state mid-teardown.
- **`sounds` registrations are invisible to vanilla** -- only `override`/`patch` of real `AudioLibrary` field names change what the game plays.
- **`inputs` ids are InputMap action names** -- namespace them, and registered actions don't appear in the vanilla rebind UI without an extra hook.
- **`events` with a bad `function` name are silent no-ops** when they fire.
- **`ai_loadouts` `replace: true` wipes other mods' earlier weapon entries** for the same agent types.
- **`WEAPONS`/`MAGAZINES`/`ATTACHMENTS` constants only support `register`** and collapse the granular result to a bool -- prefer `register_weapon(...)` etc.
- **`when` predicates in `const` setup plans evaluate at parse time** unless they're Callables. See [setup](#setup----declarative-plan).

## Troubleshooting

**`lib.register` returns `false`**
- Double-check `[registry]` is in your `mod.txt`. Without it the rewriter skips the required injections and registry writes no-op.
- Check the id doesn't collide with a vanilla name; use `override` instead.
- Check the payload shape. Most registries require specific keys (`table`, `trader`, `path`, etc.); the warning message lists what's missing.

**My registration succeeds but the game doesn't use it**
- Timing. Register during your mod `_ready()`, not after scene load. Loot consumers in particular cache on first `_ready()`.
- Missing `[registry]` in `mod.txt` -- for `ai_types`/`ai_loadouts`/`fish_species` this is a *silent* no-op (register returns true).
- If you registered loot into a table but the trader's stock hasn't changed, the trader already populated its pool for the current day. Wait for the next refresh or force a day transition.
- For `sounds`: mod-registered ids are unreachable from vanilla code; use `override` on a vanilla field name, or play the sound from your own code.

## See also

- [Hooks](Hooks): intercepting vanilla method calls
- [Setup-Plans](Setup-Plans): the declarative `setup(plan)` entry point in full
- [Dependencies](Dependencies): declaring load-order and inter-mod requirements
- [Mod-Format](Mod-Format): `mod.txt` reference (including the `[registry]` section)
- [Architecture](Architecture): where the registry sits in the load pipeline
