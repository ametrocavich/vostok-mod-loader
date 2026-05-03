# Registry

The registry system lets mods add, replace, patch, and remove content on the vanilla game data stores, items, scenes, loot tables, sounds, recipes, events, trader pools, inputs, shelters, AI types, fish species, arbitrary `.tres` resources, and node properties inside vanilla scenes, without shipping a full `Database.gd` override or source-rewriting vanilla scripts.

Registry mutations survive across scene loads (state lives on autoloads and preloaded resources) and unwind cleanly: every `register`/`override`/`patch` is reversible via `remove`/`revert`.

## Opting in

Mods that use the registry API declare an opt-in section in `mod.txt`:

```ini
[registry]
```

An empty `[registry]` section is enough, the loader only checks for its presence. Adding the section forces the rewriter to wrap `Database.gd`, `Loader.gd`, `AISpawner.gd`, and `FishPool.gd` with the injected fields the registry API needs. See [hook_pack.gd:20 `REGISTRY_TARGETS`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L20).

Without the declaration, the rewriter doesn't inject the machinery several vanilla-backed slots rely on. Behavior splits by slot:

- **Explicit failure with hint.** SCENES and SCENE_PATHS check for the injected fields on the autoload (`_rtv_mod_scenes` on Database, `_rtv_mod_scene_paths` on Loader) and emit a `push_warning` naming the missing `[registry]` section. Mod authors see the real cause immediately.
- **Silent no-op.** AI_TYPES and FISH_SPECIES write to `Engine.set_meta(...)` that the rewriter-injected resolver/prelude on AISpawner / FishPool would normally read. Without rewriting, `register` returns true with no warning but vanilla never reads the meta entries, so the override is invisible in-game.
- **Degraded revert.** SHELTERS and RANDOM_SCENES append to `Loader.shelters` / `Loader.randomScenes`. The rewriter converts vanilla's `const shelters = [...]` to `var` with a capture snapshot so `revert` can restore the original list; without the declaration, revert semantics are undefined (the append itself may still function within a single session).
- **Works regardless.** ITEMS, LOOT, RECIPES, EVENTS, SOUNDS, INPUTS, TRADER_POOLS, TRADER_TASKS, RESOURCES, and SCENE_NODES track state in the registry's own internal dicts (or, for `scene_nodes`, a `SceneTree.node_added` listener). They don't need any vanilla rewriting.

Add `[registry]` whenever you use the API. It's free if you only touch the last bucket, and necessary for anything else.

## Public API

Mods reach the loader the same way as the hook system: `Engine.get_meta("RTVModLib")`. Source: [src/registry.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd).

```gdscript
var lib = Engine.get_meta("RTVModLib")
await lib.frameworks_ready

lib.register(lib.Registry.ITEMS, "my_mod_potion", my_potion_resource)
lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/better_potato.tscn"))
lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
lib.remove(lib.Registry.ITEMS, "my_mod_potion")
lib.revert(lib.Registry.SCENES, "Potato")
```

### Methods

