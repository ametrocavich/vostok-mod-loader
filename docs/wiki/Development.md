# Developing the loader

[CONTRIBUTING](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md)
covers the first build, [Build](Build) the checks and source navigation,
[Modules](Modules) the file index and [Architecture](Architecture) the boot.
This page maps a change to the files it touches.

`build.sh` concatenates `src/` into one class: no imports, a duplicate name is
a parse error, and moving code between files does not isolate its state. A new
file goes into `build.sh` and gets a row in [Modules](Modules).

## Where to start for a change

| Task | Entry points and owners | Contract |
|---|---|---|
| Discover archives or add metadata | [`collect_mod_metadata`, `_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd); the entry fields are the return literal of `_entry_from_config` | [Mod-Format](Mod-Format) |
| Select versions or resolve duplicates | [`compare_versions`, `_dedupe_by_mod_id`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_identity.gd) | [Mod-Format](Mod-Format) |
| Decide what loads and in which order | [`_loadable_enabled_entries`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_dependencies.gd) | [Dependencies](Dependencies) |
| Save or switch profiles | [`_save_ui_config`, `_switch_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profiles.gd); MCM files in `src/profile_snapshots.gd` | [Config-Files](Config-Files) |
| Download or update an archive | [`download_mod_from_ref`, `replace_mod_from_ref`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_downloads.gd); identities in `src/mod_sources.gd` | [Browse](Browse), [Mod-Format](Mod-Format#updates-section) |
| Render installed mods | [`_rebuild_mods_tab`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods.gd); rows in `src/ui_mods_rows.gd`, host details in `src/ui_mods_metadata.gd` | [Mods](Mods) |
| Apply or unload a pack | [`apply_modpack`, `unload_modpack`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd); site packs in `src/hosted_modpacks.gd` | [Modpacks](Modpacks), [Profile-Format](Profile-Format) |
| Debug launch or restart | [`_ready`, `_run_pass_1`, `_run_pass_2`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd); early mounts in `src/boot.gd`, pass state in `src/pass_state.gd` | [Architecture](Architecture) |
| Change hook behavior | `src/hooks_api.gd` (registration), `src/rewriter_rewrite.gd` (wrappers), `src/hook_pack.gd` (pack and activation) | [Hooks](Hooks), [Limitations](Limitations) |
| Add registry content support | `src/registry.gd`, `src/registry/*.gd`, `src/rewriter_registry_inject.gd` | [Registry](Registry), [Setup-Plans](Setup-Plans) |

## Rules that are easy to miss

- Change `mod_config.cfg` through `_load_ui_cfg_for_write` and `_persist_ui_cfg`:
  they refuse an unreadable file and keep the rolling backup. `ConfigFile.load()`
  merges, so clear a reused object before loading again.
- A persisted value has a writer and readers in two processes: check the next
  launch's static-init reader in `src/boot.gd` as well as Pass 2.
- `load_all_mods` is not a reset: hooks that early autoloads registered survive it.
- Awaited download and metadata work can outlive a closed launcher window; check
  the control is still valid before painting it.
- For rewriter changes, read the generated source and compile a caller against
  it (`check_codegen.sh` does both); a string assertion is not enough.
- Link a function name to its file with the name in backticks in the link label;
  `python tools/dev.py check-docs` then fails when the name leaves that file.

## Testing a change

Add the case to the closest runner under `tests/` (the runners are listed in
[Build](Build#the-checks)). Three pieces of scaffolding carry every runner:

- `tests/common/runner_base.gd` is the base class: a runner extends it,
  overrides `_tests(ml)` and gets `begin(id)`, `_assert`, `check_eq` and a
  loader instance from `boot_loader`.
- `tests/common/stub_loader.gd` extends the neutered loader and replaces its
  network leaves with fixtures, including a stubbed `download_mod_from_ref`.
- `run_simple_check` in `tests/lib.sh` is a whole check script: it builds the
  throwaway project, neuters the boot initializer, runs the runner and, with
  `--prove`, swaps one line of the test copy and demands a failure.

## Extension recipes

### Adding a mod.txt key or section

- [`_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)
  reads the key into the entry; [`_build_entry_warnings`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd)
  turns a problem into a row warning (`_build_entry_author_notes` when only the
  author should see it). The Mods tab renders both without a UI change.
- A section that changes loading is consumed in
  [`_process_mod_candidate`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd)
  and listed in `MOD_TXT_KNOWN_SECTIONS`, or every mod using it gets the
  unrecognized-section notice.
- Document it in [Mod-Format](Mod-Format). Entries are read by key name across
  several files, so a new key is safe and a renamed one is not.

### Adding a mod host

- `src/host_types.gd`: a `HOST_<NAME>` id in `HOST_PROVIDERS_KNOWN`.
- `src/host_<name>.gd`: the adapter, with its caps and scalars functions and one
  function per operation the caps enable, each returning complete records.
- `src/host_api.gd`: an arm in every `match` and an entry in `host_providers()`
  (the Browse menu order). `check_host.sh` fails on a missing arm. If the loader
  is listed on the host, add that id to `HOST_OWN_LISTINGS`.
- `build.sh` after `host_api.gd`; a payload fixture in `tests/host/runner.gd`;
  [Browse](Browse) and the `source=` value in [Mod-Format](Mod-Format).

### Adding a download surface

Call `download_mod_from_ref` or `replace_mod_from_ref` and never their install
tails; both resolve through the host seam and record the mod's source. After
success call `_reload_entries_for_active_profile()` and `_rebuild_mods_tab(tabs)`,
guarding against a launcher closed during the wait; the Browse Download handler
in `src/ui_browse.gd` shows the pattern.

### Adding a registry section

1. `src/registry.gd`: a `Registry.FOO` constant; an arm in each dispatcher whose
   verb the section supports (`register`, `override`, `patch`,
   `_array_op_dispatch`, `remove`, `revert`, `get_entry`) and a `_VERB_REFUSALS`
   entry for each verb it rejects; an arm in `_enumerate_vanilla`. A verb with
   neither warns that the section is unwired.
2. `src/registry/<section>.gd` with the handlers (`fish.gd` is the smallest). A
   section whose entries sit in an Array on a vanilla Resource is a
   `_ARRAY_ENTRY_SHAPES` row in `src/registry/array_entries.gd` instead.
3. `build.sh`: the file after `registry/shared.gd`.
4. If vanilla code must read the entries, add a rewrite target (next section);
   a handler that hands entries to injected code calls `_registry_target_inert`
   first in `register` and `override`.
5. Document it in [Registry](Registry). `setup()` and the `*_many` verbs route
   through the same dispatchers.

### Adding a rewrite target

1. `src/hook_pack.gd`: the script's filename in `REGISTRY_TARGETS` and the text
   its rewrite must contain in `REGISTRY_EXPECTED_MARKERS`. A target compiles
   eagerly unless `_defers_scene_preloads` names it.
2. `src/rewriter_registry_inject.gd`: the code, each piece under a
   `# Vanilla anchor:` comment (`tests/ingame/rehearse_build.sh` checks them).
   A declaration transform is an arm in the filename `match` of
   `_rtv_rewrite_vanilla_source` (`src/rewriter_rewrite.gd`), a prelude an arm in
   `_apply_preludes`, an appendix an arm in `_registry_appendix`.
3. `tests/codegen/runner.gd`: the script in `FIXTURES`, a member its code names
   in `GAME_RENAMES`, and a case in `_check_registry_runtime`.

### Adding a profile.json field

The writer is [`_hosted_manifest_to_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hosted_modpacks.gd)
and the reader [`_materialize_modpack_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd);
a field one emits and the other ignores is dropped silently. A per-mod field
stored in profile sections also touches `_save_ui_config`,
`_apply_profile_to_entries`, `_erase_profile_sections`, `_rename_profile`,
`_delete_mod_file_and_cleanup` and `_modpack_reconcile_profile_keys`. The pack
backup in `_stage_pack` and the restore in `unload_modpack` carry only
`.enabled` and `.priority`. Document the field in [Profile-Format](Profile-Format).

### Adding an archive extension

`MOD_ARCHIVE_EXTENSIONS` in `src/mod_discovery.gd` is the accept set the scan
and the download-name check read. Godot mounts only `.pck` and `.zip`, so any
other extension needs the `.vmz`-style cache copy in `_try_mount_pack`
(`src/fs_archive.gd`), which the static-init mount loop also uses. The cache is
keyed by basename, so `Mod.vmz` and a same-named archive collide. Document it in
[Mod-Format](Mod-Format).
