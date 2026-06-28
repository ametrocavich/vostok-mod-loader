# Browse

The **Browse** tab installs mods straight from [ModWorkshop](https://modworkshop.net) without leaving the launcher. It is the second tab in the pre-launch window (after **Mods**). New in 3.3.

This page covers what Browse shows, how to search and install, how the download queue behaves, where dependencies surface, and what happens offline.

## What it talks to

Browse is a thin client over the public ModWorkshop API. All requests are read-only catalog lookups plus a file download; nothing is sent about your install.

| Endpoint | Used for |
|---|---|
| `https://api.modworkshop.net` | mod listings, search, categories, mod detail, file lists |
| `https://storage.modworkshop.net` | thumbnails / banner images |

The catalog is scoped to the Road to Vostok game id (`864` -- see [constants.gd:86 `MWS_RTV_GAME_ID`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/constants.gd#L86)), so you only see RTV mods. The client is in [mws_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mws_api.gd); the tab UI is `build_browse_tab` in [ui.gd:3888](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L3888).

## Layout

A toolbar across the top, a status line, then a scrolling list of mod rows with a **Load more** button at the bottom.

**Toolbar**

- **Search box** (`Search mods...`) -- free-text query.
- **Sort dropdown** -- `Recently bumped`, `Most downloaded`, `Most liked`, `Most viewed`, `Newest`.
- **Category dropdown** -- `All categories` plus the RTV category tree pulled from the API.

**Two modes.** On open, Browse is in *discover* mode: it calls the popular-and-latest landing endpoint and renders two sections, **Popular** and **Latest**. Typing a query, changing the sort, or picking a category flips it into *filter* mode, which uses the paginated search endpoint and the **Load more** button to page through results.

Rapid clicks on sort/category are safe: each fetch is stamped with a sequence number and a stale response that finishes after a newer one is discarded, so the list always matches the dropdowns (`fetch_seq`, [ui.gd:3911](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L3911)).

## A mod row

Each row shows a thumbnail, name, author, and quick stats (downloads / likes), plus an action button on the right:

- **Download** -- the mod is not installed. Click to fetch it into your `mods/` folder.
- **Installed** / an enable toggle -- the mod is already on disk. Browse matches installed mods by their `[updates] modworkshop=<id>` field, so once a mod is installed its row flips from a Download button to an enable/disable toggle that writes straight to your active profile (no need to switch to the Mods tab).

Clicking the row name opens a **detail dialog**: banner image, full description, a **Files** list (every uploaded version with size and date, primary version flagged), an **Open mod page in browser** button, and a **Download** / **Installed** button mirroring the row.

> The ModWorkshop mod-detail response carries a `dependencies` list, but Browse does not render it. Dependencies surface *after* install -- see below.

## Installing a mod

1. Find the mod (discover list, search, or category filter).
2. Click **Download** on the row (or in the detail dialog).
3. The button changes to **Downloading...**, the status line reports progress, and on success the button becomes **Installed**. The Mods tab is rebuilt so the new mod appears there immediately, enabled in your active profile.

Under the hood, `download_new_mod` ([mod_discovery.gd:884](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mod_discovery.gd#L884)) asks for the author's **primary** file first and falls back to **latest** if no primary is set, then saves the archive into `mods/`. The filename comes from the server's `Content-Disposition` (validated as a safe `.vmz`/`.zip`/`.pck` basename) or a `mws_mod_<id>.zip` fallback.

**Already have it.** A plain Browse install refuses to overwrite an existing file -- if a file of the same name is already in `mods/`, the download fails with `Already have a file named <name>` rather than clobbering it. (Modpack apply uses a different, rename-on-collision path; see [Modpacks](Modpacks).)

## The download queue

Downloads run **one at a time**. While one is in flight (`downloading_id` is set), clicking **Download** on other rows enqueues them:

- The queued row's button shows **Queued** and the status line reports the queue depth.
- When the current download finishes, the next queued item starts automatically (FIFO).
- Clicking the same mod twice is a no-op (`Already downloading` / `Already queued`).

The queue lives in the tab's shared `state` dict (`download_queue`, [ui.gd:3924](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/ui.gd#L3924)). Closing the launcher (Launch or the X) mid-download is safe: the file has already landed on disk inside `download_new_mod`, so the in-flight write completes and the UI work is skipped cleanly.

## How dependencies surface

Browse installs exactly the file you click -- it does **not** read the mod's `[dependencies]` and auto-install required mods. Dependency resolution happens in the **Mods** tab after install:

- If an installed mod declares `[dependencies] required=[...]` in its `mod.txt` and a requirement is missing or disabled, its Mods-tab row turns orange: `won't load -- needs <dep>`.
- Inline fix buttons appear: **Enable dependency** (turns on a requirement that is installed but disabled) and **Load anyway** (a per-profile override that skips the check for that mod).
- If a required dependency is missing entirely, install it from Browse the same way, then re-check.

See [Mod-Format](Mod-Format#dependencies-section) for the `[dependencies]` schema and [Config-Files](Config-Files) for where the `Load anyway` override is stored (`profile.<name>.dep_ignore`).

## Caching

- **Thumbnails / banners** persist to `user://mws_cache/thumbs/` so re-opening Browse doesn't re-fetch every image.
- **API JSON responses** are cached in memory only, keyed by URL with short per-endpoint TTLs ([mws_api.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/mws_api.gd)). They are not written to disk and do not survive a relaunch.

Both are safe to delete; see [Config-Files: Generated files](Config-Files#generated-files----safe-to-delete).

## Offline / failure behavior

Every Browse request collapses to a status-line message on failure -- network down, HTTP error, or malformed JSON all look the same to the user:

| Where | Message |
|---|---|
| Discover list (landing) | `Failed to load. Check connection.` |
| Search / filter results | `Search failed. Check connection.` |
| Detail dialog file list | `Failed to load file history.` |
| A failed download | `Download failed: <reason>` |

There is **no cached-data banner**: when a fetch fails, Browse shows the failure message and an empty (or unchanged) list, not a stale snapshot labelled "offline". Thumbnails already cached on disk may still render, but the catalog itself requires a live connection.

## Related

- [Modpacks](Modpacks) -- install a whole curated loadout (profile + MCM + mods) at once.
- [Mod-Format](Mod-Format) -- `mod.txt`, including the `[updates] modworkshop=<id>` field Browse keys installs on, and the `[dependencies]` section.
- [Config-Files](Config-Files) -- where the active profile and the `dep_ignore` overrides live; the `user://mws_cache/` cache dir.
