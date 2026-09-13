# Contributing

## Repository layout

The installed file, `modloader.gd`, is built from source and never edited
directly. The editing surface is `src/`:

```
src/
  header.gd                # extends Node, top-of-file doc (the only extends)
  constants.gd             # shared const + module-scope var declarations
  logging.gd               # _log_info/warning/critical/debug
  fs_archive.gd            # file/archive helpers, mod.txt parsing, vmz cache
  boot.gd                  # static init, override.cfg, pass state, crash streak
  security_scan.gd         # pre-mount static scan of mod archives
  host_types.gd            # host-seam records, refs, failure codes
  host_http.gd             # shared HTTP transport, cache, cooldowns
  host_api.gd              # the seam: one match per operation, per provider
  host_mws.gd              # ModWorkshop adapter
  host_vostokmods.gd       # VostokMods adapter (the default host)
  host_nexus.gd            # Nexus adapter, link-out only
  mod_discovery.gd         # scan mods, parse metadata, ordering, downloads
  modpacks.gd              # modpack scan/apply/unload + restore points
  hosted_modpacks.gd       # packs published on VostokMods, turned into local pack zips
  mod_loading.gd           # mount + apply mods at runtime
  conflict_report.gd       # developer-mode diagnostics
  ui.gd                    # launcher window, profiles, shared UI helpers
  ui_theme.gd              # palette tokens, theme, styling voices, glyphs
  ui_dialogs.gd            # dialog plumbing + profile dialogs
  ui_mods.gd               # Mods tab
  ui_browse.gd             # Browse tab
  ui_modpacks.gd           # Modpacks tab + apply flow dialogs
  ui_updates.gd            # Updates tab
  hooks_api.gd             # public hook + version + mod-info API
  registry.gd              # registry verb dispatchers + Registry const
  registry/                # shared.gd + 15 per-section handlers (16 files)
  setup.gd                 # declarative lib.setup(plan) entry point
  framework_wrappers.gd    # scene-tree class walker for the dev-mode probes
  gdsc_detokenizer.gd      # .gdc -> source reconstruction
  pck_enumeration.gd       # PCK introspection + class_name map
  rewriter_parse.gd        # regex + detokenized-source parsing
  rewriter_rewrite.gd      # rename + wrap orchestrator, wrapper emitter
  rewriter_registry_inject.gd  # per-script transforms, preludes, appendices
  rewriter_autofix.gd      # legacy-GDScript autofix, base()/reload strippers
  hook_pack.gd             # hook pack generator + activator
  hook_status.gd           # hook health record the launcher reads at boot
  lifecycle.gd             # _ready + pass orchestration
  main_menu_hook.gd        # in-game Mods button on the RTV main menu
  debug.gd                 # test scaffolding (gated behind a config flag)
```

55 files, in `build.sh`'s `FILES` order (the concat order).
`docs/wiki/Modules.md` has the per-file tour.

### Building and checking locally

```bash
./build.sh
./check.sh
```

`build.sh` concatenates the sources into `modloader.gd` at the repo root.
`check.sh` parses that file with a headless Godot 4.6.1 (`GODOT=/path/to/godot
./check.sh` if it is not on PATH), then runs the grep invariants and the six
harnesses (`check_codegen.sh`, `check_dispatch.sh`, `check_detok.sh`,
`check_identity.sh`, `check_host.sh`, `check_boot_state.sh`). Each harness
takes `--prove`, which breaks the code under test in a temp copy and requires
the harness to fail. The codegen harness skips itself on machines without the
decompiled vanilla source; the rest never skip. `docs/wiki/Build.md` lists what
each one covers.

Neither script opens a window or touches the game install. Testing whether a
mod actually mounts is still a smoke test in the real game.

`modloader.gd` is not committed; it is a build artifact attached to each
release. The installer scripts fetch it from
`/releases/latest/download/modloader.gd`.

## Branches

- `development`: target for contributor PRs. Feature branches squash-merge
  into it, so each PR is one clean conventional commit.
