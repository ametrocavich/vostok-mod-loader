# Contributing

## Repository layout

The installed artifact (`modloader.gd`) is **built from source**, not edited
directly. The editing surface lives in `src/`:

```
src/
  header.gd              # extends Node, top-of-file doc (the only extends)
  constants.gd           # all const + module-scope var declarations
  logging.gd             # _log_info/warning/critical/debug
  fs_archive.gd          # file/archive helpers, mod.txt parsing, vmz cache
  boot.gd                # static-init, override.cfg, pass state, heartbeat
  security_scan.gd       # pre-mount notable-API scan of mod archives
  mws_api.gd             # ModWorkshop REST client (Browse + downloads)
  mod_discovery.gd       # scan mods, parse metadata, ordering, updates
  modpacks.gd            # modpack scan/apply/unload + restore points
  mod_loading.gd         # mount + apply mods at runtime
  conflict_report.gd     # developer-mode diagnostics
  ui.gd                  # launcher window + tabs
  hooks_api.gd           # public hook + version + mod-info API
  registry.gd            # registry verb dispatchers + Registry const
  registry/              # 15 per-section handlers + shared.gd helpers (16 files)
  setup.gd               # declarative lib.setup(plan) entry point
  framework_wrappers.gd  # scene-tree class walker for hook-pack verify
  gdsc_detokenizer.gd    # .gdc -> source reconstruction
  pck_enumeration.gd     # PCK introspection + class_name map
  rewriter.gd            # source-rewrite codegen
  hook_pack.gd           # hook pack generator + activator
  lifecycle.gd           # _ready + pass orchestration
  main_menu_hook.gd      # in-game Mods button on the RTV main menu
  debug.gd               # test scaffolding (gated behind config flag)
```

The list mirrors `build.sh`'s `FILES` order (the concat order); `docs/wiki/Modules.md` has the per-file tour.

### Building locally

```bash
./build.sh
```

Produces `modloader.gd` at the repo root by concatenating `src/*.gd` in the
order defined in `build.sh`'s `FILES` array. Run after any source change and
before testing in-game.

`modloader.gd` is **not committed** to the repo, it's a build artifact
shipped as a release asset. The installer scripts download it from
`/releases/latest/download/modloader.gd`.

## Branches

- **`development`**: target for all contributor PRs. Feature branches merge
  here via squash (keeps each PR as a single clean conventional commit).
- **`master`**: release branch. Only maintainer PRs from
  `development → master` land here, via rebase-merge so every individual
  commit is preserved for release-please to read.

If you're contributing, open your PR against `development`. Maintainers batch
accumulated work into a PR to `master` when it's time to cut a release.

## Conventional Commits

