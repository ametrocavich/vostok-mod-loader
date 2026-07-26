# CODE_MAP

Navigation document for the Road to Vostok mod loader. Answers "where does X
happen?" Not a design essay -- see `docs/wiki/Architecture.md` for rationale
and `src/rewriter.gd:16-82` for the codegen pipeline narrative.

Every line number below was read from the code on branch `fix/3.3.1`. If a
number has drifted, the function name is the durable anchor -- grep for it.

## 0. How the file layout works

`build.sh` concatenates ~39 files from `src/` into a single `modloader.gd`
(~24.5k lines). The result is **one GDScript class, one flat namespace**:
every `func` in every `src/*.gd` is a method on the same object, and any
function can call any other regardless of file. The files are an editing
convenience, not modules.

Consequences you must internalize:

- There are no imports. A call with no obvious definition nearby is defined
  in some other `src/*.gd`. Grep the whole `src/` tree, never one file.
- Module-scope `var`s all live in `src/constants.gd:203-378`. State written
  in one file is almost always read in a different one.
- Concat order is explicit in `build.sh` FILES and is load-bearing for
  static-init ordering, not for name resolution.
- The UI is ten `src/ui_*.gd` files, split by concern. `ui_mods_tab.gd` is the
  largest at ~1,450 lines. Grep across all of them; the split is by feature
  area, so the file name tells you which tab or layer owns a symbol.

| Layer | Files |
|---|---|
| Fundamentals | `header.gd`, `constants.gd`, `logging.gd` |
| FS + archives | `fs_archive.gd` |
| Static-init boot | `boot.gd` |
| Discovery + loading | `security_scan.gd`, `mws_api.gd`, `mod_discovery.gd`, `modpacks.gd`, `mod_loading.gd`, `conflict_report.gd` |
| UI | `ui_theme.gd`, `ui_config_profiles.gd`, `ui_dialogs.gd`, `ui_shell.gd`, `ui_mods_tab.gd`, `ui_browse_tab.gd`, `ui_browse_detail.gd`, `ui_modpack_io.gd`, `ui_modpacks_tab.gd`, `ui_updates_tab.gd` |
| Public mod API | `hooks_api.gd`, `registry.gd`, `registry/*.gd`, `setup.gd`, `framework_wrappers.gd` |
| Codegen | `gdsc_detokenizer.gd`, `pck_enumeration.gd`, `rewriter.gd`, `hook_pack.gd` |
| Orchestration | `lifecycle.gd`, `main_menu_hook.gd` |
| Debug scaffolding | `debug.gd` |

Version constant: `MODLOADER_VERSION` at `src/constants.gd:20` (currently
reads `"3.3.0"`; release-please bumps it at release time).

---

## 1. Boot to mods-loaded, in order

Three entry moments per launch: **static init** (before `_ready`),
**`_ready`**, then either **Pass 1** or **Pass 2**.

### 1.1 Static init -- runs before `_ready`, mounts last session's state

| # | What | Where |
|---|---|---|
| 0 | The trigger. A module-scope var initializer, which Godot evaluates at script-load time -- before any autoload scene graph resolves | `src/constants.gd:378` -- `var _filescope_mounted: Dictionary = _mount_previous_session()` |
| 1 | The whole static-init body | `src/boot.gd:170` `_mount_previous_session()` |
| 2 | Disabled-sentinel check (`modloader_disabled` / `modloader_disabled_once` in the exe dir) | `src/boot.gd:91` `_is_modloader_disabled()`, forced-vanilla path at `src/boot.gd:111` |
| 3 | Crashed-Pass-2 recovery (`user://modloader_pass2_dirty` present -> wipe) | inside `_mount_previous_session`, `src/boot.gd:170+` |
| 4 | Load `user://mod_pass_state.cfg`; version-mismatch and exe-mtime invalidation | inside `_mount_previous_session`; wipe helper `src/boot.gd:490` `_static_wipe_hook_cache()` |
| 5 | Mount loop -- replays `archive_paths` from pass state via `ProjectSettings.load_resource_pack`, `.vmz -> .zip` fallback | `src/boot.gd:~250-301`; vmz cache `src/fs_archive.gd:13` `_static_vmz_to_zip()`; remaps `src/fs_archive.gd:154` `_static_resolve_remaps()` |
| 6 | Orphan hook-pack sweep (delete every `framework_pack_*.zip` except the one pass state names) | call `src/boot.gd:325`, def `src/boot.gd:428` `_static_cleanup_orphan_hook_packs()` |
| 7 | Hook-pack preempt mount ("Step D") + forced fresh source-compile of `hook_pack_wrapped_paths` | `src/boot.gd:303-397` |
| 8 | Dev-only test-pack mount | gated on `user://test_pack_precedence.zip`, `src/debug.gd:45` `_load_test_pack_flag()` |

Static init is the **only** place that can rewire scripts Godot pins to PCK
bytecode during `class_cache` population. Everything else is too late.

### 1.2 `_ready` -- the fork

`src/lifecycle.gd:7` `_ready()`.

- Re-entry guard `_has_loaded` -- `src/lifecycle.gd:8`
- Disabled sentinel honored + one-shot cleared -- `src/lifecycle.gd:15-23`
- Pass detection: `"--modloader-restart" in OS.get_cmdline_user_args()` --
  `src/lifecycle.gd:29`
- Dispatch -- `src/lifecycle.gd:33-36`

### 1.3 Pass 1 -- normal launch, shows the UI

`src/lifecycle.gd:114` `_run_pass_1()`, in code order:

