# Contributing

Start here when changing the loader. For writing a mod, use the
[mod-author guide](docs/wiki/Home.md#writing-a-mod).

## First build

Use Bash (Git Bash on Windows), Godot 4.6.1 and Python 3.9 or newer. Python
uses only its standard library. Run from the repository root:

```bash
./build.sh
GODOT=/path/to/godot ./check.sh
```

On Windows, use the console Godot executable and a Git Bash path such as
`/c/Tools/Godot/godot_console.exe`. `GODOT` is optional if `godot` is on PATH.
Set `PYTHON=/path/to/python` if automatic Python detection chooses the wrong
interpreter. Use a dedicated test engine directory: the boot-state harness
briefly writes `override.cfg` beside that executable and refuses an existing
file. The checks run headlessly; they do not launch the game or editor.

A complete run prints eight `OK:` lines. The two synthetic codegen fixtures
always run; ten additional fixtures run when decompiled game source is
available through `VANILLA_SRC`. [Build and checks](docs/wiki/Build.md)
describes coverage, environment variables and failure diagnosis.

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

- [Development](docs/wiki/Development.md): task-to-code map, state ownership,
  common edit recipes and debugging workflow.
- [Modules](docs/wiki/Modules.md): every source fragment and its responsibility.
- [Architecture](docs/wiki/Architecture.md): boot, restart and persistent state.

## Make a change

1. Find the owning function and its callers. Search with `rg` or the editor's
   workspace search; functions can call across any source fragment.
2. Add a regression case to the closest existing harness for a behavior fix.
   Keep mechanical moves separate from behavior changes.
3. Update the matching page in `docs/wiki/` when a contract, flow or label
   changes. `check.sh` checks local links and linked function ownership;
   reviewing the meaning of the prose is still part of the change.
4. Run `./build.sh && ./check.sh`. `check.sh` does not run `build.sh`: on its
   own it tests the `modloader.gd` left by the previous build, so a stale
   artifact passes and gets deployed. For harness changes, also run that
   script with `--prove` to check that its intentional failure is caught.
5. Record any required in-game smoke test separately. The headless gates do
   not cover the launcher UI, real downloads or the complete restart flow.

## Branches and PR titles

Contributor PRs target `development` and squash-merge. Maintainer release
PRs from `development` to `master` rebase-merge so release-please sees each
commit. CI checks every PR and pushes to `master` and `refactor/**`.

### PR titles

Use an imperative Conventional Commit title, optionally with a scope:
`fix(profiles): preserve missing mod entries`. Keep a PR about one change.

| Type | Release effect |
|---|---|
| `feat` | Minor version |
| `fix`, `perf` | Patch version |
| `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `style` | No version bump |
| `!` after the type/scope, or a `BREAKING CHANGE:` footer | Major version |

Update formats and their documentation together. Release preparation and
manual acceptance are in [the release checklist](docs/RELEASE_CHECKLIST.md);
[Build](docs/wiki/Build.md#release-please) describes release automation.
