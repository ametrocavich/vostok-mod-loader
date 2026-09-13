# Build

The installable file, `modloader.gd`, is built from the `src/` tree (`src/*.gd` plus `src/registry/*.gd`, 55 files) and is not edited directly. Edit under `src/`, run `./build.sh`, then `./check.sh`.

## build.sh

Source: [build.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh).

Concatenates the source files into one `modloader.gd` at the repo root, with a blank line between files. The order is the `FILES` array, not a filename sort:

```bash
FILES=(
    # Fundamentals (header + module-scope state + log helpers)
    "$SRC/header.gd"
    "$SRC/constants.gd"
    "$SRC/logging.gd"
    # File + archive helpers (no game-specific logic)
    "$SRC/fs_archive.gd"
    # Static-init boot layer
    "$SRC/boot.gd"
    # Mod discovery + loading
    "$SRC/security_scan.gd"
    # Mod-host seam. types -> transport -> dispatch, then one file per host.
    "$SRC/host_types.gd"
    "$SRC/host_http.gd"
    "$SRC/host_api.gd"
    "$SRC/host_mws.gd"
    "$SRC/host_vostokmods.gd"
    "$SRC/host_nexus.gd"
    "$SRC/mod_discovery.gd"
    "$SRC/modpacks.gd"
    "$SRC/hosted_modpacks.gd"
    "$SRC/mod_loading.gd"
    "$SRC/conflict_report.gd"
    # UI
    "$SRC/ui.gd"
    "$SRC/ui_theme.gd"
    "$SRC/ui_dialogs.gd"
    "$SRC/ui_mods.gd"
    "$SRC/ui_browse.gd"
    "$SRC/ui_modpacks.gd"
    "$SRC/ui_updates.gd"
    # Public API (hooks + registry)
    "$SRC/hooks_api.gd"
    # Registry dispatcher + per-section handlers
    "$SRC/registry.gd"
    "$SRC/registry/shared.gd"
    "$SRC/registry/scenes.gd"
    "$SRC/registry/items.gd"
    "$SRC/registry/loot.gd"
    "$SRC/registry/sounds.gd"
    "$SRC/registry/recipes.gd"
    "$SRC/registry/events.gd"
    "$SRC/registry/traders.gd"
    "$SRC/registry/inputs.gd"
    "$SRC/registry/loader.gd"
    "$SRC/registry/ai.gd"
    "$SRC/registry/ai_loadouts.gd"
    "$SRC/registry/fish.gd"
    "$SRC/registry/resources.gd"
    "$SRC/registry/scene_nodes.gd"
    "$SRC/registry/aggregators.gd"
    # Declarative setup() entry point
    "$SRC/setup.gd"
    "$SRC/framework_wrappers.gd"
    # Codegen pipeline
    "$SRC/gdsc_detokenizer.gd"
    "$SRC/pck_enumeration.gd"
    "$SRC/rewriter_parse.gd"
    "$SRC/rewriter_rewrite.gd"
    "$SRC/rewriter_registry_inject.gd"
    "$SRC/rewriter_autofix.gd"
    "$SRC/hook_pack.gd"
    "$SRC/hook_status.gd"
    # Orchestration
    "$SRC/lifecycle.gd"
    "$SRC/main_menu_hook.gd"
    # Temporary debug scaffolding
    "$SRC/debug.gd"
)
```

Earlier files may not reference consts defined later, because GDScript resolves const initializers top to bottom. Function bodies can call anything; the whole file is one class. `host_api.gd` dispatches into adapters listed after it, the same shape `registry.gd` uses for its handlers.

### What build.sh checks

- Every listed file exists, before anything is written.
- The output has exactly one `extends` line (the one in `header.gd`).
- The output has at most one `class_name` (there is none; the loader is the `ModLoader` autoload).

On a failure the `.tmp` is removed and nothing replaces the previous `modloader.gd`.

### Running it

```bash
./build.sh
```

`modloader.gd` is listed in `.gitignore` and never committed. End users get it from GitHub Releases through the installer scripts:

