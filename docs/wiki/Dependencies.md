# Dependencies

Declare in `mod.txt` which other mods yours needs (`required=`) or integrates with (`optional=`), and which old ids your mod still answers to after a rename (`provides=`). The loader uses these declarations to load dependencies before dependents, to skip mods whose requirements are unmet (with an explanation and fix-it buttons in the Mods tab), and to keep renamed mods satisfying their old dependents. You need this page if your mod builds on another mod, if another mod builds on yours, or if you are about to change your mod's `id`.

The `mod.txt` keys themselves are part of the [mod format](Mod-Format); this page owns the behavior.

## Declare a required dependency

```ini
[dependencies]
required=["mod_configuration_menu"]
```

Values are the other mod's `[mod] id`, not its display name and not its filename. A mod that never declared an `id` gets its archive filename as its id, extension included (`CoolMod.zip`), with two wrinkles: a folder mod defaults to its folder name, and a `100-CoolMod.vmz` filename (the old VostokMods injector's priority-prefix convention, unrelated to the vostokmods.net site) defaults to the stripped stem `CoolMod`. Always declare an id, and prefer depending on mods that declare one. Matching is case-insensitive and whitespace-trimmed; duplicates are dropped.

When the dependency is installed and enabled, the loader loads it before your mod, even if priorities say otherwise. The one exception is a [dependency cycle](#automatic-ordering-and-cycles), where ordering falls back to priorities. The reorder is minimal and stable: every mod keeps its exact priority position unless a dependency edge forces a hoist. No author or user action is needed. The boot log says `Load order adjusted: required dependencies load before their dependents.` and the launcher's order panel adds a `reordered for dependencies` line.

When the dependency is not met (missing, disabled, or itself blocked), your mod is skipped. It is not loaded at all. The boot log says:

```
Skipping My Mod (my_mod) -- required dependency mod_configuration_menu is not installed
```

and the Mods tab shows an orange explanation with fix-it buttons (see [The blocked row](#the-blocked-row-mods-tab-ui)).

## Declare an optional dependency

```ini
[dependencies]
optional=["happy_fireplace"]
```

`optional=` affects ordering only, never loading. If the optional mod is in the enabled set, it is ordered before yours (same hoisting and cycle detection as required deps). If it is absent there is no edge, no block, and your mod loads normally. It also appears in your mod's dependency sub-line tooltip (as `optional: Name (id)`) so users can see the integration exists.

To react to the optional mod's presence, check at runtime:

```gdscript
var lib = Engine.get_meta("RTVModLib")
if lib.has_mod("happy_fireplace"):
    # integrate. The mod is loaded, and (because of optional=)
    # it loaded before you
```

## Runtime API: has_mod / mod_info / loaded_mods

All three live on the `RTVModLib` object (`Engine.get_meta("RTVModLib")`, see [Hooks](Hooks) for the ready-signal pattern) and take declared mod ids:

| Call | Returns | Notes |
|---|---|---|
| `has_mod(mod_id: String, min_version: String = "") -> bool` | true if a mod with that id is loaded | Optional `min_version` does a component-wise numeric compare (`"1.2.3"` split on `.`); a leading `v` is ignored on both sides; other non-numeric components compare as 0, so no semver prerelease. A mod that declares no `version` compares as `0.0.0`. |
| `mod_info(mod_id: String) -> Dictionary` | `{mod_id, mod_name, version, file_name, priority, required_dependencies, optional_dependencies}`, or `{}` if not loaded | Returns a deep copy; safe to mutate. |
| `loaded_mods() -> Array[String]` | all loaded mod ids | Order not guaranteed; sort it if you display it. |

Unlike `[dependencies]` resolution, these lookups are exact dictionary hits on the declared `mod_id`: case-sensitive, and `provides=` aliases do not resolve. If a dependency renamed itself and you check `has_mod("old_id")`, you get `false` even though `required=["old_id"]` is satisfied through the alias. Check the current id (or both ids).

## Renaming your mod: provides=

If you change your mod's `id`, every mod that lists the old id in `[dependencies]` breaks. Declare the old id (or ids) as aliases:

```ini
[mod]
name="Better AI"
id="better_ai"
provides=["betterai_legacy", "old_better_ai"]
```

Any `required=` or `optional=` entry naming a provided alias resolves to your mod: it satisfies the requirement, gets hoisted by the automatic ordering, and takes part in cycle detection exactly as if your mod still had the old id.

Ship the alias in the same release that renames the id, and keep it; dependents update on their own schedule.

Alias resolution rules:

- Alias matching is case-insensitive and trimmed, like all id handling.
- An alias never shadows a real installed mod's id. If a mod whose actual `id` matches your alias is installed and enabled, that real mod wins for dependency resolution, and the loader logs once per scan that your alias is shadowed while that mod is enabled. If that real mod is installed but disabled, your alias satisfies dependents in its place.
- If two installed mods claim the same alias, only one resolves it (which one depends on load order); a warning names both. Do not rely on the outcome.
- Listing your own id as an alias is silently dropped. Non-string entries in the array are logged and ignored. A wrong value type logs `ignoring provides= -- expected a string array, got <type>` and degrades to no aliases. A bad `provides=` never blocks your mod.

## Value syntax (required, optional, provides)

All three keys accept the same shapes:

| Syntax | Example | Status |
|---|---|---|
| `ConfigFile` string array | `required=["a", "b"]` | Recommended |
| Quoted whole-value string, split on commas | `required="a, b"` | Fallback for older author tools; optional surrounding `[...]` inside the string is stripped |
| Bare CSV | `required=a, b` | Invalid. Not `ConfigFile` syntax; fails the entire `mod.txt` parse. The archive then mounts as a plain resource pack (no autoloads, no id, no dependencies) and the row shows `mod.txt parse error at ...` |

Per-entry cleanup: trim whitespace, strip one layer of matching surrounding quotes, drop empties, dedupe case-insensitively.

## Reference: what the loader does

The pipeline is: enabled mods, sorted by priority/name/filename, then dependency ordering (hoist plus cycle detection), then the skip-when-unmet filter. The launch button, the order panel and the actual load all read the same function, so the UI and reality cannot disagree.

### Skip-when-unmet (required only)

A mod is blocked if any `required=` entry is missing, disabled, or itself blocked. Blocking is transitive, so a failure three deps down the chain propagates up. Aliases are canonicalized to the providing mod's real id before the blocked check, so a blocked provider cannot look satisfied through its alias.

Each blocker gets a status, shown in the log line and the UI row:

| Status | Label shown | Meaning |
|---|---|---|
| `not_installed` | "not installed" | No installed mod (or alias) matches the id |
| `disabled` | "installed but disabled" | Installed, but off in this profile. The Enable dependency button fixes this |
| `not_loaded` | "blocked by its own missing dependency" | The dep exists and is enabled but is itself blocked (transitive) |
| `hidden_folder` | "a dev folder hidden while Developer Mode is off" | The dep is a folder mod; folder mods only exist in the set when [Developer Mode](Developer-Mode) is on. The row tooltip adds `(turn on Developer mode to load folder mods)` |

Things that never block:

- `optional=` entries.
- Self-dependency. Ignored, with the row warning `lists itself as a dependency (ignored)`.
- Loader ids: `metro_mod_loader`, `metromodloader`, `vostok_mod_loader`, `mod_loader`, `modloader`, `mml`, `rtvmodlib` always count as present. Authors copy "requires Metro Mod Loader" off mod pages, and the loader is installed by definition. Listing one is a harmless no-op.
- Any dependency of a mod whose Load anyway override is on (below).

If every enabled mod is blocked, the log says `All N enabled mod(s) are blocked by missing dependencies -- nothing will load. Fix or override from the Mods tab.`, the launch button reads `Launch unmodded (N blocked)`, and the order panel shows `N enabled, none will load (missing dependencies)` with the hint `Every enabled mod is missing a required dependency. Fix it from the orange row warnings, or use Load anyway.`

### Automatic ordering and cycles

`required=` entries are hard ordering edges. `optional=` entries are soft edges that only exist when the optional mod is in the enabled set. An id named in both lists produces one edge.

The reorder is a stable topological pass (lowest original index first): mods keep their exact priority position unless an edge forces a dependency to hoist above its dependent. Explicit priorities still work; the adjustment only kicks in when priority order would load a required dep too late.

Dependency cycles do not block loading. Any forced order would be wrong for someone, so cycle members keep their relative priority order, are emitted after all resolvable mods, and still load. Each gets a boot log line, `Dependency cycle involving '<id>' -- load order left as priorities.`, and the row warning `load order could not be fully resolved (dependency cycle in chain)`. Mods merely downstream of a cycle are not labeled as cycling; their real problem (a blocked dep) shows as a normal blocker row.

Ordering and cycle detection see through `provides=` aliases.

### The blocked row (Mods tab UI)

What your users see, so you can write install instructions that match:

- Every mod with required dependencies gets a dim sub-line `needs: <names>`, plus `(+N optional)` when it also has optional ones. A mod with only optional dependencies gets `N optional integration(s)` instead. Either way the tooltip lists `requires Name (id)` and `optional: Name (id)` entries.
- A blocked mod's name turns orange, with an orange line `won't load -- needs <Name (id)> -- <status label>` (`+N more` when several; the tooltip lists all).
- `Enable dependency` (or `Enable N dependencies`) appears when at least one blocker is installed but disabled. One click transitively enables every installed-but-disabled required dep down the chain.
- `Load anyway` turns the dependency check off for that mod: it loads regardless of dependency state, and counts as active for mods that depend on it. The override is per profile (persisted in `user://mod_config.cfg`, see [Config-Files](Config-Files)). Its hint reads "For when a requirement is declared wrong or you know better."
- While that override is on with requirements still unmet, the row shows `dependency check off -- missing: <names>` with a `Re-check` button that restores the normal rule.

## Gotchas

- No version constraints in `[dependencies]`. Required entries are bare ids; presence and enabled state are all that is checked. The only version gate is runtime `has_mod(id, min_version)`.
- Bare CSV kills the whole `mod.txt`. `required=a, b` makes the entire file fail to parse, so your mod mounts with no metadata at all. Use `required=["a", "b"]`.
- Depend on ids, and declare your own. A mod without a declared `id` is addressable only by its archive filename (extension included), which changes whenever the user renames the file.
- `has_mod()` does not resolve aliases and is case-sensitive, unlike `[dependencies]` matching. Check the dependency's current declared id.
- Cycles warn, they do not block. If your mod is in a cycle it still loads, but ordering falls back to priorities, so do not rely on load order inside a cycle.
- Test-as-folder trap: if a dep you keep as a dev folder suddenly blocks its dependents, look for the `hidden_folder` status (`a dev folder hidden while Developer Mode is off`). Folder mods disappear from the load set when Developer Mode is off.
- Load anyway is a user override you cannot prevent. Write your mod to fail gracefully (a `has_mod()` check before touching the dep's API) instead of assuming a declared requirement is always present at runtime.

## See also

- [Mod-Format](Mod-Format), the full `mod.txt` key reference, including `[mod] id` and `priority`
- [Hooks](Hooks), getting the `RTVModLib` object and the frameworks-ready pattern
- [Registry](Registry), content registration, which also respects load order
- [Developer-Mode](Developer-Mode), folder mods and the `hidden_folder` status
- [Setup-Plans](Setup-Plans), batching registry and hook calls as one declarative `lib.setup(plan)` literal
