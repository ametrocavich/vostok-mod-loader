# Mods

The **Mods** tab is the first tab in the launcher window and the one you use most. It lists every mod in your `mods` folder, lets you turn each one on or off, sets the order they load in, keeps several setups as profiles, and updates mods from the site they came from.

## The list

Each row is one mod: a checkbox, the mod's name, and its load-order number. A mod the launcher can match to a site also shows its thumbnail and `by <author>`; click its name to see the site details without leaving the launcher. A mod that is off in the current profile shows dimmed. The **Load order** column on the right previews the order the game will load your enabled mods in and updates as you edit.

Above the list:

- **Filter mods...** narrows the list by name. **Enable all** and **Disable all** act on the rows that match the filter, so filter first to toggle a subset. **Enable all** also turns on the rows **Hide disabled** is hiding.
- **Hide disabled** hides the rows of mods that are off in this profile.
- **Check for updates** asks each mod's site for a newer version; see [Updates](#updates).

## Load order

The number beside each mod is its priority. A higher number loads later, and a mod that loads later wins when two mods ship the same file. The default is `0` and the range is -999 to 999. Mods with the same priority load in order of mod name, then filename. Priorities are saved per profile; a mod's own `mod.txt` can suggest one, and the number you set here overrides it.

## Updates

- The check asks only the site a mod was installed from, and asks it afresh each time. Mods that do not say where they came from, developer-mode folders and mods whose `mod.txt` has no `version` are skipped; the result message counts the last kind, and says when to retry if the site rate-limited the check.
- Mods with a newer version appear under **Updates available**, each with an **Update** button that replaces the installed file. Update keeps the installed file and says why when it cannot: the game holds an enabled `.zip` or `.pck` open until it exits (disable the mod, relaunch, then update), and a download whose `mod.txt` names a different mod id is not installed over yours.
- An update whose new version is already in `mods/` under the name it would use removes the older copy and counts as done. The version a download was served as is the installed version from then on, and a mod with no `id=` keeps its profile settings when the update renames its file.
- The check also asks Vostok Mods about every pack in Your packs that came from the site. A pack whose list changed adds `N pack(s) changed; Refresh them on the Modpacks tab.` to the result, and an active one is named to unload first ([Modpacks](Modpacks#refresh-and-changed-packs)).
- Versions compare number by number. A letter after the last number (`1.0.1b`) is a later build of that number; a prerelease word (`1.2rc1`, `1.2beta`) is an earlier one.
- A mod whose ModWorkshop page stopped getting updates while its Vostok Mods page moved on reads as up to date. Reinstall it from Vostok Mods to move it over.

## Profiles

A profile is a saved set of on/off choices and load-order numbers. The **Profile** dropdown in the toolbar switches between them, and the three buttons beside it create a profile (**+**), rename the active one (the pencil) and delete it (the trash can). A new profile starts empty unless you pick **All enabled** or **Copy current selection** in its dialog. The first profile is called **Default**. A mod you install lands enabled in Default and stays off in every other profile until you turn it on there.

Each profile also keeps its own copy of your in-game mod settings (the MCM folder), so switching profiles switches those too. A switch made from the main menu while the game runs swaps the settings at the restart, before any mod runs.

While a modpack is active the profile buttons are disabled and a banner names the pack, with an **Unload** button beside it. [Modpacks](Modpacks#while-a-pack-is-active-profile-editing-is-limited) lists what else is locked until you unload it.

## Dependencies

A mod that needs another mod shows an orange `won't load -- needs ...` line when the requirement is missing or off, and the loader skips it instead of crashing. **Enable dependency** turns the required mod on, **Load anyway** loads the mod regardless in this profile, and **Re-check** removes that override. [Dependencies](Dependencies) explains the rules, including how a required mod is moved up in the load order for you.

## Missing mods

A profile can name a mod that is no longer in your `mods` folder, for example after you deleted the file or applied a modpack whose download failed. Those rows sit under **Missing from this profile** with **Download** when the launcher knows the mod's site (or **Download unavailable** when it does not) and **Remove** to forget it; **Remove all** clears the section. If the exact version the profile remembers is gone from the site, **Download** takes the current file; a modpack's row keeps its pinned version.

## Removing a mod

The trash-can button at the right of a row deletes the mod's file after a confirmation, and its entries go with it from every profile, under every version the mod was installed as. A profile whose only mod this was stays. An active modpack's own setup keeps the entry, and an older copy of the same mod hidden behind this one keeps its settings. Developer-mode folders cannot be removed from here; use **Open mods folder**.

## Warnings and tags

- A red warning marks a mod that will not work: a broken or missing `mod.txt`, a `mod.txt` inside a subfolder instead of at the root of the zip, or an autoload path that points nowhere. [Mod-Format](Mod-Format) has the packaging rules.
- `version changed: 1.0 -> 1.1` means the profile's settings for this mod came from an older version of it.
- `[dev folder]` marks an unpacked folder mod in developer mode.

A banner at the top of the tab reports a crash streak or hooks that failed last session; [Troubleshooting](Troubleshooting#banners-on-the-mods-tab) says what each one means.

## Developer mode

The **Developer mode** checkbox in the toolbar turns on verbose logging, a conflict report, and loading of unpacked folder mods from the `mods` folder. [Developer-Mode](Developer-Mode) lists everything it changes. Toggling it rescans the `mods` folder and keeps your active profile.

## Launching and reopening

In the toolbar, **Open mods folder** opens the `mods` folder and **UI scale** resizes the launcher. **Launch vanilla** in the bottom bar starts the game once with no mods and leaves your profiles alone. The launch button beside it reads:

| Label | When |
|---|---|
| **Launch modded** | at least one enabled mod will load |
| **Launch unmodded (N blocked)** | every enabled mod is blocked by a missing dependency |
| **Launch** | nothing is enabled |
| **Back to game** | reopened from the main menu, and nothing that loads changed |
| **Apply and restart** | reopened from the main menu, and what loads changed |

Closing the window does the same as clicking it. The main menu's **Mods** button reopens the window; it exists only when at least one mod loaded. The reopened window re-reads your `mods` folder, so a file dropped in by hand or a download that finished later is listed. A mod turned off and on again, a priority change on a disabled mod, or renaming a profile does not restart. Creating a profile (with any starting state, **Copy current selection** included), switching to another one or deleting one restarts, because your mod settings are swapped at that restart; switching back to the profile the game started with before closing cancels it.
