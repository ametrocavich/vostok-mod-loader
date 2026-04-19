# Metro Mod Loader -- Developer Wiki

Internal documentation for contributors to the community mod loader for Road to Vostok (Godot 4.6+).

End-user install instructions and mod-author quick-start live in the repo [README](https://github.com/ametrocavich/vostok-mod-loader/blob/development/README.md). This wiki covers how the loader actually works inside.

## Scope

- How the two-pass launch works and why it exists
- The `src/*.gd` module layout and what each file owns
- The source-rewrite hook system (rewriter + hook pack + RTVModLib API)
- The GDSC binary-tokenizer detokenizer
- Stability canaries, crash recovery, safe mode, and sentinel files
- Known Godot quirks the loader works around

## Sections

- [Architecture](Architecture) -- launch flow, two-pass restart, static-init mount, override.cfg lifecycle
- [Modules](Modules) -- per-file tour of the `src/` tree
- [Hooks](Hooks) -- RTVModLib API, source rewriter, hook pack generation + mount
- [Mod-Format](Mod-Format) -- mod.txt schema, autoload `!` prefix, `[script_overrides]`, `[rtvmodlib] needs=`
- [GDSC-Detokenizer](GDSC-Detokenizer) -- binary token format v100/v101, vanilla source cache
- [Stability-Canaries](Stability-Canaries) -- A/B/C runtime probes, safe-mode + crash-recovery sentinels
- [Build](Build) -- `build.sh` concat order, release-please, version bump flow
- [Developer-Mode](Developer-Mode) -- what the dev flag unlocks, debug probes
- [Limitations](Limitations) -- known Godot quirks, bug #83542, scene-preload defer, supported/unsupported patterns

## Source-of-truth rules

This wiki is generated from `docs/wiki/` in the main repo and synced to the GitHub Wiki via [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml). To edit a page, PR changes to `docs/wiki/*.md` -- the wiki updates itself on merge.

Every significant claim in these pages cites `src/<file>.gd:<line>`. If source drifts, the wiki is stale -- open an issue or submit a PR.

## Target audience

- **Contributors** wanting to understand what each module does before modifying it
- **Mod authors** looking for deeper semantics than the README covers (e.g. why `!` prefixes on autoload values, when hooks actually fire)
- **Anyone debugging** an unfamiliar boot-log entry, wondering which module emitted it
