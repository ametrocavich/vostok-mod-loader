# Release checklist

The pipeline automates the build and version bump. Maintainers complete the
checks and manual acceptance below before merging the release PR, because
that merge creates and publishes the release automatically. Listing updates
and published-asset checks happen afterward.

## Before merging to master

- [ ] `./build.sh && ./check.sh` prints all eight `OK:` lines: parse,
      static/documentation invariants, codegen, dispatch, detok, identity,
      host and boot_state. The codegen
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

## Manual acceptance before the release PR merges

Use a backed-up test setup and the release candidate. These are owner-run
in-game checks, separate from the automated headless checks:

- [ ] Launch cold, then launch the same mod set again. Confirm the two-pass
      restart finishes and the same-state path reaches the game.
- [ ] Reopen Mods from the main menu. Toggle a mod or change load order;
      closing restarts into the selected set. Rename a profile without
      changing its selection; closing does not restart.
- [ ] Switch between VostokMods and ModWorkshop in Browse, download a mod,
      and use its resulting profile checkbox. Check for updates on Mods.
- [ ] Apply a pack, edit its managed selection, unload, and re-apply the
      unchanged pack. Confirm pre-pack selection and MCM settings restore
      on unload and the managed edits survive re-apply.
- [ ] Import a changed hosted pack while inactive and confirm its new
      selection, priorities and MCM settings materialize on apply. Confirm
      an active pack must be unloaded before replacing its template.
- [ ] Disable every mod after a modded session. Confirm the unmodded boot
      finishes; if cleanup fails, the Retry/Quit dialog stays actionable.
- [ ] Upgrade over 3.3.1 with existing profiles and an applied pack. Confirm
      selection and MCM settings survive. Unload preserves unconsumed legacy
      originals beside the backup MCM snapshot without restoring arbitrary
      files. Retired `.modpack_backups/` restore points are removed at launch;
      deleting a profile still removes its whole snapshot slot.
- [ ] Release notes name removed flows: pack export, the Restore backup
      picker and arbitrary `overrides/` payload application. No retired
      feature is promised by the docs or listings.
- [ ] Run each installer through an actual install/upgrade on its platform.
      Check existing non-autoload override.cfg sections survive.

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