| Method | Purpose |
|---|---|
| `register(registry, id, data) -> bool` | Add a new entry. Fails on id collision with vanilla or prior mod registrations |
| `override(registry, id, data) -> bool` | Replace an existing entry wholesale. Fails if the id doesn't resolve |
| `patch(registry, id, fields) -> bool` | Mutate individual fields on an entry. Original values are stashed for revert |
| `append(registry, id, field, values, allow_duplicates=false) -> bool` | Add to an Array field. De-dups by default. Stash shared with `patch` |
| `prepend(registry, id, field, values, allow_duplicates=false) -> bool` | Same as `append` but inserts at the front |
| `remove_from(registry, id, field, values) -> bool` | Drop matching values from an Array field. Removes all occurrences, idempotent |
| `remove(registry, id) -> bool` | Undo a `register`. Fails on override-backed ids (use `revert`) |
| `revert(registry, id, fields=[]) -> bool` | Undo an `override` or `patch`. Per-field revert when `fields` is non-empty |
| `register_many(registry, {id: data, ...}) -> Dictionary` | Batched register; returns `{ok, results}` |
| `override_many(registry, {id: data, ...}) -> Dictionary` | Batched override |
| `patch_many(registry, {id: fields, ...}) -> Dictionary` | Batched patch |
| `append_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched append on the same field across many ids |
| `prepend_many(registry, field, {id: values, ...}, allow_duplicates=false) -> Dictionary` | Batched prepend |
| `remove_from_many(registry, field, {id: values, ...}) -> Dictionary` | Batched remove_from |
| `revert_many(registry, {id: fields_array, ...}) -> Dictionary` | Batched revert; per-id `fields_array` (empty = full revert of that id) |
| `remove_many(registry, [id, ...]) -> Dictionary` | Batched remove |
| `setup(plan) -> Dictionary` | Declarative entry point: list of `[verb, ...args]` entries dispatched in order. See the **`setup` plan** section below |
| `get_entry(registry, id) -> Variant` | Read the current entry (after any registry mutations). Returns `null` if missing |
| `has(registry, id, include_vanilla=true) -> bool` | Membership check. Cheaper than `get_entry(...) != null` |
| `keys(registry, include_vanilla=true) -> Array[String]` | All ids in the registry |
| `list(registry, include_vanilla=true) -> Dictionary` | All `id -> entry` pairs |
| `find(registry, predicate, include_vanilla=true) -> Array` | Filtered iteration; returns `[{id, entry}, ...]` |

Every mutating verb returns a bool indicating success; failures log a `push_warning` with the reason. The read methods (`get_entry`, `has`, `keys`, `list`, `find`) never warn; they return empty / null / false for misses.

### Aggregator helpers

Five high-level helpers that fan out to multiple primitive registries in one declarative call. They live alongside the standard verbs, take a `Dictionary` of `{id: data, ...}` (one entry or many), and return a wrapped granular result `{ok, results: {id: per_id_dict}}`.

| Method | Purpose |
|---|---|
| `register_item({id: dict, ...}) -> Dictionary` | Generic item bundle: ItemData + optional scene/icon/loot_tables/trader_pools |
| `register_weapon({id: dict, ...}) -> Dictionary` | Weapon + rig + inline magazines + fits_attachments + loot_tables |
| `register_magazine({id: dict, ...}) -> Dictionary` | Magazine + scene + fits_weapons (additive append to weapons' compatible) |
| `register_attachment({id: dict, ...}) -> Dictionary` | Attachment + scene + fits_weapons (same shape as magazine; split for readability) |
| `register_furniture({id: dict, ...}) -> Dictionary` | Furniture item + scene + trader_pools (default Generalist) + optional crafting recipe |

Aggregators are pure fan-out -- they call existing primitives under the hood. There's no separate storage; mods can drop down to primitives any time. Use the aggregators when you're shipping a complete content unit (one weapon, one furniture piece) and want all the registrations + cross-compat patches in one call. Use primitives when you need fine-grained control or you're modifying existing content rather than adding.

The wrapped result is always `{ok: bool, results: {id: per_id_dict}}`. Top-level `ok` is true when every entry's per-id `ok` is true. Per-id dict shape varies by helper but always includes:
- `ok: bool` -- did this entry's full fan-out succeed
- One bool per fanned-out registry call (e.g. `items`, `scene`, `rig`, `loot_count: int`)
- For helpers with cross-compat fields: `<rel>: [String]` (resolved ids) and `<rel>_failed: [String]` (ids that didn't resolve)

Each helper section below documents its specific schema. Source: [src/registry/aggregators.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry/aggregators.gd).

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
| `TRADER_POOLS` | `"trader_pools"` | Per-item trader boolean flags | register, remove, revert |
| `TRADER_TASKS` | `"trader_tasks"` | `TraderData.tasks` arrays | register, override, patch, append/prepend/remove_from, remove, revert |
| `INPUTS` | `"inputs"` | `InputMap` actions | register, override, patch, remove, revert |
| `SCENE_PATHS` | `"scene_paths"` | Named scene lookup on `Loader.gd` | register, override, patch, remove, revert |
| `SHELTERS` | `"shelters"` | `Loader.shelters` append-only list | register, remove |
| `RANDOM_SCENES` | `"random_scenes"` | `Loader.randomScenes` append-only list | register, remove |
| `AI_TYPES` | `"ai_types"` | Zone → agent scene overrides on `AISpawner` | register, override, remove, revert |
| `AI_LOADOUTS` | `"ai_loadouts"` | Per-AI-category weapon injections (`AI.SelectWeapon` prelude) | register, override, remove, revert |
| `FISH_SPECIES` | `"fish_species"` | `FishPool` extra species | register, remove |
| `RESOURCES` | `"resources"` | Arbitrary `.tres` by absolute path | patch, append/prepend/remove_from, revert |
| `SCENE_NODES` | `"scene_nodes"` | Property mutations on nodes inside any scene | patch, revert |
| `WEAPONS` | `"weapons"` | Aggregator-only; routes to `register_weapon` | register (collapses to bool) |
| `MAGAZINES` | `"magazines"` | Aggregator-only; routes to `register_magazine` | register (collapses to bool) |
| `ATTACHMENTS` | `"attachments"` | Aggregator-only; routes to `register_attachment` | register (collapses to bool) |

Unsupported verbs return `false` with a guidance warning (e.g. "patch on loot rejected, use override for content swaps").

Aggregator-only registries (`WEAPONS`, `MAGAZINES`, `ATTACHMENTS`) reject `override`/`patch`/`remove`/`revert` at the standard-verb dispatcher with guidance to use the underlying primitives. They exist so mods that want bool-only routing (e.g. checking `register('weapons', ...)` in a generic loop) get consistent behavior, but the dedicated `register_weapon` / etc. methods are the preferred way to call them since you get the granular result dict.

## Timing

**Register during mod `_ready()`**, before vanilla game systems finish initializing. Several consumers populate local caches once and never re-read:

- Trader stock, `LootContainer`, and `LootSimulation` copy from `LootTable` in their own `_ready()`.
- `AudioLibrary` fields are read by `@export` binding at autoload time.
- `InputMap` actions registered after gameplay starts work but don't appear in the remapping UI until a scene reload.

Mod autoloads load **after** vanilla autoloads and **before** the first scene. Registering inside your mod's `_ready()` is almost always early enough. If you need hooks to finish first, `await lib.frameworks_ready` before any `register` call.

Runtime re-registration after scene load is invisible to systems that already cached, the registry updates the underlying store, but the cache holds the old snapshot. Covered in the source-level note at [src/registry.gd:22-26](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/registry.gd#L22).

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

Overrides on mod registrations are allowed, use this to resolve same-id conflicts between mods without touching the loser's code.

### patch

Mutates specific fields on the current entry (vanilla, override, or prior `register`). Stash-and-restore semantics: the first patch to a field saves its pre-patch value; subsequent patches to the same field don't re-stash, so a full `revert` returns to the true original.

```gdscript
lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # restore just weight
lib.revert(lib.Registry.ITEMS, "Potato")              # restore everything else
```

Registries that don't support patch (loot, scenes, trader_pools, fish_species) return `false` with guidance.

### append / prepend / remove_from

Array-only mutations on a single field. Use these instead of `patch` when you want to **add to** or **subtract from** an existing array (e.g. a weapon's `compatible` list) without overwriting other entries other mods may have contributed.

```gdscript
# Add new magazines as compatible options on the AKM, without clobbering vanilla's list:
lib.append(lib.Registry.ITEMS, "res://Items/Magazines/AKM.tres", "compatible", [magA, magB])

