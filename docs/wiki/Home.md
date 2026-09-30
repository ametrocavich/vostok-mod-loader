# Metro Mod Loader -- Wiki

Documentation for the community mod loader for Road to Vostok (Godot 4.6).

What the loader gives you in-game:

- A [Mods](Mods) tab to turn installed mods on and off, set load order, keep profiles, and see why a mod is blocked
- A [Browse](Browse) tab to find and download mods from VostokMods or ModWorkshop
- A [Modpacks](Modpacks) tab to apply a setup published on VostokMods; applying it downloads the mods for you
- A **Check for updates** button on the Mods tab that tells you when installed mods have newer versions on their site

Players: start at [Setup](Setup), then [Mods](Mods), [Browse](Browse) and [Modpacks](Modpacks). When something goes wrong, [Troubleshooting](Troubleshooting). Known engine limits are in [Limitations](Limitations).

## Writing a mod

This wiki is the home for mod authors. Hooks, the registry and dependencies exist only in this loader, and these pages teach them from scratch. Start with whichever page matches what you want to do:

- [Hooks](Hooks): change vanilla behavior. Use this when you want your code to run before, after, or instead of a vanilla function (`lib.hook(hook_name, callback)`).
- [Registry](Registry): add or modify game content. Use this when you want to add items, scenes, loot, recipes, sounds, or tweak vanilla entries (`lib.register` / `lib.override` / `lib.patch`).
- [Dependencies](Dependencies): require other mods. Use this when your mod builds on another mod and must load after it (the `[dependencies]` section in mod.txt).

Then the pages every mod ships with:

- [Mod-Format](Mod-Format): the mod.txt schema: metadata, autoloads, `[updates]`, `[hooks]` / `[script_extend]` / `[registry]` declarations
- [Setup-Plans](Setup-Plans): declarative `lib.setup(plan)`, batching your registry and hook calls as one plan literal
- [Build-2-Migration](Build-2-Migration): step by step, updating a mod that worked on the previous game build for Road to Vostok Build 2 (Nomads)

Related, when you need them:

- [Config-Files](Config-Files): where profile state lives on disk, how to edit, back up and reset it
- [Limitations](Limitations): known Godot quirks, bug #83542, scene-preload defer, supported and unsupported patterns

## For developers

You do not need any of this to write a mod. These pages cover how the loader itself works, for people modifying the loader or debugging an unfamiliar boot-log entry:

- [Development](Development): task-to-code map, state ownership, edit recipes and source navigation
- [Architecture](Architecture): launch flow, two-pass restart, early mounts, override.cfg lifecycle
- [Modules](Modules): per-file tour of the `src/` tree
- [Profile-Format](Profile-Format): the metroprofile v1 JSON inside a modpack's profile.json
- [GDSC-Detokenizer](GDSC-Detokenizer): binary token format v100/v101, vanilla source cache
- [Stability-Canaries](Stability-Canaries): A/B/C runtime probes, safe-mode and crash-recovery sentinels
- [Build](Build): `build.sh` concat order, release-please, version bump flow
- [Developer-Mode](Developer-Mode): what the dev flag unlocks, debug probes

## Source-of-truth rules

These pages are the `docs/wiki/` directory of the main repo, synced to the GitHub Wiki by [.github/workflows/wiki-sync.yml](https://github.com/ametrocavich/vostok-mod-loader/blob/development/.github/workflows/wiki-sync.yml). To edit a page, PR changes to `docs/wiki/*.md`; the wiki updates itself on merge.

The code in `src/` is the authority. If a page and the code disagree, the page is stale: open an issue or submit a PR.
