# Release checklist

The pipeline builds the loader and bumps the version. Maintainers complete
the checks and manual acceptance below before merging the release PR,
because that merge creates and publishes the release. Listing updates and
published-asset checks happen afterward.

## Before merging to master

- [ ] `./build.sh && ./check.sh` prints all eleven `OK:` lines. Run it on a
      machine with the decompiled game source: the codegen gate compiles its
      ten vanilla fixtures only there, and CI runs the three synthetic ones.
- [ ] Every `check_*.sh --prove` still fails as required. A harness that
      cannot fail is not a gate, and a broken mutation is silent.
- [ ] Every commit uses a Conventional Commit prefix; an unprefixed commit is
      invisible in the release notes.
- [ ] The commit types produce the version you mean to ship. `fix:`,
      `refactor:` and `docs:` give at most a patch: for a minor, give the
      last commit a `Release-As: <version>` footer (or include a `feat:`
      commit), and confirm the release PR title before merging it.
- [ ] `git merge origin/master` first. master carries the release commits
      (version constant, manifest, CHANGELOG), so a branch without them
      declares a version that has already shipped.
- [ ] Docs match behavior: a changed format, mod.txt key or config key
      changed `docs/wiki/` in the same PR, and no release note promises
      something that is not implemented.

## Manual acceptance before the release PR merges

Use a backed-up test setup and the release candidate:

- [ ] Launch cold, then launch the same mod set again. The two-pass restart
      finishes and the same-state path reaches the game.
- [ ] Reopen Mods from the main menu. Toggle a mod or change load order;
      closing restarts into the selected set. Rename a profile without
      changing its selection; closing does not restart.
- [ ] Switch between Vostok Mods and ModWorkshop in Browse, download a mod
      and use its profile checkbox. Check for updates on Mods. Neither source
      lists the loader itself.
- [ ] Change the mod set and launch on the current game build. The log of
      the process before the restart has
      `[STABILITY] Detokenizer compatible`, one
      `[STABILITY] Probe-compiled` line with nothing demoted, and the next
      launcher shows no banner.
- [ ] Run the LTS in-game kit (`tests/ingame/lts/README.md`: `install.sh`,
      one launch to the main menu, `evaluate.py`, `restore.sh`) and attach
      the output of `evaluate.py` to the release PR. After a game update, run
      `tests/ingame/rehearse_build.sh` first; it must print READY.
- [ ] Run the Build 2 in-game kit (`tests/ingame/build2/README.md`, same
      steps). Every `[B2TEST]` line reads `PASS` and the summary `0 failed`.
- [ ] Load a mod that ships a scene `.remap` and one that ships a texture
      `.remap`. Both apply in game.
- [ ] Apply a pack, edit its managed selection, unload, and re-apply the
      unchanged pack. Pre-pack selection and MCM settings restore on unload
      and the managed edits survive re-apply.
- [ ] Import a changed hosted pack while inactive; its new selection,
      priorities and MCM settings materialize on apply. An active pack must
      be unloaded before its template is replaced.
- [ ] Under Browse > Modpacks, click Get on a pack in the Vostok Mods list
      and Get another from a pasted page link. Both list rows read Added,
      and both appear on the Modpacks tab under Your packs with their
      covers.
- [ ] Open a pack's details from the Browse > Modpacks list and from Your
      packs. The mod list shows Installed, Will download or Not available
      per mod, and the buttons read Get or Added, Apply or Unload, and Open
      page on Vostok Mods.
- [ ] Open Browse > Modpacks offline after one online visit. The list shows
      the saved page under `Showing cached results.`; Retry fills it once
      the connection is back.
- [ ] On the Modpacks tab, each Your packs row shows Details and Apply (or
      Active and Unload), and a pack from the site also shows Refresh.
      Apply one, then Unload it. Apply it again, quit, delete
      `modpack_backup_valid` from `mod_config.cfg` and relaunch: Unload
      offers Keep as profile, which leaves a plain profile named after the
      pack.
- [ ] With a pack from the site that changed since it was added (or with the
      `hash` edited in its `profile.json`), Check for updates on Mods
      reports `1 pack(s) changed`, and Refresh rewrites the pack.
