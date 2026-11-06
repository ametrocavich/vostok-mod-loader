# Profile Format

The `metroprofile` v1 JSON: the `profile.json` at the root of a modpack zip. Every pack already shared depends on this shape, so a breaking change means schema version `2`.

## The pack zip

```
MyPack.zip
  profile.json        required, at the zip root
  MCM/                optional, mirrors user://MCM/
    SomeMod.cfg
```

A zip in `<game>/mods/` with `profile.json` at its root is a modpack and goes to the Modpacks tab; one with `mod.txt` at its root is a mod. Anything else in a pack zip is ignored, and apply restores only the `MCM/` tree, within the limits on [Limitations](Limitations#modpacks). **Get** under Browse > Modpacks writes `mods/vostokmods-<slug>.zip`, named from the site slug; the loader never exports packs, but a zip made by hand in this layout applies the same way.

## JSON schema

```json
{
  "metroprofile": 1,
  "name": "Tarkov-style Economy",
  "description": "Harder AI + scarce loot",
  "enabled":  { "harsher_ai@2.1.0": true, "scarce_loot@1.4.0": true },
  "priority": { "harsher_ai@2.1.0": 100,  "scarce_loot@1.4.0": 50 },
  "sources": {
    "harsher_ai@2.1.0":  { "provider": "vostokmods", "id": "harsher-ai", "version": "2.1.0" },
    "scarce_loot@1.4.0": { "provider": "modworkshop", "id": "67890", "modworkshop_id": 67890 }
  },
  "dep_ignore": { "harsher_ai@2.1.0": true }
}
```

| Key | Required | Type | Meaning |
|---|---|---|---|
| `metroprofile` | yes | int | Schema version, `1` |
| `name` | yes | String | Display name. The profile slot is the name sanitized to cased letters (Latin, Cyrillic, Greek), ASCII digits, space, hyphen and underscore; a site pack whose name sanitizes to nothing stores its slug instead, and an empty result is rejected |
| `enabled` | yes | Dictionary | `profile_key -> bool`. Activation reads `true` entries; availability and download planning read every key |
| `priority` | no | Dictionary | `profile_key -> int`, clamped to `[-999, 999]`. A mod with no entry keeps its own default; a non-number reads as 0 |
| `dep_ignore` | no | Dictionary | `profile_key -> true`: the **Load anyway** overrides |
| `sources` | no | Dictionary | `profile_key -> source record` (below); lets apply download missing mods |
| `modloader_version`, `exported_at`, `description`, `author` | no | String | Advisory metadata; `exported_at` is when the pack last changed on the site |
| `hosted` | no | Dictionary | On a pack from a mod site: `{provider, slug, url, manifest_url, hash, format, thumbnail_url}`. **Refresh** rewrites the zip when the site's `hash` differs; `thumbnail_url` is the pack's cover, kept only when it is https |
| `unavailable` | no | Dictionary | `profile_key -> reason` (`scanning`, `no_files`, `removed`) for mods the site could not serve; apply reports these instead of downloading |
| `checksums` | no | Dictionary | `profile_key -> sha256 hex`; a download whose bytes differ is refused |

### Source records

| Field | Meaning |
|---|---|
| `provider` | Host token: `vostokmods` or `modworkshop` |
| `id` | The host's mod id. For Vostok Mods the slug, as the site's manifests carry it; a UUID resolves too |
| `version` | Exact version to fetch; apply fails if the host no longer has it. Absent: the host's current file |
| `modworkshop_id` | Mirror for loaders that predate `provider`, written only when `provider` is `modworkshop`, so an old loader never fetches an unrelated ModWorkshop mod. Ignored when `provider` is present; a record holding only `modworkshop_id` is still read |

Packs the launcher writes carry `vostokmods` records only, each pinned to the version the site's manifest names. A record with neither `provider` + `id` nor a positive `modworkshop_id` cannot be downloaded and shows as a missing-mod row with a reason.

## Profile key format

- `"<mod_id>@<version>"` for a mod whose `mod.txt` declares `[mod] id`. The version may be empty (`"foo@"`). Survives a file rename.
- `"zip:<file_name>"` for a mod without an id. A re-package that changes only the extension or a trailing version (`CoolMod_v1.0.zip` to `CoolMod_v1.1.vmz`) keeps its state, matched by normalized filename stem, and the old key is dropped at the next save; any other rename orphans the entry. When two stored keys share a stem, the mod is treated as new.
- `"vostokmods:<slug>"` in a pack from Vostok Mods, whose `mod.txt` ids are not known until the files arrive. Apply rewrites these to the installed mods' own keys.

In an ordinary profile, a stored `foo@1.0` with only `foo@2.0` installed carries its enabled state and priority over to `foo@2.0` and the row flags the version mismatch. `zip:` keys do not take part.

## How apply matches installed mods

A pack entry counts as installed on an exact key match, a case-insensitive `mod_id@version` match, or an installed mod whose recorded source is the entry's site id at the pinned version (any version when none is pinned). With a checksum in the pack, an installed copy with the same bytes counts whatever its `mod.txt` version says; a copy dropped in by hand counts when its `mod.txt` id is the pack's slug. A pack without `sources` matches an older key by id at any installed version.

A newer requested version is downloaded beside the copy already there. A newer copy installed than the pack pins stops apply before anything changes, because discovery always picks the newest copy. After the downloads, the pack's `enabled`, `priority` and `dep_ignore` keys are rewritten to the keys the matched mods have on this machine; unmatched keys stay as missing-mod rows.

## What apply reproduces

The first apply, or one after a changed site import, writes the pack's enabled set, priorities and **Load anyway** overrides into its own profile slot and nothing else, so mods outside the pack are off. An unchanged pack keeps the player's edits in that slot across unload and re-apply. Unload restores the previous profile and its MCM settings. Where these slots live is on [Config-Files](Config-Files#modpack-keys-and-managed-profiles).

## Forward compatibility

- v1 parsers ignore unknown top-level keys and tolerate every optional key missing; new optional fields stay on `metroprofile: 1`.
- Adding a required key, renaming a key or changing a value type means `metroprofile: 2`. A v1 loader rejects such a pack with `This modpack was made for a newer version of the mod loader -- update the mod loader and try again`; a missing `metroprofile`, or one below 1, is reported as a damaged file.

## See also

- [Modpacks](Modpacks): getting, applying and unloading a pack
- [Mod-Format](Mod-Format): the `mod.txt` fields a profile key is built from
- [src/hosted_modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/hosted_modpacks.gd) writes the JSON; [src/modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd) validates and applies it
