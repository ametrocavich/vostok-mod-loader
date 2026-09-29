# Build and checks

The editing surface is `src/`. The installed file, `modloader.gd`, is generated
and ignored by Git. [CONTRIBUTING](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md)
is the first-build guide; [Development](Development) maps changes to source.

## Prerequisites and commands

Use Bash (Git Bash on Windows), Godot 4.6.1 and Python 3.9 or newer. Python
uses its standard library; there are no packages to install. From the repo root:

```bash
./build.sh
GODOT=/path/to/godot ./check.sh
```

| Variable | Purpose |
|---|---|
| `GODOT` | Engine executable. If unset, scripts try `godot` on PATH, then a maintainer-specific Windows path. On Windows use the console executable, with a Git Bash path such as `/c/Tools/Godot/godot_console.exe`. |
| `PYTHON` | Interpreter for documentation checks. If unset, `check.sh` tries `python` and `python3`, requiring version 3.9 or newer. |
| `VANILLA_SRC` | Decompiled Road to Vostok project for the ten vanilla codegen fixtures. The codegen script has a maintainer-specific default; missing source leaves these fixtures out. The two synthetic fixtures always run. |

Use a dedicated Godot test directory. The boot-state harness creates and
removes `override.cfg` beside the engine executable and refuses to run if
that file already exists. Harnesses also write their own `user://` test
state. They do not open windows, run the game or use its save directory.

## Assembly and source navigation

Source: [build.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/build.sh).
The `FILES` array is the authoritative assembly order. Print it with:

```bash
./build.sh --list
```

Each fragment is preceded by a `# source: src/...` marker. To translate a
line from a built-file error, use the matching build:

```bash
python tools/dev.py locate 12345
python tools/dev.py find _save_ui_config
```

Every fragment shares one class. Constants used by other constant
initializers must come first; function bodies can call functions later in
the file. The build checks that every listed file exists, that the result
has exactly one top-level `extends`, and that it has at most one top-level
`class_name`. It writes a temporary file and replaces the artifact only on
success. Carriage returns are dropped from every fragment, so a Windows
checkout with CRLF sources builds the same bytes as the release job, which
runs on Linux from LF blobs. Parsing and behavior checks are the next step.

## The eight checks

