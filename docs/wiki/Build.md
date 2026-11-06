# Build and checks

The editing surface is `src/`. The installed file, `modloader.gd`, is generated
and ignored by Git. [CONTRIBUTING](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md)
is the first-build guide; [Development](Development) maps changes to source.

## Prerequisites and commands

Use Bash (Git Bash on Windows), Godot 4.6.1 and Python 3.9 or newer (standard
library only). From the repo root:

```bash
./build.sh
GODOT=/path/to/godot ./check.sh
```

| Variable | Purpose |
|---|---|
| `GODOT` | Engine executable; else `godot` on PATH, else `.check.env`. On Windows use the console executable, as a Git Bash path such as `/c/Tools/Godot/godot_console.exe`. |
| `PYTHON` | Interpreter for the documentation check; else `python` or `python3`, whichever is 3.9 or newer. |
| `VANILLA_SRC` | A decompiled Road to Vostok project for the ten vanilla codegen fixtures; else `.check.env`. Without it those fixtures are skipped and the three synthetic ones still run. |

`.check.env` in the repo root (ignored by Git) holds personal paths such as
`GODOT=...` and `VANILLA_SRC=...`; a variable already set in the environment
wins. Use a dedicated Godot directory: the boot-state harness creates and
removes `override.cfg` beside the engine executable and refuses to run if one
exists. Harnesses write only their own `user://` state; they open no window
and never run the game.

## Assembly and source navigation

The `FILES` array in [build.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh)
is the assembly order; `./build.sh --list` prints it. Each fragment is preceded
by a `# source: src/...` marker, which lets a line of a built-file error be
translated back, given the same build:

```bash
python tools/dev.py locate 12345
python tools/dev.py find _save_ui_config
```

`find` matches definition names, partial names included. `locate` prints
`path:line` and warns when the current source line differs from the build.

The build fails unless every listed file exists and the result has exactly one
top-level `extends` and at most one `class_name`. It writes a temporary file
and replaces the artifact only on success, and drops carriage returns, so a
CRLF checkout builds the same bytes as the Linux release job.

## The checks

[check.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/check.sh)
tests the `modloader.gd` on disk and never builds it: after a source edit run
`./build.sh` first, or the checks pass against a stale artifact. Success is
eleven lines starting with `OK:`. Two come from `check.sh` itself:

- Parse: headless `--check-only` over the built loader in a throwaway project.
- Invariants and docs: no CR byte in the build, no `await` in a string literal
  of `src/rewriter*.gd` outside the `is_coro`-gated `aw` line, no wrong await
  contract in [Hooks](Hooks), [Hook Surface](Hook-Surface) or
  [Hook Pack](Hook-Pack), and
  `python tools/dev.py check-docs` (links, heading anchors, `src/` paths, a
  function named in a link label defined in the linked file, every source file
  in [Modules](Modules), plain ASCII in the docs, sources, tests, tools and
  shell scripts, identical listing bodies). It does not
  check prose or external sites.

Then it runs the nine harness scripts in turn; each one is a short script over
the helpers in `tests/lib.sh`:

| Script | Runner | Covers |
|---|---|---|
| `check_codegen.sh` | `tests/codegen/runner.gd` | Rewritten vanilla and synthetic scripts compile, callers too; registry markers, injected code and the compile probe. |
| `check_dispatch.sh` | `tests/codegen/dispatch_runner.gd` | Hook order, replace, post, deferred and coroutine dispatch; registry and `setup()` verbs. |
| `check_detok.sh` | `tests/detok/runner.gd` | Bytecode v100 and v101 reconstruction, the PCK reader, canaries B and C. |
| `check_identity.sh` | `tests/identity/runner.gd` | Filename stems, duplicate winners, profile defaults and key migration. |
| `check_host.sh` | `tests/host/runner.gd` | Host records and dispatch, source precedence, cooldowns, listing shapes. |
| `check_profiles.sh` | `tests/profiles/runner.gd` | Packs, hosted pack slots, profiles, MCM snapshots, the reopened launcher. |
| `check_mods.sh` | `tests/mods/runner.gd` | Scan to load on real archives, dependency order, downloads, updates, deletes. |
| `check_boot_state.sh` | `tests/boot_state/runner.gd` | Crash streak, state hash, game-update detection, hook pack build, activation and canary A. |
| `check_ui.sh` | `tests/ui/runner.gd` | The launcher built headless; its structural dump must equal `tests/ui/baseline.txt`. |

Each harness builds a throwaway project, replaces the loader's boot initializer
with `{}` in the test copy and calls loader functions directly. The runtime
harnesses fail on any `SCRIPT ERROR`; codegen compares baseline and rewritten
compilation instead, because decompiled game scripts log errors outside the
game. `./check_ui.sh --update-baseline` rewrites the UI baseline and prints the
diff to review.

A green run does not cover pixels, live hosts, the installers or a full game
restart; the [release checklist](https://github.com/ametrocavich/vostok-mod-loader/blob/development/docs/RELEASE_CHECKLIST.md)
holds the manual acceptance. Three in-game tools sit under `tests/ingame/`,
each with its commands in its README or header: the `build2` and `lts` kits
(test mods that print PASS and FAIL lines, graded from the game log by
`evaluate.py`), and `rehearse_build.sh`, which checks a new game build against
the rewriter and the fallback class map without launching the game.

## Diagnose and extend a check

Run the failing harness alone; `--prove` mutates the temporary loader copy and
requires the named failure:

```bash
./check_host.sh
./check_host.sh --prove
```

Only `check_boot_state.sh` runs the clean harness before the mutation, so run
the plain harness first: a baseline that already fails can still print
`PROVE-OK`. `--prove` tests the gate's failure detection, not every bug in its
subject. Each script names its temporary `WORK` directory; the runner log and
generated files are there.

Add a case to the closest runner ([Development](Development#testing-a-change)
describes the scaffolding) and keep the runner's call list and id range in
step; a codegen fixture is a `tests/codegen/Fixture*.gd` file listed in `FIXTURES`.
Keep the eleven top-level checks.

## Continuous integration

[ci.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/ci.yml)
runs on every PR and on pushes to `master` and `development`: it downloads
Godot, builds and runs the same checks, without a decompiled corpus. The
`GODOT_VERSION` pins in the CI and release workflows change together.
[wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml)
publishes `docs/wiki/` to the GitHub wiki on a push that touches it, deleting
pages that are gone, so renaming a page changes its URL.

## release-please

[release-please.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/release-please.yml)
turns the [Conventional Commits](https://www.conventionalcommits.org/) merged to
`master` into a release PR that bumps `MODLOADER_VERSION` in `src/constants.gd`
(between the `x-release-please-start-version` and `x-release-please-end`
markers) and updates `CHANGELOG.md`. Merging that PR tags a draft release; the
workflow then builds, checks and uploads the assets before publishing it. The
[release checklist](https://github.com/ametrocavich/vostok-mod-loader/blob/development/docs/RELEASE_CHECKLIST.md)
owns the release steps, and CONTRIBUTING owns the
[PR titles](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md#pr-titles)
that decide the bump and the
[branch model](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md#branches-and-pr-titles).