# Single value also works (no need to wrap in an array):
lib.append(lib.Registry.ITEMS, "res://Items/Magazines/AKM.tres", "compatible", magC)

# Insert at the front instead of the end:
lib.prepend(lib.Registry.SOUNDS, "footsteps_dirt", "audio", newClip)

# Remove an entry; silent skip if it isn't there.
lib.remove_from(lib.Registry.ITEMS, "res://Items/Magazines/AKM.tres", "compatible", oldMag)
```

**Semantics:**
- **Array fields only.** Calling on a non-Array field returns `false` with a "field is not an Array" warning. For scalar fields, use `patch` instead.
- **De-dup on append/prepend by default.** If a value is already in the array, it isn't appended again. Pass `allow_duplicates=true` to permit repeats.
- **`remove_from` removes all matching occurrences,** not just the first. Idempotent — re-running with the same value is a no-op after the first call.
- **Stash is shared with `patch`.** A `patch` on `compatible` followed by `append` to `compatible` keeps the *original* (pre-patch, pre-append) value on first-write-wins. `revert(reg, id, ["compatible"])` restores the true original.
- **Typed-array safety.** Values that don't match the array's declared type (e.g. trying to append a non-`ItemData` Resource into `Array[ItemData]`) are rejected before any mutation, with a "rejected by typed-array constraint" warning.

**Supported registries:** `items`, `sounds`, `recipes`, `events`, `trader_tasks`, `resources`. Other registries either don't have Array fields (`inputs`, `scene_paths`) or have non-Resource entries (`scenes`, `loot`, `shelters`, etc.); calls return `false` with guidance.

### remove

Reverses a prior `register`. Fails on override-backed or vanilla ids, those need `revert`.

### revert

Reverses an `override` or `patch`. Fails if there's nothing to undo (nothing overridden and no field stashes).

- Bare `revert(registry, id)` with no `fields` argument unwinds everything for that id (patches first, then the override).
- `revert(registry, id, ["field1", "field2"])` unwinds only those specific patched fields; other patches and the override stay.

### Batched forms (`*_many`)

Every mutation verb has a sibling that takes a Dictionary of ids (or, for `remove_many`, an Array). One call, many entries, single-registry. Useful for table-driven mods that already store their data as a dict.

```gdscript
# Patch many items in one call.
lib.patch_many(lib.Registry.ITEMS, {
    "res://Items/Weapons/AKM/AKM.tres":  {"damage": 45},
    "res://Items/Weapons/AK74/AK74.tres": {"damage": 40},
})