| Step | Call | Line |
|---|---|---|
| Crash-loop guard (heartbeat + restart counter) | `_check_crash_recovery()` | `lifecycle.gd:116` (def `boot.gd:813`) |
| Safe-mode sentinel | `_check_safe_mode()` | `lifecycle.gd:117` (def `boot.gd:828`) |
| Compile the mod-scan regexes | `_compile_regex()` | `lifecycle.gd:118` (def `rewriter.gd:83`) |
| `class_name` -> path map | `_build_class_name_lookup()` | `lifecycle.gd:119` (def `pck_enumeration.gd:7`) |
| Parse RTV.pck for `res://Scripts/*.gd` | `_enumerate_game_scripts()` | `lifecycle.gd:126` (def `pck_enumeration.gd:104`) |
| Read `developer_mode` from config | `_load_developer_mode_setting()` | `lifecycle.gd:127` (def `ui_config_profiles.gd:19`) |
| **Scan the mods dir, parse every mod.txt** | `collect_mod_metadata()` | `lifecycle.gd:128` (def `mod_discovery.gd:7`) |
| Drop stale vmz/dev-zip caches | `_clean_stale_cache()` | `lifecycle.gd:129` (def `boot.gd:840`) |
| Load profiles, apply enabled/priority | `_load_ui_config()` | `lifecycle.gd:130` (def `ui_config_profiles.gd:69`) |
| **Show the launcher, block until Launch** | `await show_mod_ui()` | `lifecycle.gd:131` (def `ui_shell.gd:127`) |
| Persist the user's choices | `_save_ui_config()` | `lifecycle.gd:132` (def `ui_config_profiles.gd:404`) |
| **Mount + scan + queue autoloads** | `load_all_mods()` | `lifecycle.gd:134` (def `mod_loading.gd:7`) |
| Apply `[script_extend]` via take_over_path | `_apply_script_overrides()` | `lifecycle.gd:135` (def `mod_loading.gd:403`) |
| Split queued autoloads into early/late | `_build_autoload_sections()` | `lifecycle.gd:137` (def `boot.gd:515`) |
| Archive paths for pass state | `_collect_enabled_archive_paths()` | `lifecycle.gd:138` (def `boot.gd:596`) |
| Compute the mods hash | `_compute_state_hash()` | `lifecycle.gd:140` (def `boot.gd:767`) |

**The mods-hash short-circuit** -- `src/lifecycle.gd:146`:

```
if new_hash == old_hash and not new_hash.is_empty():
    await _finish_with_existing_mounts()   # lifecycle.gd:195
    return
```

`old_hash` is read from `[state] mods_hash` in `user://mod_pass_state.cfg`
(`lifecycle.gd:141-144`). When they match, the archives static init already
mounted are correct, so **no restart happens at all** -- this is the normal
steady-state launch. `_finish_with_existing_mounts()` at `lifecycle.gd:195`
generates the hook pack, instantiates pending autoloads, emits
`frameworks_ready`, and reloads the scene.

The hash covers archive paths + stable mtimes (folder mods hash their source
tree, not the temp zip) + prepend autoloads + declared versions + script
overrides + `MODLOADER_VERSION` + `modloader.gd`'s own mtime. See
`src/boot.gd:767-802`, especially the `modloader.gd` mtime rationale at
`src/boot.gd:786-800`.

**What triggers a restart** -- `src/lifecycle.gd:156`: hash differs AND
`archive_paths.size() > 0`. Then, in order:

1. `_register_rtv_modlib_meta()` -- `lifecycle.gd:172` (def `hooks_api.gd:21`)
2. `_generate_hook_pack(true)` -- `lifecycle.gd:173`, `defer_activation=true`
   writes the zip and pass state but does NOT mount (`hook_pack.gd:568`)
3. `_write_heartbeat()` -- `lifecycle.gd:174` (def `boot.gd:803`)
4. `_write_override_cfg(sections.prepend)` -- `lifecycle.gd:175` (def `boot.gd:617`)
5. `_write_pass_state(archive_paths, new_hash)` -- `lifecycle.gd:180` (def `boot.gd:700`)
6. `_modloader_restart(false)` -- `lifecycle.gd:183` (def `lifecycle.gd:46`),
   which calls `OS.set_restart_on_exit` + `get_tree().quit()`

If `archive_paths` is empty (no mods enabled): clean up pass state, restore a
clean `override.cfg`, wipe the hook cache, and `_finish_single_pass()` --
`src/lifecycle.gd:186-193`, `_finish_single_pass()` def at `lifecycle.gd:220`.

Any failure at steps 4-5 falls back to `_finish_single_pass()` rather than
restarting -- `lifecycle.gd:176-182`.

### 1.4 Pass 2 -- after the restart

`src/lifecycle.gd:241` `_run_pass_2()`. Archives are already mounted (static
init did it) and early autoloads are already in the tree (Godot loaded them
from `[autoload_prepend]`).

| Step | Line |
|---|---|
| Write `user://modloader_pass2_dirty` first thing | `lifecycle.gd:246-249` |
| Replay `[script_overrides]` from pass state | `lifecycle.gd:251-258` |
| `_apply_script_overrides()` | `lifecycle.gd:259` |
| `_clear_restart_counter()` | `lifecycle.gd:260` (def `boot.gd:889`) |
| Regex, class map, PCK enumeration, dev mode | `lifecycle.gd:261-266` |
| `collect_mod_metadata()` + `_load_ui_config()` | `lifecycle.gd:267-268` |
| `load_all_mods("Pass 2")` -- re-mount guarded by `_filescope_mounted` | `lifecycle.gd:270` |
| `_generate_hook_pack()` -- this time it mounts and activates | `lifecycle.gd:272` |
| Instantiate pending autoloads, skipping ones already in tree | `lifecycle.gd:321-325` |
| Dev-mode conflict report | `lifecycle.gd:327-330` |
| `_emit_frameworks_ready()` | `lifecycle.gd:331` (def `hooks_api.gd:30`) |
| Delete heartbeat, clear the dirty marker | `lifecycle.gd:332-337` |
| `reload_current_scene()` | `lifecycle.gd:338-342` |
| Windows foreground grab (the relaunched window comes up behind) | `lifecycle.gd:343-354` |

### 1.5 Post-boot reopen

The main menu gets a "Mods" button injected via the loader's own hook
machinery: `src/main_menu_hook.gd:19` `_seed_core_hooks()` (seeds
`Menu.gd::_ready` into the wrap surface), `main_menu_hook.gd:33`
`_register_core_hooks()`, `main_menu_hook.gd:50` `_inject_mods_button()`,
`main_menu_hook.gd:69` -> `reopen_mod_ui()` at `src/lifecycle.gd:98`. If
anything mutated during the reopened session (`_dirty_since_boot`), it calls
`_modloader_restart(true)` for a clean Pass 1.

---

## 2. The load path in detail

