# Profile Format

The `metroprofile` v1 JSON, which is the `profile.json` at the root of a modpack zip. Locked at the 3.0.1 release. Payloads written against v1 must keep parsing for the life of the 3.x line.

Changing the shape of v1 would break every modpack zip already shared. A breaking change means bumping the schema version to `2`.

## Container

The JSON is plain UTF-8 `profile.json` at the root of a modpack zip, next to an optional `MCM/` tree mirroring `user://MCM/`. The writer is `_hosted_write_pack_zip` (hosted_modpacks.gd), fed by `_hosted_manifest_to_profile`. Pre-apply validation is `_validate_modpack` (modpacks.gd), which rejects a zip with a missing, empty or non-object `profile.json`, a wrong `metroprofile` version, or a missing `name` / `enabled`.

## JSON schema

```json
{
  "metroprofile":      1,
  "name":              "My Build",
  "modloader_version": "3.3.1",
  "exported_at":       "2026-04-22T23:14:11",
  "enabled": {
    "rtvcoop@1.2.3":       true,
    "immersivexp@0.4.1":   true
  },
  "priority": {
    "rtvcoop@1.2.3":       100,
    "immersivexp@0.4.1":   50
  }
}
```

| Key | Required | Type | Meaning |
|---|---|---|---|
| `metroprofile` | yes | int | Schema version. Always `1` for v1 payloads. |
| `name` | yes | String | Modpack display name from the save dialog, falling back to the source profile name. Stored as typed, whitespace-stripped. The zip filename and the profile slot used on apply are derived with `_sanitize_profile_name` (letters in any script, digits, space, hyphen, underscore). |
| `enabled` | yes | Dictionary | `profile_key -> bool`. Only enabled mods are written (all values true); disabled-but-installed mods are left out so applying the pack never downloads or tracks them. Parsers still read the bool. |
| `priority` | no | Dictionary | `profile_key -> int`, load-order priority in `[-999, 999]`. Absent entries default to 0 on apply. |
| `modloader_version` | no | String | The exporter's `MODLOADER_VERSION`. Advisory only. |
| `exported_at` | no | String | Datetime when exported (`Time.get_datetime_string_from_system()`). Advisory only. |
| `description` | no | String | Modpack description from the save dialog. Omitted when empty. |
| `author` | no | String | Author handle from the save dialog. Omitted when empty. |
| `sources` | no | Dictionary | `profile_key -> {provider: String, id: String, modworkshop_id?: int, version?: String}`. Derived from each installed mod's `[updates] source=` (or legacy `modworkshop=`) plus `[mod] version=`, or, when `mod.txt` declares nothing, from the `[mod_sources]` record the launcher wrote when it downloaded the mod; lets apply download missing mods and pin exact versions. Only enabled mods' sources are written. The legacy `modworkshop_id` mirror is emitted if and only if `provider == "modworkshop"`, so an older loader reading a VostokMods record treats it as source-less instead of downloading an unrelated ModWorkshop mod of the same number. |
| `dep_ignore` | no | Dictionary | `profile_key -> true`, sparse (true-only entries). The "Load anyway" dependency overrides, re-materialized on apply. |
| `hosted` | no | Dictionary | Present on a pack the launcher pulled from a mod site: `{provider, slug, url, manifest_url, hash, format}`. `hash` is the site's own change token; **Refresh** re-fetches the manifest and rewrites the zip when it differs. |
| `unavailable` | no | Dictionary | `profile_key -> reason` for mods the site listed but could not serve when the pack was fetched (`scanning`, `no_files`, `removed`). Apply reports these instead of downloading. |
| `checksums` | no | Dictionary | `profile_key -> sha256 hex` for mods whose file checksum the site published. The download is refused if the bytes do not match. |

This JSON has one writer (`_hosted_manifest_to_profile` in hosted_modpacks.gd) and several readers in modpacks.gd and ui.gd. Profile-state fields (`enabled` / `priority` / `dep_ignore`) must be read by the single state consumer `_materialize_modpack_profile` (modpacks.gd) or they silently drop on apply. Metadata fields (`name`, `description`, `author`, `sources`) have their own readers (`_build_modpack_entry`, `_get_missing_mods_for_modpack`, the modpack detail dialog). `_validate_modpack` checks schema, `name` and `enabled` before apply.

## Profile key format

Profile keys identify mods across installs. Two shapes:

- `"<mod_id>@<version>"` for mods whose `mod.txt` declares `[mod] id=...`. The version segment may be empty (`"foo@"`). Identity survives a `.vmz` rename. See `_entry_from_config` in [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).
- `"zip:<file_name>"` for mods without a declared `mod_id`. Identity is the archive filename, so renaming the `.vmz` orphans the profile entry.
- `"vostokmods:<slug>"` in a pack pulled from VostokMods, where the mod's `mod.txt` id is not known until the file is downloaded. After the downloads land, apply rewrites these keys to the installed mods' own keys by matching each pack entry's source record against the installed mod's source.

## Version-mismatch handling on apply

When a stored profile key `foo@1.0` matches no installed mod exactly but `foo@2.0` is installed, id-prefix matching (the first `@` splits the key) applies the stored enabled / priority state to the installed version. The UI flags the entry as `profile_version_mismatch` so the carry-over is visible.

Mods without a declared `mod_id` (`zip:*` keys) do not take part in id-prefix matching; only an exact filename match counts.

## Round-trip guarantee

Saving a modpack then applying it reproduces the author's enabled set, priorities, and Load-anyway overrides for those mods. Apply materializes into a dedicated modpack profile slot: `_materialize_modpack_profile` erases the slot's enabled / priority / dep_ignore sections and writes only the pack's entries, so mods not in the pack are absent (treated as disabled). Disabled-but-installed mods on the author's machine are never serialized. The user's own pre-apply profile is backed up and restored on unload.

## Forward-compatibility rules

Parsers written against v1 will exist in the wild indefinitely. To keep them parsing:

- v1 parsers ignore unknown top-level JSON keys, so future additions can ship new optional fields without breaking them.
- v1 parsers tolerate missing optional keys (`priority`, `modloader_version`, `exported_at`, `description`, `author`, `sources`, `dep_ignore`). A missing required key is rejected with an error.
- Adding a required key, renaming a key, or changing a key's value type means bumping `metroprofile` to `2`. Old parsers then reject the pack (`_validate_modpack` reports `This modpack was made for a newer version of the mod loader -- update the mod loader and try again`) instead of mis-applying it.
- Additive changes to optional fields stay on `metroprofile: 1`.

## Defensive handling on apply

- `_validate_modpack` rejects malformed zips, missing or damaged `profile.json`, a wrong schema version, and a missing `name` / `enabled` before any state is touched.
- `priority` values are clamped to `[-999, 999]` (`PRIORITY_MIN` / `PRIORITY_MAX`) in `_materialize_modpack_profile`, so a crafted payload cannot break load-order sort stability. The UI spinbox already enforces this range on save.
- The pack `name` is re-sanitized on the reader side: `_build_modpack_entry` derives the profile slot with `_sanitize_profile_name`, and apply rejects an empty sanitized name with `Invalid modpack name`.

## See also

- [Mod-Format](Mod-Format): the `mod.txt` schema that generates `profile_key` identities.
- [Modpacks](Modpacks): the user-facing get / apply flow.
- `_hosted_manifest_to_profile` + `_hosted_write_pack_zip` (src/hosted_modpacks.gd): the write path.
- `_validate_modpack` + `_materialize_modpack_profile` (src/modpacks.gd): the read / apply path.
