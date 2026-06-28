# Modpacks

A **modpack** is a curated loadout shipped as a single `.zip`: which mods are on, their load order, the author's [MCM](https://modworkshop.net) (Mod Configuration Menu) settings, and -- crucially -- where to download each mod from. Drop the zip into `mods/`, click **Apply**, and the launcher downloads anything you're missing and switches you to the author's exact setup. New in 3.3.

The **Modpacks** tab is the fourth tab in the pre-launch window. Its implementation is [modpacks.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd); the tab UI is `build_profile_tab` in [ui.gd:1822](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L1822).

## Modpack vs. shareable profile

The launcher already has the `MTRPRF1...` [share string](Profile-Format) for moving a profile between installs. A modpack is the heavier, file-based sibling:

| | Share string (`MTRPRF1...`) | Modpack (`.zip`) |
|---|---|---|
| Carries enabled + priority | yes | yes |
| Carries MCM settings | no | yes (the `MCM/` tree) |
| Carries download sources | yes (`sources`) | yes (`sources`) |
| Transport | clipboard text | a file in `mods/` |
| Installs missing mods | no (apply is manual) | yes (Apply downloads them) |

Both use the same `metroprofile: 1` JSON schema, so a modpack's `profile.json` is a superset of the share-string body. See [Profile-Format](Profile-Format) for the shared JSON fields.

## Zip layout

A modpack zip is exactly:

```
MyPack.zip
  profile.json        <- required, at the zip ROOT
  MCM/                <- optional, mirrors user://MCM/
    SomeMod.cfg
    AnotherMod.json
```

This is what distinguishes a modpack from a regular mod at scan time: a regular mod has `mod.txt` at the root; a modpack has `profile.json` at the root. The loader sniffs the zip contents and routes modpacks into the Modpacks tab instead of the Mods tab (`_is_modpack_zip`, [modpacks.gd:91](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L91)).

Anything else inside the zip is treated as a `user://` override file and copied into place on apply, **except** these, which are silently dropped so a modpack can't tamper with launcher internals (`MODPACK_OVERRIDE_DENY_PREFIXES`, [modpacks.gd:29](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L29)): `mod_config.cfg`, `.profile_snapshots/`, `mws_cache/`, `vmz_mount_cache/`, and anything starting with `modloader_`. Paths containing `..` or starting with `/` are rejected too. `MCM/` is handled by the per-profile MCM snapshot mechanic, not the generic override copy.

## `profile.json`

