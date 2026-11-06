# Dependencies

Declare in `mod.txt` which other mods yours needs (`required=`), which it integrates with (`optional=`), and which old ids it still answers to after a rename (`provides=`). The loader loads dependencies before their dependents, skips a mod whose requirements are unmet (with an explanation and fix-it buttons in the Mods tab), and keeps a renamed mod satisfying its old dependents. The keys belong to the [mod format](Mod-Format); this page owns the behavior.

## Declare a required dependency

```ini
[dependencies]
required=["mod_configuration_menu"]
```

Values are the other mod's `[mod] id`, not its display name. A mod without an id answers to its filename stem (see [Mod-Format](Mod-Format#mod-section)), which changes whenever the file is renamed: declare your own id, and prefer depending on mods that declare one. Matching is case-insensitive and trimmed; duplicates are dropped. There are no version constraints here; the only version gate is `has_mod(id, min_version)` at runtime.

When the dependency is installed and enabled, it loads before your mod even if priorities say otherwise, except inside a [cycle](#automatic-ordering-and-cycles). The boot log then says `Load order adjusted: required dependencies load before their dependents.` and the launcher's order panel adds `reordered for dependencies`.

When the dependency is missing, disabled or itself blocked, your mod is not loaded. The boot log says `Skipping My Mod (my_mod) -- required dependency mod_configuration_menu is not installed` and the Mods tab shows the [blocked row](#the-blocked-row-mods-tab-ui).

## Declare an optional dependency

```ini
[dependencies]
optional=["happy_fireplace"]
```

`optional=` affects ordering only. When the optional mod is enabled it is ordered before yours; when it is absent nothing happens. The row's dependency tooltip lists it as `optional: Name (id)`. To act on its presence, check at runtime:

```gdscript
var lib = Engine.get_meta("RTVModLib")
if lib.has_mod("happy_fireplace"):
    pass # loaded, and before you
```

`has_mod`, `mod_info` and `loaded_mods` are in the [Hooks API reference](Hooks#api-reference). Unlike `[dependencies]`, they match the declared id exactly: case-sensitive, and `provides=` aliases do not resolve. Check a renamed dependency's current id. A user can also force your mod to load with **Load anyway**, so check before touching another mod's API.

## Renaming your mod: provides=

If you change your mod's `id`, every mod that lists the old id breaks. Declare the old ids as aliases, in the same release as the rename, and keep them:

```ini
[mod]
name="Better AI"
id="better_ai"
provides=["betterai_legacy", "old_better_ai"]
```

A `required=` or `optional=` entry naming an alias resolves to your mod for blocking, ordering and cycle detection.

- An alias never shadows a real id. While a mod whose own `id` is the alias is enabled, that mod wins and the log notes once that your alias is shadowed; while it is disabled, your alias stands in.
- When two installed mods claim one alias, load order picks one and a warning names both.
- Your own id as an alias is dropped. A non-string entry is logged and ignored; a value that is not an array logs `ignoring provides= -- expected a string array` and gives no aliases. A bad `provides=` never blocks the mod.

## Value syntax (required, optional, provides)

| Syntax | Example | Status |
|---|---|---|
| `ConfigFile` string array | `required=["a", "b"]` | Recommended |
| Quoted string, split on commas | `required="a, b"` | Accepted; surrounding `[...]` inside the string is stripped |
| Bare CSV | `required=a, b` | Invalid: the whole `mod.txt` fails to parse, so the archive mounts with no autoloads, id or dependencies and the row shows `mod.txt parse error at ...` |

Each entry is trimmed, stripped of one layer of matching quotes, dropped when empty and deduplicated case-insensitively.

## Reference: what the loader does

Enabled mods are sorted by priority, name and filename, then reordered for dependencies, then filtered by the skip rule. The launch button, the order panel and the actual load all read the same result, so the launcher and the game cannot disagree.

### Skip-when-unmet (required only)

A mod is blocked when any `required=` entry is missing, disabled or itself blocked; blocking is transitive. An alias resolves to its provider's real id first, so a blocked provider cannot look satisfied through its alias.

| Status | Label shown | Meaning |
|---|---|---|
| `not_installed` | "not installed" | no installed mod or alias has the id |
| `disabled` | "installed but disabled" | installed, off in this profile; **Enable dependency** fixes it |
| `not_loaded` | "blocked by its own missing dependency" | enabled but blocked itself |
| `hidden_folder` | "a dev folder hidden while Developer Mode is off" | a folder mod, which loads only with [Developer-Mode](Developer-Mode) on |

Never blocking: `optional=` entries; a mod listing itself (the row warns `lists itself as a dependency (ignored)`); the loader's own ids (`metro_mod_loader`, `metromodloader`, `vostok_mod_loader`, `mod_loader`, `modloader`, `mml`, `rtvmodlib`), which always count as present; and any dependency of a mod set to **Load anyway**.

When every enabled mod is blocked, nothing loads, the launch button reads `Launch unmodded (N blocked)` and the order panel says why.

### Automatic ordering and cycles

`required=` entries are hard edges; `optional=` entries are edges only while the optional mod is enabled. An id in both lists is one hard edge. The reorder is a stable topological pass: each mod keeps its priority position unless an edge forces a dependency above its dependent. Aliases take part like real ids.

A cycle does not block. Its members keep their relative priority order, load after every resolvable mod, log `Dependency cycle involving '<id>' -- load order left as priorities.`, and their rows warn `load order could not be fully resolved (dependency cycle in chain)`. Do not rely on load order inside a cycle.

### The blocked row (Mods tab UI)

What your users see, so your install instructions can match:

- A mod with required dependencies has a dim `needs: <names>` line (`(+N optional)` when it has optional ones too); a mod with only optional ones shows `N optional integration(s)`. The tooltip lists each.
- A blocked mod's name turns orange, with `won't load -- needs <Name (id)> -- <status label>`.
- **Enable dependency** (or **Enable N dependencies**) appears when a blocker is installed but disabled and no modpack is active; it enables every disabled required dependency down the chain.
- **Load anyway** turns the check off for that mod in this profile (stored in `mod_config.cfg`, see [Config-Files](Config-Files)): it loads and counts as active for its dependents. The row then shows `dependency check off -- missing: <names>` and a **Re-check** button that restores the rule.

## See also

- [Mod-Format](Mod-Format): the `mod.txt` keys, including `[mod] id` and `priority`
- [Hooks](Hooks): getting the `RTVModLib` object and the frameworks-ready pattern
- [Setup-Plans](Setup-Plans): batching registry and hook calls in one `lib.setup(plan)`
