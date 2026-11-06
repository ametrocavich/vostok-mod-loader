# Registry: world

Per-registry details for scenes, places, AI, fish and scene nodes. The verbs, their shared rules, opting in and timing are on [Registry](Registry). `scenes`, `scene_paths`, `shelters`, `maps`, `ai_types`, `ai_loadouts` and `fish_species` need the `[registry]` rewrite ([Opting in](Registry#opting-in)); `random_scenes` and `scene_nodes` do not. Every example assumes `var lib = Engine.get_meta("RTVModLib")`.

## SCENES

The scene constants on `Database.gd` (`Potato`, `Beer`, `Cabin`), keyed by the const name. `register` and `override` take a `PackedScene`; there is no patch.

```gdscript
lib.register(lib.Registry.SCENES, "mymod_biscuit", preload("res://mymod/scenes/Biscuit.tscn"))
lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/scenes/GoldenPotato.tscn"))
lib.revert(lib.Registry.SCENES, "Potato")
```

When two mods override the same scene, the second gets "already overridden (revert first to re-override)" and players see the first mod's scene.

When another mod replaces `Database.gd` with a script that extends it, `keys`, `list` and `has` still report the vanilla scene constants: the listing walks the replacement's base scripts. `scene_paths` reads a replaced `Loader.gd` the same way.

## SCENE_PATHS

Named scene lookups on `Loader.gd`, with the optional `gameData` flags `menu`, `shelter`, `permadeath` and `tutorial`. The payload is `{path: String, menu?, shelter?, permadeath?, tutorial?, transition_text?}`. Entries are open dicts: `patch` accepts any field, on a mod registration or an override.

```gdscript
lib.register(lib.Registry.SCENE_PATHS, "mymod_bunker", {"path": "res://mymod/scenes/bunker.tscn", "shelter": true})
lib.override(lib.Registry.SCENE_PATHS, "Cabin", {"path": "res://mymod/scenes/better_cabin.tscn"})
lib.patch(lib.Registry.SCENE_PATHS, "mymod_bunker", {"permadeath": true})
```

`register`, `override` and a `patch` of `path` refuse a scene that does not exist (`does not exist; did it ship in your mod?`): a missing scene would freeze the loading screen with no way back to the menu, so registration is the last safe place to fail. `register` on a vanilla name is refused; use `override`. Two overrides of the same name both succeed and the last one wins.

An override of a vanilla scene keeps that scene's own flags for any flag the entry leaves out, so overriding `Cabin` with only a `path` still loads it as a shelter (a shelter loaded with `shelter` false resets the character on quit instead of saving). A flag the entry sets replaces the vanilla one. A mod scene gets every flag from its entry, `false` when left out. `transition_text` sets the loading-screen label of a mod scene only; a vanilla scene keeps its own label.

## SHELTERS and MAPS

Named areas on `Loader`. Shelters and maps share one store and one id space; they differ only in the default of the `shelter` flag (true for `shelters`, false for `maps`). A shelter gets vanilla's `LoadShelter`/`SaveShelter` persistence (furniture, stash); a map does not. All fields are optional:

```gdscript
lib.register(lib.Registry.SHELTERS, "mymod_apartment", {
    "path": "res://mymod/scenes/apartment.tscn",  # registers a paired scene_paths entry
    "transition_text": "Apartment",               # loading-screen label; defaults to the id
    "exit_spawn": "Door_Apartment_Exit",          # node to spawn at on arrival
    "entrance_spawn": "Door_Apartment",           # node in connected_to to spawn at when leaving
    "connected_to": "Village",                    # the vanilla map holding the entrance
    "connected_content": [{"path": "res://mymod/props/door_frame.tscn",
        "position": Vector3(10, 0, 4), "rotation": Vector3(0, 90, 0)}],  # degrees
})
lib.register(lib.Registry.MAPS, "mymod_quarry", {"path": "res://mymod/scenes/quarry.tscn", "connected_to": "Village"})
```

The dict mirrors B_Loader's `add_shelter`/`add_map`, so a B_Loader mod migrates by changing the call. With a `path`, the registry also registers a `scene_paths` entry under the id and forwards `menu`, `permadeath`, `tutorial` and `transition_text` to it; `remove` drops that entry too, unless a mod has overridden it. A missing `path` file is refused, and so is a `path` under the name of a vanilla scene (`Village`, `Bridge`), by `register` and by B_Loader's `Loader.add_shelter`/`Loader.add_map` alike, since it would replace that map. Without a `path`, the name must already resolve through `Loader.LoadScene`, usually as a `scene_paths` registration; the loader does not check, and a bad name fails at load time.

A name already registered, or already in the vanilla shelter list, is refused. There is no override or patch: to change a scene, `override` the matching `scene_paths` entry. `remove` on the wrong registry fails with `id was registered as 'shelters', use that registry to remove`.

## RANDOM_SCENES

`res://` paths appended to `Loader.randomScenes`, from which `LoadSceneRandom()` picks.

```gdscript
lib.register(lib.Registry.RANDOM_SCENES, "mymod_wasteland", {"path": "res://mymod/scenes/wasteland.tscn"})
```

A missing file is refused, and so is a handle or a path registered twice.

## AI_TYPES

Replaces the enemy scene of a zone on `AISpawner`. The payload is `{scene: PackedScene, zone: String}` with zone `Area05`, `BorderZone`, `Vostok` or `Debug`. Nomads (spawned from a zone-independent pool) and bosses are not affected. There is no patch.

```gdscript
lib.register(lib.Registry.AI_TYPES, "mymod_zombie_area05", {"scene": zombie_scene, "zone": "Area05"})
lib.override(lib.Registry.AI_TYPES, "mymod_ghoul_forced", {"scene": ghoul_scene, "zone": "Area05"})
lib.revert(lib.Registry.AI_TYPES, "mymod_ghoul_forced")  # the zombie claim comes back
```

One registration per zone: a second one fails with `zone 'Area05' already claimed by 'mymod_zombie_area05'; use override to replace`. `override` displaces whatever claims the zone and keeps it; `revert` restores it.

## AI_LOADOUTS

Adds a mod weapon to AI loadouts. Entries from all mods add up into one list that the rewritten `AI.SelectWeapon` reads when an agent picks its weapon.

```gdscript
lib.register(lib.Registry.AI_LOADOUTS, "mymod_rifle", {
    "weapon_scene": preload("res://mymod/MyRifle.tscn"),  # or a scene name Database resolves
    "ai_types": ["Bandit", "Guard"],
    "chance": 0.5,     # optional, default 1.0, clamped to 0..1 with a warning
    "replace": false,  # optional; true clears the agent's existing options first
})
```

`ai_types` takes `Nomad`, `Bandit`, `Guard`, `Military`, `Boss`, `Punisher` and `Bogeyman`, in any case; an unknown name fails the call at register time instead of when nothing spawns, with `unknown ai_type '<name>'; valid: [...]`. An agent matches when any of its categories is listed: its `AIData` faction (`Nomad`, `Bandit`, `Guard`, `Military`, `Boss`) plus its variant (`Punisher`, `Bogeyman`, or the faction again), so `Boss` covers both bosses and `Punisher` one. `replace: true` also wipes weapons that other mods' entries added earlier. `override` replaces an existing mod entry wholesale (there is no vanilla side); there is no patch. `register_weapon` can create an entry through its `ai_loadout` field ([Registry-Aggregators](Registry-Aggregators#register_weapon)).

## FISH_SPECIES

Extra species for `FishPool`. The payload is `{scene: PackedScene, pool_id? = "all"}`; `"all"` makes the fish eligible in every pool, a pool node name (`"FP_2"`) restricts it.

```gdscript
lib.register(lib.Registry.FISH_SPECIES, "mymod_trout", {"scene": preload("res://mymod/fish/Trout.tscn"), "pool_id": "FP_2"})
```

## SCENE_NODES

Patches property values on one node inside a scene, without shipping a replacement scene. The id is `"<scene_path>#<node_path>"`; `#` or `#.` targets the scene root. Only `patch` and `revert` exist.

```gdscript
lib.patch(lib.Registry.SCENE_NODES, "res://UI/Interface.tscn#Tools/Crafting/Types/Margin/Buttons/Equipment",
    {"disabled": false})
```

The patch is checked against a probe instance of the scene when you call it; a node path or property that is missing rejects the whole patch. The loader applies it through `SceneTree.node_added` to each matching node before that node's `_ready`, and to instances already in the tree. The PackedScene itself is never changed. It sets property values only: it cannot add or remove nodes or patch embedded sub-resources; for that, `override` the scene through `scenes`. Patches from different mods on different properties compose; on the same property the last call wins, and `revert` restores vanilla.
