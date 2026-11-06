# Contributing

Start here when changing the loader. For writing a mod, use the
[mod-author guide](docs/wiki/Home.md#writing-a-mod).

## First build

Use Bash (Git Bash on Windows), Godot 4.6.1 and Python 3.9 or newer, then run
from the repository root:

```bash
./build.sh
GODOT=/path/to/godot ./check.sh
```

A complete run prints eleven `OK:` lines: `check.sh` parse-checks
`modloader.gd`, checks the source and documentation invariants, then runs the
nine `check_*.sh` scripts in a loop (codegen, dispatch, detok, identity, host,
profiles, mods, boot_state, ui). [Build and checks](docs/wiki/Build.md)
covers `GODOT`, `PYTHON`, `VANILLA_SRC`, the untracked `.check.env` and
failure diagnosis.

The check scripts share `tests/lib.sh` (engine and Python lookup, the temp
project, `--prove` mutations; `run_simple_check` is a whole check script).
The runners share `tests/common/`: `runner_base.gd` is the base every runner
extends, `harness.gd` holds the report and assertion helpers, and
`stub_loader.gd` is the loader with its network calls replaced by fixtures.

## Find the code to change

Edit `src/`, then rebuild. `modloader.gd` is the generated release artifact
and is not committed. All source fragments become one GDScript class;
filenames organize responsibilities, not separate runtime objects.

```bash
python tools/dev.py find _save_ui_config
python tools/dev.py locate 12345
./build.sh --list
```

`find` prints definitions with their source locations. `locate` translates a
line from a generated-file error using the current build's source markers;
use the build that produced the error. `--list` prints assembly order.
[Development](docs/wiki/Development.md) maps tasks to code,
[Modules](docs/wiki/Modules.md) lists every source fragment and
[Architecture](docs/wiki/Architecture.md) explains boot, restart and
persistent state.

## Make a change

1. Find the owning function and its callers; functions can call across any
   source fragment.
2. Follow [Style](docs/wiki/Style.md) for comments, names, guards and tests.
3. Add a regression case to the closest existing runner for a behavior fix.
   Keep mechanical moves separate from behavior changes.
4. Update the matching page in `docs/wiki/` when a contract, flow or label
   changes. `python tools/dev.py check-docs` (part of `check.sh`) checks
   links, anchors, function names linked to their source file, `src/` paths,
   the module index, plain ASCII and the shared listing body; the meaning of
   the prose is yours to review.
5. Run `./build.sh && ./check.sh`. `check.sh` does not build: on its own it
   tests the `modloader.gd` left by the previous build. For harness changes,
   also run that script with `--prove` to check that its mutation is caught.
6. Record any required in-game smoke test separately. The headless gates do
   not press launcher buttons, download for real or run the restart. The
   in-game kits are [tests/ingame/lts](tests/ingame/lts/README.md) and
   [tests/ingame/build2](tests/ingame/build2/README.md).

The wiki is `docs/wiki/`, published to the GitHub Wiki by
`.github/workflows/wiki-sync.yml` on each push to `development` or `master`
that touches it. The sync mirrors the folder, so a renamed or deleted page
disappears from the wiki. Edit pages here, never on the wiki.

## Branches and PR titles

Contributor PRs target `development` and squash-merge. Maintainer release
PRs from `development` to `master` rebase-merge so release-please sees each
commit. The rebase gives the commits on `master` new SHAs, so after each
release merge `development` is reset to `origin/master`; otherwise the two
drift apart silently. CI checks every PR and pushes to `master` and
`development`.

### PR titles

Use an imperative Conventional Commit title, optionally with a scope:
`fix(profiles): preserve missing mod entries`. Keep a PR about one change.

| Type | Release effect |
|---|---|
| `feat` | Minor version |
| `fix`, `perf` | Patch version |
| `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `style` | No version bump |
| `!` after the type/scope, or a `BREAKING CHANGE:` footer | Major version |

Release preparation, the release workflow and manual acceptance are in
[the release checklist](docs/RELEASE_CHECKLIST.md).
