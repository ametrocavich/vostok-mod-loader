# Registry: content

Per-registry details for the data the player carries, buys, crafts and presses. The verbs, their shared rules, opting in and timing are on [Registry](Registry). Every example assumes `var lib = Engine.get_meta("RTVModLib")`.

## ITEMS

`ItemData` Resources (and subclasses such as `WeaponData`) keyed by their `file` property, so ids are `file` strings (`"Potato"`, `"AKM"`), not paths; vanilla ids come from `LT_Master`. `register` and `override` take an `ItemData` and set its `file` to the id. `patch` takes any declared property; an unknown one warns and is skipped.

```gdscript
lib.register(lib.Registry.ITEMS, "mymod_elixir", load("res://mymod/items/Elixir.tres"))
lib.override(lib.Registry.ITEMS, "Potato", load("res://mymod/items/GoldenPotato.tres"))
lib.append(lib.Registry.ITEMS, "AKM", "compatible", [magA, magB])
```

`override` changes what the registry resolves for the id: `get_entry`, later patches and the [aggregator helpers](Registry-Aggregators) see the new ItemData. Vanilla has no lookup by `file`, so code that already holds the original (a loot table, a trader pool, a save) keeps it. To change an item everywhere, `patch` it.

## LOOT

Adds or swaps `ItemData` entries in a `LootTable.items` array. The id is a handle you pick. The payload is `{item: ItemData, table: String}`; `override` adds `replaces:`, an ItemData already in the table. `table` is an absolute `res://` path or a vanilla name: `LT_Master`, the airdrop, boss and tutorial `LT_*` tables, or a `Kit_*` table (the full list is `_LOOT_TABLE_PATHS` in `src/registry/loot.gd`).

```gdscript
lib.register(lib.Registry.LOOT, "mymod_fancy_in_master", {"item": fancy, "table": "LT_Master"})
lib.override(lib.Registry.LOOT, "mymod_swap_bandage", {"item": better, "table": "LT_Master", "replaces": bandage})
lib.revert(lib.Registry.LOOT, "mymod_swap_bandage")  # the bandage goes back
```

An item already in the table is refused, not added twice. Once an override has swapped an entry out, a second override that names it in `replaces` fails, since it is no longer in the table. To change a loot item's fields, patch the ItemData through `items`.

## SOUNDS

`AudioEvent` fields on `AudioLibrary.tres`, plus ids that mods register. `register` and `override` take an `AudioEvent`, a bare `AudioStream` (wrapped with volume 0 and no random pitch) or `{audioClips, volume, randomPitch}`; `patch` takes those three fields.

```gdscript
lib.register(lib.Registry.SOUNDS, "mymod_footstep", preload("res://mymod/audio/Footstep.tres"))
lib.override(lib.Registry.SOUNDS, "knifeHitFleshSlash", preload("res://mymod/audio/Slash.tres"))
lib.patch(lib.Registry.SOUNDS, "knifeHitFleshSlash", {"volume": -10.0, "randomPitch": true})
```

Only `override` and `patch` change what the game plays. Vanilla reads `audioLibrary.<field>` by name, so a registered id is reachable only through `get_entry`, from your own code or a hook. The field names are whatever the running build's `AudioLibrary` exports. `override` on a name it lacks is refused with `no vanilla AudioLibrary field with that name`, and `patch` and the array verbs with `no sound with that id`; both warnings end with `Current names:` and the full list, which is the quickest way to read it. `register` on a vanilla field name is refused (use `override`), and `override` never takes a mod-registered id.

`audioClips` holds WAV clips only. Another stream type (OGG, MP3) makes `register` and `override` return `false`, and a `patch` skip that field, each with a warning naming the type. Some sounds are `const` preloads inside the script that plays them (the airdrop sounds in `CASA.gd`, grenade bounces in `Grenade.gd`, lure impacts in `Lure.gd`); they have no library field, so hook the script instead.

## RECIPES

