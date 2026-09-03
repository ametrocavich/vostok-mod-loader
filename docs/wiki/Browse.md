# Browse

The **Browse** tab installs mods straight from a mod site without leaving the launcher. It is the second tab in the pre-launch window (after **Mods**). Introduced in 3.3.0; since 3.3.1 it browses more than one site.

This page covers which sites Browse talks to, what it shows, how to search and install, how the download queue behaves, where dependencies surface, and what happens offline.

## What it talks to

Browse opens on [VostokMods](https://vostokmods.net), the Road to Vostok community's own mod site, and can switch to [ModWorkshop](https://modworkshop.net) from the **source** menu at the left of the toolbar. Both read a public mod catalog and download the file you pick; nothing about your PC or your installed mods is sent. Each catalog only shows Road to Vostok mods.

VostokMods scans every upload before it is served. Browse only offers versions the site has cleared, so a mod whose newest file is still being scanned shows no **Download** button until the scan finishes.

The loader's own updates are not fetched from either site; the version link in the launcher header checks the loader's GitHub releases.

## Layout

A toolbar across the top, a status line, then a scrolling list of mod rows with a **Load more** button at the bottom.

**Toolbar**

- **Source menu** -- `VostokMods` or `ModWorkshop`. Everything to its right applies to the selected site, and each site keeps its own search text, sort and category while you switch back and forth.
- **Search box** (`Search VostokMods...` / `Search ModWorkshop...`) -- free-text query.
- **Sort menu** -- `Featured` first, then the site's own sorts. VostokMods: `Newest release`, `Recently updated`, `Most downloaded`, `Most viewed`, `Most followed`, `Newest mod`. ModWorkshop: `Recently updated`, `Most downloaded`, `Most liked`, `Most viewed`, `Newest`.
- **Category menu** -- `All categories` plus the site's categories.

**Two modes.** With `Featured` selected and no search or category, Browse shows the site's landing: **Popular** and **New releases** on VostokMods, **Popular this week** and **Latest** on ModWorkshop. Typing a query, picking a sort, or picking a category switches to a single filtered list. **Load more** fetches the next page and merges it into the list; the status line shows how many of the total results are loaded (e.g. `24 of 130 mods`).

ModWorkshop ignores the sort while a search query is set, so Browse re-sorts search results itself by the chosen sort across every loaded page. Rapid clicks on sort/category are safe: the list always matches the menus.

## A mod row

Each row shows a thumbnail, name, author, version where the site reports one, quick stats (downloads, plus likes and views on ModWorkshop), category and last-updated date, plus an action on the right:

- **Download**. The mod is not installed. Click to fetch it into your `mods/` folder.
- **Enabled in <profile>** toggle. The mod is already on disk. The toggle works straight from Browse (no need to switch to the Mods tab).
- **Browse only**. The site cannot serve the file through the launcher (for example a mod that is still being scanned). Open its page in the browser instead.

Browse recognizes an installed mod by the source its `mod.txt` declares (`[updates] source="vostokmods:<slug>"` or `source="modworkshop:<id>"`, or the older `modworkshop=<id>`), or, when the author declared none, by the launcher's own record of where it downloaded the file.

Clicking the row name opens a **detail dialog**: banner image, full description, a **Files** list (every downloadable version with size and date, the current one flagged as primary), an **Open mod page in browser** button, and a **Download** / **Installed** button mirroring the row.

> Neither site's dependency data is shown in the detail dialog. Dependencies surface *after* install -- see below.

## Installing a mod

1. Find the mod (landing, search, or category filter).
2. Click **Download** on the row (or in the detail dialog).
3. The button changes to **Downloading...**, the status line reports progress, and on success the button becomes **Installed**. The Mods tab is rebuilt so the new mod appears there immediately, enabled in your active profile.

The mod file is saved into your `mods/` folder, and the launcher remembers which site it came from so the Updates tab can check it later even if the author's `mod.txt` says nothing.

**Already have it.** A plain Browse install refuses to overwrite an existing file -- if a file of the same name is already in `mods/`, the download fails with `Already have a file named <name>` rather than clobbering it. (Modpack apply uses a different, rename-on-collision path; see [Modpacks](Modpacks).)

## The download queue

Downloads run **one at a time**. While one is in flight, clicking **Download** on other rows queues them up:

- The queued row's button shows **Queued** and the status line reports the queue depth.
- When the current download finishes, the next queued item starts automatically (FIFO).
- Clicking the same mod twice is a no-op (`Already downloading this mod` / `Already queued`).

Closing the launcher (Launch or the X) mid-download is safe: the in-flight download still finishes writing to disk, so you will not end up with a half-installed mod.

## How dependencies surface

Browse installs exactly the mod you click. It does **not** auto-install other mods that mod requires. Dependency checks happen in the **Mods** tab after install:

- If an installed mod requires another mod that is missing or disabled, its Mods-tab row turns orange: `won't load -- needs <dep>`.
- Inline fix buttons appear: **Enable dependency** (turns on a requirement that is installed but disabled) and **Load anyway** (a per-profile override that skips the check for that mod).
- If a required dependency is missing entirely, install it from Browse the same way, then re-check.

See [Mod-Format](Mod-Format#dependencies-section) for how mod authors declare dependencies, and [Config-Files](Config-Files) for where the **Load anyway** override is stored.

## Caching

- **Thumbnails / banners** from ModWorkshop persist to `user://mws_cache/thumbs/` (its image names never change once uploaded). VostokMods images are kept in memory for the session only.
- **Search results and mod details** are cached in memory for a few minutes. Each site's landing view is additionally saved to disk (`user://mws_cache/landing_<site>.json`) so Browse can show your last results when you are offline.

Both are safe to delete; see [Config-Files: Generated files](Config-Files#generated-files----safe-to-delete).

## Offline / failure behavior

If Browse cannot reach the selected site when it opens, it shows the last landing it successfully loaded from that site (saved on disk from a previous session) behind a notice -- `Showing cached results. VostokMods is unreachable.` -- with how old they are and a **Retry** button. If there are no saved results, or a search fails, you get a failure message with a **Retry** button instead. A failed **Load more** keeps what is already on screen -- clicking **Load more** again retries.

| Where | Message |
|---|---|
| Landing (no saved results) | `<Site>: could not load mods. Check your connection and try again.` |
| Search / filter results | `Could not reach <Site>. Check your connection.` (or the site's own error) |
| Detail dialog file list | the same site error, in place of the list |
| A failed download | `Could not download <mod name>. <reason>` |
| An empty catalog | `No mods on <Site> yet. Pick <other site> in the source menu to browse there.` |

When a site rate-limits the launcher, these messages instead read `<Site> rate limit reached. Try again in <N>s.`, and a queued download waits the cooldown out with a countdown rather than failing.

## Related

- [Modpacks](Modpacks) -- apply a shared list of mods in one go.
- [Mod-Format](Mod-Format) -- for mod authors: how a mod declares its source (which Browse uses to recognize installed mods) and its dependencies.
- [Config-Files](Config-Files) -- where the active profile, the **Load anyway** overrides, and the Browse cache live.
