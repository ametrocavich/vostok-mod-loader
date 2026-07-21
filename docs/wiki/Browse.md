# Browse

The **Browse** tab installs mods straight from [ModWorkshop](https://modworkshop.net) without leaving the launcher. It is the second tab in the pre-launch window (after **Mods**). New in 3.3.0.

This page covers what Browse shows, how to search and install, how the download queue behaves, where dependencies surface, and what happens offline.

## What it talks to

Browse talks only to modworkshop.net. It reads the public mod catalog and downloads the file you pick -- nothing about your PC or your installed mods is sent. The catalog only shows Road to Vostok mods.

## Layout

A toolbar across the top, a status line, then a scrolling list of mod rows with a **Load more** button at the bottom.

**Toolbar**

- **Search box** (`Search mods...`) -- free-text query.
- **Sort dropdown** -- `Recently updated`, `Most downloaded`, `Most liked`, `Most viewed`, `Newest`.
- **Category dropdown** -- `All categories` plus the Road to Vostok categories pulled from ModWorkshop.

**Two modes.** On open, Browse shows two sections, **Popular** and **Latest**. Typing a query, changing the sort, or picking a category switches to a single filtered list. The **Load more** button at the bottom fetches the next page and merges it into the list, keeping everything sorted by your selected sort across all loaded pages; the status line shows how many of the total results are loaded (e.g. `60 of 240 mods`).

Rapid clicks on sort/category are safe: the list always matches the dropdowns.

## A mod row

Each row shows a thumbnail, name, author, and quick stats (downloads / likes), plus an action button on the right:

- **Download** -- the mod is not installed. Click to fetch it into your `mods/` folder.
- **Installed** / an enable toggle -- the mod is already on disk. Once a ModWorkshop mod is installed, its row flips from a Download button to an enable/disable toggle that works straight from Browse (no need to switch to the Mods tab).

Clicking the row name opens a **detail dialog**: banner image, full description, a **Files** list (every uploaded version with size and date, primary version flagged), an **Open mod page in browser** button, and a **Download** / **Installed** button mirroring the row.

> ModWorkshop tracks a mod's dependencies, but Browse does not show them in the detail dialog. Dependencies surface *after* install -- see below.

## Installing a mod

1. Find the mod (discover list, search, or category filter).
2. Click **Download** on the row (or in the detail dialog).
3. The button changes to **Downloading...**, the status line reports progress, and on success the button becomes **Installed**. The Mods tab is rebuilt so the new mod appears there immediately, enabled in your active profile.

The mod file is saved into your `mods/` folder.

**Already have it.** A plain Browse install refuses to overwrite an existing file -- if a file of the same name is already in `mods/`, the download fails with `Already have a file named <name>` rather than clobbering it. (Modpack apply uses a different, rename-on-collision path; see [Modpacks](Modpacks).)

## The download queue

Downloads run **one at a time**. While one is in flight, clicking **Download** on other rows queues them up:

- The queued row's button shows **Queued** and the status line reports the queue depth.
- When the current download finishes, the next queued item starts automatically (FIFO).
- Clicking the same mod twice is a no-op (`Already downloading this mod` / `Already queued`).

Closing the launcher (Launch or the X) mid-download is safe: the in-flight download still finishes writing to disk, so you will not end up with a half-installed mod.

## How dependencies surface

Browse installs exactly the mod you click -- it does **not** auto-install other mods that mod requires. Dependency checks happen in the **Mods** tab after install:

- If an installed mod requires another mod that is missing or disabled, its Mods-tab row turns orange: `won't load -- needs <dep>`.
- Inline fix buttons appear: **Enable dependency** (turns on a requirement that is installed but disabled) and **Load anyway** (a per-profile override that skips the check for that mod).
- If a required dependency is missing entirely, install it from Browse the same way, then re-check.

See [Mod-Format](Mod-Format#dependencies-section) for how mod authors declare dependencies, and [Config-Files](Config-Files) for where the **Load anyway** override is stored.

## Caching

- **Thumbnails / banners** persist to `user://mws_cache/thumbs/` so re-opening Browse doesn't re-fetch every image.
- **Search results and mod details** are cached in memory for a few minutes. The **Popular / Latest** landing view is additionally saved to disk (alongside the thumbnails) so Browse can show your last results when you are offline.

Both are safe to delete; see [Config-Files: Generated files](Config-Files#generated-files----safe-to-delete).

## Offline / failure behavior

If Browse cannot reach ModWorkshop when it opens, it shows the last results it successfully loaded (saved on disk from a previous session) behind a notice -- `Showing cached results. ModWorkshop is unreachable.` -- with how old they are and a **Retry** button. If there are no saved results, or a search fails, you get a failure message with a **Retry** button instead. A failed **Load more** keeps what is already on screen -- clicking **Load more** again retries.

| Where | Message |
|---|---|
| Popular / Latest (no saved results) | `Could not load mods. Check your connection and try again.` |
| Search / filter results | `Could not search. Check your connection and try again.` |
| Detail dialog file list | `Could not load the file list. Check your connection and try again.` |
| A failed download | `Could not download <mod name>. <reason>` |

When ModWorkshop rate-limits the launcher, these messages instead read `ModWorkshop rate limit reached. Try again in <N>s.`

## Related

- [Modpacks](Modpacks) -- apply a shared list of mods in one go.
- [Mod-Format](Mod-Format) -- for mod authors: how a mod declares its ModWorkshop id (which Browse uses to recognize installed mods) and its dependencies.
- [Config-Files](Config-Files) -- where the active profile, the **Load anyway** overrides, and the Browse cache live.