The spine, expanded:

```
collect_mod_metadata()        mod_discovery.gd:7      scan mods dir
  _build_archive_entry()      mod_discovery.gd:83
    read_mod_config()         fs_archive.gd:191       read mod.txt from zip
      _parse_mod_txt()        fs_archive.gd:251
    _entry_from_config()      mod_discovery.gd:290    mod.txt -> entry dict
    scan_mod()                security_scan.gd:260
  _dedupe_by_mod_id()         mod_discovery.gd:972
_load_ui_config()             ui_config_profiles.gd:69               apply enabled/priority
show_mod_ui()                 ui_shell.gd:127              user edits, clicks Launch
load_all_mods()               mod_loading.gd:7
  _loadable_enabled_entries() mod_discovery.gd:777    filter + sort + deps
  _process_mod_candidate()    mod_loading.gd:123      <- per mod
    _try_mount_pack()         fs_archive.gd:133       <- THE MOUNT
      ProjectSettings.load_resource_pack(path)        fs_archive.gd:134
    scan_and_register_archive_claims()  mod_loading.gd:457
    [hooks] / [registry] / [script_extend] / [autoload] handlers
  _merge_hook_calls_into_wrap_mask()   mod_loading.gd:66
_instantiate_autoload()       mod_loading.gd:707      <- per queued autoload
```

### 2.1 Where the mods dir is scanned

`src/mod_discovery.gd:7` `collect_mod_metadata()`.

- Dir resolved: `src/mod_discovery.gd:9` --
  `OS.get_executable_path().get_base_dir().path_join(MOD_DIR)`, `MOD_DIR =
  "mods"` at `constants.gd:24`. Stored in the module-scope `_mods_dir`.
- Accepted extensions: `["vmz", "zip", "pck"]` -- `mod_discovery.gd:45`.
  Anything else is logged as skipped.
- Directories are only entries when developer mode is on --
  `mod_discovery.gd:29-38`; otherwise recorded as hidden via
  `_record_hidden_folder()` at `mod_discovery.gd:118`.
- Modpack zips (`profile.json` at root, not `mod.txt`) are filtered out here
  -- `mod_discovery.gd:55`, test at `modpacks.gd:197` `_is_modpack_zip()`.
- Dedupe by mod id: `mod_discovery.gd:972` `_dedupe_by_mod_id()`.

### 2.2 Where mod.txt is parsed

| Source | Reader |
|---|---|
| `.zip` / `.vmz` | `src/fs_archive.gd:191` `read_mod_config()` -- opens ZIPReader, requires `mod.txt` at the zip **root**; a nested one sets status `nested:<path>` (`fs_archive.gd:204-212`) |
| folder (dev mode) | `src/fs_archive.gd:232` `read_mod_config_folder()` |
| `.pck` | not parsed; status forced to `"pck"` at `mod_discovery.gd:93` |

The actual parse: `src/fs_archive.gd:251` `_parse_mod_txt()`.
- BOM strip -- `fs_archive.gd:253`
- `[hooks]` value quote-wrapping so the wiki's unquoted syntax parses --
  `fs_archive.gd:266`, def `fs_archive.gd:300` `_quote_unquoted_hooks_values()`
- Godot's `ConfigFile` drops empty sections, so a bare `[registry]` header
  gets a sentinel key injected -- `fs_archive.gd:282-286`
- Parse-failure line diagnosis -- `fs_archive.gd:349` `_diagnose_parse_failure()`

Results land on three module-scope side-channel vars read by the caller
immediately after: `_last_mod_txt_status`, `_last_mod_txt_error`,
`_last_mod_txt_files` (`constants.gd:244-256`).

**mod.txt fields -> entry dict**: `src/mod_discovery.gd:290`
`_entry_from_config()`. Reads `[mod] name/id/version/author/priority`
(`:316-325`), `[dependencies]` via `_parse_dependency_list()`
(`mod_discovery.gd:435`), `provides` via `_parse_provides_list()`
(`mod_discovery.gd:481`), and builds `profile_key` at `mod_discovery.gd:356`
(read the CONTRACT comment at `:339-355` before changing it -- the format is
parsed in four other places). The entry dict literal is at
`mod_discovery.gd:358-376`.

`[updates] modworkshop=<id>` is NOT read here -- it is read lazily off
`entry["cfg"]` at each use site (`mod_discovery.gd:1537`, `ui_mods_tab.gd:1121`,
`ui_updates_tab.gd:506`, and six more).

### 2.3 Where enable / priority is applied

Enabled state and priority are **not** in mod.txt -- they are per-profile
user config in `user://mod_config.cfg`.

| What | Where |
|---|---|
| Default `enabled: true`, `priority` from mod.txt | `mod_discovery.gd:363` |
| Config load + `.bak` recovery + legacy migration | `ui_config_profiles.gd:69` `_load_ui_config()` |
| Stamp stored enabled/priority onto `_ui_mod_entries` | `ui_config_profiles.gd:210` `_apply_profile_to_entries()` |
| Section names (`profile.<name>.enabled` etc.) | `ui_config_profiles.gd:484` `_profile_sec()`, `ui_config_profiles.gd:490` `PROFILE_SUBSECTIONS` |
| Save back | `ui_config_profiles.gd:404` `_save_ui_config()`, atomic-ish write `ui_config_profiles.gd:479` `_persist_ui_cfg()` |
| Debounced priority save | `ui_config_profiles.gd:354` `_schedule_priority_save()` |
| Final filter + sort at load time | `mod_discovery.gd:777` `_loadable_enabled_entries()` |
| Sort comparator (priority, then file_name) | `mod_discovery.gd:516` `_compare_load_order()` |
| Dependency-driven reorder | `mod_discovery.gd:656` `_apply_dependency_ordering()` |
| Blocked-by-missing-deps filter | `mod_discovery.gd:560` `_filter_dependency_ready_candidates()` |

### 2.4 Where the archive actually mounts

**`src/fs_archive.gd:133` `_try_mount_pack(path)` -> `src/fs_archive.gd:134`
`ProjectSettings.load_resource_pack(path)`.** That single line is the loader.
It is called from `src/mod_loading.gd:166`.

