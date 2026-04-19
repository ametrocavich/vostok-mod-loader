# Contributing

## Repository layout

The installed artifact (`modloader.gd`) is **built from source**, not edited
directly. The editing surface lives in `src/`:

```
src/
├── header.gd              # extends Node, top-of-file doc
├── constants.gd           # all const + module-scope var declarations
├── logging.gd             # _log_info/warning/critical/debug
├── fs_archive.gd          # file/archive helpers, mod.txt parsing
├── boot.gd                # static-init, override.cfg, pass state, heartbeat
├── mod_discovery.gd       # scan mods, parse metadata, ordering, ModWorkshop
├── mod_loading.gd         # mount + apply mods at runtime
├── conflict_report.gd     # developer-mode diagnostics
├── ui.gd                  # launcher window + tabs
├── hooks_api.gd           # public hook + version API
├── registry.gd            # registry API (under construction)
├── framework_wrappers.gd  # legacy extends-wrapper path (to be removed)
├── gdsc_detokenizer.gd    # .gdc -> source reconstruction
├── pck_enumeration.gd     # PCK introspection + class_name map
├── rewriter.gd            # source-rewrite codegen
├── hook_pack.gd           # hook pack generator + activator
├── lifecycle.gd           # _ready + pass orchestration
└── debug.gd               # test scaffolding (gated behind config flag)
```

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