This repo uses [Conventional Commits](https://www.conventionalcommits.org/) to
drive automatic version bumps and changelog generation via
[release-please](https://github.com/googleapis/release-please). When a PR
merges to `master`, release-please opens a follow-up PR that bumps
`MODLOADER_VERSION` in `src/constants.gd` and updates `CHANGELOG.md`. Merging
that PR creates the git tag and GitHub Release (with a freshly built
`modloader.gd` attached as an asset).

### PR titles

The PR title becomes the commit title on merge (squash) or lands as-is
(rebase). It needs to follow this format:

```
<type>: <description>
```

**Triggers a version bump:**

| Type | Bump | When to use |
|------|------|-------------|
| `feat:` | minor (2.3.0 → 2.4.0) | New feature or user-facing behavior |
| `fix:` | patch (2.3.0 → 2.3.1) | Bug fix, no new functionality |
| `feat!:` or `fix!:` | major (2.3.0 → 3.0.0) | Breaking change (API rename, removed feature, etc.) |

**No version bump** (still appears in changelog under "Miscellaneous"):

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

Add `!` after the type (or include `BREAKING CHANGE:` in the PR body) to
trigger a major bump. Describe what breaks in the PR body so the changelog
entry is useful.

### Branch naming

No specific format required release-please only reads commit/PR titles, not
branch names. Name your feature branches whatever makes sense.

## Checklist before opening a PR

- [ ] Edited `src/*.gd` files, not `modloader.gd` directly
- [ ] Ran `./build.sh` and tested in-game
- [ ] PR title follows `<type>: <description>`
- [ ] PR targets `development` (not `master`)

## Extending the loader

`modloader.gd` is one flat-namespace script: every top-level func/var/const in
`src/*.gd` is global across files, duplicate names break the build, and a const
referenced by another const's initializer must appear earlier in `build.sh`'s
`FILES` order. The maps below list every file + function you must touch for the
most common extension jobs (verified against the 3.3 source). Function names
are stable anchors; line numbers are not. See `docs/wiki/Modules.md` for the
per-file tour.

### Adding a mod.txt key or section (scan-time metadata)

- `src/mod_discovery.gd: _entry_from_config` -- parse the new key from the
  ConfigFile and store it on the entry Dictionary.
- `src/mod_discovery.gd: _build_entry_warnings` -- derive a row warning from
  it. The Mods tab renders `entry["warnings"]` generically, so no UI edit.
- `docs/wiki/Mod-Format.md` -- document the section.
- If the section changes LOADING (not just metadata), also
  `src/mod_loading.gd: _process_mod_candidate` -- that is where `[hooks]`,
  `[registry]`, `[script_extend]`, and `[autoload]` are consumed.

`mod.txt` itself is parsed by `_parse_mod_txt` in `src/fs_archive.gd`
(ConfigFile syntax, plus an empty-section sentinel workaround for
`[registry]`). Entry Dictionaries are consumed BY KEY NAME across ui.gd,
mod_loading.gd, boot.gd, and modpacks.gd -- new keys are additive-safe,
renames are not.

### Adding a download surface

Existing surfaces: Browse "Get" + queue (ui.gd -> `download_new_mod`), Mods-tab
update badges (`download_and_replace_mod`), Updates-tab Download/Retry
(`download_and_replace_mod`), missing-mod stub Download (ui.gd ->
`download_new_mod`), modpack missing-mod fetch (modpacks.gd ->
`download_new_mod(mws_id, version, true)`). The authoritative map lives above
the download entry points in `src/mod_discovery.gd`.

- `src/mod_discovery.gd: download_new_mod` currently fuses ModWorkshop
  file-record resolution with the generic fetch/validate/install tail
  (Content-Disposition filename derivation, `_is_safe_mod_filename`, collision
  rename, `.download` temp file, zip/pck validation, rename-finalize). A
  non-ModWorkshop surface (e.g. install-from-URL) needs that tail split out
  first -- do not copy-paste it.
- After a successful install: `_reload_entries_for_active_profile()` then
  `_rebuild_mods_tab(tabs)` (the Browse Get handler shows the pattern,
  including the `is_instance_valid` guards for a closed launcher window).

### Adding a registry section

1. `src/registry.gd`: add a `Registry.FOO` constant.
2. `src/registry.gd`: add a match arm in EACH dispatcher -- `register`,
   `override`, `patch`, `_array_op_dispatch` (covers append / prepend /
   remove_from), `remove`, `revert`, `get_entry`, and `_enumerate_vanilla`
   (pure-mod sections join the shared `return {}` arm). An omitted arm does
   not fail soft: the fallthrough warns "unknown registry", which reads as a
   loader bug. Verbs the section rejects need explicit not-supported arms
   (see `resources` / `scene_nodes` in `register`).
3. Create `src/registry/foo.gd` with the verb implementations. Copy the
   closest shape: `fish.gd` is the smallest (register/remove only),
   `events.gd` is the full array-backed pattern.
4. Add the file to `build.sh`'s `FILES` array after `registry/shared.gd`.
5. Document it in `docs/wiki/Registry.md`.

`setup.gd` and the `*_many` batch verbs route through the same dispatchers --
no extra edits there.

### Adding a profile.json / share-payload field

The metroprofile v1 payload has ONE writer and TWO parsers:

- writer: `src/ui.gd: _profile_to_json_string`. The live caller is the
  modpack zip export (`save_profile_as_modpack` ->
  `_export_profile_to_zip`); the share-string builder `_profile_to_payload`
  also routes through it but is not wired to any UI yet (latent surface).
- parser 1: `src/ui.gd: _import_profile_from_parsed`. Reached via
  `_import_profile_from_zip`; share strings are decoded separately by
  `_parse_profile_payload` (parse/validate only -- it does not call the
  importer). None of these is wired to UI yet, but they parse the same
  payload, so keep them in sync or the field silently drops the day that
  surface ships.
- parser 2: `src/modpacks.gd: _materialize_modpack_profile` (modpack apply
  -- the live read path).

A field handled by the writer but only one parser silently drops on the other
path. If the field is per-mod state stored in `mod_config.cfg` profile
sections, also touch: `_save_ui_config` (including its hidden-folder
preservation block), `_apply_profile_to_entries`, the
`[".enabled", ".priority", ".settings", ".dep_ignore"]` suffix sweeps in
`_delete_active_profile` / `_rename_profile`, and the per-key cleanup in
`_delete_mod_file_and_cleanup`. Decide explicitly whether the field rides the
modpack backup/unload round-trip -- the backup copy in `apply_modpack` and the
restore in `unload_modpack` move ONLY `.enabled` / `.priority`, by design.
New fields must stay optional (forward-compat rules in
`docs/wiki/Profile-Format.md`) and be documented there.

### Adding an archive extension

The accept set `["vmz", "zip", "pck"]` lives in TWO places that must not
drift: the scan filter in `collect_mod_metadata` and the download-name gate
`_is_safe_mod_filename` (both `src/mod_discovery.gd`). Mount-side, Godot's
`load_resource_pack` only recognizes literal `.pck` / `.zip`, so any other
extension needs the vmz-style cache-copy fallback in THREE places:
`_try_mount_pack` (fs_archive.gd), the static remount loop in
`_mount_previous_session` (boot.gd), and the cached-zip sibling resolution in
`_generate_hook_pack` (hook_pack.gd). Also: the `"vmz", "zip"` match arm in
`scan_mod` (security_scan.gd), the modpack sniff in `collect_mod_metadata`
(zip-only by design), the skip-log literal, and `docs/wiki/Mod-Format.md`.
Hazard: `_static_vmz_to_zip` keys its cache on basename, so `Mod.vmz` and a
same-basename alias archive would collide in `user://vmz_mount_cache`.