The decision to mount at all is `src/mod_loading.gd:137-171`:

- `mount_path` starts as the mod's `full_path` -- `mod_loading.gd:137`
- **folder mods** re-point `mount_path` at their temp dev-zip --
  `mod_loading.gd:149` `_folder_dev_zip_path()`, rebuilt only when the folder
  changed via `mod_loading.gd:153` `zip_folder_to_temp()` (def
  `fs_archive.gd:413`)
- **re-mount guard**: `skip_remount = _filescope_mounted.has(...)` --
  `mod_loading.gd:138` and `:150`. In Pass 2 and in the hash-match fast path,
  static init already mounted these, and re-mounting with
  `replace_files=true` would clobber later overlays.
- on mount failure the mod is dropped with a CRITICAL log -- `mod_loading.gd:167`

Post-mount fixups:
- `.vmz` fallback (rename-to-.zip cache) -- `fs_archive.gd:137-142`, cache
  writer `fs_archive.gd:13` `_static_vmz_to_zip()`
- `.remap` resolution so `preload()` of original `.tscn`/`.tres` paths works
  -- `fs_archive.gd:147` `_resolve_remaps()` / `:154` `_static_resolve_remaps()`
- file-claim scan (what res:// paths this archive owns, plus GDScript source
  scanning) -- `mod_loading.gd:175` -> `mod_loading.gd:457`
  `scan_and_register_archive_claims()`, source scanner
  `mod_loading.gd:582` `_scan_gd_source()`

### 2.5 mod.txt section handlers (all inline in one function)

All in `_process_mod_candidate`, in this order. The seam comment is at
`src/mod_loading.gd:114-122`.

| Section | Line | Writes to |
|---|---|---|
| `[hooks]` | `mod_loading.gd:219-278` | `_hooked_methods[path][method]` |
| `[registry]` | `mod_loading.gd:285-287` | `_any_mod_declared_registry` |
| B_Loader implicit registry | `mod_loading.gd:297-303` | `_any_mod_declared_registry` |
| `[script_extend]` / `[script_overrides]` | `mod_loading.gd:312-330` | `_pending_script_overrides` |
| `[autoload]` (`!` prefix = early) | `mod_loading.gd:332-376` | `_pending_autoloads`, `_registered_autoload_names` |

`_loaded_mod_ids[mod_id]` (backing `has_mod()` / `mod_info()`) is populated at
`mod_loading.gd:196-204`.

### 2.6 Where autoloads get queued and instantiated

- **Queued**: `mod_loading.gd:370-373` appends
  `{mod_name, name, path, is_early}` to `_pending_autoloads`. Path is
  validated against the archive's file set first (`mod_loading.gd:352-363`)
  with a "similar paths" hint for typos.
- **Split early vs late**: `boot.gd:515` `_build_autoload_sections()`. Early
  ones need to exist on disk because Godot opens `[autoload_prepend]` scripts
  before file-scope code runs -- extraction at `boot.gd:570`
  `_ensure_early_autoload_on_disk()`, into `user://modloader_early`.
- **Early autoloads are loaded by Godot itself** from `[autoload_prepend]` in
  `override.cfg` (`boot.gd:617` `_write_override_cfg()`). Late autoloads are
  deliberately never written there -- Godot would try to load them before
  archives mount.
- **Instantiated**: `mod_loading.gd:707` `_instantiate_autoload()`, handling
  both `PackedScene` (`:721`) and `GDScript` (`:731`). Called from all three
  finish paths: `lifecycle.gd:207`, `lifecycle.gd:225`, `lifecycle.gd:325`.

---

## 3. The hook pack pipeline

Purpose: RTV ships its scripts as compiled `.gdc` bytecode inside `RTV.pck`.
To let mods hook vanilla methods, the loader reconstructs source, rewrites it,
ships the rewrite in a zip whose entries sit at the *original* vanilla paths,
and mounts that zip so Godot's VFS layering serves the rewrite instead.

An accurate narrative version of this already exists in
`src/rewriter.gd:16-82` ("PIPELINE MAP"). Read it. Stage locations:

### Stage 1 -- enumerate (`pck_enumeration.gd`)

| What | Where |
|---|---|
| Walk `RTV.pck`'s GDPC file table | `pck_enumeration.gd:174` `_parse_pck_file_list()` |
| Yield every `res://Scripts/*.gd`, canonicalize `.gdc`/`.remap` -> `.gd`, memoized into `_all_game_script_paths` | `pck_enumeration.gd:104` `_enumerate_game_scripts()` |
| `class_name` -> path map | `pck_enumeration.gd:7` `_build_class_name_lookup()` (hardcoded fallback at `:42`) |
| Detect module-scope `preload("...tscn")` (drives deferred activation) | `pck_enumeration.gd:150` `_collect_module_scope_scene_preloads()` |

### Stage 2 -- detokenize (`gdsc_detokenizer.gd`)

| What | Where |
|---|---|
| Entry point, on-disk cache first (`user://modloader_hooks/vanilla/`) | `gdsc_detokenizer.gd:450` `_read_vanilla_source()` |
| Raw `.gdc` -> token stream (GDSC v100/v101) | `gdsc_detokenizer.gd:114` `_detokenize_script()` |
| Token stream -> source text | `gdsc_detokenizer.gd:276` `_gdsc_reconstruct()` |
| Column -> tab-depth math | `gdsc_detokenizer.gd:404` `_indent_from_column()` |
| Cache write | `gdsc_detokenizer.gd:481` `_save_vanilla_source()` |
| Format-version probe (stability canary B input) | `gdsc_detokenizer.gd:503` `_probe_gdsc_version()` |

Critical invariant documented at `gdsc_detokenizer.gd:450-457`: never call
`load()` on a vanilla path before the hook pack mounts, or Godot caches the
PCK bytecode at that path and every later rewrite silently loses.

### Stage 3 -- decide the wrap surface

The surface is **opt-in**. A vanilla script is wrapped only if a mod declared
it. Three sources feed `_hooked_methods` / `_any_mod_declared_registry`:

