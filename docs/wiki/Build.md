# Build

The installable artifact `modloader.gd` is **built** from `src/*.gd` -- not edited directly. The editing surface is the `src/` tree; `modloader.gd` is produced on demand.

## build.sh

Source: [build.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh).

Concatenates `src/*.gd` into a single `modloader.gd` at the repo root. Explicit ordering (not filename-based sort) is in the `FILES` array:

```bash
FILES=(
    "$SRC/header.gd"
    "$SRC/constants.gd"
    "$SRC/logging.gd"
    "$SRC/fs_archive.gd"
    "$SRC/boot.gd"
    "$SRC/mod_discovery.gd"
    "$SRC/mod_loading.gd"
    "$SRC/conflict_report.gd"
    "$SRC/ui.gd"
    "$SRC/hooks_api.gd"
    "$SRC/registry.gd"
    "$SRC/framework_wrappers.gd"
    "$SRC/gdsc_detokenizer.gd"
    "$SRC/pck_enumeration.gd"
    "$SRC/rewriter.gd"
    "$SRC/hook_pack.gd"
    "$SRC/lifecycle.gd"
    "$SRC/debug.gd"
)
```

Dependencies flow top-down -- earlier files may not reference code defined later. This mirrors how GDScript parses a file.

### Invariants enforced by build.sh

Post-concat sanity checks ([build.sh:57-69](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh#L57)):

- **Exactly one `extends` line**, and it must be at the very top ([header.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/header.gd)).
- **At most one `class_name`** declaration (currently there is none -- the loader is ModLoader autoload).

Missing source file aborts before concat ([build.sh:46-48](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh#L46)).

### Running it

```bash
./build.sh
```

Produces `modloader.gd` at the repo root. Run after any `src/` edit and before testing in-game.

`modloader.gd` is **not committed** (see `.gitignore`). It's downloaded from GitHub Releases by end users via the installer scripts:

```
/releases/latest/download/modloader.gd
/releases/latest/download/override.cfg
```

## release-please

Source: [.github/workflows/release-please.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/release-please.yml).

Automates version bumps and changelog generation from [Conventional Commits](https://www.conventionalcommits.org/).

### Flow

1. PR merges to `master`.
2. `release-please-action@v4` parses Conventional Commits since the last tag.
3. Opens a follow-up PR titled something like "chore(main): release 2.3.2" that bumps `MODLOADER_VERSION` in [src/constants.gd:13](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L13) and updates `CHANGELOG.md`.
4. Merging that PR creates the git tag + GitHub Release.
5. On release creation, the workflow rebuilds `modloader.gd` via `./build.sh` and uploads it (plus `override.cfg`) as release assets.

The workflow only rebuilds on release creation -- normal `master` pushes don't trigger a build.

### Version-bump mapping

From [CONTRIBUTING.md](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md):

**Triggers a bump:**

| Type | Bump | Example |
|---|---|---|
| `feat:` | minor (2.3.0 -> 2.4.0) | new feature or user-facing behavior |
| `fix:` | patch (2.3.0 -> 2.3.1) | bug fix |
| `feat!:` / `fix!:` | major (2.3.0 -> 3.0.0) | breaking change |

**No bump** (appears under "Miscellaneous" in changelog):

`chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `build:`, `ci:`, `style:`.

### Where the version lives

The bump is applied by release-please to a single line:

```gdscript
# x-release-please-start-version
const MODLOADER_VERSION := "2.3.1"
# x-release-please-end
```

Mods read the version at runtime via:

```gdscript
var lib = Engine.get_meta("RTVModLib")
if lib.major_version() >= 3:
    use_new_api()
```

Accessors ([hooks_api.gd:9-19](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd#L9)): `version() -> String`, `major_version() -> int`, `minor_version() -> int`, `patch_version() -> int`. All static.

## Branch model

From [CONTRIBUTING.md](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md):

- **`development`** -- target for all contributor PRs. Feature branches merge here via **squash** (keeps each PR as a single clean conventional commit).
- **`master`** -- release branch. Only maintainer PRs from `development -> master` land here, via **rebase-merge** so every individual commit is preserved for release-please to read.

Contributor workflow:

1. Branch off `development`.
2. PR against `development`.
3. PR title follows `<type>: <description>` (release-please reads this).
4. On merge: squashed into one commit on `development`.

Maintainers batch accumulated work into a `development -> master` PR when it's time to cut a release. Rebase-merge preserves individual commits so release-please can build an accurate changelog.

## Wiki sync

This wiki is generated from [docs/wiki/*.md](https://github.com/ametrocavich/vostok-mod-loader/tree/development/docs/wiki) via [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml).

The workflow triggers on push to `development` or `master` when `docs/wiki/**` changes. It clones `<repo>.wiki.git` using the default `GITHUB_TOKEN` (scoped to `contents: write`), rsyncs `docs/wiki/` into the clone with `--delete`, and pushes a commit. Since the wiki git repo is considered part of the repo's content scope, no PAT is needed.

To edit a page, PR changes to `docs/wiki/*.md` on `development`. The wiki updates itself on merge.
