# Registry

The registry lets a mod add, replace, patch and remove content in the game's data stores: items, loot tables, recipes, sounds, events, trader stock and tasks, input actions, scenes, shelters and maps, AI types and loadouts, fish, arbitrary `.tres` fields, and node properties inside vanilla scenes. You do not ship a rewritten `Database.gd` or edit vanilla files. Every mutation is tracked, so it can be undone: `register` pairs with `remove`, `override` and `patch` pair with `revert`.

Use it when your mod changes game data. To intercept game code, use [Hooks](Hooks).

Updating a mod for Road to Vostok Build 2 (Nomads)? [Build-2-Migration](Build-2-Migration) walks through it step by step, including which ids and names changed.

## Quick start

Get the API object, then register or patch from your mod's `_ready()`:

```gdscript
var lib = Engine.get_meta("RTVModLib")

func _ready() -> void:
    # Register a new item and drop it into a loot table
    var elixir: Resource = load("res://mods/mymod/elixir.tres")  # an ItemData .tres
    lib.register(lib.Registry.ITEMS, "mymod_elixir", elixir)
    lib.register(lib.Registry.LOOT, "mymod_elixir_drop", {"item": elixir, "table": "LT_Master"})

    # Patch fields on a vanilla item, revertable
    lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
```

Undo:

```gdscript
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # one field
lib.revert(lib.Registry.ITEMS, "Potato")              # everything on that id
lib.remove(lib.Registry.ITEMS, "mymod_elixir")        # undo a register
```

Two prerequisites:

