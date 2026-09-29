# Developing the loader

Start with [CONTRIBUTING](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md)
for prerequisites and a first build. This page maps common changes to their
owners. [Modules](Modules) is the detailed file index; [Architecture](Architecture)
explains the boot sequence.

## One class, several source fragments

`build.sh` concatenates its `FILES` list into one `modloader.gd` extending
`Node`. Every top-level function, variable, constant and signal shares that
class. There are no imports between these fragments. Duplicate definitions
are parse errors; a constant used by another constant's initializer must
appear first in assembly order. Function bodies can call functions later in
the file.

The installed artifact is generated. Edit `src/`, add new fragments to
`build.sh`, add their ownership to [Modules](Modules), then build and check.
`./build.sh --list` prints the authoritative order. Keep a new helper with
the subsystem that owns its state; put broadly shared loader state in
`constants.gd`. Moving code between fragments does not isolate its state.

## Where to start for a change

| Task | Entry points and owners | Contract to read |
|---|---|---|
| Discover archives or add metadata | [`collect_mod_metadata`, `_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd) | [Mod-Format](Mod-Format); the entry Dictionary contract above `_entry_from_config` |
| Select versions or resolve duplicates | [`compare_versions`, `_dedupe_by_mod_id`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_identity.gd) | [Mod-Format](Mod-Format) |
| Decide what loads and in which order | [`_loadable_enabled_entries`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_dependencies.gd) | [Dependencies](Dependencies) |
| Save or switch profiles | [`_save_ui_config`, `_switch_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/profiles.gd), MCM file operations in `src/profile_snapshots.gd` | [Config-Files](Config-Files) |
| Download or update an archive | [`download_mod_from_ref`, `replace_mod_from_ref`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_downloads.gd), persisted identities in `src/mod_sources.gd` | [Browse](Browse), [Mod-Format](Mod-Format#updates) |
| Render installed mods | [`_rebuild_mods_tab`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui_mods.gd), rows in `src/ui_mods_rows.gd`, async metadata in `src/ui_mods_metadata.gd` | [Mods](Mods) |
| Apply or unload a pack | [`apply_modpack`, `unload_modpack`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd), hosted conversion in `src/hosted_modpacks.gd` | [Modpacks](Modpacks), [Profile-Format](Profile-Format) |
| Debug launch or restart | [`_ready`, `_run_pass_1`, `_run_pass_2`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/lifecycle.gd), early mounts and pass-state writes in `src/boot.gd` | [Architecture](Architecture), [Stability-Canaries](Stability-Canaries) |
| Change hook behavior | Public registration in `src/hooks_api.gd`, wrapper emission in `src/rewriter_rewrite.gd`, pack activation in `src/hook_pack.gd` | [Hooks](Hooks), [Limitations](Limitations) |
| Add registry content support | Dispatch in `src/registry.gd`, handlers in `src/registry/*.gd`, code injection in `src/rewriter_registry_inject.gd` | [Registry](Registry), [Setup-Plans](Setup-Plans) |

## Follow state, not only calls

| State | Owner and lifetime |
|---|---|
| Mod entries | `collect_mod_metadata` creates Dictionaries without mounting archives. Profiles apply enabled/priority values; dependency selection decides what is loadable. UI and loading consume the same entries. Re-scans replace `_ui_mod_entries`. |
| Profile configuration | `profiles.gd` reads/writes `user://mod_config.cfg`. Use `_load_ui_cfg_for_write` and `_persist_ui_cfg` for mutations so unreadable state is refused and the rolling backup is preserved. `ConfigFile.load()` merges; clear a reused object before reloading. |
| MCM settings | `profile_snapshots.gd` snapshots the active `user://MCM/` folder under `user://.profile_snapshots/<profile>/MCM/`. These files are separate from `mod_config.cfg`. |
| Host identity | `mod_sources.gd` resolves explicit mod metadata, stored `[mod_sources]` records and legacy ModWorkshop IDs. Host adapters normalize network payloads; the UI consumes complete host records. |
| Download state | `mod_downloads.gd` owns validation and replacement on disk. Callers refresh profile entries and UI after success. `mod_updates.gd` decides update candidates; it does not install them. |
| Boot handoff | `boot.gd` persists `mod_pass_state.cfg` and `override.cfg` for the next process. `_filescope_mounted` is initialized when the autoload instance is constructed, before `_ready`. This is called "static init" in older log labels. |
| Hooks and registry | Shared loader state in `constants.gd`, mutated through `hooks_api.gd` and registry dispatchers. Early autoload hooks must survive `load_all_mods`; that method is not a general reset. |
| Launcher | `ui.gd` owns the window; tab files own controls. Awaited metadata/download work can outlive a closed window, so check control validity before repainting. `_mark_mod_set_changed` records changes that require a post-boot restart. |

For persistence changes, find both the writer and every reader, including the
next process's early-boot reader. For async UI changes, follow success,
failure and window-close paths. For rewriter changes, inspect generated
source and caller compilation, not just string assertions.

## Navigate an error

```bash
python tools/dev.py find _save_ui_config
rg -n '_save_ui_config' src tests
python tools/dev.py locate 12345
```

`find` searches top-level definition names, including partial names. `locate`
uses `# source: src/...` markers in the built file to print `path:line` and
the line's text. It requires the exact build that produced the error; a
rebuild from different source changes generated line numbers. It warns when
the corresponding current source line differs, but cannot identify which
release produced a pasted error.

[Build](Build) maps failures to harnesses. Test runners are small executable
examples of reaching loader behavior without launching the game. Each
harness runs a throwaway project with the boot initializer disabled. Put
engine probes in an existing runner, run its check script and remove the
probe afterward. Use the console executable for checks; do not open the
editor or game as part of automated verification.

## Keep documentation aligned

The source of wiki pages is `docs/wiki/`; the published wiki can describe a
different revision from the current checkout. Prefer local pages while
working on a branch. Link function names to their owning source file using
backticks in the link label. `python tools/dev.py check-docs` checks those
owners, local/repository links, source paths and the module index. It also
runs inside the existing static-invariants stage of `check.sh`.

The check does not validate prose, URL fragments or external sites. Review
claims about defaults, failure handling, saved state and UI labels against
their consumers. Avoid copying the build manifest or assertion counts into
guides; the scripts and runner output already provide them.

## Extension recipes

### Adding a mod.txt key or section (scan-time metadata)

- [`_entry_from_config`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd) parses the key from the
  ConfigFile and stores it on the entry Dictionary.
- [`_build_entry_warnings`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd) derives a row warning from it
  when the mod will not work; `_build_entry_author_notes` when only the
  author should hear about it. The Mods tab renders `entry["warnings"]` for
  everyone and `entry["author_notes"]` in developer mode, so no UI edit.
- `docs/wiki/Mod-Format.md` documents the section.
- If the section affects loading as well as scan-time metadata, also
  [`_process_mod_candidate`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_loading.gd), which is where `[hooks]`,
  `[registry]`, `[script_extend]` and `[autoload]` are consumed. Add the
  section name to `MOD_TXT_KNOWN_SECTIONS` there, or every mod using it gets
  the unrecognized-section notice.

`mod.txt` is parsed by `_parse_mod_txt` in `src/fs_archive.gd` (ConfigFile
syntax, plus the unquoted-`[hooks]` value repair and an empty-section
workaround for `[registry]`). Entry Dictionaries are read by key name across
profiles.gd, mod_loading.gd, boot.gd and modpacks.gd: new keys are additive-safe,
renames are not.

### Adding a mod host

- `src/host_types.gd`: a `HOST_<NAME>` id, added to `HOST_PROVIDERS_KNOWN`
  (what the on-disk `source=` parser accepts).
- `src/host_<name>.gd`: the adapter. `_<tag>p_caps()` declares what it can
  do, `_<tag>p_scalars()` the sorts, landing sections and limits, and one
  function per operation the caps turn on, each returning a HostResult
  (`host_ok` / `host_err`) built from `host_types.gd` records. Every field of
  every record must be present with its declared type; use the sentinels,
  never omit a key.
- `src/host_api.gd`: a match arm in every dispatcher (`host_list_mods`,
  `host_get_mod`, `host_list_files`, `host_resolve_file`,
  `host_list_categories`, `host_latest_versions`, `host_display_name`,
  `host_caps`, `host_mod_page_url`, `host_note_rate_headers`,
  `_host_scalars`) and an entry in `host_providers()`, whose order is the
  Browse source menu order. A provider with no arm in a dispatcher gets
  `HOST_ERR_UNWIRED` from its `_:` default; `check_host.sh` T9 reads the
  dispatchers off the built source and fails when a provider is missing
  from one. If the loader itself is listed on the new host, add that id to
  `HOST_OWN_LISTINGS` so `_host_hide_own_listing` keeps it out of Browse.
- `build.sh`: add the file after `host_api.gd`.
- `tests/host/runner.gd`: a normalizer fixture for the host's payload shape.
- `docs/wiki/Browse.md` and `docs/wiki/Mod-Format.md` (the `source=` value).

Downloads need nothing host-specific beyond `host_resolve_file`; the install
tail is shared (next section).

### Adding a download surface

Existing surfaces: Browse "Download" (ui_browse.gd ->
`download_mod_from_ref`), the Mods-tab update badges
(`replace_mod_from_ref`), the missing-mod stub Download (ui_mods.gd ->
`download_mod_from_ref(ref, version, true)`), and modpack missing-mod fetch
and retry (modpacks.gd, the same call).
The authoritative map sits above the download entry points in
`src/mod_downloads.gd`.

- Both entry points take a host ref (`{provider, id}`, see `host_ref` in
  `src/host_types.gd`), resolve the file through `host_resolve_file` and
  fetch it with `_http_download_to_temp`, the one place a response body is
  written to disk. `download_mod_from_ref` then hands the temp file to
  `_host_install_downloaded_archive`: Content-Disposition filename
  derivation, `_is_safe_mod_filename`, collision rename, zip/pck validation,
  rename-finalize. `replace_mod_from_ref` has its own tail, which parks the
  installed archive as `.bak` and rolls back on failure. Both finish with the
  `[mod_sources]` record (`_record_installed_mod_source`). A new surface
  calls one of the two entry points and never touches either tail.
- After a successful install: `_reload_entries_for_active_profile()` then
  `_rebuild_mods_tab(tabs)`. The Browse Download handler shows the pattern,
  including the `is_instance_valid` guards for a closed launcher window.
  `_reload_entries_for_active_profile` already calls `_mark_mod_set_changed`,
  so a post-boot download restarts into the new mod set on close.

### Adding a registry section

1. `src/registry.gd`: add a `Registry.FOO` constant.
2. `src/registry.gd`: add a match arm in each dispatcher: `register`,
   `override`, `patch`, `_array_op_dispatch` (covers append / prepend /
   remove_from), `remove`, `revert`, `get_entry` and `_enumerate_vanilla`
   (pure-mod sections join the shared `return {}` arm). An omitted arm does
   not fail soft: the fallthrough warns that the section is declared but has
   no match arm, and names it a loader bug. Verbs the section rejects need
   explicit not-supported arms
   (see `resources` / `scene_nodes` in `register`).
3. Create `src/registry/<section>.gd` with the verb implementations. Copy the
   closest shape: `fish.gd` is the smallest (register/remove only),
   `events.gd` is the full array-backed pattern.
4. Add the file to `build.sh`'s `FILES` array after `registry/shared.gd`.
5. If the section needs code injected into a vanilla script: a transform in
   `src/rewriter_registry_inject.gd`, the script in `REGISTRY_TARGETS` and a
   marker in `REGISTRY_EXPECTED_MARKERS` (`src/hook_pack.gd`), and a fixture
   line in `tests/codegen/runner.gd`. A handler that hands its entries over
   through Engine metadata only the injected code reads calls
   `_registry_target_inert` first in `register` / `override`, so a target
   the compile probe shipped without registry code returns `false`.
6. Document it in `docs/wiki/Registry.md`.

`setup.gd` and the `*_many` batch verbs route through the same dispatchers,
so nothing else changes.

### Adding a profile.json field

The metroprofile v1 payload has one writer and one live reader:

- writer: [`_hosted_manifest_to_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hosted_modpacks.gd), packed by
  `_hosted_write_pack_zip`.
- reader: [`_materialize_modpack_profile`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd) (modpack apply).
  `_validate_modpack` checks the schema before apply touches any state, and
  `_get_missing_mods_for_modpack` reads the zip's `sources` and `checksums`
  for the download loop, and `_modpack_sources` reads `sources` again for
  the key reconciliation.

A field the writer emits and the reader ignores silently drops. If the field
is per-mod state stored in `mod_config.cfg` profile sections, also touch:
`_save_ui_config` (including its hidden-folder preservation block),
`_apply_profile_to_entries`, the `PROFILE_SUBSECTIONS` sweep in
`_delete_active_profile`, the `[".enabled", ".priority", ".dep_ignore"]`
sweeps in `_rename_profile`, the per-key cleanup in
`_delete_mod_file_and_cleanup`, and `_modpack_reconcile_profile_keys`
(modpacks.gd), which rewrites the same three suffixes after a pack's
downloads land. Decide whether the field rides the modpack backup/unload
round-trip: the backup copy in `_apply_modpack_inner` and the restore in
`unload_modpack` move only `.enabled` and `.priority`, by design. New fields
stay optional (forward-compat rules in `docs/wiki/Profile-Format.md`) and get
documented there.

### Adding an archive extension

The accept set `["vmz", "zip", "pck"]` lives in two places that must not
drift: the scan filter in `collect_mod_metadata` and the download-name gate
`_is_safe_mod_filename` (`src/mod_downloads.gd`). On the mount side,
Godot's `load_resource_pack` only recognizes literal `.pck` / `.zip`, so any
other extension needs the vmz-style cache-copy fallback in `_try_mount_pack`
(fs_archive.gd) and in the early-boot remount loop of `_mount_previous_session`
(boot.gd). The hook pack never reads mod archives, so it needs no change.
Also: the `"vmz", "zip"` match arm in `scan_mod` (security_scan.gd),
the modpack sniff in `collect_mod_metadata` (zip-only by design), the
skip-log literal, and `docs/wiki/Mod-Format.md`. Hazard: `_static_vmz_to_zip`
keys its cache on basename, so `Mod.vmz` and a same-basename alias archive
would collide in `user://vmz_mount_cache`.
