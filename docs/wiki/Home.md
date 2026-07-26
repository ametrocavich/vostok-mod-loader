# Metro Mod Loader -- Wiki

Documentation for the community mod loader for Road to Vostok (Godot 4.6+).

What the loader gives you in-game:

- A **Mods** tab to turn installed mods on and off
- A **Browse** tab to find and download mods from ModWorkshop
- A **Modpacks** tab to share your whole mod list as one small file -- applying it downloads the mods for you
- An **Updates** tab that tells you when installed mods have newer versions

Players: start at [Setup](Setup), then [Browse](Browse) and [Modpacks](Modpacks). Known engine limits are in [Limitations](Limitations).

## Writing a mod

This wiki is the home for mod authors. Everything here -- hooks, the registry, dependencies -- exists only in this loader, and these pages teach it from scratch. Start with whichever page matches what you want to do:

- [Hooks](Hooks) -- **change vanilla behavior.** Use this when you want your code to run before, after, or instead of a vanilla function (`lib.hook(hook_name, callback)`).
- [Registry](Registry) -- **add or modify game content.** Use this when you want to add new items, scenes, loot, recipes, sounds, and more, or tweak vanilla entries (`lib.register` / `lib.override` / `lib.patch`).
- [Dependencies](Dependencies) -- **require other mods.** Use this when your mod builds on another mod and must load after it (the `[dependencies]` section in mod.txt).

Then the pages every mod ships with:

- [Mod-Format](Mod-Format) -- the mod.txt schema: metadata, autoloads, `[hooks]` / `[script_extend]` / `[registry]` declarations
- [Setup-Plans](Setup-Plans) -- declarative `lib.setup(plan)`: batch your registry + hook calls as one plan literal

Related, when you need them:

- [Config-Files](Config-Files) -- where profile state lives on disk, how to edit/back up/reset it
- [Profile-Format](Profile-Format) -- the metroprofile v1 JSON format used inside a modpack's profile.json
- [Limitations](Limitations) -- known Godot quirks, bug #83542, scene-preload defer, supported/unsupported patterns

## Internals (for contributors)

You do not need any of this to write a mod. These pages cover how the loader itself works, for people modifying the loader or debugging an unfamiliar boot-log entry:

- [Architecture](Architecture) -- launch flow, two-pass restart, static-init mount, override.cfg lifecycle
- [Modules](Modules) -- per-file tour of the `src/` tree
- [GDSC-Detokenizer](GDSC-Detokenizer) -- binary token format v100/v101, vanilla source cache
- [Stability-Canaries](Stability-Canaries) -- A/B/C runtime probes, safe-mode + crash-recovery sentinels
- [Build](Build) -- `build.sh` concat order, release-please, version bump flow
- [Developer-Mode](Developer-Mode) -- what the dev flag unlocks, debug probes

## Source-of-truth rules

This wiki is generated from `docs/wiki/` in the main repo and synced to the GitHub Wiki via [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml). To edit a page, PR changes to `docs/wiki/*.md` -- the wiki updates itself on merge.

Every significant claim in these pages cites `src/<file>.gd:<line>`. If source drifts, the wiki is stale -- open an issue or submit a PR.
