# Release checklist

The pipeline automates the build and the version bump. Everything below is
what it does not check. Work top to bottom; anything unchecked is a reason not
to tag.

## Before merging to master

- [ ] `./build.sh && ./check.sh` green locally. The parse and all six gates:
      codegen, dispatch, detok, identity, host, boot_state. The codegen
      gate compiles its ten vanilla fixtures only on a machine with the
      decompiled game source, so run it here; CI compiles the three synthetic
      fixtures and leaves those ten out.
- [ ] `./check_host.sh --prove`, `./check_detok.sh --prove`,
      `./check_identity.sh --prove`, `./check_dispatch.sh --prove`,
      `./check_boot_state.sh --prove` and `./check_codegen.sh --prove` still
      fail as required. A harness that cannot fail is not a gate, and a broken
      mutation is silent.
- [ ] Every commit uses a Conventional Commit prefix. release-please derives
      the version and the changelog from these; an unprefixed commit is
      invisible in the release notes.
- [ ] `git merge origin/master` first. master carries the release commits
      (version constant, manifest, CHANGELOG), so a branch that has not merged
      it declares a version that has already shipped.
- [ ] Docs match behavior. If a format, a mod.txt key or a config key changed,
      `docs/wiki/` changed in the same PR.
- [ ] No new user-facing claim without an implementation behind it. Release
      notes promising a button that does not exist are a support burden.

## Merging

- [ ] PR into master. CI (`ci.yml`) builds and runs `check.sh` on the PR.
- [ ] After the rebase-merge, reset `development` to `origin/master`.
      Rebase-merge rewrites SHAs and the branches diverge silently otherwise.
- [ ] The wiki synced. `wiki-sync.yml` fires only on pushes to `development`
      and `master`, so a page edited on a feature branch reaches the GitHub
      Wiki only after the merge; open the wiki and check one changed page.

## The release itself

release-please opens a release PR from the Conventional Commits. Merging it
tags, creates a draft release, then `release-please.yml` builds `modloader.gd`,
runs `check.sh` against the exact artifact, uploads the assets, and only then
publishes. The draft step matters: `/releases/latest/download/modloader.gd` is
what both installers fetch, so a published-but-assetless release breaks every
new install until someone notices.

- [ ] The release PR's version bump is what you expect. `feat:` is a minor,
      `fix:` a patch.
- [ ] After publish, `/releases/latest/download/modloader.gd` resolves and the
      file is the size you expect.
- [ ] The published `MODLOADER_VERSION` matches the tag.

## After the release

- [ ] Update the VostokMods and ModWorkshop listings: bump the version and
      replace the hosted zip on each. Manual steps outside the pipeline. The
      in-launcher self-update check reads the GitHub release, so a stale
      listing no longer hides a fix from users, but people who install from a
      listing get whatever it hosts.
- [ ] Smoke test in the real game: launch, toggle a mod, switch the Browse
      source between VostokMods and ModWorkshop, download something, apply a
      modpack, and click Check for updates on the Mods tab. No harness covers
      the launcher end to end.
- [ ] Upgrade over 3.3.1: start from a user folder that still holds
      `.modpack_backups/` and a profile snapshot slot with `overrides/` and
      `overrides_manifest.json` beside `MCM/`. After one launch the backups
      directory is gone, and deleting that profile removes the whole slot.

## Known gaps in this process

- The launcher UI has no automated coverage. `check.sh` proves the file parses
  and that the translation layers behave; it proves nothing about a button.
- No harness runs the two-pass boot. `check_boot_state.sh` drives the real
  boot-state functions and the real state files, but the restart decision is
  inline in `_run_pass_1`, which shows the launcher, mounts archives and
  relaunches the process, so it cannot run headlessly. The one ordering fact
  it depends on (Pass 2 clears the streak after the crash window) is checked
  against the built source text.
- No harness talks to a real host. `check_host.sh` covers the normalizers and
  the on-disk source format with captured payloads; endpoint URLs, rate-limit
  dialects and what the hosts send today are only proven by the smoke test.
