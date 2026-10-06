# Modpacks

A modpack is a mod list published on vostokmods.net: which mods are on, their load order, the author's in-game mod settings, and where to download each mod from. It does not contain the mods themselves. Get one from the Modpacks tab, click **Apply**, and the launcher downloads anything you are missing and switches you to the author's setup.

Modpacks from Vostok Mods are in beta in 3.4. The site's pack pages are new, and the feature was built and tested against the site's published format before any real pack existed. Apply backs up your profile and mod settings first and **Unload** brings them back, so trying a pack is safe; if one misbehaves, [report it](https://github.com/ametrocavich/vostok-mod-loader/issues) with the pack link.

The **Modpacks** tab is the third tab in the pre-launch window.

Applying a pack downloads each mod from Vostok Mods at the version the pack names. A mod the site cannot serve right now is listed with the reason, and you install it by hand. Curious what is inside a pack? See [Profile-Format](Profile-Format).

## Packs from Vostok Mods

**Get from Vostok Mods** on the Modpacks tab opens the packs published on vostokmods.net. Search them, sort by recently updated, newest or name, and click **Get** on one, or paste a pack link into the box at the top (the pack's page address or the "Copy loader link" from the site both work) and click **Add**. The launcher fetches the pack's mod list and writes it into your mods folder as `vostokmods-<slug>.zip`, and from there it is an ordinary modpack: **Apply** and **Unload** work the same way.

A pack from the site lists Vostok Mods mods only. A mod you already have counts as installed whether its `mod.txt` names it by slug or by the UUID the site writes into every file it serves, and so does one the site cannot serve right now; the launcher learns which slug goes with which UUID from the site, and before an apply asks it about installed mods it has not paired yet. Each missing mod is downloaded by its slug at the version the pack names, and when the site publishes a checksum for the file the download is checked against it. A mod the site cannot serve right now shows as **Not available** in the pack's details, with the reason on hover, and is reported on apply instead of downloaded:

- `this mod's file is still being scanned by Vostok Mods -- try again in a while`
- `this mod has no downloadable file on Vostok Mods yet -- try again later`
- `this mod was removed from Vostok Mods -- install it manually`

Packs published on the site carry their MCM settings, and applying one restores them the same way a local pack's `MCM/` folder is restored.

A pack you got from the site shows `from Vostok Mods` in its row and a **Refresh** button. Refresh asks the site whether the pack changed (its mod list, pinned versions or settings); if it did, the local zip is rewritten and you apply it again to pick up the changes. A refresh that changed the pack also resets the edits you made to it, so the next apply is the author's new setup: mod list, load order and MCM settings. Pasting the link again or using **Get** for a changed pack resets the kept setup in the same way. Reimporting a pack with the same site hash keeps your edits. An active pack cannot be refreshed or replaced by a changed import; unload it first. The pack's details dialog has an **Open page on Vostok Mods** button.

## Apply

Click **Apply** on a modpack row. A confirmation names the pack, how many mods it activates, how many it will download, and how many it cannot download and will list for a manual install; then the launcher downloads the missing mods, backs up your current setup, and switches you to the pack's setup. A malformed pack fails before anything changes.

Mods that fail to download show up in a summary you can retry from. A mod the pack has no download link for gets an explicit reason instead of vanishing:

- `the modpack has no download info for this mod -- install it manually`
- `the modpack does not say where this mod is hosted -- install it manually`

While the downloads run you can **Cancel**. The download in flight finishes (it cannot be interrupted cleanly mid-request), no further ones start, and the apply stops before touching your profiles: `Apply cancelled -- the modpack was not applied and your profiles are unchanged.` Any mods that had already downloaded stay in your mods folder.

A pack can pin a mod to an exact version. If you already have a newer copy of that mod installed, Apply refuses before it downloads or changes anything: `This pack requires <mod> at <version>. Remove the newer installed version <version> before applying it.` Remove the newer file from the Mods tab (or your mods folder) and apply again; the pinned version is then downloaded. A pack from Vostok Mods pins the versions the site had when you got it, so there the message suggests **Refresh** first: the author's current list usually names the version you already have.

Only one modpack can be active at a time. To apply a different pack, **Unload** the current one first.

## Unload

Click **Unload** to go back to the setup you had before applying. Your profile and your MCM settings are restored. Non-MCM overrides from packs applied in 3.3.1 are no longer restored automatically; any original files left beside the backup slot's `MCM/` directory remain on disk for manual recovery.

Your edits to the pack are kept, so re-applying the same pack resumes where you left off instead of resetting to the author's defaults.

If the backup is missing (a corrupt or hand-edited launcher config), unload refuses and leaves everything untouched: `The backup for this modpack is missing, so nothing was unloaded and your profiles are untouched.` To force-remove the pack in that case, quit the game and delete the `active_modpack` line from `mod_config.cfg`.

## Retrying failed downloads

The apply summary lists the downloads that failed, and its **Retry failed** button re-attempts only those. After that, a mod the pack lists but that is not installed shows in the Mods tab as a missing-mod row with its own **Download** button. Neither path touches your backup or the edits you made while the pack was active. The active pack's row offers **Unload** only; there is no second **Apply**.

## While a pack is active, profile editing is limited

The Mods tab treats your profile as locked while a modpack is active:

- The profile toolbar's add (**+**), rename (pencil) and delete (trash can) buttons are disabled; their tooltip reads `Unload the active modpack first`.
- The per-row dependency actions **Enable dependency**, **Load anyway** and **Re-check** are hidden. The orange `won't load -- needs ...` line still shows why a mod is blocked; you just cannot act on it until you unload the pack.

A banner at the top of the Mods tab reads `Modpack "<name>" is active. Changes here save to the modpack, not your profiles.` with an **Unload** button beside it.

## For modpack authors

Everything below is internals. You do not need any of it to use modpacks.

### Zip layout

**Get from Vostok Mods** writes the pack as `mods/vostokmods-<slug>.zip`. Its `profile.json` carries three optional fields (`hosted`, `unavailable`, `checksums`) described in [Profile-Format](Profile-Format), and its mods are keyed `vostokmods:<slug>` until apply rewrites them to the installed mods' own keys. The launcher applies any zip in the mods folder that has `profile.json` at its root, so a pack made by hand in this layout works too.

A modpack zip is:

```
MyPack.zip
  profile.json        <- required, at the zip ROOT
  MCM/                <- optional, mirrors user://MCM/
    SomeMod.cfg
    AnotherMod.json
```

This is what distinguishes a modpack from a regular mod at scan time: a regular mod has `mod.txt` at the root, a modpack has `profile.json` at the root. The launcher sniffs the zip contents and routes modpacks into the Modpacks tab instead of the Mods tab.

Anything else inside the zip is ignored.

### `profile.json`

A modpack's `profile.json` uses the metroprofile v1 format; see [Profile-Format](Profile-Format) for the full field reference. The modpack-relevant fields:

```json
{
  "metroprofile":      1,
  "name":              "Tarkov-style Economy",
  "modloader_version": "3.4.1",
  "exported_at":       "2026-09-30T18:02:55",
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
    "harsher_ai@2.1.0":   { "provider": "vostokmods", "id": "harsher-ai", "version": "2.1.0" },
    "scarce_loot@1.4.0":  { "provider": "modworkshop", "id": "67890", "modworkshop_id": 67890, "version": "1.4.0" }
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
| `provider` | string | yes (new format) | Host token: `modworkshop` or `vostokmods`. |
| `id` | string | yes (new format) | That host's mod id. For Vostok Mods this is the slug, which is what the site's manifests carry; a mod UUID resolves too. |
| `modworkshop_id` | int | mirror | Compatibility mirror for older loaders, for a hand-written `provider == "modworkshop"` record only; packs the launcher writes are Vostok Mods-only and never carry it. An older loader reads this; a newer one reads `provider` + `id` and never consults the mirror. Absent for other hosts so an old loader does not download an unrelated ModWorkshop mod with the same number. |
| `version` | string | no | Exact version to pin. When set, apply fetches that version, or fails if the host no longer has it; when absent, it fetches the host's current file. |

A record with neither a resolvable `provider` + `id` nor a positive `modworkshop_id` cannot be auto-installed and appears as a missing-mod row with a reason.

A pack from Vostok Mods pins every mod to the version its manifest names. A hand-written pack may carry only the id, in which case the current file is fetched.

At apply time a mod counts as already installed on an exact `profile_key` match, a case-insensitive `mod_id@version` match, or when an installed mod's recorded source is the pack entry's site id at the pinned version (any version when the pack pins none). A site's version label can differ from the version in the file's own `mod.txt`, so when the pack carries a checksum for the pinned file, an installed archive of that mod with the same bytes counts as the pinned version whatever its `mod.txt` says. A newer requested version is fetched, landing beside the copy already there with a `-v<version>` suffix. If a newer copy is already installed than the pack requests, Apply stops before downloads or profile changes and asks you to remove that newer copy first: discovery always selects the newest copy. After the downloads land, the pack's `enabled` / `priority` / `dep_ignore` keys are rewritten to the keys those mods actually have on the recipient's machine (matched by `mod_id@version`, or by the pack's source record against the installed mod's source at the pinned version), so a mod the author keyed by filename still enables when the host serves it under another name.

### Generated state

| Path | What |
|---|---|
| `mods/vostokmods-<slug>.zip` | the modpack itself, written by **Get from Vostok Mods** |
| `mod_config.cfg` -> `profile.modpack__<name>.*` | live state of the applied pack |
| `mod_config.cfg` -> `profile._before_modpack_<name>.*` | pre-apply backup of your profile |
| `user://.profile_snapshots/modpack__<name>/` | the pack's MCM |
| `user://.profile_snapshots/_before_modpack_<name>/` | your pre-apply MCM |

See [Config-Files](Config-Files) for the full key reference.

## Related

- [Browse](Browse): where Apply downloads missing mods from.
- [Profile-Format](Profile-Format): the metroprofile v1 format inside a modpack's `profile.json`.
- [Config-Files](Config-Files): `active_modpack`, `modpack_backup_profile`, and the managed profile sections on disk.
- [Mod-Format](Mod-Format): the `[updates] source=` field that feeds `sources`.
