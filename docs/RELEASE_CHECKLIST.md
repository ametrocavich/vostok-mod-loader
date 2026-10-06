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
      decompiled game source, so run it here; CI compiles the two synthetic
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
- [ ] Switch between Vostok Mods and ModWorkshop in Browse, download a mod,
      and use its resulting profile checkbox. Check for updates on Mods.
      Neither source lists the loader itself, on the landing or in a search.
- [ ] Change the mod set and launch on the current game build (Build 2,
      Nomads, since 2026-09-30). The log of the process before the restart
      has `[STABILITY] Detokenizer compatible: GDSC v101 on Godot 4.6.3`, one
      `[STABILITY] Probe-compiled` line with nothing demoted, and the
      launcher shows no banner on the next start.
- [ ] Run the Build 2 in-game kit (`tests/ingame/build2/README.md`:
      `install.sh`, one launch to the main menu, `evaluate.py`,
      `restore.sh`). Every `[B2TEST]` line `PASS`, `0 failed`; it covers
      the registries Build 2 touched, the live rewritten `AI.gd` and
      `AISpawner.gd`, hooks from a second mod and the report for a hook
      target the game removed.
- [ ] Load a mod that ships a scene `.remap` and one that ships a texture
      `.remap`. Both still apply in game.
- [ ] Apply a pack, edit its managed selection, unload, and re-apply the
      unchanged pack. Confirm pre-pack selection and MCM settings restore
      on unload and the managed edits survive re-apply.
- [ ] Import a changed hosted pack while inactive and confirm its new
      selection, priorities and MCM settings materialize on apply. Confirm
      an active pack must be unloaded before replacing its template.
- [ ] Disable every mod after a modded session. Confirm the unmodded boot
      finishes; if cleanup fails, the Retry/Quit dialog stays actionable.
- [ ] Upgrade over the last stable release with existing profiles. GitHub's
      "latest" excludes pre-releases, so check which tag it names: 3.3.0,
      3.3.1 and 3.4.0 are all flagged pre-release, so "latest" is still 3.2.1
      (checked 2026-09-30), both installers and both listings hand out 3.2.1,
      and that is the folder most upgraders have.
- [ ] Upgrade over 3.4.0 with existing profiles. Its update check reads
      "latest", so it only learns about 3.4.1 if 3.4.1 is published stable.
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
      A fix branch cut from `origin/master` (fix/build-2 for 3.4.1) goes in
      the same way, without passing through `development`.
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
      `fix:` a patch. With a merge-commit PR the PR title and body are read
      as a commit too: give it a Conventional title, and keep the words
      `BREAKING CHANGE` out of the body unless a major bump is intended.
- [ ] The release PR is opened by `GITHUB_TOKEN`, so `ci.yml` does not run
      on it. The bumped `src/constants.gd` is first built inside the release
      job. Pull the release PR branch and run `./build.sh && ./check.sh`
      locally before merging it.
- [ ] Replace the generated release notes (PR body and the new `CHANGELOG.md`
      section) when they list fixes for bugs that never shipped, or a feature
      both added and removed since the last tag.
- [ ] If the release job fails after the merge, the draft release stays
      without assets and a re-run skips every build step (`release_created`
      is false the second time). Recover by hand from the release commit on
      master: `./build.sh && ./check.sh`, then
      `gh release upload <tag> modloader.gd override.cfg windows-installer.bat linux-installer.sh --clobber`
      and `gh release edit <tag> --draft=false`. Do this on Linux or from a
      checkout with LF shell scripts.
- [ ] After publish, `/releases/latest/download/modloader.gd` resolves and the
      file is the size you expect.
- [ ] The published `MODLOADER_VERSION` matches the tag.
- [ ] The release is not flagged pre-release, unless that is intended. A
      pre-release never becomes "latest": both installers, the README link
      and the in-launcher update check keep resolving to the previous stable
      tag. 3.4.0 was flagged pre-release by hand, so as of 2026-09-30 that
      tag is 3.2.1; 3.4.1 published stable becomes the first stable release
      since 3.2.1 and the first one 3.4.0 installs are told about. For 3.4.1
      leave the flag alone: the workflow publishes the draft as a full
      release, and nothing in the pipeline sets pre-release.
- [ ] The release PR that appears right after the merge is wrong, and it
      is expected. The run that created the draft also opened the NEXT
      release PR, and it did so before the tag existed (a draft release has
      no tag). With no last-release commit to stop at, release-please read
      the whole history, and the old `Release-As: 3.0.0` footers from the
      3.0.0 era set the version: that is how "chore(master): release 3.0.0"
      (PR #91) appeared minutes after v3.4.0, and the 3.4.1 merge will open
      or rewrite one the same way. Never merge it.
- [ ] Once the release is published, close that stale release PR by hand
      and remove its `autorelease: pending` label. Do not count on the
      workflow to close it: for 3.4.1 two `gh workflow run
      release-please.yml` runs left it open (PR #93), although a dry run on
      master opened nothing. The next push to master opens the real next
      release PR. Only then move on to the listings.

## After the release

- [ ] Update the Vostok Mods and ModWorkshop listings: bump the version and
      replace the hosted zip on each. Manual steps outside the pipeline.
      Build the zip from the published release assets, not from a local
      build: a local tree that has not pulled the release commit still says
      the old `MODLOADER_VERSION`, and a Windows checkout can carry CRLF
      shell scripts.
      Loaders up to 3.3.1 check the ModWorkshop listing for their own update,
      so the listing bump is the only notice those installs get. From 3.4.0
      the check reads the GitHub release instead; people who install from a
      listing still get whatever it hosts. Neither listing was bumped for the
      3.4.0 pre-release (both serve 3.2.1 with the pre-3.3 description as of
      2026-09-30), so the 3.4.1 listing text has to cover everything since
      3.2.1; `MWS_PAGE.md` and `VOSTOKMODS_PAGE.md` carry that text and a
      changelog block.

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
  dialects and what the hosts send today are only proven by the manual acceptance run.