| Source | Where |
|---|---|
| `[hooks]` section in mod.txt | `mod_loading.gd:219-278` |
| Source-scanned `.hook("<stem>-<method>[-pre\|-post\|-callback]")` calls | regex `rewriter.gd:107`, scan `mod_loading.gd:582`, resolve `mod_loading.gd:66` `_merge_hook_calls_into_wrap_mask()` |
| `add_hook()` (godot-mod-loader compat) | `hooks_api.gd:122` |
| `[registry]` declaration -> `REGISTRY_TARGETS` | `mod_loading.gd:285`, targets list `hook_pack.gd:20` |
| Core-owned `Menu.gd::_ready` wrap | `main_menu_hook.gd:19` `_seed_core_hooks()`, invoked at `hook_pack.gd:178` |

Surface assembly + per-path per-method mask: `hook_pack.gd:188-241`.

### Stage 4 -- rewrite (`rewriter.gd`)

| What | Where |
|---|---|
| Parse detokenized source into funcs/vars/signature structure | `rewriter.gd:228` `_rtv_parse_script()` |
| **The rewrite**: rename masked methods to `_rtv_vanilla_<name>`, append dispatch wrappers | `rewriter.gd:349` `_rtv_rewrite_vanilla_source()` |
| Emit the wrapper body itself | `rewriter.gd:1490` `_rtv_dispatch_inline_src()` |
| Registry appendix injections (Database/Loader/AISpawner/AI/FishPool/Compiler) | `rewriter.gd:487` `_rtv_registry_injection()`, `:508`, `:741`, `:978`, `:1049` |
| Function-prelude injection | `rewriter.gd:615` `_rtv_apply_prelude_injections()`, `:641` `_rtv_inject_prelude()` |
| Godot-3-era syntax autofix (bodyless blocks, `onready var`, `export var`, bare `base()`) | `rewriter.gd:1186` `_rtv_autofix_legacy_syntax()` |
| Bare `super()` / `base()` rewriting | `rewriter.gd:1078`, `rewriter.gd:1295` |
| Indent-style detection | `rewriter.gd:1122` `_detect_indent_style()` |

Read `project_gdscript_rewrite_gotchas` territory before touching
`_rtv_rewrite_vanilla_source` -- the header comment at `rewriter.gd:1-14`
points at it.

### Stage 5 -- pack, mount, activate (`hook_pack.gd`)

`src/hook_pack.gd:98` `_generate_hook_pack(defer_activation := false)`.

| Step | Line |
|---|---|
| Per-call unique zip name `user://modloader_hooks/framework_pack_<ticks>.zip` | `hook_pack.gd:106` |
| Do NOT delete the previously mounted zip (VFS holds a handle) | rationale `hook_pack.gd:108-115` |
| Stability canaries (GDSC version, detokenizer round-trip) | `hook_pack.gd:51` `_canary_detokenizer_roundtrip_ok()` |
| Seed core hooks | `hook_pack.gd:178` |
| Build wrap surface + per-method mask | `hook_pack.gd:188-241` |
| Pre-read mod sibling `.gd` files BEFORE opening ZIPPacker (Windows handle invalidation) | `hook_pack.gd:252-344` |
| Open the zip | `hook_pack.gd:347` |
| Per-script loop: skip lists, zero-byte PCK entries, surface filter | `hook_pack.gd:358-379` |
| Read + parse + mask + rewrite | `hook_pack.gd:397-442` |
| **The three-entry recipe** -- `.gd` at the vanilla path, self-referencing `.gd.remap`, empty `.gdc` | `hook_pack.gd:449-481` |
| Sibling autofix emission ("Step E") | `hook_pack.gd:500-544` |
| `defer_activation` branch: persist state, do not mount | `hook_pack.gd:568-578` |
| Normal branch: `load_resource_pack(pack, true)` + VFS canary readback | `hook_pack.gd:579-596` |
| Force GDScriptCache to serve the rewrite | `hook_pack.gd:597` -> `hook_pack.gd:621` `_activate_rewritten_scripts()` |
| Persist `hook_pack_path` + `hook_pack_wrapped_paths` into pass state | `hook_pack.gd:783` -> `boot.gd:681` `_persist_hook_pack_state()` |

Activation strategy in `_activate_rewritten_scripts` (`hook_pack.gd:621`):
`source_code` mutation + `reload()` first, `CACHE_MODE_IGNORE` + `take_over_path`
as fallback (`hook_pack.gd:747-768`). Scripts with module-scope scene preloads
are deferred from eager activation (`hook_pack.gd:438-441` records them,
`hook_pack.gd:622-630` skips them) unless they are `REGISTRY_TARGETS`.

**Next session**, static init re-mounts the same zip and preempts exactly the
recorded `hook_pack_wrapped_paths` -- `boot.gd:303-397`. That closes the loop.

### Stage 6 -- runtime dispatch (`hooks_api.gd`)

Generated wrappers call back into:

| API | Where |
|---|---|
| `hook(name, callable, priority)` | `hooks_api.gd:73` |
| `add_hook(script_path, method, cb, is_before)` (gml compat) | `hooks_api.gd:122` |
| `hook_many()` / `unhook()` | `hooks_api.gd:153` / `:165` |
| `_dispatch` / `_dispatch_post` / `_dispatch_deferred` | `hooks_api.gd:279` / `:312` / `:343` |
| `skip_super()` | `hooks_api.gd:196` |
| `has_mod()` / `mod_info()` / `loaded_mods()` | `hooks_api.gd:215` / `:234` / `:245` |
| `frameworks_ready` emission + post-boot verification | `hooks_api.gd:30` `_emit_frameworks_ready()` |

Mods reach all of this through `Engine.get_meta("RTVModLib")`, registered at
`hooks_api.gd:21` `_register_rtv_modlib_meta()`.

---

## 4. Where do I go to change X?

