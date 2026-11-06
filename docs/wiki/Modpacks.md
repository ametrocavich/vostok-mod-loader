# Modpacks

A modpack is a mod list published on Vostok Mods: which mods are on, their load order, the author's in-game mod settings, and where to download each mod. It does not contain the mods. Find one under **Browse > Modpacks** and **Get** it; it then shows on the **Modpacks** tab (the third tab of the launcher), where **Apply** downloads what you are missing and switches you to the author's setup.

Apply backs up your profile and mod settings first and **Unload** brings them back, so trying a pack is safe. If one misbehaves, [report it](https://github.com/ametrocavich/vostok-mod-loader/issues) with the pack link. What a pack file holds is on [Profile-Format](Profile-Format); what a pack cannot carry is on [Limitations](Limitations#modpacks).

## The tab

The tab lists Your packs, the packs in your mods folder, each with **Details**, **Apply** (or an **Active** badge and **Unload**) and, for a pack from the site, **Refresh**. Each row counts the pack's mods and how many you have installed, for example `5 mods - 2 installed`; a pack from the site also shows its cover and `from Vostok Mods`. With no pack yet, the tab says so and points at Browse > Modpacks.

## Get a pack

Packs are found under **Browse > Modpacks**: search and sort the site's packs, or paste a pack link, and click **Get**. [Browse](Browse#modpacks) covers that list. A pack you get is saved in your mods folder as `vostokmods-<slug>.zip`, shows up on this tab the next time you open it, and from then on works like any other modpack.

## Pack details

Clicking a pack's name under Browse > Modpacks, or **Details** on a pack in Your packs, opens one dialog: the cover and description, the author, a count line such as `4 mods - 1 installed`, and the mod list. A pack in Your packs that came from the site asks the site for its mods' names; offline it lists them by key. Each mod shows `[on]` or `[off]` and one marker:

- **Installed**: you have it. A mod counts as installed whether its `mod.txt` names it by slug or by UUID.
- **Will download**: Apply fetches it.
- **Not available**: the site cannot serve it right now (still being scanned, no file yet, or removed); the reason shows on hover, and Apply reports it instead of downloading it.
- **Install by hand**: the pack gives no download source.

The dialog's buttons are **Get** (or **Added**) for a pack listed under Browse and **Apply** (or **Unload**) for one in Your packs, plus **Open page on Vostok Mods**.

## Refresh and changed packs

**Refresh** asks the site whether the pack changed. If it did, the pack file is rewritten and your edits to it are reset, so the next apply is the author's new setup. Getting a changed pack again does the same; getting or refreshing an unchanged one keeps your edits and adds the site's file checksums and the cover when the pack lacks them. Refresh then still reports `"<name>" is up to date with Vostok Mods.`, and the row shows the cover the next time you open the tab. Two packs with the same name are kept apart. An active pack cannot be refreshed; unload it first.

**Check for updates** on the Mods tab also asks the site about every pack in Your packs that came from it and reports the ones that changed ([Mods](Mods#updates)).

## Apply

Click **Apply** on a pack's row. A confirmation names the pack and counts the mods it activates, downloads, and cannot download. The launcher then downloads the missing mods (checking each against the site's checksum when there is one), backs up your setup, and switches to the pack's. A malformed pack fails before anything changes.

- **Cancel** during the downloads lets the one in flight finish, starts no more, and stops before touching your profiles. Mods already downloaded stay in your mods folder.
- A mod that fails to download is listed in the summary with its reason (by name once the launcher has read the pack's list from the site, else by its key); **Retry failed** tries only those again. A mod the pack gives no download link for is listed with the reason, for you to install by hand.
- A pack can pin an exact version. If a newer copy of that mod is installed, Apply refuses before changing anything and names the copy to remove. For a pack from the site, **Refresh** first: the author's current list usually names the version you have.

Only one pack can be active at a time; unload it before applying another. While an apply runs, **Get** and **Refresh** answer `Wait for the current apply to finish.`

## Unload

**Unload** restores the profile and MCM settings you had before applying. Your edits to the pack are kept, so applying the same pack again resumes them. If the backup is missing (a damaged or hand-edited `mod_config.cfg`), Unload cannot restore your previous profile and offers **Keep as profile** instead. That turns the pack's mods and its current MCM settings into a plain profile named after the pack (`Name 2` if the name is taken) and leaves the pack, without deleting anything from your mods folder.

## Missing mods after an apply

A mod the pack lists but that is not installed appears under **Missing from this profile** on the Mods tab with its own **Download** button. A mod the site could not serve fails there with the site's reason until the site serves it; try later or install it by hand. Neither path touches your backup or your edits.

## While a pack is active, profile editing is limited

- The profile toolbar's add, rename and delete buttons are disabled (`Unload the active modpack first`).
- The dependency buttons **Enable dependency**, **Load anyway** and **Re-check** are hidden; the orange `won't load` line still says why a mod is blocked.
- A banner at the top of the Mods tab says the pack is active and that changes save to the pack, with an **Unload** button.

## Related

- [Profile-Format](Profile-Format): the pack file, for pack authors
- [Config-Files](Config-Files): `active_modpack` and the managed profile sections on disk
- [Browse](Browse): installing single mods and getting packs from the same site