1. `mod.txt` must contain a `[registry]` section. An empty section is enough; the loader only checks for its presence. Without it several registries fail, some silently. See [Opting in](#opting-in) and [Mod-Format](Mod-Format).
2. Register during your mod's `_ready()`. Traders, loot containers, the crafting UI and the event system copy from the shared stores in their own `_ready()` and never re-read. A later registration mutates the store but is invisible in-game. See [Timing](#timing).

If you need hooks or other framework state first, `await lib.frameworks_ready` before registering.

The rest of this page is reference: [constants and data shapes](#registry-constants), [verb semantics](#verb-semantics), [per-registry details](#per-registry-reference), [aggregator helpers](#aggregator-helpers), [reading](#reading-the-registry), [gotchas](#gotchas).

## Opting in

Mods that use the registry API declare it in `mod.txt`:

```ini
[registry]
```

An empty section is enough. When any mod declares it, the rewriter wraps `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd` and `Compiler.gd` and injects the fields the registry needs (`REGISTRY_TARGETS` in [src/hook_pack.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd)). A mod whose script calls B_Loader's `Loader.add_shelter` or `Loader.add_map` counts as declaring `[registry]` even without the section, so those mods keep working unedited.

The declaration is what puts those six scripts into the wrap surface; the rewriter adds the registry code to any rewrite of a registry target, so a script that is in the surface only because a mod hooks one of its methods carries it too. A target that no mod declares or hooks stays vanilla, its injected fields are missing, and the registries behave differently:

- `scenes` and `scene_paths` check for the injected fields (`_rtv_mod_scenes` on Database, `_rtv_mod_scene_paths` on Loader) and fail with a `push_warning`. Every message names the missing injected fields; the Database ones also ask whether `mod.txt` includes a `[registry]` section.
- `ai_types`, `ai_loadouts` and `fish_species` write to `Engine.set_meta(...)` entries that only the rewritten `AISpawner`, `AI` and `FishPool` read. `register` returns `true` with no warning, and the game never sees the entry.
- `shelters` and `maps` need the rewriter to turn vanilla's `const shelters = [...]` into a `var` and to inject the `_rtv_mod_shelters` dict the spawn prelude reads. A registration that carries a `path` fails through the `scene_paths` check above. A path-less registration warns that `_rtv_mod_shelters` is missing and returns `false`; nothing is appended to a `shelters` array that is still `const`.
- `items`, `loot`, `recipes`, `events`, `sounds`, `inputs`, `trader_pools`, `trader_tasks`, `random_scenes`, `resources` and `scene_nodes` work regardless. They mutate loaded Resources, `InputMap` or plain vars (`scene_nodes` uses a `SceneTree.node_added` listener) and track state in the registry's own dicts.

Add `[registry]` whenever you use the API.

With the declaration, one case is still checked. After a game update the injected code for a target may no longer compile; the loader then ships that script with hooks only, or leaves it vanilla (see [Hooks](Hooks#compile-probe-before-packing)). `register` and `override` on `ai_types` (`AISpawner.gd`), `ai_loadouts` (`AI.gd`) and `register` on `fish_species` (`FishPool.gd`), `shelters` and `maps` (`Compiler.gd`) then return `false` with a `push_warning` (`the loader's registry code for <file> does not fit this game build and was left out`), instead of reporting success for an entry nothing reads. The Database and Loader registries need no extra check: they already look for their injected fields on the live node. `shelters` and `maps` depend on `Compiler.gd` as well as `Loader.gd`: the `Spawn` prelude is what reads the entry on arrival. If `Compiler.gd` shipped without it, `register` returns `false` with the same warning before anything is stored, the paired `scene_paths` entry included. `remove` still works for an entry registered earlier.

A transform whose vanilla anchor moved without a rename still compiles, so the probe passes it. The pack-time marker check (`REGISTRY_EXPECTED_MARKERS`) then reports the script `PARTIAL` in the reconciliation report, missing `registry transform`, and `AISpawner.gd` also logs a critical `vanilla 'enemy = <name>' assignments not found (game update?)` when a mod declares `[registry]`. `ai_types` calls still return `true` in that case; nothing reads them.

## Timing

Register during your mod's `_ready()`, before vanilla systems finish initializing. Several consumers copy the shared store once and never re-read:

- Trader stock, `LootContainer` and `LootSimulation` copy from `LootTable` resources in their own `_ready()`.
- The crafting `Interface` copies recipe arrays in its `_ready()`; `EventSystem` copies events; traders copy tasks.
- `FishPool._ready()` runs on map load, which is after the main menu, so a mod autoload is early enough.
- `InputMap` actions registered after gameplay starts work, but the remapping UI does not pick them up until a scene reload.

Mod autoloads load after vanilla autoloads and before the first scene, so registering inside your mod's `_ready()` is almost always early enough. If you need hooks to finish first, `await lib.frameworks_ready` before the first `register` call.

Re-registering after scene load updates the underlying store, but a system that already copied it keeps the old snapshot. This is the usual cause of "register returned true but nothing changed".

## Public API

Mods reach the loader the same way as the hook system: `Engine.get_meta("RTVModLib")`. Source: [src/registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd) for the dispatchers, `src/registry/*.gd` for the per-section handlers.

### Methods

| Method | Purpose |
|---|---|
| `register(registry, id, data) -> bool` | Add a new entry. Fails on id collision with vanilla or an earlier mod registration |
| `override(registry, id, data) -> bool` | Replace an existing entry wholesale. Fails if the id doesn't resolve |
| `patch(registry, id, fields) -> bool` | Mutate individual fields on an entry. Original values are stashed for revert |
| `append(registry, id, field, values, allow_duplicates=false) -> bool` | Add to an Array field. De-dups by default. Shares the `patch` stash |
| `prepend(registry, id, field, values, allow_duplicates=false) -> bool` | Same as `append` but inserts at the front |
| `remove_from(registry, id, field, values) -> bool` | Drop matching values from an Array field. Removes all occurrences, idempotent |
| `remove(registry, id) -> bool` | Undo a `register`. Fails on override-backed ids (use `revert`) and vanilla entries |
| `revert(registry, id, fields=[]) -> bool` | Undo an `override` or `patch`. Per-field when `fields` is non-empty |
| `register_many(registry, {id: data, ...}) -> Dictionary` | Batched register; returns `{ok, results}` |
| `override_many(registry, {id: data, ...}) -> Dictionary` | Batched override |
| `patch_many(registry, {id: fields, ...}) -> Dictionary` | Batched patch |
| `append_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched append, one field across many ids |
| `prepend_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched prepend |
| `remove_from_many(registry, field, {id: values, ...}) -> Dictionary` | Batched remove_from |
| `revert_many(registry, {id: fields_array, ...}) -> Dictionary` | Batched revert; `[]` means full revert of that id |
| `remove_many(registry, [id, ...]) -> Dictionary` | Batched remove (an Array of ids, not a dict) |
| `setup(plan) -> Dictionary` | Declarative entry point: a list of `[verb, ...args]` entries run in order. See [setup](#setup----declarative-plan) |
| `get_entry(registry, id) -> Variant` | Read the current entry, after any registry mutations. `null` if missing |
| `has(registry, id, include_vanilla=true) -> bool` | Membership check |
| `keys(registry, include_vanilla=true) -> Array[String]` | All ids in the registry |
| `list(registry, include_vanilla=true) -> Dictionary` | All `id -> entry` pairs |
| `find(registry, predicate, include_vanilla=true) -> Array` | Filtered iteration; returns `[{id, entry}, ...]` |

Every mutating verb returns a bool. Failures log a `push_warning` with the reason. `register`, `override`, `patch` and the array verbs reject an empty id up front; `remove` and `revert` on an empty id fall through to the normal "not registered" warning. The read methods never warn on a missing id; they return `null`, `false` or an empty collection. `get_entry` does warn, and return `null`, when pointed at a registry with nothing to read (`scene_nodes`, the aggregator-only registries) or at an unknown registry name.

### Registry constants

Use `lib.Registry.<NAME>` instead of raw strings so typos surface at parse time:

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
| `AI_TYPES` | `"ai_types"` | Zone -> enemy scene overrides on `AISpawner` | register, override, remove, revert |
| `AI_LOADOUTS` | `"ai_loadouts"` | Per-AI-category weapon injections (`AI.SelectWeapon` prelude) | register, override, remove, revert |
| `FISH_SPECIES` | `"fish_species"` | `FishPool` extra species | register, remove (revert = alias) |
| `RESOURCES` | `"resources"` | Arbitrary `.tres` by absolute `res://` path | patch, append/prepend/remove_from, revert |
| `SCENE_NODES` | `"scene_nodes"` | Property mutations on nodes inside any scene | patch, revert |
| `WEAPONS` | `"weapons"` | Aggregator-only; routes to `register_weapon` | register (collapses to bool) |
| `MAGAZINES` | `"magazines"` | Aggregator-only; routes to `register_magazine` | register (collapses to bool) |
| `ATTACHMENTS` | `"attachments"` | Aggregator-only; routes to `register_attachment` | register (collapses to bool) |

An unsupported verb returns `false` with a warning that points at the right tool. For example `patch` on `loot`: loot entries are ItemData references, so patch the ItemData through `items` instead.

The aggregator-only registries (`WEAPONS`, `MAGAZINES`, `ATTACHMENTS`) reject `override`, `patch`, `remove` and `revert` with a pointer to the underlying primitives. They exist so a generic loop can call `register('weapons', ...)` and get a bool back. Call `register_weapon` and friends directly when you want the granular result dict.

### Data shapes at a glance

| Registry | `register` data | `override` data | `patch` fields / notes |
|---|---|---|---|
| scenes | `PackedScene` | `PackedScene` | no patch (monolithic) |
| items | `ItemData` Resource (register sets `data.file = id`) | `ItemData` Resource | any declared property; unknown fields warn and skip |
| loot | `{item: ItemData, table: String}` | register shape + `replaces: ItemData` | no patch; patch the ItemData via `items` |
| sounds | `AudioEvent`, bare `AudioStream`, or `{audioClips, volume, randomPitch}` | same coercion; id must be a real `AudioLibrary` `@export` field | `{audioClips, volume, randomPitch}` subset |
| recipes | `{recipe: RecipeData, category: String}` | register shape + `replaces: RecipeData` | patch by String handle or direct `RecipeData` ref |
| events | `{event: EventData}` | `{event, replaces: EventData}` | patch by handle or `EventData` ref |
| trader_pools | `{item: ItemData, trader: String}` | n/a | n/a; remove/revert restore the stashed flag |
| trader_tasks | `{task: TaskData, trader: String}` | register shape + `replaces: TaskData` | patch by handle or `TaskData` ref |
| inputs | `{display_label?, default_event: InputEvent, deadzone? = 0.5}`; the id is the action name | same shape | only `display_label` / `default_event` / `deadzone` |
| scene_paths | `{path: String, menu?, shelter?, permadeath?, tutorial?}`; `path` must exist | same shape | open dict; any field accepted, and a `path` must exist |
| shelters / maps | `{path?, transition_text?, exit_spawn?, entrance_spawn?, connected_to?, connected_content?, shelter?}` | n/a | n/a |
| random_scenes | `{path: String}`; `path` must exist | n/a | n/a |
| ai_types | `{scene: PackedScene, zone: String}` (zone: Area05 / BorderZone / Vostok / Debug) | same shape (forcibly claims the zone) | no patch |
| ai_loadouts | `{weapon_scene: PackedScene or String, ai_types: [String], chance? = 1.0, replace? = false}` | same shape (id must exist) | no patch; override to replace |
| fish_species | `{scene: PackedScene, pool_id? = "all"}` | n/a | n/a |
| resources | n/a | n/a | id = absolute `res://` path; any declared field |
| scene_nodes | n/a | n/a | id = `"<scene_path>#<node_path>"`; `#` or `#.` targets the scene root |

## Verb semantics

### register

Adds a new entry. It fails if the id matches a vanilla const or field name on the underlying store (use `override`), if the id was already registered by a mod this session, or if the payload fails the registry's shape check (wrong type, missing keys).

### override

Replaces an existing entry wholesale. The new payload takes the slot; the original is stashed for revert.

```gdscript
lib.override(lib.Registry.ITEMS, "Potato", my_replacement_item)
var current = lib.get_entry(lib.Registry.ITEMS, "Potato")  # returns my_replacement_item
lib.revert(lib.Registry.ITEMS, "Potato")                    # back to vanilla
```

`scenes`, `loot`, `recipes`, `events`, `trader_tasks`, `ai_types` and `ai_loadouts` reject a second `override` of an already-overridden id (the warning starts "already overridden (revert first"). The in-place registries (`items`, `sounds`, `inputs`, `scene_paths`) accept it: the second override wins, and the stash keeps the original from before the first override, so a full `revert` still restores vanilla. Overriding a mod registration is allowed everywhere except `sounds`, which only overrides vanilla field names. Use that to resolve same-id conflicts between mods without touching the loser's code.

### patch

Mutates specific fields on the current entry, whether vanilla, override or an earlier `register`. The first patch to a field saves its pre-patch value; later patches to the same field don't re-stash, so a full `revert` returns to the true original.

```gdscript
lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # restore just weight
lib.revert(lib.Registry.ITEMS, "Potato")              # restore everything else
```

The `id` is a String for most registries. `recipes`, `events` and `trader_tasks` also accept a direct Resource ref (`RecipeData` / `EventData` / `TaskData`), so you can patch vanilla entries without registering a handle first.

Registries without patch (`loot`, `scenes`, `trader_pools`, `shelters`, `maps`, `random_scenes`, `ai_types`, `ai_loadouts`, `fish_species`) return `false` with a pointer to the alternative.

The return value drifts by registry. `items`, `sounds`, `recipes`, `events` and `trader_tasks` return `true` whenever the id resolves, even if every field was rejected as unknown (each bad field warns and is skipped). `resources` and `inputs` return `false` unless at least one field applied. `scene_nodes` validates up front and rejects the whole patch if any field is missing. `scene_paths` entries are open dicts, so any field name is accepted; a `path` that does not exist rejects the whole patch. Every handler returns `false` when the id doesn't resolve.

### append / prepend / remove_from

Array-only mutations on a single field. Use these instead of `patch` when you want to add to or subtract from an existing array (a weapon's `compatible` list, say) without overwriting entries other mods contributed.

```gdscript
# Add new magazines as compatible options on the AKM, without clobbering vanilla's
# list. Items ids are ItemData.file strings ("AKM"), not .tres paths:
lib.append(lib.Registry.ITEMS, "AKM", "compatible", [magA, magB])

# Single value also works (no need to wrap in an array):
lib.append(lib.Registry.ITEMS, "AKM", "compatible", magC)

# Insert at the front instead of the end:
lib.prepend(lib.Registry.SOUNDS, "knifeHitFleshSlash", "audioClips", newClip)

# Remove an entry; silent skip if it isn't there.
lib.remove_from(lib.Registry.ITEMS, "AKM", "compatible", oldMag)
```

Rules:

- Calling on a non-Array field returns `false` with a "field ... is not an Array" warning. For scalar fields use `patch`.
- `append` and `prepend` skip values already in the array. Pass `allow_duplicates=true` to permit repeats.
- `remove_from` removes every matching occurrence and is idempotent.
- `prepend` preserves argument order: `prepend(..., [a, b])` on `[c]` yields `[a, b, c]`.
- `null` values are rejected; an empty values Array warns and returns `false`.
- The stash is shared with `patch`. A `patch` on `compatible` followed by `append` to `compatible` keeps the original from before both, so `revert(reg, id, ["compatible"])` restores it.
- Every value is validated against the array's declared type up front; one bad value rejects the whole call before any mutation.

Supported on `items`, `sounds`, `recipes`, `events`, `trader_tasks` and `resources`. `inputs` and `scene_paths` have no Array fields, and the rest have non-Resource entries; those calls return `false` with guidance.

### remove

Reverses an earlier `register`. Fails on override-backed ids ("use revert") and on vanilla entries.

### revert

Reverses an `override` or `patch`. Fails if there is nothing to undo.

A bare `revert(registry, id)` unwinds everything for that id: patches are restored first, then the override is dropped. The order matters, because the patches were applied on top of the override. `revert(registry, id, ["field1", "field2"])` unwinds only those patched fields; other patches and the override stay.

On `shelters`, `maps`, `random_scenes`, `fish_species` and `trader_pools`, `revert` is an alias for `remove`.

### Batched forms (`*_many`)

Every mutation verb has a sibling that takes a Dictionary of ids (or, for `remove_many`, an Array). One call, many entries, one registry.

```gdscript
# Patch many items in one call (items ids are ItemData.file strings).
lib.patch_many(lib.Registry.ITEMS, {
    "AKM":   {"weight": 3.2},
    "AK_12": {"weight": 3.4},
})

# Append the same field across many ids. The field comes BEFORE the entries dict.
lib.append_many(lib.Registry.ITEMS, "compatible", {
    "AKM":   [magA, magB],
    "AK_12": [magC],
})

# Per-id field lists for revert. Empty array = full revert of that id.
lib.revert_many(lib.Registry.ITEMS, {
    "AKM":   ["weight", "compatible"],
    "AK_12": [],
})

# Remove a list of mod-registered entries.
lib.remove_many(lib.Registry.ITEMS, ["my_mod_potion", "my_mod_grenade"])
```

Each `_many` returns `{ok: bool, results: {id: bool, ...}}`. `ok` is true only when every entry succeeded. One bad id doesn't stop the others; the per-id bools tell you which landed.

```gdscript
var result := lib.patch_many(lib.Registry.ITEMS, {...})
if not result.ok:
    for id in result.results:
        if not result.results[id]:
            push_warning("[mymod] failed to patch %s" % id)
```

`append_many`, `prepend_many` and `remove_from_many` take one `field` that applies to every entry. For different fields per id, make several calls or use `setup`.

`revert_many` values must be Arrays. `{id: "field"}` is rejected with a warning, not coerced; pass `["field"]`, or `[]` for a full revert. This guards against a typo that would otherwise full-revert the id.

### setup -- declarative plan

`setup(plan)` runs an ordered list of `[verb, ...args]` entries. The verbs are the registry verbs above plus `hooks` (batched hook registration), the aggregator helpers, and `when` (conditional sub-plans). Entries run in order, so register-then-patch flows work; failures are isolated per entry.

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
        ["patch",    lib.Registry.ITEMS, {"AKM": {"weight": 3.2}}],
        ["append",   lib.Registry.ITEMS, "compatible", {"AKM": [magA]}],
        ["hooks",    {"interface-getmagazine": _replace_get_mag}],
        ["when",     func(): return some_runtime_flag, [
            ["patch", lib.Registry.ITEMS, {"Sticks": {"value": 200}}],
        ]],
    ])
```

Returns `{ok: bool, results: Array}` with one result per top-level entry: `{"verb": ..., "ok": bool, "results": {...}}`. A malformed entry yields `{"verb", "ok": false, "error"}`. `when` yields `{"verb": "when", "evaluated": bool, "ok": bool, "results"?}`, with `results` present only when the block ran; a skipped `when` reports `ok = true`. An unknown verb warns and reports `ok = false`.

A Callable predicate is evaluated when `setup()` reaches it. Bools and numbers are read as-is, `null` counts as false, and anything else warns and counts as false. In a `const` plan, non-Callable predicates are evaluated at script-parse time, so use Callables for runtime state.

Hook names in a plan are plain Dictionary keys, not literal `.hook("...")` calls, so the loader's source scanner does not enroll their targets in the wrap surface. Make sure each target is wrapped some other way: a literal `.hook()` call elsewhere in your source, or a `[hooks]` declaration in `mod.txt`. See [Hooks](Hooks#wrap-surface----why-hook-alone-is-not-enough).

[Setup-Plans](Setup-Plans) has the full verb table, predicate forms, return shape and a complete example.

## Conflict-handling fundamentals

These rules hold across every registry:

- `register` on a colliding id fails, whether the collision is with vanilla or with an earlier mod. The second caller gets `false` and a warning. Nothing is silently overwritten.
- `override` on an already-overridden id fails on the array-swap and slot registries (`scenes`, `loot`, `recipes`, `events`, `trader_tasks`, `ai_types`, `ai_loadouts`); the second caller must `revert` first. On the in-place registries (`items`, `sounds`, `inputs`, `scene_paths`) the second override succeeds and wins; the stash still holds the true original, so `revert` returns to vanilla.
- `patch` on the same field stacks. Both writes apply in call order and the last value is visible. The stash keeps the first patcher's pre-patch value, so a later `revert` returns to vanilla, not to the first patcher's value. Mod A's patch is lost on revert even if Mod A never called revert.
- `patch` on different fields coexists. Each field has its own stash.
- The array-based registries (`loot`, `recipes`, `events`, `trader_tasks`) are additive on `register`. Two mods registering different ids into the same array both succeed.
- An array `override` (the `replaces:` form) fails if the target is already gone. If mod A swapped `vanillaX` for `newA`, mod B can't also swap `vanillaX`; it is no longer in the array. Mod B would have to target `newA`, which silently undoes mod A's swap. Avoid that.

## Per-registry reference

Each section has a minimal example per verb and the registry-specific edges.

### SCENES

Scene constants on `Database.gd` (`Potato`, `Beer`, `Cabin`), keyed by the const name. Verbs: `register`, `override`, `remove`, `revert`.

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

Two mods overriding the same vanilla scene: the second fails with "already overridden (revert first to re-override)". Players see the first mod's scene.

### ITEMS

`ItemData` Resources (or subclasses: WeaponData, AttachmentData, etc.) keyed by their `file` property. Ids are `file` strings (`"Potato"`, `"AKM"`), not `res://` paths. To patch a Resource by path, use [`RESOURCES`](#resources). Verbs: all five plus the array verbs.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var elixir = load("res://mymod/items/Elixir.tres")

# register: sets elixir.file = "mymod_elixir" for you (vanilla code reads item.file)
lib.register(lib.Registry.ITEMS, "mymod_elixir", elixir)

# override: what lib.get_entry and the aggregators resolve for "Potato" from now on
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

`override` on `items` swaps what the registry resolves for that id: `get_entry`, later `patch` calls and the aggregator helpers see the new ItemData. Vanilla code that already holds the original Resource (a loot table, a trader pool, a save) keeps it, since vanilla has no lookup by `file`. To change an item everywhere, `patch` it.

Patches are global and persist into saves. Godot's Resource cache shares one instance program-wide, so patching an item mutates it for every holder, including what saves serialize (`SlotData` serializes ItemData by value). There is no per-save isolation; `revert` is the only undo.

Two overrides of the same item both succeed and the second wins; the stash keeps the true original, so `revert` returns to vanilla. Two patches on the same field both succeed and the second value shows; any revert on that id returns to vanilla and loses both. Patches on different fields coexist.

### LOOT

Adds or swaps `ItemData` entries inside `LootTable.items`. Ids are mod-chosen handles, not tied to any in-game name. Verbs: `register`, `override`, `remove`, `revert`.

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

`table:` accepts a known name or an absolute `res://` path. Known names: `LT_Master`, `LT_Airdrop_01` .. `LT_Airdrop_03`, `LT_Patient_Report`, `LT_Punisher_01` .. `LT_Punisher_03`, `LT_Bogeyman_01`, `LT_Oil_Sample`, `LT_Weapons_01` .. `LT_Weapons_04`, `LT_Ammo`, `LT_Medical`, `LT_Equipment`, `LT_Armor`, `LT_Grenades`, `LT_Attachments`, `LT_Items`, `Kit_Colt`, `Kit_Glock`, `Kit_MP5K`, `Kit_Makarov`, `Kit_Mosin`, `Kit_Remington`.

There is no patch on loot; entries are whole `ItemData` references. Patch the `ItemData` through `items` instead.

Registering an item that is already in the table is refused, not inserted twice. Two `override` calls with the same `replaces:` target: the second fails because the first already removed `replaces` from the table.

### SOUNDS

`AudioEvent` fields on `AudioLibrary.tres`, plus mod-registered lookup entries. Verbs: all five plus the array verbs.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var custom_event = preload("res://mymod/audio/Footstep.tres")  # AudioEvent

# register: add a new sound id (lookup via get_entry only; vanilla code
# can't reach these ids because it hardcodes property names)
lib.register(lib.Registry.SOUNDS, "mymod_custom_footstep", custom_event)

# register via Dictionary shorthand (builds an AudioEvent internally),
# or pass a bare AudioStream (wrapped with volume=0, randomPitch=false)
lib.register(lib.Registry.SOUNDS, "mymod_dict_sound", {
    "audioClips": [],
    "volume": -3.0,
    "randomPitch": true,
})

# override: replace a vanilla AudioLibrary @export field.
# `id` must be a real @export field name on AudioLibrary.tres;
# override rejects mod-registered ids.
lib.override(lib.Registry.SOUNDS, "knifeHitFleshSlash", custom_event)

# patch: mutate AudioEvent fields (audioClips, volume, randomPitch)
lib.patch(lib.Registry.SOUNDS, "knifeHitFleshSlash", {"volume": -10.0, "randomPitch": true})

# revert per-field / full / remove
lib.revert(lib.Registry.SOUNDS, "knifeHitFleshSlash", ["randomPitch"])
lib.revert(lib.Registry.SOUNDS, "knifeHitFleshSlash")
lib.remove(lib.Registry.SOUNDS, "mymod_custom_footstep")
```

Only `override` and `patch` change what vanilla plays. The field names are whatever the current game build's `AudioLibrary.gd` exports; Build 2 (Nomads) renamed or removed many of them (for example `vostokEnter` became `vostok`, `firemodeSemi` became `semi`, the knife draw and slash fields are gone), and an override on a name the build does not have is refused with `no vanilla AudioLibrary field with that name (register can't be overridden; revert the register first). Current names: ...`, where the tail lists every field the running build's library has. `patch` and the array verbs refuse an unknown id the same way (`no sound with that id. Current names: ...`), so one refused call is the quickest way to read the current list. Vanilla code reads `audioLibrary.propertyName` directly, so a mod-registered id is unreachable from vanilla code paths. Fetch it with `lib.get_entry` and play it from your own code or hooks. Registrations live in the registry's lookup dict, not on the AudioLibrary Resource, so `audioLibrary.get("mymod_id")` returns null.

The game's `AudioEvent` holds WAV clips only (`audioClips: Array[AudioStreamWAV]`). A bare stream or a dict whose clips are another type, such as an OGG or MP3 stream, makes `register` and `override` return `false` with a warning naming the type; a `patch` of `audioClips` skips that field with the same warning. Import your sound as WAV.

Build 2 also moved some sounds out of the library into `const` preloads inside the script that plays them (the airdrop sounds in `CASA.gd`, the grenade bounce sounds in `Grenade.gd`, the lure impacts in `Lure.gd`). Those have no `AudioLibrary` field, so the `sounds` registry cannot reach them; hook the script instead.

`register` on a vanilla `@export` field name is rejected (use `override`). `override` only works on vanilla fields, never on mod-registered ids. Otherwise the rules are the same as items.

### RECIPES

`RecipeData` Resources in per-category arrays on `Recipes.tres`. Categories: `consumables`, `medical`, `equipment`, `weapons`, `electronics`, `misc`, `furniture`. Verbs: all five plus the array verbs. Patch accepts a String handle or a direct `RecipeData` ref.

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

Vanilla ships the Equipment and Misc crafting tabs disabled and faded because those categories are empty. Registering a recipe into `equipment` or `misc` patches the tab button clickable through the `scene_nodes` registry for you.

Register and override conflicts follow the loot rules. Patches stack per field.

### EVENTS

`EventData` entries in `Events.tres`. Mirrors recipes: `register`, `override`, `patch`, `remove`, `revert`, plus the array verbs. Patch accepts a String handle or a direct `EventData` ref.

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

`EventData.function` must name a method on `EventSystem`. The string is resolved as `Callable(EventSystem, function)` when the event fires; a name that doesn't exist there makes the event a silent no-op. To run mod code from an event, point `function` at a vanilla method you have intercepted with a [hook](Hooks).

### TRADER_POOLS

Flips a trader's boolean flag on an `ItemData` (`item.doctor = true` puts the item in the Doctor's pool). Verbs: `register`, `remove`, `revert` (an alias for remove).

```gdscript
var lib = Engine.get_meta("RTVModLib")
var potato = load("res://Items/Consumables/Potato/Potato.tres")

# register: enable item for the Doctor trader
lib.register(lib.Registry.TRADER_POOLS, "mymod_potato_doctor", {
    "item": potato,
    "trader": "Doctor",  # Generalist / Doctor / Gunsmith / Driver / Hunter / Grandma; case-insensitive
})

# remove / revert: restore the original flag value
lib.remove(lib.Registry.TRADER_POOLS, "mymod_potato_doctor")
```

No `override` or `patch`; pool membership is a single flag. Entries are keyed by the mod handle, not the item, so two mods can independently enable the same item for the same trader.

`Driver` and `Hunter` are Build 2 (Nomads) traders; on the build before it `ItemData` has no `driver` or `hunter` flag and the call fails with `item has no '<flag>' flag field`. `Grandma` is accepted because `ItemData.grandma` exists, but no trader reads that flag in either build, so it puts the item in no pool.

When a second mod registers the same (item, trader) pair, its stash inherits the original value from the handle already live, so once every handle is removed the flag returns to vanilla. The remaining surprise: `remove` restores the original immediately, so removing any one handle turns the flag off even while other handles are still registered. Avoid double-registering the same pair across mods.

### TRADER_TASKS

`TaskData` entries in per-trader `tasks` arrays. Verbs: all five plus the array verbs. Patch accepts a String handle or a direct `TaskData` ref. `trader` is `"Generalist"`, `"Doctor"`, `"Gunsmith"`, `"Driver"`, `"Hunter"`, or an absolute `res://` path to a `TraderData` resource.

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

Conflicts follow the loot rules. Two mods overriding the same task: the second fails once `replaces` is no longer in the array.

### INPUTS

Declares new `InputMap` actions with a default event, and lets mods rebind vanilla actions. Verbs: all five. The registry id is the InputMap action name, so namespace it (`"mymod_heal"`, not `"heal"`).

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

Registered actions work immediately through `Input.is_action_pressed("mymod_quick_heal")` in your own code. `register` fails if the action already exists in `InputMap`, vanilla or otherwise; use `override`. `remove` only takes away an action a mod registered; a vanilla action that a mod patched or overrode is left in `InputMap`, and `revert` is what undoes those.

Vanilla's Settings -> Keybinds panel reads a hardcoded `inputs` dict inside `Inputs.gd`. A registered action works in-game but does not appear in the rebind menu without a hook on `inputs-createactions-pre` (hook names are lowercase) that merges it into that dict. The registry does not install that hook.

Two mods overriding the same action: both succeed and the last write wins. The stash keeps the original event list and deadzone, so `revert` restores them. A `default_event` patch stashes every event the action had, not only the first.

### SCENE_PATHS

Named scene lookups on `Loader.gd` with optional `gameData` flags (`menu`, `shelter`, `permadeath`, `tutorial`). Verbs: all five. Source: [src/registry/loader.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/loader.gd).

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

An override of a vanilla scene keeps that scene's own flags for any flag the entry leaves out, so overriding `Cabin` with just a `path` still loads it as a shelter (a shelter loaded with `shelter` false resets the character on quit instead of saving it). A flag the entry sets replaces the vanilla one. A mod scene gets every flag from its entry, `false` when left out. A `transition_text` on the entry sets the loading-screen label of a mod scene only; an override of a vanilla scene keeps that scene's label, because the game picks the scene's flags by that name.

`register` and `override` refuse a `path` that does not exist on disk. A missing scene would freeze the loading screen with no way back to the menu, so the check happens at registration, the last point where it can fail safely. Check the path and that the file shipped in your archive.

A `register` that collides with a vanilla const is rejected; use `override`. Two mods overriding the same vanilla scene path: both succeed and the last write wins. `revert` from either drops the override and vanilla resolution returns.

### SHELTERS

Append-only list of shelter names on `Loader.shelters`. Verbs: `register`, `remove` (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

# register with path: auto-creates a paired scene_paths entry with shelter=true
lib.register(lib.Registry.SHELTERS, "mymod_bunker", {
    "path": "res://mymod/scenes/bunker.tscn",
})

# full registration dict (everything but `path` optional):
lib.register(lib.Registry.SHELTERS, "mymod_apartment", {
    "path": "res://mymod/scenes/apartment.tscn",
    "transition_text": "Apartment",       # loading-screen label; defaults to id
    "exit_spawn": "Door_Apartment_Exit",  # transition node to spawn at on arrival
    "entrance_spawn": "Door_Apartment",   # node in connected_to to spawn at when leaving
    "connected_to": "Village",            # vanilla map where this shelter's entrance lives
    "connected_content": [                # spawned into /root/Map/Content on entering connected_to
        {"path": "res://mymod/props/door_frame.tscn",
         "position": Vector3(10, 0, 4), "rotation": Vector3(0, 90, 0)},
    ],
    "shelter": true,                      # default true here (false for MAPS)
})

# register without path: the name must not already be in Loader.shelters,
# and it needs to resolve through Loader.LoadScene some other way. The
# usual case is promoting a mod-registered SCENE_PATHS entry:
lib.register(lib.Registry.SCENE_PATHS, "mymod_cave", {
    "path": "res://mymod/scenes/cave.tscn",
})
lib.register(lib.Registry.SHELTERS, "mymod_cave", {})  # promote to shelter list

# remove strips from Loader.shelters AND cleans up the auto scene_paths entry
lib.remove(lib.Registry.SHELTERS, "mymod_bunker")
```

The registration dict mirrors the B_Loader mod's `add_shelter`/`add_map` shape, so B_Loader-pattern mods migrate by changing one call site. `menu`, `permadeath` and `tutorial`, if present, are forwarded to the auto-created `scene_paths` entry, and so is `transition_text`. Rotations in `connected_content` are degrees. A `path` that does not exist is refused, as for `scene_paths`. A `path` under a vanilla scene's name (`Village`, `Bridge`, ...) is refused too, by `register` and by the B_Loader-compatible `Loader.add_shelter`/`Loader.add_map`: it would replace that map. To change a vanilla scene, `override` its `scene_paths` entry. The loader does not check that a path-less registration resolves; if it doesn't, `LoadScene` fails at runtime.

No `override` or `patch`; the list is append-only. To swap a shelter's scene, `override` the matching `scene_paths` entry.

Two mods registering the same shelter name: the second fails. A name already in the vanilla shelter list is also rejected. Shelters and maps share one id space, so registering a map and a shelter under the same id fails.

### MAPS

Non-persistent named areas on `Loader`. Same registration schema and storage as SHELTERS (entries are kind-tagged), differing only in the `shelter` flag default: `false` for maps. A map does not get the `LoadShelter`/`SaveShelter` persistence treatment (furniture, stash); a shelter does. Verbs: `register`, `remove` (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.MAPS, "mymod_quarry", {
    "path": "res://mymod/scenes/quarry.tscn",
    "connected_to": "Village",
})

lib.remove(lib.Registry.MAPS, "mymod_quarry")
```

Same rules as SHELTERS. `remove('maps', X)` fails if `X` was registered as a shelter, and vice versa: "id was registered as 'shelters', use that registry to remove".

### RANDOM_SCENES

Append-only list of `res://` paths on `Loader.randomScenes`, picked by `LoadSceneRandom()`. Verbs: `register`, `remove` (revert = alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone", {
    "path": "res://mymod/scenes/wasteland.tscn",
})

lib.remove(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone")
```

A `path` that does not exist is refused. The same handle or the same path registered twice: the second fails.

### AI_TYPES

Zone -> enemy scene overrides on `AISpawner`. Valid zones: `"Area05"`, `"BorderZone"`, `"Vostok"`, `"Debug"`. Verbs: `register`, `override`, `remove`, `revert`. One registration per zone. The override replaces the zone's enemy scene; Build 2's nomads (spawned from a separate, zone-independent pool) and the bosses are not affected.

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

No patch. Two mods registering into the same zone: the second fails with "zone 'Area05' already claimed by 'mymod_zombie_area05'; use override to replace". `override` displaces the current claim and keeps it internally; `revert` restores it.

### AI_LOADOUTS

Injects mod weapons into AI spawn loadouts. Entries from all mods are additive: they are flattened into a list that the rewritten `AI.SelectWeapon` reads when an agent picks its weapon. Verbs: `register`, `override`, `remove`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.AI_LOADOUTS, "mymod_rifle_loadout", {
    "weapon_scene": preload("res://mymod/MyRifle.tscn"),  # PackedScene, or a String id resolvable via Database
    "ai_types": ["Bandit", "Guard"],  # subset of Nomad / Bandit / Guard / Military / Boss / Punisher / Bogeyman; case-insensitive
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

`ai_types` names are canonicalized to CamelCase; an unknown name fails the whole call with a warning, so a typo surfaces at register time instead of when nothing spawns. An AI matches an entry when any of its categories is listed: since Build 2 that is its `AIData` faction (`Nomad`, `Bandit`, `Guard`, `Military`, `Boss`) plus its variant name (`Punisher`, `Bogeyman`, or the faction name again), so `"Boss"` covers both bosses and `"Punisher"` only one. `chance` values outside 0..1 are clamped with a warning. `replace: true` clears the agent's existing weapon options before adding this one, which also wipes weapons added by other mods' entries that ran earlier. `register_ai_loadout(entries)` is a batched wrapper over this registry, and `register_weapon` can create an entry for you through its `ai_loadout` field.

No patch; entries are flat dicts, so `override` to replace.

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

No override or patch.

### RESOURCES

Escape hatch: patch arbitrary fields on any `.tres` by absolute path. Verbs: `patch`, `append`/`prepend`/`remove_from`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# patch any exposed field on the Resource
lib.patch(lib.Registry.RESOURCES, "res://Resources/GameData.tres", {"difficulty": 2})

# revert per-field or full
lib.revert(lib.Registry.RESOURCES, "res://Resources/GameData.tres", ["difficulty"])
lib.revert(lib.Registry.RESOURCES, "res://Resources/GameData.tres")
```

No register, override or remove; the Resource already exists in vanilla. For items, prefer `ITEMS`, which checks the `ItemData` shape; `RESOURCES` skips those checks.

Same patch-stacking rules as items: same-field writes last-wins, and revert returns to vanilla however many mods patched.

### SCENE_NODES

Patch property values on a specific node inside a scene without shipping a full scene override. Verbs: `patch`, `revert`. Id format: `"<scene_path>#<node_path>"`; `"...tscn#"` or `"...tscn#."` targets the scene root.

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

The loader listens to `SceneTree.node_added`. When a scene whose path has a registered patch instantiates, the patch is applied to each matching node before that node's `_ready` runs. The PackedScene resource is never mutated, only live instances. A patch registered after the scene is already in the tree is applied to the existing instances too.

The patch is checked at call time against a probe instantiation of the scene. If the node path or any property is missing, the whole patch is rejected and nothing applies.

Property values only. It cannot add or remove nodes and cannot patch embedded sub-resources. For that, `override(SCENES, ...)` with a full replacement scene.

Different properties on the same node from different mods compose. The same property: last call wins, and revert restores vanilla.

## Aggregator helpers

Six helpers that fan out to several primitive registries (items, scenes, loot, trader_pools, plus tracked patches) in one call. Use them when you ship a complete content unit, one weapon or one furniture piece, and want all the registrations and cross-compat patches at once. Use the primitives when you need finer control or are modifying existing content. The helpers are also reachable from [Setup-Plans](Setup-Plans) as `["register_weapon", {...}]` and so on.

| Method | Purpose |
|---|---|
| `register_item({id: dict, ...}) -> Dictionary` | Generic item bundle: ItemData + optional scene/icon/loot_tables/trader_pools |
| `register_weapon({id: dict, ...}) -> Dictionary` | Weapon + rig + inline magazines + fits_attachments + loot_tables + optional AI loadout |
| `register_magazine({id: dict, ...}) -> Dictionary` | Magazine + scene + fits_weapons (adds to each weapon's `compatible`) |
| `register_attachment({id: dict, ...}) -> Dictionary` | Attachment + scene + fits_weapons (same shape as magazine; split for readability) |
| `register_furniture({id: dict, ...}) -> Dictionary` | Furniture item + scene + trader_pools (default Generalist) + optional crafting recipe |
| `register_ai_loadout({id: dict, ...}) -> Dictionary` | Batch wrapper over the `ai_loadouts` primitive (per-id result is just `{ok}`) |

They always take a Dictionary of `{id: data}`, even for a single registration. There is no `(id, data)` overload; the `_register_*(id, data)` functions in `src/registry/aggregators.gd` are the internal workers.

```gdscript
# Single registration
lib.register_weapon({"my_ak": {"item_path": ..., "scene_path": ..., "rig_path": ...}})

# Multiple registrations, same shape
lib.register_weapon({
    "my_ak": {"item_path": ..., "scene_path": ..., "rig_path": ...},
    "my_m4": {"item_path": ..., "scene_path": ..., "rig_path": ...},
})
```

The return shape is `{ok: bool, results: {id: granular_dict}}`. Top-level `ok` is true only when every entry's per-id `ok` is true; failures are isolated per id. Each per-id dict has `ok`, one bool per fanned-out registry call (`items`, `scene`, `rig`, and `loot_count: int`), and for helpers with cross-compat fields, `<rel>: [String]` (resolved ids) and `<rel>_failed: [String]` (ids that didn't resolve).

```gdscript
var result := lib.register_weapon({"my_ak": {...}, "my_m4": {...}})
if not result.ok:
    for id in result.results:
        var per: Dictionary = result.results[id]
        if not per.ok:
            push_warning("[mymod] %s failed: items=%s scene=%s rig=%s" \
                    % [id, per.items, per.scene, per.rig])
```

The bundles create loot entries under `"<id>_in_<table>"` and trader-pool entries under `"<id>_in_pool_<pool>"`. Weapon rigs are registered as scene id `"<weapon_id>_Rig"`, furniture recipes as `"<id>_recipe"`. You need these handles to `remove` or `get_entry` the pieces individually.

The helpers have no storage of their own; they call the primitives. Undo by removing or reverting the primitives. Source: [src/registry/aggregators.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/aggregators.gd).

### register_item

Generic item bundle for content that isn't a weapon, magazine, attachment or furniture piece (consumables, keys, tools, ammo).

```gdscript
var result: Dictionary = lib.register_item({
    "MyMedkit": {
        "item_path":    "res://mymod/items/MyMedkit.tres",     # required
        "scene_path":   "res://mymod/items/MyMedkit.tscn",     # optional
        "icon_path":    "res://mymod/icons/MyMedkit.png",      # optional, sets ItemData.icon
        "loot_tables":  ["LT_Master"],                         # optional
        "trader_pools": ["Doctor"],                            # optional; Generalist, Doctor, Gunsmith, Driver, Hunter, Grandma
    },
})
# result.results.MyMedkit = {ok, items, scene, loot_count, trader_pool_count,
#                            trader_pools: [String], trader_pools_failed: [String]}
```

Per-id `scene` is `true` when no `scene_path` was given. Per-id `ok` requires `items`, `scene`, and no failed trader_pools.

### register_weapon

Weapon + first-person rig + optional inline magazines, fits_attachments, loot tables and AI loadout.

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

`magazines` adds each magazine's ItemData to the weapon's `compatible` array as a tracked patch. `fits_attachments` resolves vanilla or mod-registered attachment ids and adds them to `compatible` too. The rig is registered as scene id `"<weapon_id>_Rig"`.

Per-id `ok` requires `items`, `scene`, `rig` and zero `fits_attachments` failures. The optional `ai_loadout` dict creates an `ai_loadouts` entry using the weapon's own scene and id; you supply `ai_types`, `chance` and `replace`. A failed loadout shows in the per-id `ai_loadout` but does not gate `ok`: the weapon still spawns as loot, it just won't be carried by AI.

### register_magazine

Standalone magazine: item + scene + optional loot. `fits_weapons` patches each target weapon's `compatible` to include this magazine.

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

Same per-entry shape and result as `register_magazine`. Vanilla's `compatible` field takes mags and attachments interchangeably; the split is for readability.

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

Furniture is an ItemData with `type = "Furniture"` plus a placed world scene. It gets its own helper because the obtainment path differs: furniture never spawns from loot pools, it is bought from traders or crafted, and on purchase vanilla routes it to the catalog grid instead of the inventory grid.

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

`loot_tables` is warned about and ignored; furniture isn't loot-pool spawnable in vanilla. An `ItemData.type` other than `"Furniture"` warns but does not fail: vanilla branches on that string when the player buys the item, so a wrong type sends it to the inventory grid instead of the catalog. A `recipe` builds a fresh `RecipeData` with the registered item as output, `category` locked to `"furniture"`, registered under `"<id>_recipe"`. Trader-only furniture omits `recipe`.

## Reading the registry

Five read methods. All but `get_entry` take an optional `include_vanilla: bool = true`; pass `false` to see only what mods registered.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# Current entry at game-visible precedence (override > register > vanilla)
var potato = lib.get_entry(lib.Registry.ITEMS, "Potato")

# Membership check
if lib.has(lib.Registry.ITEMS, "AK_12"):
    lib.patch(lib.Registry.ITEMS, "AK_12", {"value": 500})

# All ids in this registry (default: vanilla + mod)
var all_item_ids: Array[String] = lib.keys(lib.Registry.ITEMS)
var only_mod_items: Array[String] = lib.keys(lib.Registry.ITEMS, false)

# Full id -> entry mapping
var all_items: Dictionary = lib.list(lib.Registry.ITEMS)

# Filtered iteration. Predicate signature: func(entry) -> bool
# Returns an Array of {id, entry} dicts
var weapons: Array = lib.find(lib.Registry.ITEMS, func(it):
    return it != null and "type" in it and it.get("type") == "Weapon"
)
for entry in weapons:
    print(entry["id"], " -> ", entry["entry"].get("name"))
```

For the handle-based registries (`loot`, `recipes`, `events`, `trader_pools`, `trader_tasks`, `inputs`, `scene_paths`, `shelters`, `maps`, `random_scenes`, `ai_types`, `ai_loadouts`, `fish_species`) `get_entry` returns the record the registry stored for that handle, or `null` if the id isn't a mod registration. The record is not always the payload you passed: `loot` adds the resolved `table_res`, `trader_pools` stores `{item, trader, flag, original}`, `shelters` / `maps` wrap the payload as `{auto_scene_path, entry, kind}`, `ai_types` stores `{scene, zone}`, and `ai_loadouts` stores the canonicalized entry (`weapon_scene` resolved to a `PackedScene`, `ai_types` in canonical case, `chance` clamped). `inputs` also returns a record for a vanilla action a mod has patched (marked `vanilla_stub`). It does not enumerate vanilla content. `scene_paths` returns the override dict when the id is overridden, vanilla names included, since that is the entry the game loads. For `resources` the id is a `res://` path and it returns `load(id)`. `scene_nodes` and the aggregator-only registries warn and return `null`.

Mod entries beat vanilla on id collision, so `list(ITEMS)` returns the mod's version when both exist.

Vanilla enumeration for `keys`, `list` and `find` with `include_vanilla = true`:

- `ITEMS` walks `LT_Master.items`, keyed by `.file`.
- `SCENES` reads the rewriter-captured `_rtv_vanilla_scenes` dict on Database, falling back to the script const map filtered to `PackedScene` when no rewrite happened.
- `SCENE_PATHS` reads the Loader script's const map filtered to `res://` strings.
- `SHELTERS` reads the vanilla shelter list snapshot.
- `RECIPES` walks the seven category arrays on `Recipes.tres` with ids synthesized as `"<category>:<recipe.name>"`. It is the only registry whose vanilla keys are in a different namespace from its register ids.
- Every other registry has an empty vanilla side; the primitives only track what mods added.

## Gotchas

The cross-cutting sharp edges. Per-registry edges are in the sections above.

- Timing is the usual failure. Traders, loot containers, the crafting UI and the event system cache in their own `_ready()` and never re-read. Register in your mod's `_ready()`. See [Timing](#timing).
- A missing `[registry]` section can fail silently. `scenes` and `scene_paths` warn, but `ai_types`, `ai_loadouts` and `fish_species` return `true` and do nothing in-game. See [Opting in](#opting-in).
- Aggregator helpers take `{id: data}` dicts only. `lib.register_item("my_id", {...})` is wrong; write `lib.register_item({"my_id": {...}})`.
- Patches are global and reach saves. Patched ItemData is what save files serialize. `revert` is the only undo.
- `remove` only undoes a mod `register`; it refuses vanilla entries and override-backed ids. `revert` undoes overrides and patches. On the append-only registries (`shelters`, `maps`, `random_scenes`, `fish_species`, `trader_pools`) `revert` is an alias for `remove`.
- `patch` return values drift by registry (see [patch](#patch)). On `items`, `sounds`, `recipes`, `events` and `trader_tasks`, `true` does not mean every field applied.
- Resource-ref ids work only for `recipes`, `events` and `trader_tasks`. Passing a `RecipeData`, `EventData` or `TaskData` to `patch`, `revert` or the array verbs is how you touch vanilla entries without a handle. Every other registry needs String ids.
- `revert_many` values must be Arrays (`[]` for full revert); bare strings are rejected, not coerced. `patch_many` values must be Dictionaries. Either way the bad entry warns, reports `false` and the rest of the batch runs.
- A `find` predicate that returns something other than a bool or a number counts as no match.
- A full `revert` restores patches first, then drops the override. Each patched value goes back onto the entry it was read from, so a patch made before an override is undone on the entry under the override, not on the override.
- `sounds` registrations are invisible to vanilla. Only `override` or `patch` of real `AudioLibrary` field names changes what the game plays.
- `inputs` ids are InputMap action names. Namespace them, and remember registered actions don't appear in the vanilla rebind UI without an extra hook.
- `events` with a bad `function` name are silent no-ops when they fire.
- `ai_loadouts` `replace: true` wipes other mods' earlier weapon entries for the same agent types.
- `scene_paths`, `shelters`, `maps` and `random_scenes` refuse a `path` that doesn't exist, on `register`, `override` and a `scene_paths` `patch` alike.
- The `WEAPONS`, `MAGAZINES` and `ATTACHMENTS` constants only support `register` and collapse the granular result to a bool. Prefer `register_weapon(...)` and friends.
- `when` predicates in `const` setup plans evaluate at parse time unless they are Callables. See [setup](#setup----declarative-plan).

## Troubleshooting

`lib.register` returns `false`:

- Check that `[registry]` is in your `mod.txt`. Without it the rewriter skips the injections that `scenes`, `scene_paths`, `shelters` and `maps` depend on.
- Check that the id doesn't collide with a vanilla name; use `override` instead.
- Check the payload shape. Most registries require specific keys (`table`, `trader`, `path`, and so on); the warning lists what is missing.

The registration succeeds but the game doesn't use it:

- Timing. Register during your mod's `_ready()`, not after scene load. Loot consumers in particular cache on their first `_ready()`.
- Missing `[registry]` in `mod.txt`. For `ai_types`, `ai_loadouts` and `fish_species` this is a silent no-op; `register` returns `true`.
- If you registered loot into a table but the trader's stock hasn't changed, the trader already filled its pool for the current day. Wait for the next refresh or force a day transition.
- For `sounds`, mod-registered ids are unreachable from vanilla code. Use `override` on a vanilla field name, or play the sound from your own code.

## See also

- [Hooks](Hooks): intercepting vanilla method calls
- [Setup-Plans](Setup-Plans): the declarative `setup(plan)` entry point in full
- [Dependencies](Dependencies): declaring load order and inter-mod requirements
- [Mod-Format](Mod-Format): `mod.txt` reference, including the `[registry]` section
- [Architecture](Architecture): where the registry sits in the load pipeline
