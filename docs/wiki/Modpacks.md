# Modpacks

A **modpack** is a curated loadout shipped as a single `.zip`: which mods are on, their load order, the author's in-game mod settings, and -- crucially -- where to download each mod from. Drop the zip into your mods folder, click **Apply**, and the launcher downloads anything you're missing and switches you to the author's exact setup. New in 3.3.0.

The **Modpacks** tab is the third tab in the pre-launch window.

A modpack is a small recipe file, not a copy of the mods themselves -- it lists which mods are on, their order, and where to download each one. Applying it downloads the actual mods from ModWorkshop. A mod can only be downloaded automatically if it's linked to ModWorkshop; any that aren't must be installed by hand. (Curious what's inside the file? See [Profile-Format](Profile-Format) -- the format inside a modpack's `profile.json`.)

## Creating a modpack

From the Modpacks tab, the **Save current profile as modpack** button saves your active profile as `<name>.zip` in your mods folder. It refuses to overwrite an existing zip. The save dialog takes an optional author handle (remembered for next time) and a description shown on the pack's row.

If any enabled mod isn't linked to ModWorkshop, the dialog warns you first: those mods are still listed in the pack, but whoever applies it will have to install them by hand.

While a modpack is active you can't save a new one -- the button is disabled ("Unload the active modpack first").

## Apply

Click **Apply** on a modpack row: the launcher checks the pack, downloads any mods you're missing, backs up your current setup, and switches you to the pack's setup. A malformed pack fails clean -- your current setup is untouched.

Mods that fail to download show as failures you can retry. A mod the pack has no download link for shows an explicit reason -- "the modpack has no download info for this mod -- install it manually" -- rather than silently vanishing.

While a pack is applying you can **Cancel**; the in-flight download finishes (it can't be interrupted cleanly mid-request) but no further ones start, and you get a partial-success summary.

Only one modpack can be active at a time. To apply a different pack, **Unload** the current one first.

## Unload

Click **Unload** to go back to exactly the setup you had before applying -- your mods, settings, and any files the pack replaced are restored.

Your edits to the pack are kept, so re-applying the same pack resumes where you left off rather than resetting to the author's defaults.

**Safety stop:** if the backup is missing (corrupt or hand-edited launcher config), unload aborts and leaves everything untouched rather than wiping your setup. To force-remove the pack in that case, quit the game and delete the `active_modpack` line from `mod_config.cfg`.

## Re-apply

Clicking **Apply** on the already-active pack is a re-apply: it re-runs only the download step (to pick up mods that failed the first time), so it never clobbers your backup and never discards edits you made while the pack was active. A **Retry failed** button in the apply summary re-attempts only the downloads that failed.

## Restore backup

As an extra safety net, a restore point is saved automatically right before every apply. The **Restore backup** button on the Modpacks tab rolls your profiles, mod settings, and overwritten files back to a point saved before a modpack was applied. Only the newest few restore points are kept.

Restoring is refused while a pack is active -- Unload first. Unload reverts the pack's files; restoring on top of an active pack would leave its files behind.

## While a pack is active, profile editing is limited

While a modpack is active, the Mods tab treats your profile as locked:

- The profile toolbar's **New / Rename / Delete** buttons are disabled ("Unload the active modpack first").
- The per-row dependency quick-actions -- **Enable dependency**, **Load anyway**, **Re-check** -- are hidden. You can still see *why* a mod is blocked (the orange `won't load -- needs ...` line still renders); you just can't act on it inline until you unload the pack.

The Mods tab shows a banner noting the pack is active and that edits save to the pack's setup.

## For modpack authors

Everything below is internals -- you don't need any of it to use modpacks.

### Zip layout

A modpack zip is exactly:

```
MyPack.zip
  profile.json        <- required, at the zip ROOT
  MCM/                <- optional, mirrors user://MCM/
    SomeMod.cfg
    AnotherMod.json
```

This is what distinguishes a modpack from a regular mod at scan time: a regular mod has `mod.txt` at the root; a modpack has `profile.json` at the root. The launcher sniffs the zip contents and routes modpacks into the Modpacks tab instead of the Mods tab.

Anything else inside the zip is treated as a `user://` override file and copied into place on apply, **except** launcher-internal paths, which are silently dropped so a modpack can't tamper with launcher state: `mod_config.cfg`, `.profile_snapshots/`, `.modpack_backups/`, `mws_cache/`, `vmz_mount_cache/`, and anything starting with `modloader_`. Paths containing `..` or starting with `/` are rejected too. `MCM/` is handled by the per-profile MCM snapshot mechanic, not the generic override copy.

### `profile.json`

A modpack's `profile.json` uses the metroprofile v1 format -- see [Profile-Format](Profile-Format) for the full field reference. The modpack-relevant fields:

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

Required fields are validated before apply touches any state: `metroprofile` must be `1`, `name` must be a string, `enabled` must be a dictionary.

### `sources`

`sources` maps each `profile_key` to where the launcher can download that mod:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `modworkshop_id` | int | yes (to be downloadable) | ModWorkshop mod id. `<= 0` or absent means the mod can't be auto-installed; it shows up as an unresolved missing-mod stub. |
| `version` | string | no | Exact version to pin. When set, apply fetches `/files/<version>`; when absent, it fetches the author's primary file. |

> The on-disk field name is `modworkshop_id` (not `mws_id`). The launcher's auto-generated modpacks include `version`; older / hand-written ones may carry only `modworkshop_id`, in which case the primary file is fetched. `sources` is built from each installed mod's `[updates] modworkshop=` and `[mod] version=`, so a mod with no `[updates] modworkshop` in its `mod.txt` gets no source entry and can't be auto-installed from the pack.

At apply time, only an exact `profile_key` match (or a case-insensitive `mod_id@version` match) counts as already-installed; a different version of the same mod is treated as missing and the pinned version is fetched, landing beside the copy already there (rename-on-collision). A mod listed in `enabled` but absent from `sources` (or with no `modworkshop_id`) is surfaced as an explicit failure row -- "the modpack has no download info for this mod -- install it manually" -- rather than silently vanishing.

### Generated state

| Path | What |
|---|---|
| `mods/<name>.zip` | the modpack itself (you put it there) |
| `mod_config.cfg` -> `profile.modpack__<name>.*` | live state of the applied pack |
| `mod_config.cfg` -> `profile._before_modpack_<name>.*` | pre-apply backup of your profile |
| `user://.profile_snapshots/modpack__<name>/` | the pack's MCM |
| `user://.profile_snapshots/_before_modpack_<name>/` | your pre-apply MCM + override snapshots + `overrides_manifest.json` |
| `user://.modpack_backups/` | independent pre-apply restore points (newest few kept) -- what **Restore backup** restores |

See [Config-Files](Config-Files) for the full key reference.

## Related

- [Browse](Browse) -- where Apply downloads missing mods from.
- [Profile-Format](Profile-Format) -- the metroprofile v1 format inside a modpack's `profile.json`.
- [Config-Files](Config-Files) -- `active_modpack`, `modpack_backup_profile`, and the managed profile sections on disk.
- [Mod-Format](Mod-Format) -- the `[updates] modworkshop=<id>` field that feeds `sources`.