Same schema as the [share-string body](Profile-Format#json-schema) with the modpack-relevant fields:

```json
{
  "metroprofile":      1,
  "name":              "Tarkov-style Economy",
  "modloader_version": "3.3.0",
  "exported_at":       "2026-06-20T18:02:55",
  "description":       "Harder AI + scarce loot",
  "author":            "somemodder",
  "enabled": {
    "harsher_ai@2.1.0":     true,
    "scarce_loot@1.4.0":    true
  },
  "priority": {
    "harsher_ai@2.1.0":     100,
    "scarce_loot@1.4.0":    50
  },
  "sources": {
    "harsher_ai@2.1.0":   { "modworkshop_id": 12345, "version": "2.1.0" },
    "scarce_loot@1.4.0":  { "modworkshop_id": 67890 }
  },
  "dep_ignore": {
    "harsher_ai@2.1.0": true
  }
}
```

Required fields are validated before apply touches any state (`_validate_modpack`, [modpacks.gd:47](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L47)): `metroprofile` must be `1`, `name` must be a string, `enabled` must be a dictionary. A malformed zip fails clean -- your current setup is untouched.

### `sources`

`sources` maps each `profile_key` to where the launcher can download that mod:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `modworkshop_id` | int | yes (to be downloadable) | ModWorkshop mod id. `<= 0` or absent means the mod can't be auto-installed; it shows up as an unresolved missing-mod stub. |
| `version` | string | no | Exact version to pin. When set, apply fetches `/files/<version>`; when absent, it fetches the author's primary file. |

> The on-disk field name is `modworkshop_id` (not `mws_id`). The launcher's auto-generated modpacks include `version`; older / hand-written ones may carry only `modworkshop_id`, in which case the primary file is fetched. `sources` is built from each installed mod's `[updates] modworkshop=` and `[mod] version=` (`_build_profile_sources`, [ui.gd:557](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L557)), so a mod with no `[updates] modworkshop` in its `mod.txt` gets no source entry and can't be auto-installed from the pack.

A mod listed in `enabled` but absent from `sources` (or with no `modworkshop_id`) is surfaced as an explicit failure row at apply time -- "no source info for this mod in the modpack" -- rather than silently vanishing.

## Creating a modpack

From the Modpacks tab, the **Save as modpack** action on a profile writes `<sanitized-name>.zip` into your `mods/` folder (`save_profile_as_modpack`, [modpacks.gd:843](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L843)). It refuses to overwrite an existing zip. The save dialog takes an optional author handle (remembered for next time) and a description shown on the pack's row.

If any enabled mod lacks `[updates] modworkshop=<id>`, the dialog warns you first: those mods get written to `enabled` but not to `sources`, so whoever applies the pack on a clean install sees them as missing-mod stubs they must source by hand.

## Apply

Click **Apply** on a modpack row. `apply_modpack` ([modpacks.gd:455](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L455)) runs, in order:

1. **Validate** the zip (above). Fail here = nothing changed.
2. **Download missing mods** declared in `sources`. Only an exact `profile_key` match (or a case-insensitive `mod_id@version` match) counts as already-installed; a different version of the same mod is treated as missing and the pinned version is fetched. Downloads use rename-on-collision, so a pinned version can land beside a copy you already have. Failures are non-fatal -- they become missing-mod stubs you can retry.
3. **Back up** your current profile (see below) -- skipped on a re-apply.
4. **Materialize** the pack into a managed profile slot `modpack__<name>` (only on first apply; later applies preserve any edits you made).
5. **Apply override files** from the zip, snapshotting any originals so unload can revert them.
6. **Switch** to the `modpack__<name>` profile and mark it active.

Progress (downloading / retrying / applying) is reported in the UI during the download phase, and an in-progress guard prevents two applies racing.

While a pack is applying you can **Cancel**; the in-flight download finishes (it can't be interrupted cleanly mid-request) but no further ones start, and you get a partial-success summary.

## What gets backed up

Before the first apply, your pre-pack state is snapshotted so unload can put it back exactly:

- Your active profile's `enabled` / `priority` sections are copied into a backup profile slot `_before_modpack_<name>` in `mod_config.cfg`.
- `[settings] modpack_backup_profile` records which profile you were on (so unload knows where to restore).
- Your pre-pack MCM (`user://MCM/`) is snapshotted into the backup slot under `user://.profile_snapshots/_before_modpack_<name>/`.
- Any `user://` files the pack overrides are snapshotted under that same slot, with an `overrides_manifest.json` recording which were replaced vs. newly added.

`[settings] active_modpack` is set to the pack's sanitized name to mark it live.

## Unload

**Unload** ([modpacks.gd:720](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/modpacks.gd#L720)) reverses apply:

1. Restores the `_before_modpack_<name>` sections back into your original profile.
2. Restores overridden `user://` files from the manifest (replaced files put back, added files deleted).
3. Switches you back to the profile you were on.
4. Restores your pre-pack MCM from the backup snapshot.
5. Wipes the backup slot and clears `active_modpack` / `modpack_backup_profile`.

The `modpack__<name>` slot is **kept** with any edits intact, so re-applying the same pack resumes where you left off rather than resetting to the author's defaults.

**Safety stop:** if the backup sections are gone (corrupt or hand-edited `mod_config.cfg`), unload aborts and leaves every profile untouched rather than wiping your pre-apply profile with nothing. The orange "active" state stays visible; clear it by deleting `settings.active_modpack` in `mod_config.cfg` by hand.

## Re-apply

Clicking **Apply** on the already-active pack is a re-apply: it re-runs the download step (to pick up mods that failed the first time) but **skips** the backup, materialize, and switch steps -- so it never clobbers your original backup and never discards edits you made to the live `modpack__<name>` slot. There's also a **Retry failed downloads** path that re-attempts only the items that failed.

## Current limitation: an active pack hides some dependency quick-actions

While a modpack is active, the active profile *is* the managed `modpack__<name>` slot, and the Mods tab treats it as locked:

- The profile toolbar's **New / Rename / Delete** buttons are disabled ("Unload the active modpack first").
- The per-row dependency quick-actions -- **Enable dependency**, **Load anyway**, **Re-check** -- are **hidden** while a pack is active, because edits to a managed slot wouldn't be persisted the normal way (`profile_editable` gates on the lock, [ui.gd:3109](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L3109)).

You can still see *why* a mod is blocked (the orange `won't load -- needs ...` line still renders), you just can't act on it inline until you unload the pack. The Mods tab shows a banner noting the pack is active and that edits save to the pack's slot.

## Generated state

| Path | What |
|---|---|
| `mods/<name>.zip` | the modpack itself (you put it there) |
| `mod_config.cfg` -> `profile.modpack__<name>.*` | live state of the applied pack |
| `mod_config.cfg` -> `profile._before_modpack_<name>.*` | pre-apply backup of your profile |
| `user://.profile_snapshots/modpack__<name>/` | the pack's MCM |
| `user://.profile_snapshots/_before_modpack_<name>/` | your pre-apply MCM + override snapshots + `overrides_manifest.json` |

See [Config-Files](Config-Files) for the full key reference.

## Related

- [Browse](Browse) -- where Apply downloads missing mods from.
- [Profile-Format](Profile-Format) -- the shared `metroprofile: 1` JSON schema and `profile_key` format.
- [Config-Files](Config-Files) -- `active_modpack`, `modpack_backup_profile`, and the managed profile sections on disk.
- [Mod-Format](Mod-Format) -- the `[updates] modworkshop=<id>` field that feeds `sources`.