# Append the same field across many ids.
lib.append_many(lib.Registry.ITEMS, "compatible", {
    "res://Items/Weapons/AKM/AKM.tres":  [magA, magB],
    "res://Items/Weapons/AK74/AK74.tres": [magC],
})

# Per-id field lists for revert. Empty array = full revert of that id.
lib.revert_many(lib.Registry.ITEMS, {
    "res://Items/Weapons/AKM/AKM.tres":  ["damage", "compatible"],
    "res://Items/Weapons/AK74/AK74.tres": [],
})

# Remove a list of mod-registered entries.
lib.remove_many(lib.Registry.ITEMS, ["my_mod_potion", "my_mod_grenade"])
```

**Return shape.** Each `_many` returns `{ok: bool, results: {id: bool, ...}}`. `ok` is true only when every entry succeeded. Failures are isolated — one bad id doesn't stop the others, and the per-id success bools tell you which ones landed.

```gdscript
var result := lib.patch_many(lib.Registry.ITEMS, {...})
if not result.ok:
    for id in result.results:
        if not result.results[id]:
            push_warning("[mymod] failed to patch %s" % id)
```

**One field per call** for the array verbs. `append_many` / `prepend_many` / `remove_from_many` all take a single `field` arg that applies to every entry in the dict. If you need different fields per id, make multiple calls — or use `setup` (below) which runs an ordered sequence of verbs in one call.

### setup -- declarative plan

`setup(plan)` runs an ordered list of `[verb, ...args]` entries that map to the registry verbs above plus `hooks` (batched hook registration) and `when` (conditional sub-plans). One declarative literal replaces the typical pile of administrative `_ready` lines.

```gdscript
const PLAN = [
    ["register", lib.Registry.ITEMS, {"my_mod_potion": myPotionData}],
    ["patch",    lib.Registry.ITEMS, {"res://Items/Weapons/AKM/AKM.tres": {"damage": 45}}],
    ["append",   lib.Registry.ITEMS, "compatible", {"res://Items/Weapons/AKM/AKM.tres": [magA, magB]}],
    ["hooks",    {"interface-getmagazine": _replace_get_mag}],
    ["when",     _is_hardcore, [
        ["patch", lib.Registry.ITEMS, {"res://Items/Misc/Sticks/Sticks.tres": {"value": 200}}],
    ]],
]

func _ready() -> void:
    var lib = Engine.get_meta("RTVModLib")
    await lib.frameworks_ready
    lib.setup(PLAN)
