# Setup plans

`lib.setup(plan)` runs an ordered list of `[verb, ...args]` entries, each passed to an existing [Registry](Registry) or [Hooks](Hooks) call. It suits a mod whose `_ready()` is all registrations and hooks: the whole installation becomes one literal.

```gdscript
func _ready() -> void:
    var lib = Engine.get_meta("RTVModLib")
    await lib.frameworks_ready
    lib.setup([
        ["register", lib.Registry.ITEMS, {"mymod_potion": potion}],
        ["patch",    lib.Registry.ITEMS, {"AKM": {"weight": 3.2}}],
        ["append",   lib.Registry.ITEMS, "compatible", {"AKM": [mag_a]}],
        ["hooks",    {"interface-getmagazine": _on_get_magazine}],
        ["when", func(): return _hardcore_mode, [
            ["patch", lib.Registry.ITEMS, {"Sticks": {"value": 200}}],
            ["when", func(): return _has_economy_mod, [
                ["patch", lib.Registry.ITEMS, {"Potato": {"value": 50}}],
            ]],
        ]],
    ])
```

`setup` adds no behavior of its own (source: `src/setup.gd`). A plan can also be a module-scope `const`, but a `const` initializer runs at script-parse time, before the loader object exists: write the registry names as strings (`"items"`, not `lib.Registry.ITEMS`) and use Callable predicates.

## Verb shapes

| Entry | Calls |
|---|---|
| `["register", reg, {id: data, ...}]` | `register_many` |
| `["override", reg, {id: data, ...}]` | `override_many` |
| `["patch", reg, {id: fields, ...}]` | `patch_many` |
| `["append", reg, field, {id: values, ...}]` | `append_many`; a fifth element `true` allows duplicates |
| `["prepend", reg, field, {id: values, ...}]` | `prepend_many`; same fifth element |
| `["remove_from", reg, field, {id: values, ...}]` | `remove_from_many` |
| `["revert", reg, {id: fields_array, ...}]` | `revert_many`; `[]` reverts the whole id |
| `["remove", reg, [id, ...]]` | `remove_many` |
| `["hooks", {hook_name: callback, ...}]` | `hook_many` at priority 100 |
| `["register_item", {id: data, ...}]` | `register_item`; likewise `register_weapon`, `register_magazine`, `register_attachment`, `register_furniture` and `register_ai_loadout` ([Registry-Aggregators](Registry-Aggregators)) |
| `["when", predicate, sub_plan]` | Runs `sub_plan` as a nested plan when `predicate` is true |

## Predicates for `when`

A predicate is a bool, an int or float (read with `bool()`), `null` (false), or a Callable whose return value is read by the same rules. A Callable runs when `setup` reaches the entry, so it sees runtime state. A plain value in a `const` plan is fixed at parse time, which suits constants and nothing else.

Anything else, such as a String or a Dictionary, warns `when-predicate has unexpected type <n>; treating as false` and skips the sub-plan, since running it on a typo would be worse. A Callable whose object is gone warns `when-predicate Callable is no longer valid; treating as false`.

A skipped `when` reports `ok = true`: nothing ran, so nothing failed. Nested `when` entries run only when every predicate on the way is true. There is no `else`; write a second `when` with the negated predicate.

## Order and failure isolation

Entries run in the order written, so register an item before the entry that patches it, and an item before the recipe that uses it. A `remove` or `revert` later in the same plan undoes what an earlier entry did.

A bad entry (wrong shape, unknown verb, a verb that fails) reports `ok = false` and the next entry still runs. An unknown verb also warns `setup: unknown verb '<verb>' -- entry skipped`, since most mods never read the result.

## Hook names in a plan

The names in a `hooks` entry are Dictionary keys, not literal `.hook("...")` calls, so the source scan that builds the wrap surface does not see them. Wrap each target some other way: a literal `.hook()` call elsewhere in your mod, or a `[hooks]` line in `mod.txt` ([Hooks](Hooks#wrap-surface----why-hook-alone-is-not-enough)).

## Return shape

`setup` returns `{ok, results}`. `ok` is true only when every top-level entry succeeded; `results` has one dict per top-level entry, in order:

- data verbs: `{verb, ok, results: {id: bool}}`
- aggregators: `{verb, ok, results: {id: per_id}}`, with the per-id dicts from [Registry-Aggregators](Registry-Aggregators)
- `hooks`: `{verb, ok, results: {hook_name: hook_id or -1}}`
- `when`: `{verb, evaluated, ok}`, plus `results` when the sub-plan ran
- a malformed entry: `{verb, ok: false, error}`; `verb` is `<malformed>` or `<empty>` when the first element is not a usable verb

```gdscript
var result: Dictionary = lib.setup(plan)
for r in result.results:
    if not r.ok:
        push_warning("[mymod] setup entry %s failed: %s" % [r.verb, r.get("error", "see log")])
```