`RecipeData` in the seven category arrays of `Recipes.tres`: `consumables`, `medical`, `equipment`, `weapons`, `electronics`, `misc` and `furniture`. The payload is `{recipe: RecipeData, category: String}`; `override` adds `replaces: RecipeData`. `patch`, `revert` and the array verbs also take a `RecipeData` ref, which reaches vanilla recipes without a handle.

```gdscript
lib.register(lib.Registry.RECIPES, "mymod_craft_elixir", {"recipe": my_recipe, "category": "consumables"})
lib.patch(lib.Registry.RECIPES, "mymod_craft_elixir", {"time": 30.0})
lib.patch(lib.Registry.RECIPES, vanilla_recipe, {"time": 60.0})
```

Vanilla ships the Equipment and Misc crafting tabs disabled because they are empty. A recipe registered into `equipment` or `misc` enables that tab's button through `scene_nodes`.

## EVENTS

`EventData` in `Events.tres`. The payload is `{event: EventData}`; `override` adds `replaces: EventData`. Patch by handle or by `EventData` ref.

```gdscript
lib.register(lib.Registry.EVENTS, "mymod_meteor", {"event": my_event})
lib.patch(lib.Registry.EVENTS, "mymod_meteor", {"possibility": 75, "day": 5})
```

`EventData.function` must name a method on `EventSystem`. It is resolved when the event fires, and a name that does not exist there makes the event do nothing. To run mod code from an event, point `function` at a vanilla method you hook.

## TRADER_POOLS

Sets a trader's boolean flag on an `ItemData` (`item.doctor = true` puts it in the Doctor's pool). The payload is `{item: ItemData, trader: String}`, where `trader` is `Generalist`, `Doctor`, `Gunsmith`, `Driver`, `Hunter` or `Grandma`, in any case. `Grandma` is accepted because `ItemData.grandma` exists, but no trader reads that flag.

```gdscript
lib.register(lib.Registry.TRADER_POOLS, "mymod_potato_doctor", {"item": potato, "trader": "Doctor"})
```

Entries are keyed by handle, so two mods can enable the same item for the same trader. The flag stays set while any handle on that pair is registered; removing the last one, in any order, restores the value from before the first. An ItemData without the flag fails with `item has no '<flag>' flag field`.

## TRADER_TASKS

`TaskData` in a trader's `tasks` array. The payload is `{task: TaskData, trader: String}`; `override` adds `replaces: TaskData`. `trader` is `Generalist`, `Doctor`, `Gunsmith`, `Driver`, `Hunter` or an absolute `res://` path to a `TraderData`. Patch by handle or by `TaskData` ref.

```gdscript
lib.register(lib.Registry.TRADER_TASKS, "mymod_potato_quest", {"task": my_task, "trader": "Generalist"})
```

As with loot, a second override of the same task fails once `replaces` has left the array.

## INPUTS

`InputMap` actions. The id is the action name, so namespace it (`mymod_heal`, not `heal`). The payload is `{default_event: InputEvent, display_label?, deadzone? = 0.5}`, and `patch` takes only those three fields.

```gdscript
var key_h := InputEventKey.new()
key_h.keycode = KEY_H
lib.register(lib.Registry.INPUTS, "mymod_quick_heal", {"display_label": "Quick Heal", "default_event": key_h})
```

A registered action works at once through `Input.is_action_pressed`. `register` fails if the action already exists, vanilla or not; `override` replaces the events of any action. A second override wins, and the stash keeps every original event and the deadzone; a `default_event` patch stashes all events too. `remove` takes away only an action a mod registered; a patched or overridden vanilla action is undone with `revert`.

Vanilla's Keybinds panel reads a hardcoded dict in `Inputs.gd`, so a registered action is not listed there unless you hook `inputs-createactions-pre` and merge it into that dict. The registry does not install that hook.

## RESOURCES

Patches any field of any `.tres` by its absolute `res://` path. There is no register, override or remove: the Resource already exists in vanilla.

```gdscript
lib.patch(lib.Registry.RESOURCES, "res://Resources/GameData.tres", {"difficulty": 2})
lib.revert(lib.Registry.RESOURCES, "res://Resources/GameData.tres", ["difficulty"])
```

For items, prefer `items`, which checks the ItemData shape; `resources` does not.