| Task | File + function |
|---|---|
| Add a `mod.txt` field under `[mod]` | `mod_discovery.gd:290` `_entry_from_config()` (read + add to the entry dict at `:358`); document in `docs/wiki/Mod-Format.md` |
| Add a whole new `mod.txt` **section** | `mod_loading.gd:123` `_process_mod_candidate()` -- add an inline block alongside the existing ones (seam note at `mod_loading.gd:114-122`). If values use non-Variant syntax (bare identifiers, `*`, top-level commas) also preprocess in `fs_archive.gd:251` `_parse_mod_txt()`; if the section can be empty, add a sentinel-key workaround like `[registry]` at `fs_archive.gd:282` |
| Change what a Mods-tab row shows | `ui_mods_tab.gd:279` `build_mods_tab()`, row loop starting `ui_mods_tab.gd:1101`. Row visibility: `ui_config_profiles.gd:283` `_mods_entry_visible()`. Rebuild helper: `ui_shell.gd:31` `_rebuild_mods_tab()` |
| Change the launcher window / theme / tab set | `ui_shell.gd:127` `show_mod_ui()`; TabContainer at `ui_shell.gd:283`, tabs added `ui_shell.gd:372-384`; theme `ui_theme.gd:124` `make_dark_theme()`; palette constants `ui_theme.gd:7-41` |
| Change how updates are checked | `ui_updates_tab.gd:491` `_run_updates_check_for_mods()` (Mods-tab badges) and `ui_updates_tab.gd:557` `check_updates_for_ui()` (Updates tab). Batched fetch: `mod_discovery.gd:1032` `fetch_latest_modworkshop_versions()`. Version comparison: `mod_discovery.gd:916` `compare_versions()` |
| Change how an update is downloaded/installed | `mod_discovery.gd:1184` `download_and_replace_mod()`; fresh installs `mod_discovery.gd:1309` `download_new_mod()`; filename safety `mod_discovery.gd:1124` `_is_safe_mod_filename()` |
| Change loader self-update prompting | `ui_updates_tab.gd:627` `_check_modloader_update_async()`, dialog `ui_updates_tab.gd:696` |
| Add / change a ModWorkshop API call | `mws_api.gd:74` `_mws_get_json()` (caching, retry, rate limits); endpoint wrappers `mws_api.gd:302-421`; base URLs + TTLs `constants.gd:96-105` and `mws_api.gd:155-171` |
| Change the Browse tab | `ui_browse_tab.gd:1` `build_browse_tab()`; row rendering `ui_browse_detail.gd:38` `_browse_render_mod_row()`; detail dialog `ui_browse_detail.gd:504`; thumbnails `ui_browse_detail.gd:253` `_browse_load_thumbnail_async()` |
| Add a **registry section** (new content kind) | 1. add the key to `Registry` const at `registry.gd:44`; 2. add match arms in every verb dispatcher (`registry.gd:181` register, `:224` override, `:288` patch, `:386` array ops, `:490` remove, `:528` revert, `:735` get_entry, `:916` `_enumerate_vanilla`); 3. create `src/registry/<name>.gd` with the `_register_*` / `_override_*` / `_remove_*` / `_revert_*` handlers; 4. add the file to `build.sh` FILES; 5. document in `docs/wiki/Registry.md` |
| Add a registry **verb** | `registry.gd` top-level funcs + `setup.gd:55` `setup()` plan dispatch (`setup.gd:126`, `:137`, `:198`) |
| Make the rewriter inject something into a vanilla script | `rewriter.gd:349` `_rtv_rewrite_vanilla_source()` plus the specific injector (`rewriter.gd:487` registry, `:615` preludes). Checklist for a NEW target is written out at `rewriter.gd:57-82` -- follow it; `constants.gd:161-194` skip lists are checked BEFORE the wrap surface and win silently |
| Change the security scanner's rules | `security_scan.gd:61` `_SECURITY_RULES` (pattern + description + `binary` flag). Red-escalation logic: `security_scan.gd:161` `_RED_SOLO_RULES`, `:167` `_PROCESS_SPAWN_RULES`, `:171` `_OBFUSCATION_RULES`, `:174` `_RUNTIME_CODE_RULES`, decision in `security_scan.gd:188` `compute_risk_level()` |
| Change how scan results are surfaced | scan entry `security_scan.gd:260` `scan_mod()`; wiring `mod_discovery.gd:98-100` and `:110-112`; log `mod_discovery.gd:176` `_log_security_findings()`; findings dialog `ui_dialogs.gd:163`; launch-time confirm `ui_dialogs.gd:255` `_confirm_red_launch()` |
| Change what invalidates the mods hash (forces a restart) | `boot.gd:767` `_compute_state_hash()` |
| Change what persists between sessions | `boot.gd:700` `_write_pass_state()`; readers in `boot.gd:170` `_mount_previous_session()` and `lifecycle.gd:251` |
| Change `override.cfg` content or write strategy | `boot.gd:617` `_write_override_cfg()`; preserved sections `fs_archive.gd:93` `_read_preserved_cfg_sections()`; clean template `boot.gd:127` `_clean_override_cfg_content()` |
| Add a profile feature | `ui_config_profiles.gd:336` `_list_profiles()`, `:604` `_create_profile()`, `:654` `_switch_profile()`, `:691` `_rename_profile()`, `:619` `_delete_active_profile()`; storage layout `ui_config_profiles.gd:484`/`:532` |
| Change modpack apply/rollback | `modpacks.gd:882` `apply_modpack()` -> `:899` `_apply_modpack_inner()`; snapshot `modpacks.gd:492` `_snapshot_state_before_apply()`; restore `modpacks.gd:694` `_restore_apply_snapshot()`; unload `modpacks.gd:1191`; export `modpacks.gd:1335` `save_profile_as_modpack()`; UI flow `ui_modpacks_tab.gd:509` `_apply_modpack_with_ui_flow()` |
| Change the modpack file format / validation | `modpacks.gd:156` `_validate_modpack()`, `:209` `_build_modpack_entry()`, `:197` `_is_modpack_zip()`; override allowlist `modpacks.gd:108` + `:316` |
| Add a public API method mods can call | `hooks_api.gd` (hooks/introspection), `registry.gd` (content), `setup.gd` (declarative plans). All are methods on the same object exposed via `Engine.get_meta("RTVModLib")` |
| Change dev-folder behavior | gate `mod_discovery.gd:29`; zip build `fs_archive.gd:413` `zip_folder_to_temp()`; staleness `fs_archive.gd:394` `_folder_dev_zip_current()`; setting read `ui_config_profiles.gd:19` |
| Add a log line / change log levels | `logging.gd:33-51`; developer-mode gating flows through `_developer_mode` (`constants.gd:204`) |
| Change crash recovery / safe mode | `boot.gd:813` `_check_crash_recovery()`, `boot.gd:828` `_check_safe_mode()`, sentinel names `constants.gd:49-59` |
| Add a src file | edit the `FILES` array in `build.sh` -- order matters and is not alphabetical |

