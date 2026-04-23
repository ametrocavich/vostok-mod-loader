# Profile Format

Specification for the `metroprofile` payload that `Share` / `Import` use to move profiles between installs. Locked at v3.0.1 release. Payloads written against v1 must keep parsing correctly for the life of the 3.x line.

Changing the shape of v1 would break every payload already pasted into Discord, forums, wiki, and mod READMEs. Breaking changes require bumping the schema version to `2`.

## Wrapper format

The clipboard-visible string:

```
MTRPRF1.<base64(utf8(JSON))>.<first 8 hex chars of SHA-256(base64 body)>
```

- `MTRPRF1` magic -- identifies this as a metroprofile v1 payload. Alternate magic means the parser rejects with `"Unknown payload type"`.
- Base64 body -- UTF-8 JSON encoded via `Marshalls.utf8_to_base64`. The Base64 alphabet `[A-Za-z0-9+/=]` contains no dots, so `.` is safe as a delimiter between the three parts.
- 8-hex checksum -- first 8 hex characters of SHA-256 over the base64 body bytes (not the decoded JSON). Detects clipboard / paste corruption. 32 bits, not a security boundary.

Parser rejects with specific errors for: wrong part count, unknown magic, bad checksum, invalid base64, non-object JSON, unsupported `metroprofile` value, missing `name`, missing `enabled`.

## JSON schema

Inside the base64 body:

```json
{
  "metroprofile":      1,
  "name":              "My Build",
  "modloader_version": "3.0.1",
  "exported_at":       "2026-04-22T23:14:11",
  "enabled": {
    "rtvcoop@1.2.3":       true,
    "immersivexp@0.4.1":   true,
    "zip:CustomHUD.vmz":   false
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
| `name` | yes | String | Profile name. Sanitized on both export and import via `_sanitize_profile_name` (ASCII letters / digits / space / hyphen / underscore). |
| `enabled` | yes | Dictionary | `profile_key -> bool`. Full manifest of every mod on the exporter's install, enabled or disabled. |
| `priority` | no | Dictionary | `profile_key -> int`. Load-order priority in `[-999, 999]`. Absent entries default to 0 on import. |
| `modloader_version` | no | String | Exporter's `MODLOADER_VERSION`. Advisory only. |
| `exported_at` | no | String | ISO datetime when exported. Advisory only. |

## Profile key format

Profile keys identify mods across installs. Two shapes:

- `"<mod_id>@<version>"` -- for mods whose `mod.txt` declares `[mod] id=...`. The version segment may be empty (`"foo@"`). Identity is stable across `.vmz` renames. See `_entry_from_config` in [mod_discovery.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd).
- `"zip:<file_name>"` -- for mods without a declared `mod_id`. Identity is the archive filename. Renaming the `.vmz` orphans the profile entry.

## Version-mismatch handling on import

When a payload's profile key `foo@1.0` doesn't match any installed mod exactly, but the importer has `foo@2.0`, the importer uses id-prefix matching (first `@` splits the key) to apply the payload's enabled / priority state to the newer version. The UI flags this as `profile_version_mismatch` so the user sees the carry-over isn't silent.

Mods without a declared `mod_id` (`zip:*` keys) don't participate in id-prefix matching; exact filename match only.

## Round-trip guarantee

For a profile with N declared mods, exporting then importing back into the same installation yields identical enabled + priority state. Keys absent from the payload default to their pre-import state -- except for `enabled`, where [`_import_profile_from_parsed`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) writes `false` for every local mod that isn't in the payload (explicit-manifest semantics; prevents unshared local mods / dev folders from being silently enabled on import).

## Forward-compatibility rules

Importers written against v1 will exist in the wild indefinitely. Rules for keeping them parsing correctly:

- v1 parsers MUST ignore unknown top-level JSON keys. Future additions can ship new optional fields without breaking v1 parsers.
- v1 parsers MUST tolerate missing optional keys (`priority`, `modloader_version`, `exported_at`). Missing required keys -> reject with error.
- Any change that adds a REQUIRED key, renames an existing key, or alters the value type of an existing key requires bumping `metroprofile` to `2`. Old parsers will correctly reject v2 with `"Unsupported metroprofile schema version"` rather than silently mis-applying.
- Additive changes to optional fields stay on `metroprofile: 1`. Old parsers ignore the new key.

## Defensive handling

On import:

- `name` is re-sanitized on the importer side (exporter-side sanitization is not trusted). An empty result rejects with `"Payload contains an invalid profile name."`
- `priority` values are clamped to `[-999, 999]` to prevent a crafted payload from breaking load-order sort stability. The UI spinbox already enforces this range on save.
- Checksum mismatch rejects before JSON parsing.

## See also

- [Mod-Format](Mod-Format) -- the `mod.txt` schema that generates `profile_key` identities.
- [`_profile_to_payload`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) + [`_parse_profile_payload`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd) -- the export / import code paths.