```

See **[Setup](Setup)** for the full verb table, predicate forms, return shape, and a comprehensive example covering every supported entry.

### get_entry

Reads the current state without mutating. Useful for assertions and to chain reads after an override, the returned Variant is whatever the registry's logical "current entry" is.

## Conflict-handling fundamentals

Before the per-registry examples, the rules that apply across every registry:

- **`register` on a colliding id fails.** Whether the collision is with vanilla or with an earlier mod's registration, the second caller's `register` returns `false` with a `push_warning`. No silent overwrite.
- **`override` on an already-overridden id fails.** The second caller must `revert` first (if they want to replace the earlier mod's override) or target the override's id explicitly.
- **`patch` on the same field stacks.** Both writes apply in call order; last writer's value is visible. The stash preserves the **true vanilla original** (the first patcher's pre-patch value), so a later `revert` returns to vanilla, not to the first patcher's value. Mod A's patch is lost on revert even if Mod A didn't call revert themselves.
- **`patch` on different fields coexists.** Independent stash per field name; both mods' patches are respected simultaneously.
- **Array-based registries (`loot`, `recipes`, `events`, `trader_tasks`) are additive on `register`.** Two mods registering different ids into the same array both succeed; the array just grows.
- **Array `override` (the `replaces:` form) fails if the target is already gone.** If mod A swapped `vanillaX` for `newA`, mod B can't also swap `vanillaX`, it's no longer in the array. Mod B would have to target `newA` instead (which then silently undoes mod A's swap, avoid this).

The rest of this doc walks each registry with a minimal example per verb and a note on any registry-specific conflict edge.

---

## SCENES

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

---

## ITEMS

`ItemData` Resources keyed by `file`. Verbs: all five.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var elixir = load("res://mymod/items/Elixir.tres")
# elixir.file must equal "mymod_elixir"; register enforces this

# register
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

**Conflicts.**
- Two overrides of the same item: second fails, first wins.
- Two patches on the **same field**: both calls succeed, second value wins visually. The stash holds vanilla, so any revert on that id returns to vanilla, losing both patches.
- Two patches on **different fields**: both coexist independently.

---

## LOOT

Adds/swaps `ItemData` entries inside `LootTable.items`. IDs are mod-chosen handles (not tied to any in-game name). Verbs: `register`, `override`, `remove`, `revert`.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var fancy = load("res://mymod/items/FancyBandage.tres")

# register: append to a loot table
lib.register(lib.Registry.LOOT, "mymod_fancy_in_master", {
    "item": fancy,
    "table": "LT_Master",         # bare stem or "res://Loot/LT_Master.tres"
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

**Patch is not supported** on loot; loot entries are whole `ItemData` references, not dicts of fields. Patch returns `false` with guidance ("use override for content swaps").

**Conflicts.**
- Two `register` calls adding the same item to the same table: rejected as a duplicate (the table would contain the same `ItemData` twice).
- Two `override` calls with the same `replaces:` target: second fails because the first removed `replaces` from the table. Mod B would need to target mod A's new item; avoid this, it silently undoes mod A.

---

## SOUNDS

`AudioEvent` fields on `AudioLibrary.tres`, plus mod-registered lookup entries. Verbs: all five.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var custom_event = preload("res://mymod/audio/Footstep.tres")  # AudioEvent

# register: add a new sound id (lookup via get_entry only; vanilla code
# can't reach these ids directly since it hardcodes property names)
lib.register(lib.Registry.SOUNDS, "mymod_custom_footstep", custom_event)

# register via Dictionary shorthand (builds an AudioEvent internally)
lib.register(lib.Registry.SOUNDS, "mymod_dict_sound", {
    "audioClips": [],
    "volume": -3.0,
    "randomPitch": true,
})

# override: replace a vanilla AudioLibrary @export field.
# `id` must match a real @export field name on AudioLibrary.tres;
# override rejects mod-registered ids (revert first to re-register).
lib.override(lib.Registry.SOUNDS, "knifeSlash", custom_event)

# patch: mutate AudioEvent fields (audioClips, volume, randomPitch)
lib.patch(lib.Registry.SOUNDS, "knifeSlash", {"volume": -10.0, "randomPitch": true})

# revert per-field / full / remove
lib.revert(lib.Registry.SOUNDS, "knifeSlash", ["randomPitch"])
lib.revert(lib.Registry.SOUNDS, "knifeSlash")
lib.remove(lib.Registry.SOUNDS, "mymod_custom_footstep")
```

**Conflicts.** Same rules as items. `register` collisions with vanilla `@export` field names are rejected (use `override`). Override only works on vanilla fields, not mod-registered ids.

---

## RECIPES

`RecipeData` Resources in per-category arrays on `Recipes.tres`. Verbs: all five. Patch accepts either a String handle OR a direct `RecipeData` ref.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var my_recipe = load("res://mymod/recipes/CraftElixir.tres")

