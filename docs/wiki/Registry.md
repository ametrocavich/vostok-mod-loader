# Registry

The registry system lets mods add, replace, patch, and remove content on the vanilla game data stores, items, scenes, loot tables, sounds, recipes, events, trader pools, inputs, shelters, AI types, fish species, and arbitrary `.tres` resources, without shipping a full `Database.gd` override or source-rewriting vanilla scripts.

Registry mutations survive across scene loads (state lives on autoloads and preloaded resources) and unwind cleanly: every `register`/`override`/`patch` is reversible via `remove`/`revert`.

## Opting in

The registry is gated behind an opt-in declaration in `mod.txt`. Without it, the loader skips all registry-related rewriting and your `lib.register(...)` calls will fail silently.

```ini
[registry]
```

An empty `[registry]` section is enough, the loader only checks for its presence. Adding the section forces the rewriter to wrap `Database.gd`, `Loader.gd`, `AISpawner.gd`, and `FishPool.gd` with the injected fields the registry API needs. See [hook_pack.gd:20 `REGISTRY_TARGETS`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hook_pack.gd#L20).

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
| `remove(registry, id) -> bool` | Undo a `register`. Fails on override-backed ids (use `revert`) |
| `revert(registry, id, fields=[]) -> bool` | Undo an `override` or `patch`. Per-field revert when `fields` is non-empty |
| `get_entry(registry, id) -> Variant` | Read the current entry (after any registry mutations). Returns `null` if missing |

Every verb returns a bool indicating success; failures log a `push_warning` with the reason.

### Registry constants

Use `lib.Registry.<NAME>` rather than raw strings so typos surface at parse time:

| Constant | String | Underlying store | Verbs supported |
|---|---|---|---|
| `SCENES` | `"scenes"` | `Database.gd` scene consts | register, override, remove, revert |
| `ITEMS` | `"items"` | `ItemData` `.tres` keyed by `file` | register, override, patch, remove, revert |
| `LOOT` | `"loot"` | `LootTable.items` arrays | register, override, remove, revert |
| `SOUNDS` | `"sounds"` | `AudioLibrary.tres` `@export` fields | register, override, patch, remove, revert |
| `RECIPES` | `"recipes"` | `Recipes.tres` category arrays | register, override, patch, remove, revert |
| `EVENTS` | `"events"` | `Events.tres` events array | register, override, patch, remove, revert |
| `TRADER_POOLS` | `"trader_pools"` | Per-item trader boolean flags | register, remove, revert |
| `TRADER_TASKS` | `"trader_tasks"` | `TraderData.tasks` arrays | register, override, patch, remove, revert |
| `INPUTS` | `"inputs"` | `InputMap` actions | register, override, patch, remove, revert |
| `SCENE_PATHS` | `"scene_paths"` | Named scene lookup on `Loader.gd` | register, override, patch, remove, revert |
| `SHELTERS` | `"shelters"` | `Loader.shelters` append-only list | register, remove |
| `RANDOM_SCENES` | `"random_scenes"` | `Loader.randomScenes` append-only list | register, remove |
| `AI_TYPES` | `"ai_types"` | Zone → agent scene overrides on `AISpawner` | register, override, remove, revert |
| `FISH_SPECIES` | `"fish_species"` | `FishPool` extra species | register, remove |
| `RESOURCES` | `"resources"` | Arbitrary `.tres` by absolute path | patch, revert |

Unsupported verbs return `false` with a guidance warning (e.g. "patch on loot rejected, use override for content swaps").

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

### remove

Reverses a prior `register`. Fails on override-backed or vanilla ids, those need `revert`.

### revert

Reverses an `override` or `patch`. Fails if there's nothing to undo (nothing overridden and no field stashes).

- Bare `revert(registry, id)` with no `fields` argument unwinds everything for that id (patches first, then the override).
- `revert(registry, id, ["field1", "field2"])` unwinds only those specific patched fields; other patches and the override stay.

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