Source: [check.sh](https://github.com/ametrocavich/vostok-mod-loader/blob/development/check.sh).
Run it after every build. `check.sh` does not run `build.sh`: it tests the
`modloader.gd` already on disk, however old, and only a missing file makes it
ask for a build. After a source edit always run `./build.sh` first, or the
checks pass against a stale artifact. Success prints eight lines starting with `OK:`:

| Check | Runner | Coverage |
|---|---|---|
| Parse | Inline in `check.sh` | Headless `--check-only` parses and type-checks the assembled loader in a throwaway project. Catches duplicate definitions, unresolved names and incompatible types. |
| Static invariants and docs | Inline greps and `tools/dev.py check-docs` | The built file holds no CR byte (a local build must match the LF release build). Wrapper templates emit `await` only through the coroutine-gated variable; Hooks.md must describe that contract. Checks local/repository Markdown targets, source paths, linked definition ownership and module-index coverage. It does not verify prose, URL fragments or external sites. |
| Code generation | `tests/codegen/runner.gd` | Two synthetic and, when available, ten vanilla fixtures. Compiles original source, rewritten source and caller stubs; checks signatures, coroutine behavior and masked rewrites. `_check_vetting` runs the pre-ship compile probe on every fixture: each real rewrite must vet as `full`; five vanilla scripts with a renamed member (`GAME_RENAMES`) must ship wrap-only, compile, carry no registry code and record the demotion; a `Database.gd` with no const preloads must still ship hooked, without the scenes appendix; a rewrite that compiles in no form is excluded; persisted verdicts are repeated unprobed. |
| Dispatch | `tests/codegen/dispatch_runner.gd` | T1 to T23: hook ordering, replacement, post hooks, deferred calls, re-entrancy, defaults and coroutines; registry/setup operations; coroutine detection that ignores `await` inside strings and comments. |
| Detokenizer | `tests/detok/runner.gd` | T1 to T11: v100/v101 reconstruction, empty tokens, VFS/PCK precedence, cache stamps, `.gdc` fallback and the engine canary. |
| Identity | `tests/identity/runner.gd` | T1 to T12: filename stems, duplicate winners, metadata read records, profile defaults, key migration, missing active profiles and profile rename/create behavior. |
| Host and packs | `tests/host/runner.gd` | T1 to T32: complete host records, dispatch coverage, source migration, pack conversion/apply/unload, preserved original files, refreshed imports, pack names with no usable characters, refused-manifest copy, exact-version pins, download names, cooldowns, update outcomes, dependency ordering, and that a listing page never carries the loader's own entry on either host (matched per host, paging fields untouched, error results passed through), nor does a saved landing read back from disk. |
| Boot state | `tests/boot_state/runner.gd` | T1 to T27: crash streak, state hash, game-update detection, hook health and early hooks, config recovery, failed writes, linked-root deletion guards, unmodded cleanup retry, which rewritten scripts wait for lazy compile, that mounting an archive with a scene `.remap` loads nothing, that the hook pack carries no mod scripts, and that the compile probe's verdicts persist through pass state: the following generation does not probe, Pass 1 probes afresh, registry verbs on a demoted target return `false`, and the launcher notice names the script. |

The six harness scripts are `check_codegen.sh`, `check_dispatch.sh`,
`check_detok.sh`, `check_identity.sh`, `check_host.sh` and `check_boot_state.sh`.
Each builds a throwaway project, replaces the loader's boot initializer with
`{}` in the test copy, and calls loader functions explicitly. The five runtime
harnesses fail on any `SCRIPT ERROR`. Codegen compares baseline and generated
compilation because the decompiled game scripts can log errors outside the
game. Assertion counts come from the runners' success output.

A green run does not test the rendered launcher, live hosts, installers or a
complete game restart. See [the release checklist](https://github.com/ametrocavich/vostok-mod-loader/blob/development/docs/RELEASE_CHECKLIST.md)
for manual acceptance.

## Diagnose and extend a check

Run the failing harness directly to shorten the feedback loop:

```bash
./check_host.sh
./check_host.sh --prove
```

`--prove` makes a targeted mutation in the temporary copy and requires the
named failure. Only `check_boot_state.sh` runs the clean harness first; the
others go straight to the mutated run, so `--prove` on a baseline that already
fails can still print `PROVE-OK`. Run the plain harness (or `./check.sh`)
before trusting it. It leaves repository source unchanged, and it tests the
gate's failure detection, not every possible bug in its subject.
Each check script defines its temporary `WORK` directory; inspect the runner
output and that directory's generated files when a fixture fails.

Add cases to the closest existing runner. When adding a T number, update its
call list, `_finish` range and this page's coverage row. Dispatch also lists
the case IDs at the top of its runner and check script. For codegen, add a
fixture to `FIXTURES` in its runner; the script header explains masks and
intentional body changes. Keep the eight top-level checks.

## Continuous integration

Source: [.github/workflows/ci.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/ci.yml).
CI runs on every PR and pushes to `master` and `refactor/**`. It downloads
Godot, builds and runs the same checks. CI has no decompiled game corpus;
synthetic codegen fixtures still run. Python is supplied by the Ubuntu runner.

Godot's current default is 4.6.1-stable. When changing it, update `check.sh`,
all six `check_*.sh` scripts and both CI/release workflow pins together.

## release-please

Source: [.github/workflows/release-please.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/release-please.yml).

Automates the version bump and the changelog from [Conventional Commits](https://www.conventionalcommits.org/).

### Flow

1. A PR merges to `master`.
2. `release-please-action@v4` parses the Conventional Commits since the last tag (`release-please-config.json`, `.release-please-manifest.json`).
3. It opens a release PR ("chore(master): release <version>") that bumps `MODLOADER_VERSION` in `src/constants.gd`, updates `CHANGELOG.md` and records the version in `.release-please-manifest.json`. `src/constants.gd` is the only source file it edits.
4. Merging the release PR creates the tag and a draft GitHub Release.
5. The same workflow then runs `./build.sh`, downloads Godot and runs `./check.sh` against the exact bytes about to ship (release-please rewrote `constants.gd` on the way in, so no PR compiled this file), uploads `modloader.gd`, `override.cfg`, `windows-installer.bat` and `linux-installer.sh` as release assets, and only then flips the release from draft to published.

The draft step matters. From the moment a release is published, `/releases/latest/download/modloader.gd` resolves to it, and both installers fetch that URL. A build or upload failure on a published release left every new install failing on a 404.

Within this workflow, building and uploading assets only run when a release is created. The separate CI workflow still builds and checks normal pushes to `master`.

### Version-bump mapping

`feat:` bumps the minor version, `fix:` the patch, and a `!` after the type the major. The full table, with the types that do not bump, is in [CONTRIBUTING.md](https://github.com/ametrocavich/vostok-mod-loader/blob/development/CONTRIBUTING.md#pr-titles).

### Where the version lives

One line in `src/constants.gd`:

```gdscript
# x-release-please-start-version
const MODLOADER_VERSION := "<version>"
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