```
/releases/latest/download/modloader.gd
/releases/latest/download/override.cfg
```

## check.sh

Source: [check.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/check.sh). Run it after `build.sh`. It needs a Godot 4.6.1 binary: `GODOT=/path/to/godot ./check.sh`, or `godot` on PATH, or the maintainer's local install path baked into the script.

The script never opens a window and never touches the game. It copies `modloader.gd` into a throwaway project under the system temp dir and runs Godot with `--headless --check-only`, which parses and type-checks and then exits. A 27,000-line single-namespace file fails in ways review does not catch (two files defining the same function, a call to a renamed function, a merge joining halves that were never built together), and any of those is a parse error in an autoload, which means the game does not start.

After the parse, `check.sh` runs two grep invariants and six harnesses. Every harness assembles its own throwaway project, loads a neutered copy of `modloader.gd` (the `_filescope_mounted` initializer replaced by `{}`, so static init cannot run), and exits non-zero on any failed assertion. Each `check_*.sh` also takes `--prove`: it breaks the code under test in the temp copy and requires the harness to fail, which is how you know the gate can fail at all.

| Gate | Runner | What it pins |
|---|---|---|
| await grep | inline in `check.sh` | No `out += ...` line in `src/rewriter*.gd` contains a literal `await`. An unconditional await makes every wrapped vanilla method a coroutine and breaks every caller at parse time; 3.3.0 shipped that. The only legal emission is the `aw` variable, set when the vanilla target is itself a coroutine |
| docs grep | inline in `check.sh` | `docs/wiki/Hooks.md` does not describe the replace callback as always awaited. The 3.3.0 commit documented the bug as intended, in two places |
| `check_codegen.sh` | `tests/codegen/runner.gd` | Runs the real rewriter over 13 fixtures (three synthetic `tests/codegen/Fixture*.gd`, ten decompiled vanilla scripts including `Database.gd`, `Loader.gd`, `Camera.gd`, `Character.gd`) and compiles the pristine source, the rewritten output at its canonical path, and a generated caller stub that invokes every wrapped method without `await`. Also asserts the wrapper signature is byte-identical and a masked rewrite renames only the masked methods. Skips with a banner on machines without the decompiled vanilla source |
| `check_dispatch.sh` | `tests/codegen/dispatch_runner.gd` | Rewrites a synthetic fixture, attaches it to real Nodes, registers hooks through the public API and asserts dispatch behavior: T1 to T12 cover pre, replace with and without `skip_super`, post result mutation and the legacy 2-arg form, deferred callbacks, ordering by priority, replace single-owner, `unhook`, `_caller` across nested calls, re-entrancy guard release, two instances, coroutine vanilla methods, defaulted parameters. Never skips |
| `check_detok.sh` | `tests/detok/runner.gd` | Builds the same token stream as a v101 buffer and as a v100 buffer (indices from 83 shifted down) and requires identical reconstruction; also that no `<tk?>` placeholder appears and `TK_EMPTY` is skipped. T1 to T5. Never skips |
| `check_identity.sh` | `tests/identity/runner.gd` | Filename-stem normalization for mods without `id=`: an extension change or version bump collapses to one identity and the newest wins, distinct mods stay distinct, a declared id still wins, `.pck` never collapses. T1 to T6 |
| `check_host.sh` | `tests/host/runner.gd` | The host seam's pure layer: ModWorkshop and VostokMods normalizers emit every field, the result envelope, the `provider:id` grammar rejects instead of guessing, on-disk source records of every era converge in one pass, the legacy `modworkshop_id` mirror is written only for ModWorkshop, and every declared capability has a dispatch arm. T1 to T9 |
| `check_boot_state.sh` | `tests/boot_state/runner.gd` | The crash-loop breaker: the streak survives the crashed-Pass-2 wipe, one crash does not trip it, `MAX_RESTART_COUNT` crashes do, a clean finish resets it to zero, and Pass 2 clears it after the crash window (checked against the built source text). T1 to T6 |

