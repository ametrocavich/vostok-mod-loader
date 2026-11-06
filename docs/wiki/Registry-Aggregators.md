# Registry: aggregator helpers

Six helpers register a complete content unit, such as one weapon or one furniture piece, by calling several primitive registries (`items`, `scenes`, `loot`, `trader_pools`, plus tracked patches) in one go. Use them when you ship new content; use the primitives on [Registry](Registry) for finer control or for changing existing content. They are also `setup` verbs ([Setup-Plans](Setup-Plans)).

| Helper | Registers |
|---|---|
| `register_item` | An item with optional scene, icon, loot tables and trader pools |
| `register_weapon` | A weapon, its first-person rig, inline or referenced magazines, attachments, loot tables and an optional AI loadout |
| `register_magazine` | A magazine and scene, added to each weapon in `fits_weapons` |
| `register_attachment` | The same shape as `register_magazine`; vanilla's `compatible` takes both |
| `register_furniture` | A furniture item, its placed scene, trader pools and an optional recipe |
| `register_ai_loadout` | A batch over the `ai_loadouts` registry; the per-id result is `{ok}` |

Every helper takes `{id: data}`, even for one entry: `lib.register_item({"my_id": {...}})`, never `lib.register_item("my_id", {...})`. The result is `{ok, results: {id: per_id}}`; the top-level `ok` is true only when every entry succeeded, and one failure does not stop the others. Each `per_id` dict has its own `ok`, one bool per primitive call (`items`, `scene`, `rig`), `loot_count`, and for cross-references a list of the ids that resolved plus `<field>_failed` with those that did not.

The helpers keep no state of their own. Their pieces get these handles, which you need to `remove` or `get_entry` them one at a time:

- loot entries: `"<id>_in_<table>"`
- trader-pool entries: `"<id>_in_pool_<trader>"`
- a weapon's rig: scene `"<id>_Rig"`
- a furniture recipe: `"<id>_recipe"`

The `WEAPONS`, `MAGAZINES` and `ATTACHMENTS` constants call the same code through `register` and collapse the result to a bool; every other verb on them is refused with a pointer to the primitives.

## register_item

For items that are not a weapon, magazine, attachment or furniture: consumables, keys, tools, ammo.

```gdscript
var result: Dictionary = lib.register_item({
    "MyMedkit": {
        "item_path":    "res://mymod/items/MyMedkit.tres",  # required
        "scene_path":   "res://mymod/items/MyMedkit.tscn",  # optional
        "icon_path":    "res://mymod/icons/MyMedkit.png",   # optional, sets ItemData.icon
        "loot_tables":  ["LT_Master"],                      # optional
        "trader_pools": ["Doctor"],                         # optional
    },
})
```

The per-id result adds `trader_pool_count`, `trader_pools` and `trader_pools_failed`. `scene` is `true` when no `scene_path` was given. `ok` needs `items`, `scene` and no failed trader pool.

## register_weapon

```gdscript
var result: Dictionary = lib.register_weapon({
    "MyRifle": {
        "item_path":  "res://mymod/MyRifle.tres",       # required
        "scene_path": "res://mymod/MyRifle.tscn",       # required, world model
        "rig_path":   "res://mymod/MyRifle_Rig.tscn",   # required, first-person rig
        "icon_path":  "res://mymod/Icon_MyRifle.png",   # optional
        "magazines": [                                   # optional
            {"id": "MyRifle_Mag", "item_path": "res://mymod/MyRifle_Mag.tres",
             "scene_path": "res://mymod/MyRifle_Mag.tscn", "loot_tables": ["LT_Master"]},
            "AK_12_Magazine",                            # an existing magazine id
        ],
        "fits_attachments": ["ACOG", "Kobra"],           # optional
        "loot_tables": ["LT_Master"],                    # optional
        "ai_loadout": {"ai_types": ["Bandit"], "chance": 0.5},  # optional
    },
})
```

An inline magazine dict is registered like `register_magazine` and must carry an `id`; a string refers to an existing magazine. Each magazine and each resolved attachment is added to the weapon's `compatible` array as one tracked patch. The per-id result adds `magazines` (one `{id, ok, item_data}` per entry), `fits_attachments`, `fits_attachments_failed` and `ai_loadout`: `null` when not requested, else whether the loadout registered.

`ok` needs `items`, `scene`, `rig` and no failed attachment. `ai_loadout` creates an [`ai_loadouts`](Registry-World#ai_loadouts) entry with the weapon's own scene and id; you give `ai_types`, `chance` and `replace`. A failed loadout does not affect `ok`: the weapon still drops as loot, AI just never carries it.

## register_magazine and register_attachment

```gdscript
var result: Dictionary = lib.register_magazine({
    "MyExtendedMag": {
        "item_path":    "res://mymod/MyExtendedMag.tres",  # required
        "scene_path":   "res://mymod/MyExtendedMag.tscn",  # required
        "icon_path":    "res://mymod/Icon_MyMag.png",      # optional
        "fits_weapons": ["AK_12", "AKM"],                  # optional
        "loot_tables":  ["LT_Master"],                     # optional
    },
})
```

`fits_weapons` adds the item to each weapon's `compatible` array. The per-id result adds `fits_weapons` and `fits_weapons_failed`; `ok` needs `items`, `scene` and no failed weapon. `register_attachment` takes and returns the same shape.

## register_furniture

Furniture is an ItemData with `type = "Furniture"` plus a placed world scene. It never comes from loot: it is bought from traders or crafted, and a bought piece goes to the catalog grid instead of the inventory.

```gdscript
var result: Dictionary = lib.register_furniture({
    "MyBed": {
        "item_path":    "res://mymod/MyBed_F.tres",    # required, type = "Furniture"
        "scene_path":   "res://mymod/MyBed_F.tscn",    # required, placed world scene
        "icon_path":    "res://mymod/Icon_MyBed.png",  # optional
        "trader_pools": ["Generalist"],                # optional; defaults to Generalist with a warning
        "recipe": {                                    # optional
            "name": "My Bed",                          # default: the id
            "input": [plank_item, nail_item],          # required, non-empty ItemData list
            "time": 10.0,                              # default 1.0; "audio" is optional too
            "workbench": true,                         # optional flags: heat, workbench, testbench, shelter
        },
    },
})
```

`loot_tables` is ignored with a warning. An `ItemData.type` other than `"Furniture"` warns but does not fail; vanilla branches on that string at purchase, so the item would land in the inventory. A `recipe` builds a `RecipeData` with the item as output in the `furniture` category, registered as `"<id>_recipe"`; leave it out for trader-only furniture. The per-id result adds `trader_pool_count`, `trader_pools`, `trader_pools_failed` and `recipe` (`null` when not requested).
