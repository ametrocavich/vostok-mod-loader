# Browse

The **Browse** tab installs mods from a mod site, and gets modpacks from Vostok Mods, without leaving the launcher. It is the second tab in the pre-launch window, after **Mods**.

## What it talks to

Browse opens on [Vostok Mods](https://vostokmods.net), the Road to Vostok community's own mod site. The **source** menu in the toolbar switches to [ModWorkshop](https://modworkshop.net), and the launcher remembers whichever you used last. The launcher reads each site's public catalog and downloads the file you pick; nothing about your PC or your installed mods is sent.

Vostok Mods scans every upload before serving it. Browse only offers versions the site has cleared, so a mod whose newest file is still being scanned shows **No file yet** until the scan finishes.

The **Mods** / **Modpacks** switch at the left of the toolbar picks what Browse lists; packs are covered under [Modpacks](#modpacks) below. The launcher remembers the choice.

Both sites list the mod loader itself; Browse never shows that listing, because **Download** would put the loader into `mods/`. A page can come back one row short for that reason. Install or update the loader from its [release page](https://github.com/ametrocavich/vostok-mod-loader/releases/latest); see [Setup](Setup).

## Layout

A toolbar across the top, a status line, then a scrolling list of rows with a **Load more** button at the bottom; the switch decides whether the rows are mods or packs. The toolbar, left to right:

- **Mods** / **Modpacks** switch. Each keeps its own list and place, so switching back does not reload.
- Source menu: `Vostok Mods` or `ModWorkshop`. Each site keeps its own search text, sort and category, so switching back and forth does not lose your place.
- Search box (`Search Vostok Mods...` / `Search ModWorkshop...`).
- Sort menu: `Featured` first, then the site's own sorts. Vostok Mods: `Recently updated` (newest downloadable file first; editing a mod's page does not move it), `Most downloaded`, `Most viewed`, `Most followed`, `Newest mod`. ModWorkshop: `Recently updated`, `Most downloaded`, `Most liked`, `Most viewed`, `Newest`.
- Category menu: `All categories` plus the site's categories.

With `Featured` selected and no search or category, Browse shows the site's landing: **Popular** and **New releases** on Vostok Mods, **Popular this week** and **Latest** on ModWorkshop. A query, a sort or a category switches to a single filtered list. **Load more** appends the next page; the status line counts what is loaded against the total, for example `24 of 130 mods`.

ModWorkshop ignores the sort while a search query is set, so Browse re-sorts search results itself across every loaded page. Clicking sort and category quickly is safe; the list always matches the menus.

## A mod row

Each row shows a thumbnail (the first frame of an animated cover), name, author, version where the site reports one, downloads and views (plus likes on ModWorkshop), category and last-updated date (on Vostok Mods, the upload date of the newest downloadable file), and an action on the right:

- **Download**: the mod is not installed. Click to fetch it into your `mods/` folder.
- **Enabled in <profile>**: the mod is already on disk. The checkbox toggles it in your active profile without a trip to the Mods tab.
- **No file yet**: the site has nothing to serve for this mod right now, usually because its upload is still being scanned.

Browse knows a mod is installed from the `[updates] source=` line in its `mod.txt`, or else from the launcher's own record of where it downloaded the file. A Vostok Mods mod matches by its slug or its UUID. [Mod-Format](Mod-Format#updates-section) has the `source=` format.

Clicking the row name opens a detail dialog: banner image, full description, a **Files** list (every downloadable version with size and date, the current one marked `(primary)`), an **Open mod page in browser** button, and a **Download** or **Installed** button matching the row. Neither site's dependency data appears there.

## Installing a mod

Click **Download** on the row or in the detail dialog. The button changes to **Downloading...** and the status line reports progress, then `Installed <file name>`. When the queue finishes, the row gains its **Enabled in <profile>** checkbox and the Mods tab is rebuilt. The new mod is enabled if your active profile is **Default**; any other profile lists it unticked until you turn it on. The launcher records which site the file came from, so the update check finds it even if the author's `mod.txt` says nothing.

A Browse download never overwrites an existing file. If `mods/` already holds a file of the same name that is not the same mod at the same or a newer version, the download fails with `Already have a file named <name>`. When it is the same mod (one you dropped in by hand), nothing is downloaded: the row flips to **Installed** and the site is recorded as its source.

When you already have a mod from the same mod page, a download whose `mod.txt` names the `id` of a mod you installed from elsewhere is refused, and the error says the page may be serving the wrong file. A file whose `id` matches nothing you have is treated as the author renaming the mod and installs beside the old file; delete the old one from the Mods tab. Modpack apply and the missing-mod **Download** button make the same check.

Browse installs exactly the mod you click, not the mods it requires. A missing requirement shows on the Mods tab after install; see [Mods](Mods#dependencies).

A download made after the game booted (from the main menu's Mods button) restarts the game on close only when the new mod is enabled in your active profile.

## The download queue

Downloads run one at a time. Clicking **Download** on other rows meanwhile queues them: the button shows **Queued**, the status line reports the queue depth, and the next item starts on its own, in click order. Clicking the same mod twice does nothing. If the site rate-limits the launcher mid-queue, the next download waits out the cooldown with a countdown instead of failing.

A download is written to the mods folder only once all of it has arrived, so closing the launcher never leaves a half-installed mod. If Launch restarts the game before a download finishes, that download is dropped; start it again next time. If the window closes without a restart, the download keeps running and the mod is listed the next time you open the window.

## Caching and offline

Search results and mod details are cached in memory for minutes; ModWorkshop images and each site's landing view are also saved to disk ([Config-Files](Config-Files#generated-files-safe-to-delete) lists the files, all safe to delete).

If Browse cannot reach the selected site when it opens, it shows the last landing it loaded from that site under `Showing cached results.`, with how old the results are and a **Retry** button. With no saved results, or when a search, a detail file list or a download fails, Browse shows the site's error with a **Retry** button. A failed **Load more** keeps what is already on screen; click it again to retry.

Vostok Mods tells the launcher how many requests it has left. When they run out, or the site refuses a request as too frequent, the launcher pauses its requests to that site for the seconds the site names, and a rate-limited request says when to try again.

## Modpacks

With **Modpacks** selected, Browse lists the packs published on Vostok Mods; the source menu is hidden, since packs come from that site only. The list loads the first time you switch to it. The toolbar holds a search box (`Search Vostok Mods packs...`), a sort menu (`Recently updated`, `Newest`, `Most downloaded`, `Most viewed`) and a box for a pack link with its own **Get** button. The search runs as you type, or at once on Enter. The status line counts what is loaded, for example `20 of 45 packs`, and **Load more** appends the next page.

Each row shows the pack's cover, name, author, mod count, downloads, views and last-updated date. **Get** saves the pack to the [Modpacks](Modpacks) tab without applying it; the button then reads **Added**. Pasting a pack link (the page address, the site's "Copy loader link", or the bare slug) and clicking that **Get** does the same. The status line reads `Getting "<name>"...` for a row's **Get** and `Getting the pack...` for a pasted link, then `Added "<name>" to Your packs; Apply it on the Modpacks tab.` One pack is fetched at a time: while one is in flight, every other **Get** is disabled. Clicking a row's name opens the pack's details ([Modpacks](Modpacks#pack-details)).

The pack is saved in your mods folder as `vostokmods-<slug>.zip`. The launcher fetches packs and their mods only from `vostokmods.net` over https, and a link that answers with a different pack than it names is refused. A link with a port number (`vostokmods.net:443/...`) counts as another site: `That is not a Vostok Mods modpack link.`

When the site cannot be reached, the list shows the last first page it loaded for the chosen sort under `Showing cached results.`, with how old it is and a **Retry** button. A search, or a sort with no saved page, shows `Could not load packs.` with the reason in the banner above it.
