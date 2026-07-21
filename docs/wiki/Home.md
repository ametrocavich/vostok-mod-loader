# Metro Mod Loader -- Wiki

Documentation for the community mod loader for Road to Vostok (Godot 4.6+). Player guides come first; the rest of this page covers how the loader works inside, for contributors and mod authors.

What the loader gives you in-game:

- A **Mods** tab to turn installed mods on and off
- A **Browse** tab to find and download mods from ModWorkshop
- A **Modpacks** tab to share your whole mod list as one small file -- applying it downloads the mods for you
- An **Updates** tab that tells you when installed mods have newer versions

Players: start at [Setup](Setup), then [Browse](Browse) and [Modpacks](Modpacks). Known engine limits are in [Limitations](Limitations).

Mod-author quick-start lives in the repo [README](https://github.com/ametrocavich/vostok-mod-loader/blob/development/README.md). The rest of this wiki covers how the loader actually works inside.

## Scope

- How the two-pass launch works and why it exists
- The `src/*.gd` module layout and what each file owns
- The opt-in source-rewrite hook system (rewriter + hook pack + RTVModLib API)
- The registry API for data-driven content (items, scenes, loot, recipes, ...)
- The GDSC binary-tokenizer detokenizer
- Stability canaries, crash recovery, safe mode, and sentinel files
- Known Godot quirks the loader works around

## Sections

- [Setup](Setup) -- installing the mod loader and getting your first mods
- [Browse](Browse) -- finding and downloading mods from ModWorkshop, plus the Updates tab
- [Modpacks](Modpacks) -- sharing your mod list as a single file and applying someone else's
- [Architecture](Architecture) -- launch flow, two-pass restart, static-init mount, override.cfg lifecycle
- [Modules](Modules) -- per-file tour of the `src/` tree
- [Hooks](Hooks) -- RTVModLib API, opt-in wrap surface, source rewriter, hook pack generation + mount
- [Registry](Registry) -- `lib.register` / `lib.override` / `lib.patch` for items, scenes, loot, sounds, recipes, events, traders, inputs, shelters, AI, fish, resources
- [Setup-Plans](Setup-Plans) -- declarative `lib.setup(plan)`: batch registry + hook calls as one plan literal
- [Mod-Format](Mod-Format) -- mod.txt schema, autoload `!` prefix, `[hooks]` / `[script_extend]` / `[registry]` declarations
- [Profile-Format](Profile-Format) -- the metroprofile v1 JSON format used inside a modpack's profile.json (fields, forward-compat rules)
- [Config-Files](Config-Files) -- where profile state lives on disk, how to edit/back up/reset, sentinel files, generated caches
- [GDSC-Detokenizer](GDSC-Detokenizer) -- binary token format v100/v101, vanilla source cache
- [Stability-Canaries](Stability-Canaries) -- A/B/C runtime probes, safe-mode + crash-recovery sentinels
- [Build](Build) -- `build.sh` concat order, release-please, version bump flow
- [Developer-Mode](Developer-Mode) -- what the dev flag unlocks, debug probes
- [Limitations](Limitations) -- known Godot quirks, bug #83542, scene-preload defer, supported/unsupported patterns

## Source-of-truth rules

This wiki is generated from `docs/wiki/` in the main repo and synced to the GitHub Wiki via [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml). To edit a page, PR changes to `docs/wiki/*.md` -- the wiki updates itself on merge.

Every significant claim in these pages cites `src/<file>.gd:<line>`. If source drifts, the wiki is stale -- open an issue or submit a PR.

## Target audience

- **Players** -- start with [Setup](Setup), [Browse](Browse), [Modpacks](Modpacks), and [Limitations](Limitations)
- **Contributors** wanting to understand what each module does before modifying it
- **Mod authors** looking for deeper semantics than the README covers (e.g. why `!` prefixes on autoload values, when hooks actually fire)
- **Anyone debugging** an unfamiliar boot-log entry, wondering which module emitted it