---

## 5. Glossary

The naming is the main reason this codebase is hard to navigate. This section
is the decoder ring.

| Term | Plain English | Where it lives |
|---|---|---|
| **mount** | Register a zip/pck with Godot's virtual filesystem so its files answer to `res://` paths. This IS "loading a mod" in engine terms. | `fs_archive.gd:133` `_try_mount_pack()` -> `ProjectSettings.load_resource_pack` |
| **pack** | Any archive Godot can mount (`.pck`, `.zip`, `.vmz`). "Load a resource pack" is Godot's own wording; the loader inherited it. | `constants.gd:128` TRACKED_EXTENSIONS |
| **archive** | Same as pack, used for the mod's own file. `_archive_file_sets[file]` = the res:// paths it claims. | `constants.gd:294`, `mod_loading.gd:457` |
| **hook pack** / **framework pack** | A zip the loader *generates* each session containing rewritten copies of vanilla game scripts. Not a mod. Lives at `user://modloader_hooks/framework_pack_<ticks>.zip`. Its entries sit at the **original vanilla paths** (`Scripts/Camera.gd`), which is how it wins over the PCK. | `hook_pack.gd:98`, filename `hook_pack.gd:106` |
| **Pass 1** | The launch where the user sees the launcher UI. Ends by either finishing in place or quitting with a restart request. | `lifecycle.gd:114` `_run_pass_1()` |
| **Pass 2** | The relaunch, detected by `--modloader-restart`. Archives and early autoloads are already live; this pass finishes the job. | `lifecycle.gd:241` `_run_pass_2()` |
| **two-pass restart** | The whole quit-and-relaunch dance. Only needed when a mod declares an early (`!`) autoload or the mod set changed. | `lifecycle.gd:156-184` |
| **mods hash** / **state hash** | md5 fingerprint of the enabled mod set. If it matches last session's, Pass 1 skips the restart entirely. | `boot.gd:767` `_compute_state_hash()`, check `lifecycle.gd:146` |
| **pass state** | `user://mod_pass_state.cfg` -- what static init needs to replay last session (archive paths, hook pack path, wrapped paths, hash, restart count). | `boot.gd:700` `_write_pass_state()` |
| **static init** / **file-scope** | Code that runs when the script *loads*, before `_ready`. Achieved by a module-scope var whose initializer is a function call. Earliest possible hook into engine boot. | `constants.gd:378`, `boot.gd:170` |
| **candidate** | An enabled, dependency-satisfied mod entry that survived filtering and is about to be mounted. Only exists inside the load path. | `mod_loading.gd:26`, produced by `mod_discovery.gd:777` |
| **entry** | The Dictionary describing one installed mod (file_name, full_path, ext, mod_name, mod_id, version, author, priority, enabled, profile_key, cfg, warnings, security_findings, risk_level, ...). The universal currency between discovery, UI, and loading. Lives in `_ui_mod_entries`. | built `mod_discovery.gd:358`, stored `constants.gd:275` |
| **profile** | A named set of enable/priority choices in `user://mod_config.cfg`, sections `profile.<name>.enabled` / `.priority` / `.settings` / `.dep_ignore`. | `ui_config_profiles.gd:484` `_profile_sec()` |
| **profile_key** | Stable identity for a mod across file renames: `"<mod_id>@<version>"`, or `"zip:<file_name>"` when no id is declared. The key used in every persisted per-profile section. | `mod_discovery.gd:356` (contract comment `:339-355`) |
| **modpack** | A shareable `.zip` with `profile.json` at its root instead of `mod.txt`, containing a mod list + settings. Lives in the same `mods/` folder; filtered out of the Mods tab. | `modpacks.gd:197` `_is_modpack_zip()`, `modpacks.gd:242` |
| **registry** | Two unrelated meanings. (a) The **content API** mods use to add items/recipes/scenes: `registry.gd` + `registry/*.gd`. (b) `_override_registry`, a bookkeeping dict of which mod claims which `res://` path, used only for the conflict report. | (a) `registry.gd:44`; (b) `constants.gd:292`, `mod_loading.gd:382` |
| **claim** | A record that mod X provides `res://some/path`. Feeds conflict detection. | `mod_loading.gd:382` `_register_claim()` |
| **detokenize** | Turn RTV's compiled `.gdc` bytecode back into readable GDScript source. Necessary because the game ships no plain-text scripts. | `gdsc_detokenizer.gd:114` `_detokenize_script()` |
| **rewrite** | Take detokenized vanilla source and produce a modified copy where hookable methods are renamed to `_rtv_vanilla_<name>` and replaced by dispatch wrappers. | `rewriter.gd:349` `_rtv_rewrite_vanilla_source()` |
| **wrap surface** / **wrap mask** | The set of vanilla scripts (and, per script, which methods) that get rewritten. Opt-in: nothing declared means nothing rewritten. Stored in `_hooked_methods[path] = {method: true}`; an **empty inner dict is the wildcard sentinel** meaning "wrap every method". | built `hook_pack.gd:188-241`, populated `mod_loading.gd:219`, `mod_loading.gd:66` |
| **remap** | Godot's `.remap` redirect file (`foo.gd.remap` -> `foo.gdc`). The loader (a) resolves mods' remaps after mount so `preload()` works, and (b) ships a *self-referencing* `foo.gd.remap` -> `foo.gd` in the hook pack to defeat the PCK's redirect to bytecode. | (a) `fs_archive.gd:154`; (b) `hook_pack.gd:459-467` |
| **three-entry recipe** | The exact zip layout that beats the PCK for one script: rewritten `.gd`, self-referencing `.gd.remap`, and a **zero-byte `.gdc`** (Godot prefers a sibling `.gdc`, so an empty one forces fallback to compiling our `.gd`). | `hook_pack.gd:449-481` |
| **VFS** | Godot's virtual filesystem -- the layered view of PCK + mounted packs behind `res://`. "Mount precedence" = later mounts with `replace_files=true` win. | `ProjectSettings.load_resource_pack` call sites |
| **preempt** | At static init, force a fresh source-compile of a wrapped script before Godot's `class_cache` pass pins the PCK bytecode. Only works this early. | `boot.gd:303-397` |
| **activate** | Post-mount, force Godot's already-populated script cache to serve the rewrite (`source_code`+`reload()`, else `CACHE_MODE_IGNORE`+`take_over_path`). | `hook_pack.gd:621` `_activate_rewritten_scripts()` |
| **dev folder** / **folder mod** | An unzipped mod directory in `mods/`, visible only when developer mode is on. Zipped to `user://vmz_mount_cache/<name>_dev.zip` before mounting, because Godot cannot mount a directory. | gate `mod_discovery.gd:29`, zip `fs_archive.gd:413` |
| **early autoload** | An autoload whose mod.txt path starts with `!`. Written into `override.cfg`'s `[autoload_prepend]` so Godot loads it *before* the game's own autoloads. Requires the two-pass restart, and requires the script to be extracted to disk. | classify `mod_loading.gd:339`, split `boot.gd:515`, extract `boot.gd:570` |
| **`[autoload_prepend]`** | Godot override.cfg section, **reverse insertion order** -- the last entry listed is the first loaded. ModLoader must always be last. | `boot.gd:617-632` |
| **sentinel** | A marker file whose mere existence changes behavior: `modloader_disabled`, `modloader_disabled_once`, `modloader_safe_mode` (exe dir), `modloader_pass2_dirty`, `modloader_heartbeat.txt` (`user://`). | `constants.gd:49-58`, checks `boot.gd:91`/`:813`/`:828` |
| **canary** | A cheap boot-time self-test that fails loudly instead of degrading silently: GDSC token version, detokenizer round-trip, VFS mount precedence. | `hook_pack.gd:51`, `hook_pack.gd:584-594`, `gdsc_detokenizer.gd:503` |
| **skip list** | Vanilla scripts the rewriter must never touch (runtime-sensitive, serialized resource, or data). Checked **before** the wrap surface, so a listed file silently never wraps. | `constants.gd:161-194` |
| **sibling** | A `.gd` file inside a mod archive that is not itself an autoload -- pulled through legacy-syntax autofix and re-emitted into the hook pack. Historically "Step E". | `hook_pack.gd:252-344`, `:500-544` |
| **`_rtv_` prefix** | Anything generated or injected by the rewriter. `_rtv_vanilla_foo` is the original body of `foo`. Seeing it in a stack trace means you are inside a rewritten script. | `rewriter.gd:349` |
| **hook name** | `"<script-stem>-<method>[-pre\|-post\|-callback]"`, all lowercase, e.g. `"menu-_ready-post"`. A bare `"<stem>-<method>"` is a *replace* hook. | `hooks_api.gd:47` `_hook_base_of()`, regex `rewriter.gd:107` |
| **RTVModLib** | The name the loader registers itself under in `Engine.get_meta()`. This object is the entire public mod API. | `hooks_api.gd:21` |
| **frameworks_ready** | Signal emitted once every mod autoload has run `_ready()`. The safe point for mods to assume other mods exist. | `hooks_api.gd:30`, signal declared `constants.gd:299` |