Each runner prints its assertion count on success (`[host] PASS: N assertion(s) across T1..T9`); the counts are computed at run time, not fixed.

Godot is pinned at 4.6.1-stable in `check.sh`, `ci.yml` and `release-please.yml`. Move all three together.

## Continuous integration

Source: [.github/workflows/ci.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/ci.yml).

Runs on every pull request and on pushes to `master` and `refactor/**`. It downloads Godot 4.6.1 (cached by version), runs `./build.sh`, then `./check.sh`. The harnesses that need the decompiled game source skip themselves with a banner, so the run is meaningful without shipping game files into CI.

## release-please

Source: [.github/workflows/release-please.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/release-please.yml).

Automates the version bump and the changelog from [Conventional Commits](https://www.conventionalcommits.org/).

### Flow

1. A PR merges to `master`.
2. `release-please-action@v4` parses the Conventional Commits since the last tag (`release-please-config.json`, `.release-please-manifest.json`).
3. It opens a release PR ("chore(master): release 3.3.1" or similar) that bumps `MODLOADER_VERSION` in `src/constants.gd` and updates `CHANGELOG.md`. That constant is the only file release-please edits.
4. Merging the release PR creates the tag and a draft GitHub Release.
5. The same workflow then runs `./build.sh`, downloads Godot and runs `./check.sh` against the exact bytes about to ship (release-please rewrote `constants.gd` on the way in, so no PR compiled this file), uploads `modloader.gd`, `override.cfg`, `windows-installer.bat` and `linux-installer.sh` as release assets, and only then flips the release from draft to published.

The draft step matters. From the moment a release is published, `/releases/latest/download/modloader.gd` resolves to it, and both installers fetch that URL. A build or upload failure on a published release left every new install failing on a 404.

Normal pushes to `master` do not build anything; only a release creation does.

### Version-bump mapping

| Type | Bump | Example |
|---|---|---|
| `feat:` | minor (3.3.1 -> 3.4.0) | new feature or user-facing behavior |
| `fix:` | patch (3.3.1 -> 3.3.2) | bug fix |
| `feat!:` / `fix!:` | major (3.3.1 -> 4.0.0) | breaking change |

`chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `build:`, `ci:` and `style:` do not bump; they appear under "Miscellaneous" in the changelog.

### Where the version lives

One line in `src/constants.gd`:

```gdscript
# x-release-please-start-version
const MODLOADER_VERSION := "3.3.1"
# x-release-please-end
```

Mods read it at runtime:

```gdscript
var lib = Engine.get_meta("RTVModLib")
if lib.major_version() >= 3:
    use_new_api()
```

The accessors are static functions at the top of [hooks_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hooks_api.gd): `version() -> String`, `major_version() -> int`, `minor_version() -> int`, `patch_version() -> int`.

## Branch model

From [CONTRIBUTING.md](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md):

- `development` is the target for contributor PRs. Feature branches squash-merge into it, so each PR is one conventional commit.
- `master` is the release branch. Only maintainer PRs from `development` land there, by rebase-merge, so release-please sees every commit.

Contributor workflow: branch off `development`, PR against `development`, title the PR `<type>: <description>`. On merge it becomes one squashed commit.

When it is time to release, the maintainer opens a `development -> master` PR. After the rebase-merge the SHAs on `master` differ from the ones on `development`, so `development` is reset to `origin/master`; otherwise the two drift apart silently.

## Wiki sync

The wiki is generated from [docs/wiki/*.md](https://github.com/ametrocavich/vostok-mod-loader/tree/development/docs/wiki) by [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml).

The workflow runs on a push to `development` or `master` that touches `docs/wiki/**` (and on manual dispatch). It clones `<repo>.wiki.git` with the default `GITHUB_TOKEN` (`contents: write`), rsyncs `docs/wiki/` into the clone with `--delete`, and pushes one commit named after the source SHA. The wiki repository counts as repo content, so no PAT is needed.

To change a page, PR the edit to `docs/wiki/*.md` on `development`. The wiki updates on merge.
