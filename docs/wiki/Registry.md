# Registry

The registry lets a mod add, replace, patch and remove game data without shipping a rewritten `Database.gd`: items, loot, recipes, sounds, events, trader stock and tasks, input actions, scenes, shelters and maps, AI types and loadouts, fish, any `.tres` field and node properties inside vanilla scenes. Every change is tracked so it can be undone: `register` pairs with `remove`, `override` and `patch` pair with `revert`. To intercept game code instead, use [Hooks](Hooks).

The per-registry details are on three pages: [Registry-Content](Registry-Content) (items, loot, sounds, recipes, events, traders, inputs, resources), [Registry-World](Registry-World) (scenes, scene paths, shelters, maps, AI, fish, scene nodes) and [Registry-Aggregators](Registry-Aggregators) (the `register_weapon` family).

## Quick start

```gdscript
var lib = Engine.get_meta("RTVModLib")

func _ready() -> void:
    var elixir: Resource = load("res://mods/mymod/elixir.tres")  # an ItemData
    lib.register(lib.Registry.ITEMS, "mymod_elixir", elixir)
    lib.register(lib.Registry.LOOT, "mymod_elixir_drop", {"item": elixir, "table": "LT_Master"})
    lib.patch(lib.Registry.ITEMS, "Potato", {"weight": 0.1, "value": 500})

# Undo
lib.revert(lib.Registry.ITEMS, "Potato", ["weight"])  # one field
lib.revert(lib.Registry.ITEMS, "Potato")              # everything on that id
lib.remove(lib.Registry.ITEMS, "mymod_elixir")        # undo a register
```

