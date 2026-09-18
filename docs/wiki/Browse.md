# Browse

The **Browse** tab installs mods from a mod site without leaving the launcher. It is the second tab in the pre-launch window, after **Mods**.

## What it talks to

Browse opens on [VostokMods](https://vostokmods.net), the Road to Vostok community's own mod site. The **source** menu at the left of the toolbar switches to [ModWorkshop](https://modworkshop.net), and the launcher remembers whichever you used last. Both sites expose a public catalog of Road to Vostok mods; the launcher reads that catalog and downloads the file you pick. Nothing about your PC or your installed mods is sent.

VostokMods scans every upload before serving it. Browse only offers versions the site has cleared, so a mod whose newest file is still being scanned shows **No file yet** instead of a **Download** button until the scan finishes.

The loader does not fetch its own updates from either site. The version link in the launcher header checks the loader's GitHub releases.

## Layout

A toolbar across the top, a status line, then a scrolling list of mod rows with a **Load more** button at the bottom.

The toolbar, left to right:

- Source menu: `VostokMods` or `ModWorkshop`. Everything to its right applies to the selected site. Each site keeps its own search text, sort and category, so switching back and forth does not lose your place.
- Search box (`Search VostokMods...` / `Search ModWorkshop...`).
- Sort menu: `Featured` first, then the site's own sorts. VostokMods: `Newest release`, `Recently updated`, `Most downloaded`, `Most viewed`, `Most followed`, `Newest mod`. ModWorkshop: `Recently updated`, `Most downloaded`, `Most liked`, `Most viewed`, `Newest`.
- Category menu: `All categories` plus the site's categories.

Browse has two modes. With `Featured` selected and no search or category, it shows the site's landing: **Popular** and **New releases** on VostokMods, **Popular this week** and **Latest** on ModWorkshop. Typing a query, picking a sort, or picking a category switches to a single filtered list. **Load more** fetches the next page and appends it; the status line counts what is loaded against the total, for example `24 of 130 mods`.

ModWorkshop ignores the sort while a search query is set, so Browse re-sorts search results itself by the chosen sort across every loaded page. Clicking sort and category quickly is safe; the list always matches the menus.

## A mod row

Each row shows a thumbnail, name, author, version where the site reports one, quick stats (downloads, plus likes and views on ModWorkshop), category and last-updated date, and an action on the right:

- **Download**: the mod is not installed. Click to fetch it into your `mods/` folder.
- **Enabled in <profile>**: the mod is already on disk. The checkbox toggles it in your active profile without a trip to the Mods tab.
- **No file yet**: the site has nothing to serve for this mod right now, usually because its upload is still being scanned. Check back later or open its page in the browser.

Browse recognizes an installed mod by an explicit `[updates] source="vostokmods:<slug>"` or `source="modworkshop:<id>"` in its `mod.txt`. Without one, the launcher's own record of where it downloaded the file counts, and only then the older `modworkshop=<id>` line. Files served by VostokMods carry that older line, so a mod you installed from the VostokMods tab stays a VostokMods mod.

Clicking the row name opens a detail dialog: banner image, full description, a **Files** list (every downloadable version with size and date, the current one marked `(primary)`), an **Open mod page in browser** button, and a **Download** or **Installed** button matching the row. A mod with nothing to download shows `No downloadable files yet.` where the list would be.

Neither site's dependency data appears in the detail dialog. Dependencies surface after install, see below.

## Installing a mod

1. Find the mod (landing, search, or category filter).
2. Click **Download** on the row or in the detail dialog.
3. The button changes to **Downloading...** and the status line reports progress. On success the button becomes **Installed**, the status line reads `Installed <file name>`, and the Mods tab is rebuilt so the new mod appears there, enabled in your active profile.

The file is saved into your `mods/` folder, and the launcher records which site it came from in `mod_config.cfg` so the update check can find it later even if the author's `mod.txt` says nothing.

A Browse download never overwrites an existing file. If `mods/` already holds a file of the same name, the download fails with `Already have a file named <name>`. Modpack apply takes a different path and renames on collision; see [Modpacks](Modpacks).

If you download a mod after the game has already booted (from the main menu's Mods button), closing the launcher restarts the game so the new mod set loads.

## The download queue

Downloads run one at a time. While one is in flight, clicking **Download** on other rows queues them:

- The queued row's button shows **Queued** and the status line reports the queue depth.
- When the current download finishes, the next queued item starts on its own, in click order.
- Clicking the same mod twice does nothing (`Already downloading this mod` / `Already queued`).

If the site rate-limits the launcher mid-queue, the next download waits out the cooldown with a countdown (`Rate limited by <Site> -- resuming in <N>s`) instead of failing.

Closing the launcher (Launch or the X) mid-download never leaves a half-installed mod: a download is written to the mods folder only once all of it has arrived. If Launch restarts the game to apply your mod changes before a download finishes, that download is dropped and nothing of it is kept; start it again next time.

## How dependencies surface

Browse installs exactly the mod you click. It does not install other mods that mod requires. Dependency checks happen in the **Mods** tab after install:

- If an installed mod requires another mod that is missing or disabled, its Mods-tab row shows an orange line: `won't load -- needs <dep>`.
- Inline fix buttons appear beside it: **Enable dependency** (turns on a requirement that is installed but disabled) and **Load anyway** (a per-profile override that skips the check for that mod). **Re-check** undoes Load anyway.
- If a required dependency is missing entirely, install it from Browse the same way.

See [Mod-Format](Mod-Format#dependencies-section) for how mod authors declare dependencies, and [Config-Files](Config-Files) for where the **Load anyway** override is stored.

## Caching

- ModWorkshop thumbnails and banners are saved to `user://mws_cache/thumbs/` (its image names never change once uploaded). VostokMods images are kept in memory for the session only.
- Search results and mod details are cached in memory: VostokMods listings for five minutes, details for thirty, categories for an hour. Each site's landing view is also saved to disk as `user://mws_cache/landing_<site>.json` so Browse can show your last results when you are offline.

Both are safe to delete; see [Config-Files: Generated files](Config-Files#generated-files----safe-to-delete).

## Offline / failure behavior

If Browse cannot reach the selected site when it opens, it shows the last landing it loaded from that site behind a notice, `Showing cached results. VostokMods is unreachable.`, with how old the results are (`Last refreshed ...`) and a **Retry** button. If there are no saved results, or a search fails, you get a failure message with a **Retry** button instead. A failed **Load more** keeps what is already on screen; click **Load more** again to retry.

| Where | Message |
|---|---|
| Landing (no saved results) | `<Site>: could not load mods. Check your connection and try again.` |
| Search / filter results | `Could not reach <Site>. Check your connection.` (or the site's own error) |
| Detail dialog file list | the same site error, in place of the list |
| A failed download | `Could not download <mod name>. <reason>` |
| An empty catalog | `No mods on <Site> yet. Pick <other site> in the source menu to browse there.` |

If only some of the landing sections load, the ones that did are shown under a `Part of this page could not be loaded.` banner with a **Retry** button.

When a site rate-limits the launcher, these messages read `<Site> rate limit reached. Try again in <N>s.` instead.

## Related

- [Modpacks](Modpacks): apply a shared list of mods in one go.
- [Mod-Format](Mod-Format): for mod authors, how a mod declares its source (which Browse uses to recognize installed mods) and its dependencies.
- [Config-Files](Config-Files): where the active profile, the **Load anyway** overrides, and the Browse cache live.