- [ ] Disable every mod after a modded session. The unmodded boot finishes;
      if cleanup fails, the Retry/Quit dialog stays actionable.
- [ ] Upgrade over the last stable release and over the oldest version a
      listing still serves (GitHub's "latest" excludes pre-releases; the
      listings serve whatever was last uploaded). Use existing profiles, an
      applied hosted pack and a pending post-boot profile switch (switch from
      the main menu, then quit without closing the launcher). Selection and
      MCM settings survive, and the switch completes at the next launch with
      the MCM files swapped before any mod runs.
- [ ] Run each installer through an install and an upgrade on its platform.
      Existing non-autoload `override.cfg` sections survive.

## Merging

- [ ] PR into master; `ci.yml` builds and runs `check.sh` on it. A fix
      branch cut from `origin/master` goes in the same way.
- [ ] After the rebase-merge, reset `development` to `origin/master`.
- [ ] Open the wiki and check one changed page; `wiki-sync.yml` publishes
      `docs/wiki/` only on pushes to `development` and `master`.

## The release itself

release-please reads the Conventional Commits since the last tag and opens a
release PR ("chore(master): release <version>") that bumps
`MODLOADER_VERSION` in `src/constants.gd` and updates `CHANGELOG.md` and the
manifest. Merging it tags and creates a draft release; `release-please.yml`
then builds `modloader.gd`, runs `check.sh` against those exact bytes,
uploads `modloader.gd`, `override.cfg`, `windows-installer.bat` and
`linux-installer.sh`, and only then publishes. Both installers fetch
`/releases/latest/download/modloader.gd`, so a published release without
assets breaks every new install.

- [ ] The version bump is what you expect. With a merge-commit PR the PR
      title and body are read as a commit too: give it a Conventional title,
      and keep `BREAKING CHANGE` out of the body unless a major is intended.
- [ ] `GITHUB_TOKEN` opens the release PR, so `ci.yml` does not run on it and
      the bumped `src/constants.gd` is first built in the release job. Pull
      the release PR branch and run `./build.sh && ./check.sh` before merging.
- [ ] Replace the generated notes (PR body and the new `CHANGELOG.md`
      section) when they list fixes for bugs that never shipped, or a feature
      both added and removed since the last tag.
- [ ] If the release job fails after the merge, the draft stays without
      assets and a re-run skips every build step. Recover by hand from the
      release commit on master, in a checkout with LF shell scripts:
      `./build.sh && ./check.sh`, then
      `gh release upload <tag> modloader.gd override.cfg windows-installer.bat linux-installer.sh --clobber`
      and `gh release edit <tag> --draft=false`.
- [ ] After publish, `/releases/latest/download/modloader.gd` resolves, the
      file has the expected size, and its `MODLOADER_VERSION` matches the tag.
- [ ] The release is not flagged pre-release. A pre-release never becomes
      "latest", so the installers, the README link and the in-launcher update
      check keep the previous stable tag. Nothing in the pipeline sets it.
- [ ] A release PR naming an old version appears right after the merge: the
      run that created the draft opened it before the tag existed. Never
      merge it. Once the release is published, close it by hand and remove
      its `autorelease: pending` label; a manual run
      (`gh workflow run release-please.yml`) does not close it. The next push
      to master opens the real next release PR.

## After the release

- [ ] Update the Vostok Mods and ModWorkshop listings: bump the version and
      replace the hosted zip on each. Build the zip from the published
      release assets, not a local build: a tree without the release commit
      says the old `MODLOADER_VERSION`, and a Windows checkout can carry CRLF
      shell scripts. Installs from a listing get only what it hosts, so check
      which version each listing serves first: its changelog field needs
      every block since then. `MWS_PAGE.md` and `VOSTOKMODS_PAGE.md` carry
      the listing text and one changelog block per release.

## Known gaps in this process

- `check_ui.sh` compares every launcher widget, property and theme entry
  against a golden dump, but nothing presses a button or watches a repaint.
- No harness runs the two-pass boot: the restart decision in `_run_pass_1`
  shows the launcher and relaunches the process. `check_boot_state.sh`
  drives the boot-state functions and files around it.
- No harness talks to a real host. `check_host.sh` replays captured
  payloads; endpoint URLs, rate limits and what the hosts send today are
  proven only by the manual acceptance run.
