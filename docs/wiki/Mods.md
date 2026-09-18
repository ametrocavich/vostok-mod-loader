# Mods

The **Mods** tab is the first tab in the launcher window and the one you use most. It lists every mod in your `mods` folder, lets you turn each one on or off, sets the order they load in, keeps several setups as profiles, and updates mods from the site they came from.

## The list

Each row is one mod: a checkbox, the mod's name and author, and its load-order number. Click the name of a mod that came from VostokMods or ModWorkshop to see its site details without leaving the launcher. A mod that is off in the current profile shows dimmed.

The **Load order** column on the right previews the order the game will load your enabled mods in. It updates as you edit.

Above the list:

- **Filter mods...** narrows the list by name. **Enable all** and **Disable all** act on the visible rows only, so filter first to toggle a subset.
- **Hide disabled** hides the rows of mods that are off in this profile.
- **Check for updates** asks each mod's site for a newer version. Mods that do not say where they came from are skipped, and so are developer-mode folders and mods whose mod.txt has no `version`; the result message counts the last kind. If the site rate-limited the check, the message says so and when to try again. Mods with a newer version appear in an **Updates available** section, each with an **Update** button that downloads the new file and replaces the installed one.

## Load order

The number beside each mod is its priority. A higher number loads later, and a mod that loads later wins when two mods ship the same file. The default is `0` and the range is -999 to 999. Mods with the same priority load in filename order.

Priorities are saved per profile. A mod's own `mod.txt` can suggest a priority; the number you set here overrides it.

## Profiles

A profile is a saved set of on/off choices and load-order numbers. The **Profile** dropdown in the toolbar switches between them, and the three buttons beside it create a profile (**+**), rename the active one (the pencil) and delete it (the trash can). A new profile starts empty unless you pick **All enabled** or **Copy current selection** in its dialog. The first profile is called **Default**. A mod you install lands enabled in Default and stays off in every other profile until you turn it on there.

Each profile also keeps its own copy of your in-game mod settings (the MCM folder), so switching profiles switches those too.

While a modpack is active the profile buttons are disabled and a banner reads `Modpack "<name>" is active. Changes here save to the modpack, not your profiles.` with an **Unload** button beside it. See [Modpacks](Modpacks).

## Dependencies

A mod that needs another mod shows an orange `won't load -- needs ...` line when the requirement is missing or off, and the loader skips it instead of crashing. The buttons beside the line fix the common cases: **Enable dependency** turns the required mod on, **Load anyway** loads the mod regardless in this profile, and **Re-check** removes that override. [Dependencies](Dependencies) explains the rules, including how a required mod is moved up in the load order for you.

## Missing mods

A profile can name a mod that is no longer in your `mods` folder, for example after you deleted the file or applied a modpack whose download failed. Those rows sit under **Missing from this profile**, each with a **Download** button when the launcher knows which site the mod came from, or **Download unavailable** when it does not, plus **Remove** to forget it. **Remove all** clears the whole section.

## Removing a mod

The **Remove** button at the right of a row deletes the mod's file from your `mods` folder after a confirmation, and its profile entries go with it. Developer-mode folders cannot be removed from here; use **Open mods folder**.

## Warnings and tags

Some rows carry extra lines:

- A red warning for a mod that will not work: a broken or missing `mod.txt`, a `mod.txt` inside a subfolder instead of at the root of the zip, or an autoload path that points nowhere. [Mod-Format](Mod-Format) has the packaging rules.
- `version changed: 1.0 -> 1.1` when the profile's settings for this mod came from an older version of it.
- A red `suspicious code` tag when the built-in scanner matched patterns seen in malicious mods. Click it to see what matched. The tag never blocks loading.
- `[dev folder]` on an unpacked folder mod in developer mode.

A banner at the top of the tab appears when the hook system did not work last session, usually after a game update. It starts with `Last time the game ran, ...` (hooks did not work on the named scripts, none of the script rewrites took effect, or the loader could not build or mount its hook pack), `The loader could not read this version of Road to Vostok's scripts correctly ...` or `This version of Road to Vostok stores its scripts in a format ...`. Mods still load, but mods that change vanilla scripts do nothing until a loader update fixes it; the banner's **Check for loader update** button opens the release page. A quieter notice, `Road to Vostok was updated ...`, means the loader rebuilt its script cache and hooks should keep working.

## Developer mode

The **Developer mode** checkbox in the toolbar turns on verbose logging, a conflict report, and loading of unpacked folder mods from the `mods` folder. It is meant for people writing mods; [Developer-Mode](Developer-Mode) lists everything it changes. Toggling it rescans the `mods` folder and keeps your active profile.

## Bottom bar

**UI scale** resizes the launcher. **Open mods folder** opens the `mods` folder in your file manager. The launch button reads **Launch modded** when at least one enabled mod will load, **Launch unmodded (N blocked)** when every enabled mod is blocked by a missing dependency, and **Launch** when nothing is enabled; closing the window does the same as clicking it. **Launch vanilla** starts the game once with no mods and leaves your profiles alone.

Once the game is running, the **Mods** button on the main menu reopens this window. If you change which mods load there, closing it restarts the game into the new mod set. Renaming a profile, or creating one with **Copy current selection**, changes nothing that loads, so it does not restart.

## Related

- [Setup](Setup): installing the loader and your first mods.
- [Browse](Browse): installing mods from VostokMods or ModWorkshop.
- [Troubleshooting](Troubleshooting): when the game will not start or a mod does nothing.
- [Config-Files](Config-Files): where profiles and settings live on disk.