---

## 6. Where `docs/wiki/Architecture.md` disagrees with the code

Checked line by line against `fix/3.3.1`. The doc is substantially accurate;
these are the discrepancies found.

| # | Doc claim | Reality |
|---|---|---|
| 1 | Static-init trigger is at `src/constants.gd:366` (Architecture.md:12) | It is at **`src/constants.gd:378`**. The line number drifted; the code is correct. |
| 2 | Pass 1 outline (Architecture.md:39-69) lists "compile regex, build class_name lookup, load dev-mode setting" | Omits **`_enumerate_game_scripts()` at `lifecycle.gd:126`**, which was deliberately hoisted into Pass 1/2 so the `.hook()` prefix resolver can match `class_name`-less scripts. Without it in the map, that call looks redundant with the one inside `_generate_hook_pack`. |
| 3 | Pass 2 outline (Architecture.md:77-88) ends at `reload_current_scene()` | Misses the trailing **Windows foreground-grab block, `lifecycle.gd:343-354`**. |
| 4 | Atomic override.cfg write is "boot.gd:654-679" (Architecture.md:108) | The park/promote block actually spans **`boot.gd:657-679`**. Off by three; behavior described is correct. |
| 5 | ~~`hook_pack.gd:94-97` said "The zip mounts at `res://modloader_hooks/` and wrappers load from there"~~ **FIXED on this branch** | That was false and inverted the design. The zip *file* lives in `user://modloader_hooks/`, but its **entries are written at the original vanilla paths** (`Scripts/Camera.gd`) -- `hook_pack.gd:449` `var gd_entry := script_path.trim_prefix("res://")`. Writing them under a subfolder would override nothing and defeat the whole mechanism. The comment now says so, and the dead constant `HOOK_PACK_MOUNT_BASE` (declared in `constants.gd`, referenced nowhere) was removed with a note in its place. |

Nothing else in Architecture.md contradicted the code. The pass-state key
table (Architecture.md:116-128), the override.cfg invariants, and the
heartbeat/safe-mode section all check out.

### Verified branch order inside `_mount_previous_session`

Architecture.md's numbered list matches the code. Exact guard lines:

| Guard | Line |
|---|---|
| Disabled sentinel | `boot.gd:186` |
| Crashed-Pass-2 marker (`modloader_pass2_dirty`) | `boot.gd:195` |
| Pass state load / absent | `boot.gd:208` |
| `modloader_version` mismatch -> wipe | `boot.gd:217` |
| Exe mtime changed -> wipe hook cache | `boot.gd:231-234` |
| Empty `archive_paths` -> skip | `boot.gd:242` |
| Any archive missing -> clean `override.cfg`, delete pass state, return | `boot.gd:250-282` |
| Mount loop | `boot.gd:284+` |
| Step D hook-pack preempt | `boot.gd:303-397` |

`_write_pass_state` increments `restart_count` on **every** call, not only
restart-bound ones -- `boot.gd:703-704`. Architecture.md:136 is correct.