- `master`: release branch. Only maintainer PRs from `development` to `master`
  land here, by rebase-merge, so every commit survives for release-please.

Open your PR against `development`. The maintainer batches accumulated work
into a PR to `master` when it is time to release, and resets `development` to
`origin/master` afterwards (rebase-merge rewrites the SHAs).

CI (`.github/workflows/ci.yml`) runs `build.sh` and `check.sh` on every pull
request and on pushes to `master` and `refactor/**`.

## Conventional Commits

The repo uses [Conventional Commits](https://www.conventionalcommits.org/) so
[release-please](https://github.com/googleapis/release-please) can bump the
version and write the changelog. When a PR merges to `master`, release-please
opens a follow-up PR that bumps `MODLOADER_VERSION` in `src/constants.gd` and
updates `CHANGELOG.md`. Merging that PR creates the tag and a draft GitHub
Release; the workflow then builds `modloader.gd`, runs `check.sh` on the exact
artifact, uploads the assets, and publishes.

### PR titles

The PR title becomes the commit title on squash (or lands as is on rebase), so
it has to follow this format:

```
<type>: <description>
```

Triggers a version bump:

| Type | Bump | When to use |
|------|------|-------------|
| `feat:` | minor (3.3.1 -> 3.4.0) | New feature or user-facing behavior |
| `fix:` | patch (3.3.1 -> 3.3.2) | Bug fix, no new functionality |
| `feat!:` or `fix!:` | major (3.3.1 -> 4.0.0) | Breaking change (API rename, removed feature) |

No version bump (still listed in the changelog under "Miscellaneous"):

| Type | When to use |
|------|-------------|
| `chore:` | Maintenance, deps, housekeeping |
| `docs:` | Documentation only |
| `refactor:` | Code restructure, no behavior change |
| `test:` | Test changes only |
| `perf:` | Performance improvement |
| `build:` / `ci:` / `style:` | Build, CI, formatting |

### Examples

```
feat: add register_scene API for mods
fix: mcm crash on knife draw
feat!: rename MODLOADER_VERSION to version()
docs: document hook API in README
chore: bump release-please config schema
```

### Breaking changes

Add `!` after the type, or put `BREAKING CHANGE:` in the PR body, to force a
major bump. Say what breaks in the body so the changelog entry is useful.

### Branch naming

No rule. release-please reads commit and PR titles, not branch names.

## Checklist before opening a PR

- [ ] Edited files under `src/`, not `modloader.gd`
- [ ] Ran `./build.sh && ./check.sh` and tested in-game
- [ ] If a format, a mod.txt key or a config key changed, `docs/wiki/` changed
      in the same PR
- [ ] PR title follows `<type>: <description>`
- [ ] PR targets `development`, not `master`

## Extending the loader

`modloader.gd` is one flat-namespace script: every top-level func, var and
const in `src/*.gd` is global across files, duplicate names break the build,
and a const referenced by another const's initializer must appear earlier in
`build.sh`'s `FILES` order. The maps below list every file and function you
touch for the common extension jobs, checked against the 3.3.1 source.
Function names are stable anchors; line numbers are not.

### Adding a mod.txt key or section (scan-time metadata)

- `src/mod_discovery.gd: _entry_from_config` parses the key from the
  ConfigFile and stores it on the entry Dictionary.
- `src/mod_discovery.gd: _build_entry_warnings` derives a row warning from it.
  The Mods tab renders `entry["warnings"]` generically, so no UI edit.
- `docs/wiki/Mod-Format.md` documents the section.
- If the section affects loading and not only scan-time metadata, also
  `src/mod_loading.gd: _process_mod_candidate`, which is where `[hooks]`,
  `[registry]`, `[script_extend]` and `[autoload]` are consumed. Add the
  section name to `MOD_TXT_KNOWN_SECTIONS` there, or every mod using it gets
  the unrecognized-section notice.

`mod.txt` is parsed by `_parse_mod_txt` in `src/fs_archive.gd` (ConfigFile
syntax, plus the unquoted-`[hooks]` value repair and an empty-section
workaround for `[registry]`). Entry Dictionaries are read by key name across
ui.gd, mod_loading.gd, boot.gd and modpacks.gd: new keys are additive-safe,
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
  Browse source menu order. A capability declared without an arm returns
  `HOST_ERR_UNWIRED`, and `check_host.sh` T9 fails on it.
- `build.sh`: add the file after `host_api.gd`.
- `tests/host/runner.gd`: a normalizer fixture for the host's payload shape.
- `docs/wiki/Browse.md` and `docs/wiki/Mod-Format.md` (the `source=` value).

Downloads need nothing host-specific beyond `host_resolve_file`; the install
tail is shared (next section). Nexus is the reference for a link-out-only
host; keep it that way.

### Adding a download surface

Existing surfaces: Browse "Download" (ui.gd -> `download_mod_from_ref`), the
Mods-tab update badges and the Updates tab (`replace_mod_from_ref`), the
missing-mod stub Download (ui.gd -> `download_mod_from_ref(ref, version,
true)`), and modpack missing-mod fetch and retry (modpacks.gd, the same call).
The authoritative map sits above the download entry points in
`src/mod_discovery.gd`.

- Both entry points take a host ref (`{provider, id}`, see `host_ref` in
  `src/host_types.gd`), resolve the file through `host_resolve_file`, and
  hand it to `_host_install_downloaded_archive`: Content-Disposition filename
  derivation, `_is_safe_mod_filename`, collision rename, `.download` temp
  file, zip/pck validation, rename-finalize, and the `[mod_sources]` record
  (`_record_installed_mod_source`). A new surface calls one of the two entry
  points and never touches the tail.
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
   not fail soft: the fallthrough warns "unknown registry", which reads as a
   loader bug. Verbs the section rejects need explicit not-supported arms
   (see `resources` / `scene_nodes` in `register`).
3. Create `src/registry/foo.gd` with the verb implementations. Copy the
   closest shape: `fish.gd` is the smallest (register/remove only),
   `events.gd` is the full array-backed pattern.
4. Add the file to `build.sh`'s `FILES` array after `registry/shared.gd`.
5. If the section needs code injected into a vanilla script: a transform in
   `src/rewriter_registry_inject.gd`, the script in `REGISTRY_TARGETS` and a
   marker in `REGISTRY_EXPECTED_MARKERS` (`src/hook_pack.gd`), and a fixture
   line in `tests/codegen/runner.gd`.
6. Document it in `docs/wiki/Registry.md`.

`setup.gd` and the `*_many` batch verbs route through the same dispatchers,
so nothing else changes.

### Adding a profile.json field

The metroprofile v1 payload has one writer and one live reader:

- writer: `src/ui.gd: _profile_to_json_string`, reached through
  `_export_profile_to_zip` from `save_profile_as_modpack` (modpacks.gd).
- reader: `src/modpacks.gd: _materialize_modpack_profile` (modpack apply).
  `_validate_modpack` checks the schema before apply touches any state, and
  `_modpack_sources` reads the `sources` map for the download loop and the
  key reconciliation.

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
`_is_safe_mod_filename` (both `src/mod_discovery.gd`). On the mount side,
Godot's `load_resource_pack` only recognizes literal `.pck` / `.zip`, so any
other extension needs the vmz-style cache-copy fallback in `_try_mount_pack`
(fs_archive.gd) and in the static remount loop of `_mount_previous_session`
(boot.gd); the hook pack's sibling pre-read reads whatever path
`scan_and_register_archive_claims` recorded in `_archive_zip_paths`, so it
follows. Also: the `"vmz", "zip"` match arm in `scan_mod` (security_scan.gd),
the modpack sniff in `collect_mod_metadata` (zip-only by design), the
skip-log literal, and `docs/wiki/Mod-Format.md`. Hazard: `_static_vmz_to_zip`
keys its cache on basename, so `Mod.vmz` and a same-basename alias archive
would collide in `user://vmz_mount_cache`.
