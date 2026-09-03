# Release checklist

The pipeline automates the build and the version bump; everything below is what
it does NOT check. Work top to bottom. Anything unchecked is a reason not to
tag.

## Before merging to master

- [ ] `./build.sh && ./check.sh` green locally. All five gates, not just the
      parse: codegen, dispatch, detok, identity, host.
- [ ] `./check_host.sh --prove` and `./check_detok.sh --prove` still FAIL as
      required. A harness that cannot fail is not a gate, and a broken mutation
      is silent.
- [ ] Every commit uses a Conventional Commit prefix. release-please derives
      the version and the changelog from these; an unprefixed commit is
      invisible in the release notes.
- [ ] `git merge origin/master` first. master carries the release commits
      (version constant, manifest, CHANGELOG), so a branch that has not merged
      it declares a version that has already shipped.
- [ ] Docs match behavior. If a format, a mod.txt key or a config key changed,
      `docs/wiki/` changed in the same PR.
- [ ] No new user-facing claim without an implementation behind it. Release
      notes promising a button that does not exist is a support burden.

## Merging

- [ ] PR into master. CI (`ci.yml`) builds and runs `check.sh` on the PR.
- [ ] After the rebase-merge, reset `development` to `origin/master` --
      rebase-merge rewrites SHAs and the branches diverge silently otherwise.

## The release itself

release-please opens a release PR from Conventional Commits. Merging it tags,
creates a DRAFT release, then `release-please.yml` builds `modloader.gd`, runs
`check.sh` against the exact artifact, uploads the assets, and only then
publishes. The draft step matters: `/releases/latest/download/modloader.gd` is
what both installers fetch, so a published-but-assetless release breaks every
new install until someone notices.

- [ ] The release PR's version bump is what you expect. `feat:` is a minor,
      `fix:` a patch.
- [ ] After publish, `/releases/latest/download/modloader.gd` actually resolves
      and the file is the size you expect.
- [ ] The published `MODLOADER_VERSION` matches the tag.

## After the release

- [ ] Update the VostokMods and ModWorkshop listings: bump the version AND
      replace the hosted zip on each. Manual steps outside the pipeline. The
      in-launcher self-update check reads the GitHub release, so a stale
      listing no longer hides a fix from users, but people who install from
      a listing get whatever it hosts.
- [ ] Smoke test in the real game: launch, toggle a mod, apply a modpack,
      check for updates. No harness covers the launcher end to end.

## Known gaps in this process

- The launcher UI has no automated coverage. `check.sh` proves the file parses
  and that the translation layers behave; it proves nothing about a button.
- No harness runs the two-pass boot. `tests/boot_state/` exists but is written
  test-first against a bug that is not fixed yet, so it is deliberately NOT
  wired into `check.sh`; wiring a red gate would mask the other five.
