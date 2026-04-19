# Security scan fixtures

Three folder-mods that exercise the modloader's only-egregious-cases
scanner (see `src/security_scan.gd`). Each is deliberately inert: no
`mod.txt` declares an autoload, every dangerous-pattern call lives
inside a function nothing calls, and no payload would actually run if
the mod were enabled.

## Fixtures

| Fixture          | Triggers                                             |
| ---------------- | ---------------------------------------------------- |
| `clean_mod`      | nothing -- baseline                                  |
| `dropper_mod`    | byte_decode_loop + large_int_array + os_execute -- the screenshot dropper pattern; trips three of the red combo paths |
| `os_misuse_mod`  | os_crash + disable_save_safety -- two solo red triggers (anti-debug, ransomware setup) |

## What the scanner flags

The scanner classifies every mod as either **clean** (nothing shown to
the user) or **red** (a "suspicious code" tag in the launcher and a
confirmation dialog at Launch time). There is no middle tier.

Red fires only on:

- `os_crash` present (anti-debug / scanner evasion)
- `disable_save_safety` present (ransomware setup)
- both obfuscation rules together (`byte_decode_loop` AND `large_int_array`)
- any obfuscation pattern AND any process-spawn rule (decoded execute)
- any runtime-code-build pattern AND any process-spawn rule (constructed execute)

Loading is never blocked. The Launch button just opens a confirmation
dialog when a red mod is enabled. Most mods will never trip the scanner.

## How to test

Two paths -- pick one.

**Folder mods (developer mode):**
1. Enable developer mode in the modloader UI (Settings -> Developer Mode).
2. Copy the fixture folders into `<game>/mods/`.
3. Launch RTV. The dropper and misuse fixtures should show a red
   "suspicious code" tag in the mod list.

**Archive mods (regular flow):**
1. Run `bash build_vmz.sh`. Produces `<fixture>.vmz` for each folder
   under `tests/security_scan_fixtures/dist/`.
2. Drop the .vmz files into `<game>/mods/`.
3. Launch RTV. Same expected findings. Enabling either red mod and
   clicking Launch should pop a confirmation dialog before the game
   starts.