# register
lib.register(lib.Registry.RECIPES, "mymod_craft_elixir", {
    "recipe": my_recipe,
    "category": "consumables",  # consumables, medical, equipment, weapons, electronics, misc, furniture
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

**Conflicts.** Same as loot for `register`/`override`. Patches stack per field.

---

## EVENTS

`EventData` entries in `Events.tres`. Mirrors recipes exactly: `register`, `override`, `patch`, `remove`, `revert`. Patch accepts String handle or direct `EventData` ref.

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

---

## TRADER_POOLS

Flips a trader's boolean flag on an `ItemData` (e.g. `item.doctor = true` puts the item in the Doctor's pool). Verbs: `register`, `remove`, `revert` (revert is a straight alias for remove).

```gdscript
var lib = Engine.get_meta("RTVModLib")
var potato = load("res://Items/Consumables/Potato/Potato.tres")

# register: enable item for the Doctor trader
lib.register(lib.Registry.TRADER_POOLS, "mymod_potato_doctor", {
    "item": potato,
    "trader": "Doctor",  # "Generalist", "Doctor", "Gunsmith"; case-insensitive
})

# remove / revert: restore the original flag value
lib.remove(lib.Registry.TRADER_POOLS, "mymod_potato_doctor")
# or equivalently:
lib.revert(lib.Registry.TRADER_POOLS, "mymod_potato_doctor")
```

**No `override` or `patch`**. Pool membership is binary and ungated. Trader pool entries keyed by the mod handle, not the item; two mods can independently enable the same item for the same trader (both `register` calls succeed, flag stays `true` until both remove).

**Conflicts.** Mostly harmless. The underlying flag is idempotent (`true` OR `true` = `true`). The only surprise: on `remove`, the flag restores to the stashed "original", whatever the flag was when that specific `register` call fired. If mod A registered first (stash=false), mod B registered second (stash=true, because mod A already flipped it), and mod A removes first, the flag goes back to `false` despite mod B still "owning" a registration. This is a known quirk; avoid double-registering the same item/trader pair across mods.

---

## TRADER_TASKS

`TaskData` entries in per-trader `tasks` arrays. Verbs: all five. Patch accepts String handle or direct `TaskData` ref.

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

---

## INPUTS

Declares new `InputMap` actions with a default event; lets mods rebind vanilla actions. Verbs: all five.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var key_h = InputEventKey.new()
key_h.keycode = KEY_H

# register a new action
lib.register(lib.Registry.INPUTS, "mymod_quick_heal", {
    "display_label": "Quick Heal",
    "default_event": key_h,
    "deadzone": 0.5,  # optional
})

# override an existing action's default event (vanilla or mod-registered)
var key_f = InputEventKey.new()
key_f.keycode = KEY_F
lib.override(lib.Registry.INPUTS, "forward", {
    "display_label": "Move Forward",
    "default_event": key_f,
})

# patch specific fields (display_label, default_event, or deadzone)
lib.patch(lib.Registry.INPUTS, "mymod_quick_heal", {"display_label": "Heal!"})

lib.revert(lib.Registry.INPUTS, "forward")
lib.remove(lib.Registry.INPUTS, "mymod_quick_heal")
```

**Conflicts.** Standard register/override rules. Two mods overriding the same action: second fails. InputMap rebinding is visible immediately; in-game key prompts update on next UI refresh.

**UI caveat.** Vanilla's Settings → Keybinds panel reads from a hardcoded `inputs` dict inside `Inputs.gd`. Registering an action makes it functional in-game but it **won't appear in the rebind menu** without an additional hook on `Inputs-createactions-pre`. See `src/registry/inputs.gd:19-26` for details.

---

## SCENE_PATHS

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

# patch just the flags
lib.patch(lib.Registry.SCENE_PATHS, "mymod_bunker", {"permadeath": true})

lib.revert(lib.Registry.SCENE_PATHS, "Cabin")
lib.remove(lib.Registry.SCENE_PATHS, "mymod_bunker")
```

**Conflicts.** Standard rules. Vanilla-const collisions on `register` are rejected; use `override`. Two mods overriding the same vanilla scene path: second fails.

---

## SHELTERS

Append-only list of shelter names on `Loader.shelters`. Verbs: `register`, `remove` only.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# register with path: auto-creates paired scene_paths entry with shelter=true
lib.register(lib.Registry.SHELTERS, "mymod_bunker", {
    "path": "res://mymod/scenes/bunker.tscn",
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

**No override / patch / revert**. The list is append-only. To swap a shelter's scene, `override` the corresponding `SCENE_PATHS` entry instead.

**Conflicts.** Two mods registering the same shelter name: second fails. Collision with vanilla shelter list also rejected.

---

## RANDOM_SCENES

Append-only list of `res://` paths on `Loader.randomScenes` (picked by `LoadSceneRandom()`). Verbs: `register`, `remove` only.

```gdscript
var lib = Engine.get_meta("RTVModLib")

lib.register(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone", {
    "path": "res://mymod/scenes/wasteland.tscn",
})

lib.remove(lib.Registry.RANDOM_SCENES, "mymod_wasteland_zone")
```

**Conflicts.** Same handle or same path registered twice: second fails.

---

## AI_TYPES

Zone → agent scene overrides on `AISpawner`. Zone is a string key (e.g. `"Area05"`). Verbs: `register`, `override`, `remove`, `revert`.

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

---

## FISH_SPECIES

Append-only list of `PackedScene` + `pool_id` entries on `FishPool`. Verbs: `register`, `remove` (revert is an alias).

```gdscript
var lib = Engine.get_meta("RTVModLib")
var salmon = preload("res://mymod/fish/Salmon.tscn")

# pool_id="all" (default): eligible in every fishing pool
lib.register(lib.Registry.FISH_SPECIES, "mymod_salmon", {
    "scene": salmon,
    "pool_id": "all",
})

# pool_id="FP_2": restricted to one pool
lib.register(lib.Registry.FISH_SPECIES, "mymod_trout_fp2", {
    "scene": preload("res://mymod/fish/Trout.tscn"),
    "pool_id": "FP_2",
})

lib.remove(lib.Registry.FISH_SPECIES, "mymod_salmon")
# revert is equivalent:
lib.revert(lib.Registry.FISH_SPECIES, "mymod_salmon")
```

**No override / patch.**

---

## RESOURCES

Escape hatch: patch arbitrary fields on any `.tres` by absolute path. Verbs: `patch`, `revert` only.

```gdscript
var lib = Engine.get_meta("RTVModLib")
var path = "res://Items/Consumables/Potato/Potato.tres"

# patch any exposed field on the Resource
lib.patch(lib.Registry.RESOURCES, path, {"weight": 0.01, "value": 9999})

# revert per-field or full
lib.revert(lib.Registry.RESOURCES, path, ["weight"])
lib.revert(lib.Registry.RESOURCES, path)
```

**No register / override / remove**. This registry is for touching Resources that don't have a dedicated handler. For items specifically, prefer `ITEMS` which enforces `ItemData`-shape validation. Falling back to `RESOURCES` bypasses those checks.

**Conflicts.** Same patch-stacking semantics as items: same-field writes last-wins, revert returns to vanilla regardless of how many mods patched.

---

## SCENE_NODES

Patch property values on a specific node inside a scene without shipping a full scene override. Verbs: `patch`, `revert` only. Id format: `"<scene_path>#<node_path>"`.

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

The loader subscribes to `SceneTree.node_added`. When a scene whose path matches a registered patch instantiates, the loader walks the registered node paths inside that scene and applies the patch to each match. The PackedScene resource is never mutated; only live instances. Late patches (registered after the scene is already in the tree) scan existing live instances and apply retroactively.

**No `register` / `override`**. To add new nodes use `override(SCENES, ...)` with a full replacement scene. To swap the whole scene's PackedScene wholesale, same. `SCENE_NODES` is patch-only.

**Conflicts.** Multiple mods patching different properties on the same node compose cleanly. Multiple mods patching the **same** property: last call wins; revert restores vanilla.

---

## Aggregator helpers (registries to use them with)

The five `register_<thing>(entries)` methods are pure fan-out wrappers that call multiple primitive registry verbs. Use them when you're shipping a complete content unit and want one declarative call. They're also reachable from [Setup](Setup) as `["register_weapon", {...}]` etc.

**Always take a Dictionary**. Even a single registration goes in as a one-key dict. There is no `(id, data)` overload.

```gdscript
# Single registration
lib.register_weapon({"my_ak": {item_path: ..., scene_path: ..., rig_path: ...}})

# Multiple registrations -- same shape, more keys
lib.register_weapon({
    "my_ak":  {item_path: ..., scene_path: ..., rig_path: ...},
    "my_m4":  {item_path: ..., scene_path: ..., rig_path: ...},
})
```

**Return shape** is uniform: `{ok: bool, results: {id: granular_dict}}`. Each value in `results` is the per-id granular dict. `ok` at the top is true only when every entry succeeded.

```gdscript
var result := lib.register_weapon({"my_ak": {...}, "my_m4": {...}})
if not result.ok:
    for id in result.results:
        var per: Dictionary = result.results[id]
        if not per.ok:
            push_warning("[mymod] %s failed: items=%s scene=%s rig=%s" \
                    % [id, per.items, per.scene, per.rig])
```

### register_item

Generic item bundle. Use for content that doesn't fit weapon/mag/attachment/furniture (consumables, keys, tools, ammo).

```gdscript
var result: Dictionary = lib.register_item({
    "MyMedkit": {
        "item_path":    "res://mymod/items/MyMedkit.tres",     # required
        "scene_path":   "res://mymod/items/MyMedkit.tscn",     # optional
        "icon_path":    "res://mymod/icons/MyMedkit.png",      # optional, sets ItemData.icon
        "loot_tables":  ["LT_Master"],                         # optional
        "trader_pools": ["Doctor"],                            # optional
    },
})
# result.results.MyMedkit = {ok, items, scene, loot_count, trader_pool_count,
#                            trader_pools: [String], trader_pools_failed: [String]}
```

Per-id `scene` defaults to `true` when no `scene_path` is provided (vacuously satisfied). The per-id `ok` requires `items` + `scene` + no failed trader_pools.

### register_weapon

Weapon + first-person rig + optional inline magazines + optional fits_attachments + optional loot tables.

```gdscript
var result: Dictionary = lib.register_weapon({
    "MyRifle": {
        "item_path":  "res://mymod/MyRifle.tres",                # required
        "scene_path": "res://mymod/MyRifle.tscn",                # required (world model)
        "rig_path":   "res://mymod/MyRifle_Rig.tscn",            # required (first-person rig)
        "icon_path":  "res://mymod/Icon_MyRifle.png",            # optional
        "magazines": [                                            # optional, mixed array
            {                                                     # inline = new mag registration
                "id": "MyRifle_StdMag",
                "item_path":  "res://mymod/MyRifle_Mag.tres",
                "scene_path": "res://mymod/MyRifle_Mag.tscn",
                "loot_tables": ["LT_Master"],                     # mag's own loot
            },
            "AK_12_Magazine",                                     # id-string = ref to existing mag
        ],
        "fits_attachments": ["ACOG", "Kobra"],                    # optional
        "loot_tables": ["LT_Master"],                             # optional, weapon's own loot
    },
})
# result.results.MyRifle = {ok, items, scene, rig,
#                           magazines: [{id, ok, items, scene, loot_count}, ...],
#                           fits_attachments: [String], fits_attachments_failed: [String],
#                           loot_count: int}
```

The `magazines` field auto-populates the weapon's `compatible` array with each magazine's ItemData ref. `fits_attachments` resolves vanilla / mod-registered attachment ids and appends them to `compatible` too.

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

Same per-entry shape as `register_magazine`. Vanilla's `compatible` field accepts mags and attachments interchangeably; the API split is for mod-author readability.

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
            "input": [<ItemData refs>],                            # required if recipe present
            "time":  10.0,
            "audio": <AudioEvent ref>,                             # optional
        },
    },
})
# result.results.MyBed = {ok, items, scene, trader_pool_count,
#                         trader_pools: [String], trader_pools_failed: [String], recipe: bool}
```

**`loot_tables` is rejected with a warning** -- furniture isn't loot-pool spawnable in vanilla. If the modder includes it, the field is logged as ignored.

**Type validation**: warns (doesn't fail) if `ItemData.type` isn't `"Furniture"`. Vanilla code branches on this string when the player buys the item; a wrong type means the item goes to the inventory grid instead of the catalog.

**Recipe construction**: builds a fresh `RecipeData` with output = the registered item, `category = "furniture"` locked. Mods that just want trader-only furniture skip the `recipe` field entirely.

---

## Reading the registry

Three methods complement `get_entry` for bulk reads. All take an optional `include_vanilla: bool = true` -- pass `false` to see only what mods registered.

```gdscript
var lib = Engine.get_meta("RTVModLib")

