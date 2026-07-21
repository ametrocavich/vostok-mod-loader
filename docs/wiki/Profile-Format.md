# Profile Format

Specification for the `metroprofile` v1 JSON -- the `profile.json` at the root of a modpack zip. Locked at v3.0.1 release. Payloads written against v1 must keep parsing correctly for the life of the 3.x line.

Changing the shape of v1 would break every modpack zip already shared. Breaking changes require bumping the schema version to `2`.

## Container

The JSON lives as plain UTF-8 `profile.json` at the root of a modpack zip, alongside an optional `MCM/` tree mirroring `user://MCM/`. Writer: `_export_profile_to_zip` (ui.gd). Pre-apply validation: `_validate_modpack` (modpacks.gd), which rejects zips with a missing / empty / non-object `profile.json`, a wrong `metroprofile` version, or a missing `name` / `enabled`.

## JSON schema

```json
{
  "metroprofile":      1,
  "name":              "My Build",
  "modloader_version": "3.3.0",
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
| `name` | yes | String | Modpack display name (save-as-modpack dialog; falls back to the source profile name). The zip filename and the profile slot used on apply are derived via `_sanitize_profile_name` (ASCII letters / digits / space / hyphen / underscore) -- the payload value itself is stored as typed, whitespace-stripped. |
| `enabled` | yes | Dictionary | `profile_key -> bool`. Only ENABLED mods are written (all values true); disabled-but-installed mods are excluded so applying the pack never downloads or tracks them. Parsers still read the bool value. |
| `priority` | no | Dictionary | `profile_key -> int`. Load-order priority in `[-999, 999]`. Absent entries default to 0 on apply. |
| `modloader_version` | no | String | Exporter's `MODLOADER_VERSION`. Advisory only. |
| `exported_at` | no | String | ISO datetime when exported. Advisory only. |
| `description` | no | String | Author-provided modpack description (save-as-modpack dialog). Omitted when empty. |
| `author` | no | String | Author handle from the save-as-modpack dialog. Omitted when empty. |
| `sources` | no | Dictionary | `profile_key -> {modworkshop_id: int, version?: String}`. Auto-derived from each installed mod's `[updates] modworkshop=` + `[mod] version=`; lets modpack apply download missing mods from ModWorkshop and pin exact versions. Only enabled mods' sources are written. |
| `dep_ignore` | no | Dictionary | `profile_key -> true`, sparse (true-only entries). "Load anyway" dependency overrides; re-materialized on modpack apply. |

Like `sources`, the `priority` and `dep_ignore` dictionaries are filtered to the enabled set on export.

This JSON has ONE writer (`_profile_to_json_string` in ui.gd) and several readers in modpacks.gd / ui.gd. Profile-STATE fields (`enabled` / `priority` / `dep_ignore`) must be read by the single state consumer `_materialize_modpack_profile` (modpacks.gd) or they silently drop on apply. Metadata fields (`name`, `description`, `author`, `sources`) need their own readers (`_build_modpack_entry`, `_get_missing_mods_for_modpack`, the modpack detail dialog). `_validate_modpack` pre-checks schema / `name` / `enabled` before apply.

## Profile key format

Profile keys identify mods across installs. Two shapes:

- `"<mod_id>@<version>"` -- for mods whose `mod.txt` declares `[mod] id=...`. The version segment may be empty (`"foo@"`). Identity is stable across `.vmz` renames. See `_entry_from_config` in [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).
- `"zip:<file_name>"` -- for mods without a declared `mod_id`. Identity is the archive filename. Renaming the `.vmz` orphans the profile entry.

## Version-mismatch handling on apply

When a modpack (or profile) is applied against the installed mod set and a stored profile key `foo@1.0` doesn't match any installed mod exactly, but the install has `foo@2.0`, id-prefix matching (first `@` splits the key) applies the stored enabled / priority state to the newer version. The UI flags this as `profile_version_mismatch` so the user sees the carry-over isn't silent.

Mods without a declared `mod_id` (`zip:*` keys) don't participate in id-prefix matching; exact filename match only.

## Round-trip guarantee

Saving a modpack then applying it reproduces the author's enabled set, priorities, and Load-anyway overrides for those mods. Apply materializes into a dedicated modpack profile slot: `_materialize_modpack_profile` erases the slot's enabled / priority / dep_ignore sections and writes only the pack's entries, so mods not in the pack are simply absent (treated as disabled). Disabled-but-installed mods on the author's machine are never serialized. The user's own pre-apply profile is auto-backed up and restored on unload.

## Forward-compatibility rules

Parsers written against v1 will exist in the wild indefinitely. Rules for keeping them parsing correctly:

- v1 parsers MUST ignore unknown top-level JSON keys. Future additions can ship new optional fields without breaking v1 parsers.
- v1 parsers MUST tolerate missing optional keys (`priority`, `modloader_version`, `exported_at`, `description`, `author`, `sources`, `dep_ignore`). Missing required keys -> reject with error.
- Any change that adds a REQUIRED key, renames an existing key, or alters the value type of an existing key requires bumping `metroprofile` to `2`. Old parsers will correctly reject v2 (`_validate_modpack` reports "This modpack was made for a newer version of the mod loader -- update the mod loader and try again") rather than silently mis-applying.
- Additive changes to optional fields stay on `metroprofile: 1`. Old parsers ignore the new key.

## Defensive handling on apply

- `_validate_modpack` rejects malformed zips, missing / damaged `profile.json`, a wrong schema version, and a missing `name` / `enabled` before any state is touched.
- `priority` values are clamped to `[-999, 999]` (`PRIORITY_MIN` / `PRIORITY_MAX`) in `_materialize_modpack_profile`, preventing a crafted payload from breaking load-order sort stability. The UI spinbox already enforces this range on save.
- The pack `name` is re-sanitized on the reader side: `_build_modpack_entry` derives the profile slot via `_sanitize_profile_name`, and `save_profile_as_modpack` rejects an empty sanitized name with `"Invalid modpack name"`.

## See also

- [Mod-Format](Mod-Format) -- the `mod.txt` schema that generates `profile_key` identities.
- [Modpacks](Modpacks) -- the user-facing save / share / apply flow.
- `_profile_to_json_string` + `_export_profile_to_zip` (src/ui.gd) -- the write path.
- `_validate_modpack` + `_materialize_modpack_profile` (src/modpacks.gd) -- the read / apply path.
