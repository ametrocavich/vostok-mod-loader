# Hook pack

How the [wrap surface](Hook-Surface) becomes rewritten vanilla scripts served over the game's bytecode. You do not need this page to write a hook mod; it is for reading boot logs and changing the loader. Generation and activation live in `src/hook_pack.gd`, the source rewrite in `src/rewriter_*.gd`, dispatch in `src/hooks_api.gd`.

## The generated wrapper

Each wrapped method is renamed `_rtv_vanilla_<name>` where it stands, and a wrapper with the original name, parameters and return annotation is appended to the script:

```
func jump(delta):                  # the wrapper, at the original name
    # no RTVModLib meta, no hook ever registered, or none on "controller-jump": run vanilla
    # re-entry guard for this instance and hook; _caller = self
    # -pre; the replace callback, then vanilla unless it called skip_super()
    # -post (may replace the result); -callback deferred; restore _caller
func _rtv_vanilla_jump(delta):     # the vanilla body, renamed
```

`_wrapper_source` in `src/rewriter_rewrite.gd` emits it; `_dispatch`, `_dispatch_post` and `_dispatch_deferred` in `hooks_api.gd` run the callbacks.

- A void method's wrapper dispatches `-post` and ignores what it returns; a non-void one chains the result through `_dispatch_post`. The engine lifecycle methods in `RTV_ENGINE_VOID_METHODS` are always void.
- `await` goes before the vanilla call and the replace call only when the vanilla body contains `await` as code; one inside a string, a comment or a lambda does not count. A function whose body holds `await` is a coroutine, so an unconditional `await` would turn every wrapped method into one and break every caller that does not await it. `check.sh` and `check_codegen.sh` lock the rule.
- `_skip_super` and `_caller` are saved and restored around the dispatch, so nested wrapped calls are safe.
- `_hooked_bases`, a per-name refcount kept by `hook()` and `unhook()`, is why a wrapped method nobody hooks costs almost nothing.
- In developer mode each wrapper counts its dispatches for the report logged 30 seconds after launch.

## How a script is rewritten

`_generate_hook_pack` runs once per generation:

1. Preflight (`_pack_preflight`): canaries B and C ([Stability-Canaries](Stability-Canaries)). No loaded mod means no pack.
2. Triage (`_triage_script`): skip lists, zero-byte entries and scripts no mod declared stay vanilla.
3. Source: `_read_vanilla_source` returns the detokenized text of the game's own copy ([GDSC-Detokenizer](GDSC-Detokenizer)).
4. Parse (`_rtv_parse_script`): signatures, parameters, return types, whether a body awaits or returns a value.
5. Rewrite (`_rtv_rewrite_vanilla_source`), described below.
6. Probe-compile (`_hook_pack_vet_rewrite`): the full rewrite, else the wrap-only form, else vanilla ([Stability-Canaries](Stability-Canaries#pre-ship-compile-probe)).
7. Check (`_check_rewrite`): every selected method was renamed, and a registry target carries its marker string; a miss is a `PARTIAL` line in the [reconciliation report](Hook-Surface#the-reconciliation-report).
8. Write the pack entries, then log the report.

The rewrite itself:

- Line endings become LF throughout, to match the appended wrappers. Godot compiles CRLF and mixed endings fine; mod scripts are never touched.
- The indent unit is read from the first indented code line (a tab when there is none), so the wrappers match the file. GDScript rejects tabs and spaces mixed in one file.
- A bare `super()` inside a renamed body becomes `super.<name>()`; left alone it would look for `_rtv_vanilla_<name>` on the parent, and the reload would fail. An explicit `super.Other()` is untouched.
- Registry targets also get their declaration transforms, function preludes and appended helpers from `src/rewriter_registry_inject.gd` ([Registry](Registry)). The wrap-only form leaves all three out.

## Pack layout

Each rewritten script ships as three entries:

| Entry | Purpose |
|---|---|
| `Scripts/<Name>.gd` | The rewritten source, at the vanilla path; anywhere else the class cache reports `Class X hides a global script class` |
| `Scripts/<Name>.gd.remap` | A `[remap]` pointing at the `.gd`, overriding the PCK's `.gd.remap` to `.gdc` redirect |
| `Scripts/<Name>.gdc` | Zero bytes. Godot prefers a sibling `.gdc` even after the remap; an empty one fails to parse and falls back to the `.gd` |

The pack also holds `__modloader_canary__.txt` for the VFS canary, and nothing else: mod scripts run from their own archives. It is `user://modloader_hooks/framework_pack_<ticks>.zip`, mounted at `res://` with `replace_files`, because `extends` resolution of `class_name` parents breaks for scripts loaded from `user://`.

Every generation writes a new file name. `load_resource_pack` dedupes by path, and a mounted pack holds a zip handle that deleting or rewriting the file would invalidate (reads then fail with "Cannot open file" from `file_access_zip.cpp`). Old packs are swept at the next static init, before any mount. With mods loaded but nothing declared, the pack holds only the `Menu.gd` wrap.

## Activation

The Pass 1 generation does not activate. It persists the pack path and the eagerly wrapped script paths, and the next process's static init mounts the pack and loads each of those scripts with `CACHE_MODE_IGNORE` plus `take_over_path` before anything compiles them (`_preempt_wrapped_scripts` in `src/boot.gd`). Once the class cache pins a compiled script, neither reload path can replace it.

A generation that activates mounts the pack, checks the VFS canary and runs `_activate_rewritten_scripts`, which handles each script in `_activate_one`:

- Already live from static init: kept, or taken over by a fresh load when its source differs from the pack's (an older pack).
- Cached vanilla: `source_code` is set to the rewrite and `reload()` runs.
- Compiled from `.gdc` (scripts the initial scene graph references, such as `Camera.gd` and `WeaponRig.gd`): `reload()` re-reads the bytecode instead of parsing the new source, so `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` compiles the `.gd` through the remap and `take_over_path` installs it.

A script counts as activated only when its method list carries a `_rtv_vanilla_*` name. A mod's replacement at an activated path is overwritten ([Hooks](Hooks#composing-with-script_extend)). Scripts with a module-scope scene preload are not activated at all ([Limitations](Limitations#scene-preload-deferred-compile)); the DEFER-VERIFY watchdog checks them later. Canary A runs last.

## Related

- [Stability-Canaries](Stability-Canaries): every check around generation and activation
- [Architecture](Architecture): where generation sits in the two-pass boot
- [Limitations](Limitations): engine quirks the pack works around