# Membership check
if lib.has(lib.Registry.ITEMS, "AK_12"):
    lib.patch(lib.Registry.ITEMS, "AK_12", {"damage": 50})

# All ids in this registry (default: vanilla + mod)
var all_item_ids: Array[String] = lib.keys(lib.Registry.ITEMS)
var only_mod_items: Array[String] = lib.keys(lib.Registry.ITEMS, false)

# Full id -> entry mapping
var all_items: Dictionary = lib.list(lib.Registry.ITEMS)
for id in all_items:
    var item_data = all_items[id]

# Filtered iteration. Predicate signature: func(entry) -> bool
# Returns Array of {id, entry} dicts so callers don't need a separate id lookup
var weapons: Array = lib.find(lib.Registry.ITEMS, func(it):
    return it != null and "type" in it and it.get("type") == "Weapon"
)
for entry in weapons:
    print(entry["id"], " -> ", entry["entry"].get("name"))
```

**Mod-vs-vanilla precedence** matches `get_entry`: mod entries override vanilla on id collision. So `list(ITEMS)` returns the mod's version when both exist.

**Per-registry vanilla enumeration**:
- `ITEMS` -- walks `LT_Master.items`, keyed by `.file`
- `SCENES` -- Database script's const map filtered to `PackedScene`
- `SCENE_PATHS` -- Loader script's const map filtered to `res://` strings
- `SHELTERS` -- vanilla shelter list snapshot
- `RECIPES` -- walks `Recipes.tres` seven category arrays, ids synthesized as `"<category>:<name>"`
- All other registries (loot, trader_pools, sounds, events, inputs, etc.) -- vanilla side returns empty; these are mod-only registries by nature, the registry primitives only track what mods added

`include_vanilla = false` returns only `_registry_registered[name]` for any registry.

---

## Troubleshooting

**`lib.register` returns `false`**
- Double-check `[registry]` is in your `mod.txt`. Without it the rewriter skips the required injections and registry writes no-op.
- Check the id doesn't collide with a vanilla name, use `override` instead.
- Check the payload shape. Most registries require specific keys (`table`, `trader`, `path`, etc.), the warning message lists what's missing.

**My registration succeeds but the game doesn't use it**
- Timing. Register during your mod `_ready()`, not after scene load. Loot consumers in particular cache on first `_ready()`.
- If you registered loot into a table but the trader's stock hasn't changed, the trader already populated its pool for the current day. Wait for the next refresh or force a day transition.

## See also

- [Hooks](Hooks): intercepting vanilla method calls
- [Mod-Format](Mod-Format): `mod.txt` reference
- [Architecture](Architecture): where the registry sits in the load pipeline