Use `lib.Registry.<NAME>` rather than the raw string, so a typo fails at the call. Put `[registry]` in `mod.txt` ([Opting in](#opting-in)) and register from `_ready()` ([Timing](#timing)).

## Opting in

```ini
[registry]
```

An empty section is enough. When any mod declares it, the rewriter wraps `Database.gd`, `Loader.gd`, `AISpawner.gd`, `AI.gd`, `FishPool.gd` and `Compiler.gd` (`REGISTRY_TARGETS` in `src/hook_pack.gd`) and injects the fields the registry needs. A script that calls B_Loader's `Loader.add_shelter` or `Loader.add_map` counts as declaring it. A registry target that is rewritten only because some mod hooks one of its methods carries the registry code too. A target that nothing declares or hooks stays vanilla, and then:

- `scenes` and `scene_paths` warn that the injected fields are missing (the `scenes` warning asks "Does your mod.txt include a [registry] section?") and return `false`; `shelters` and `maps` warn `Loader is missing _rtv_mod_shelters`.
- `ai_types`, `ai_loadouts` and `fish_species` return `true` with no warning, and the game never reads the entry.
- `items`, `loot`, `recipes`, `events`, `sounds`, `inputs`, `trader_pools`, `trader_tasks`, `random_scenes`, `resources` and `scene_nodes` work regardless; they change loaded Resources, `InputMap` or plain vars.

With the declaration, a game update can still break the injected code. The compile probe then ships that script with hooks only, or vanilla ([Hooks](Hooks#compile-probe-before-packing)), and `register` and `override` on `ai_types` and `ai_loadouts`, and `register` on `fish_species`, `shelters` and `maps`, return `false` with a warning that the script `lacks registry code on this game build`. Nothing is stored, the paired `scene_paths` entry of a shelter included. If an anchor moved but the code still compiles, the reconciliation report lists the script as `PARTIAL`, missing `registry transform`.

## Timing

Register from your mod's `_ready()`. Mod autoloads run after the vanilla autoloads and before the first scene, which is early enough; `await lib.frameworks_ready` first if you also need hooks. Several consumers copy a store once in their own `_ready()` and never re-read it: trader stock, `LootContainer` and `LootSimulation` (loot tables), the crafting `Interface` (recipes), `EventSystem` (events) and traders (tasks). A later registration changes the store but not those copies, which is the usual cause of "register returned true but nothing changed". A trader that already filled today's stock shows new loot at the next refresh. `FishPool` reads its species on map load.

## Verbs

| Call | Does |
|---|---|
| `register(reg, id, data)` | Add a new entry |
| `override(reg, id, data)` | Replace an existing entry wholesale |
| `patch(reg, id, fields)` | Set fields on the current entry |
| `append(reg, id, field, values, allow_duplicates=false)` | Add to the end of an Array field |
| `prepend(reg, id, field, values, allow_duplicates=false)` | Add to the front of an Array field |
| `remove_from(reg, id, field, values)` | Drop values from an Array field |
| `remove(reg, id)` | Undo a `register` |
| `revert(reg, id, fields=[])` | Undo an `override` or `patch`; only the named fields when given |
| `register_many`, `override_many`, `patch_many`, `append_many`, `prepend_many`, `remove_from_many`, `revert_many`, `remove_many` | [Batched forms](#batched-forms) |
| `setup(plan)` | A list of verb entries run in order; see [Setup-Plans](Setup-Plans) |
| `get_entry`, `has`, `keys`, `list`, `find` | [Reading](#reading-the-registry) |

Every mutating verb returns a bool; a failure logs a `push_warning` starting `[Registry]` with the reason. `register`, `override`, `patch` and the array verbs reject an empty id up front.

## Registries

"Array verbs" are `append`, `prepend` and `remove_from`. A verb not listed for a registry returns `false` with a warning that names the right tool (for example `patch` on `loot` points at `items`).

| Constant | Verbs | Details |
|---|---|---|
| `SCENES` | register, override, remove, revert | [Registry-World](Registry-World#scenes) |
| `ITEMS` | register, override, patch, array verbs, remove, revert | [Registry-Content](Registry-Content#items) |
| `LOOT` | register, override, remove, revert | [Registry-Content](Registry-Content#loot) |
| `SOUNDS` | register, override, patch, array verbs, remove, revert | [Registry-Content](Registry-Content#sounds) |
| `RECIPES` | register, override, patch, array verbs, remove, revert | [Registry-Content](Registry-Content#recipes) |
| `EVENTS` | register, override, patch, array verbs, remove, revert | [Registry-Content](Registry-Content#events) |
| `TRADER_POOLS` | register, remove, revert (= remove) | [Registry-Content](Registry-Content#trader_pools) |
| `TRADER_TASKS` | register, override, patch, array verbs, remove, revert | [Registry-Content](Registry-Content#trader_tasks) |
| `INPUTS` | register, override, patch, remove, revert | [Registry-Content](Registry-Content#inputs) |
| `RESOURCES` | patch, array verbs, revert | [Registry-Content](Registry-Content#resources) |
| `SCENE_PATHS` | register, override, patch, remove, revert | [Registry-World](Registry-World#scene_paths) |
| `SHELTERS`, `MAPS` | register, remove, revert (= remove) | [Registry-World](Registry-World#shelters-and-maps) |
| `RANDOM_SCENES` | register, remove, revert (= remove) | [Registry-World](Registry-World#random_scenes) |
| `AI_TYPES` | register, override, remove, revert | [Registry-World](Registry-World#ai_types) |
| `AI_LOADOUTS` | register, override, remove, revert | [Registry-World](Registry-World#ai_loadouts) |
| `FISH_SPECIES` | register, remove, revert (= remove) | [Registry-World](Registry-World#fish_species) |
| `SCENE_NODES` | patch, revert | [Registry-World](Registry-World#scene_nodes) |
| `WEAPONS`, `MAGAZINES`, `ATTACHMENTS` | register only, result collapsed to a bool | [Registry-Aggregators](Registry-Aggregators) |

## Verb rules

- `register` fails when the id names a vanilla entry (use `override`), was already registered by a mod, or the payload fails the registry's shape check. Nothing is silently overwritten. Two mods registering different ids into the same array (`loot`, `recipes`, `events`, `trader_tasks`) both land.
- `override` stashes the original. On `scenes`, `loot`, `recipes`, `events`, `trader_tasks`, `ai_types` and `ai_loadouts` a second override of the same id fails with "already overridden (revert first"; on `items`, `sounds`, `inputs` and `scene_paths` it wins, and the stash still holds the original. Overriding a mod's registration resolves a same-id conflict without touching the other mod, except on `sounds`, which overrides vanilla fields only.
- `patch` works on whatever the id resolves to: vanilla, override or registration. The first patch of a field stashes its value, and later patches of that field stack in call order, so `revert` returns to vanilla, not to an earlier mod's value. Patches on different fields coexist. A patch changes the shared Resource, so every holder sees it, saves included; `revert` is the only undo.
- `patch` returns `true` on `items`, `sounds`, `recipes`, `events` and `trader_tasks` whenever the id resolves, even if every field was unknown (each unknown field warns and is skipped). `resources` and `inputs` return `false` unless a field applied; `scene_nodes` and `scene_paths` reject the whole patch on one bad field or path.
- `recipes`, `events` and `trader_tasks` also take the entry Resource itself as the id of `patch`, `revert` and the array verbs, which reaches vanilla entries without a handle. Every other registry takes String ids.
- The array verbs change one Array field without overwriting what other mods added; a single value need not be wrapped. `append` and `prepend` skip values already present unless `allow_duplicates` is true, and type-check every value first: one bad value rejects the call. `prepend([a, b])` on `[c]` gives `[a, b, c]`; `remove_from` drops every occurrence. `null` or an empty Array warns and returns `false`, as does a field that is not an Array. They share the `patch` stash, so `revert(reg, id, ["compatible"])` restores the array from before both.
- `remove` undoes a mod's `register` only. It refuses vanilla entries and override-backed ids (`use revert instead`).
- A full `revert` restores the patches first, then drops the override. Each stashed value goes back onto the object it was read from, so a patch made before an override is undone on the entry under the override.

### Batched forms

Each mutating verb has a `_many` form that takes `{id: data}`; `remove_many` takes an Array of ids, and `append_many`, `prepend_many` and `remove_from_many` take the field before the dict. The result is `{ok, results: {id: bool}}`; `ok` is true only when every id succeeded, and one bad id does not stop the rest.

```gdscript
lib.append_many(lib.Registry.ITEMS, "compatible", {"AKM": [magA, magB], "AK_12": [magC]})
lib.revert_many(lib.Registry.ITEMS, {"AKM": ["weight"], "AK_12": []})  # [] = full revert
```

`patch_many` values must be Dictionaries and `revert_many` values Arrays. A bare string such as `{id: "field"}` is rejected with a warning, not coerced, because it would otherwise full-revert the id.

## Reading the registry

`get_entry(reg, id)` returns the current entry (override, then registration, then vanilla) or `null`. `has`, `keys`, `list` and `find(reg, predicate)` take an optional `include_vanilla = true`; `find` returns `[{id, entry}, ...]` for entries where the predicate returns a true bool or a non-zero number. A mod entry beats a vanilla one with the same id. A missing id never warns; `get_entry` on `scene_nodes`, an aggregator constant or an unknown name does.

```gdscript
var weapons: Array = lib.find(lib.Registry.ITEMS, func(it): return it.get("type") == "Weapon")
var only_mod_items: Array[String] = lib.keys(lib.Registry.ITEMS, false)
```

On the handle-based registries `get_entry` returns the record stored for the handle, which is not always the payload: `loot` adds `table_res`, `trader_pools` stores `{item, trader, flag, original}`, `shelters` and `maps` store `{auto_scene_path, entry, kind}`, and `ai_loadouts` stores the canonical entry. `inputs` also has a record for a vanilla action a mod patched (marked `vanilla_stub`). `scene_paths` returns the override dict when there is one, and `resources` returns `load(id)`.

Vanilla enumeration: `ITEMS` walks `LT_Master.items` by `file`; `SCENES` reads Database's scene consts; `SCENE_PATHS` reads the Loader consts that hold `res://` strings; `SHELTERS` reads the vanilla shelter list; `RECIPES` walks the seven category arrays with ids `"<category>:<recipe name>"`, the one registry whose vanilla ids differ from its register handles. Every other registry has no vanilla side.

## See also

- [Setup-Plans](Setup-Plans): the declarative `setup(plan)` entry point
- [Mod-Format](Mod-Format): the `mod.txt` reference
- [Dependencies](Dependencies): load order between mods
