# Metro Mod Loader 3.3 -- Queued Proposals (need user decision / runtime test)

These are deliberately NOT auto-committed. Each touches a sensitive, UNTESTABLE-
here path where a confidently-wrong change is worse than the edge it fixes
(standing rule). Diff sketches below; greenlight to land.

Already LANDED (safe, additive): B1 order-panel autowrap crash (1c83aa1),
S2 dep_ignore round-trip + S3 managed-prefix reject (f0411f2).
STATUS UPDATE 2026-07-01: S1's safe subset (.bak rolling backup + recovery),
S4's option (a) (live update-path re-resolve), and G5 option B (disable-content-
mod confirm dialog) all LANDED in d6c2bae -- sections below kept for the parts
still open (S1 fully-atomic write, S4 option b, G5 option C). The 2026-07-01
Fable readiness review landed a further hardening commit (8f3b36f) and queued
the NEW proposals at the bottom of this file.

--------------------------------------------------------------------------------
## S1 -- atomic config writes / all-profiles-wipe guard  (MEDIUM, deferred)
--------------------------------------------------------------------------------

THE RISK with a naive fix: true atomic replace needs rename-over-existing, which
does NOT reliably overwrite on Windows in Godot's DirAccess -- and Windows is the
real deploy target I cannot test here. A wrong rename could break EVERY config
save (bigger blast radius than the rare corruption S1 fixes; the report rated its
trigger probability low).

RECOMMENDED SAFE SUBSET (no rename footgun) -- two parts:
  1. Rolling backup: after a successful central save, best-effort
     `DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")`
     (copy_absolute overwrites cross-platform; never touches the live file's
     write path).
  2. Load-failure fallback in _load_ui_config (ui.gd:29): before materializing a
     fresh Default and overwriting, try to load `.bak`; if it loads, adopt it and
     preserve the broken file as `.corrupt-<n>` for the user. Only if `.bak` also
     fails -> fresh Default.

This addresses the actual harm (load failure wiping all profiles) without making
the write non-atomic in a Windows-unsafe way. OPEN QUESTION for you: land the safe
subset, or hold out for a fully-atomic write (needs a Windows-correct replace
primitive we'd have to validate on real hardware)?

--------------------------------------------------------------------------------
## S4 -- Updates-tab / badge path desync  (MEDIUM, deferred)
--------------------------------------------------------------------------------

After a badge-side update, `_ui_mod_entries = collect_mod_metadata()` reassigns the
array and orphans the dict the Updates tab holds by reference; the Updates tab is
built once and never rebuilt on tab_changed. A later cross-surface re-update of an
already-updated mod resolves a stale full_path -> rename-collision guard ->
repeatable "Update Failed: unknown". First update SUCCEEDS; harm is a stale badge +
misleading message that self-heals on UI reopen.

THE RISK: the clean fix is "rebuild the Updates tab on tab_changed," but unlike the
Modpacks tab (which has _rebuild_profile_tab with a _rebuilding_profile_tab
recursion guard + current_tab preservation), the Updates tab has NO rebuild helper.
Building one blind risks the exact tab-rebuild/tab_changed recursion the existing
code comments (ui.gd ~2405, ~2688) warn about.

PROPOSED, in order of safety:
  a. Low-risk, high-value: in BOTH download paths, re-resolve full_path from a
     fresh collect_mod_metadata() immediately before the download instead of using
     the captured path. Kills the "Update Failed: unknown" repeat without any tab
     rebuild. (This alone fixes the user-visible failure.)
  b. Optional follow-up: add a guarded _rebuild_updates_tab mirroring
     _rebuild_profile_tab, and extend the tab_changed listener (ui.gd:2691) to call
     it when switching to "Updates". More surface, needs runtime check for the
     recursion edge.

Recommend landing (a) after a read-through; defer (b) unless you want the live
badge to refresh without reopen.

--------------------------------------------------------------------------------
## G5 -- disabling a content mod bricks an existing save  (HIGH-conditional)
--------------------------------------------------------------------------------

Mechanism (confirmed): registry/items.gd _register_item does `data.set("file", id)`
with no resource_path/take_over_path, so saves reference mod items BY ext-resource
PATH. Disable the mod -> the path is gone -> game Loader.gd null-derefs on Continue.
Save is NOT corrupted (re-enabling the mod fully restores it), but 3.3 ships an
enable/disable feature with no warning. This is NEW behavior on the save path ->
must not land autonomously before you test (standing rule).

DESIGN OPTIONS (pick one):
  A. Documented known-limitation only (zero runtime risk): a Limitations.md +
     Modpacks/profile-docs note "disabling a mod that adds items/recipes/etc. can
     break saves created with it; re-enable to recover." Ship-safe today.
  B. Disable-time confirm dialog (additive UI, no save/load change): when the user
     disables a mod whose mod.txt declares [registry] content, show "This mod adds
     game content. Existing saves that use it may fail to load until it's
     re-enabled. Disable anyway?" Detect content via the manifest (static, known).
  C. Boot-time save scan (most help, most risk): read the active save, detect refs
     to missing mod resources, warn by name. Complex, can itself crash boot, fully
     untestable here -- NOT recommended for a stable release.

RECOMMENDATION: A for 3.3 stable now (safe), B as a fast-follow (additive, low-risk
but needs your runtime confirm). C only if A+B prove insufficient in real use.

Status: A LANDED (docs/wiki/Limitations.md entry, commit with the 3.3 docs). The
docs pass also surfaced a mechanism nuance worth knowing: the failure is that mod
items live only in the per-launch registry table (not merged into vanilla's
LT_Master.items), so a save can't re-resolve the content once the mod is gone --
the consequence (load fails, save not corrupted, re-enable recovers) is the same
as the report's null-deref framing, but the exact crash-vs-soft-lock depends on
the game build (closing wave logged it as L2, a recoverable G5-family soft-lock).
B (confirm dialog) still queued for your runtime verification.

--------------------------------------------------------------------------------
## G6 / L1 -- override('scene_paths', <vanilla scene>) silent clobber  (HIGH should-fix, deferred)
--------------------------------------------------------------------------------

Found by the closing review wave (full detail in RELEASE_READINESS_3.3_CLOSING.md,
finding L1). registry/loader.gd:_override_scene_path injects via the rewriter
prelude (rewriter.gd ~554-579), but the unmodified vanilla if/elif scene-path
chain runs AFTER and silently overwrites the override -- so a documented first-
class API (override scene_paths) is a no-op, and it also clobbers gameData flags.

Degrades gracefully: the vanilla scene loads, NO crash, NO save damage. So it
gates the scene-override FEATURE but is not a hard ship blocker.

THE RISK with fixing blind: this is in the rewriter prelude / patch engine -- the
same untestable, high-blast-radius surface as G4. A wrong prelude edit can break
boot for every modded launch. DEFER to a proposal + runtime test rather than a
blind commit. Fix direction (for collaborative build): have the injected prelude
short-circuit/return the overridden path BEFORE the vanilla if/elif chain, and
preserve the gameData flag writes. Validate against the live game build (ties into
G4's rewriter-vs-live-build verification).


================================================================================
# NEW PROPOSALS -- 2026-07-01 Fable readiness review (propose-only zone)
================================================================================
All four touch the modpack apply/unload state machine (standing rule: propose,
don't commit). Finding IDs reference FABLE_READINESS_REVIEW_20260701.md.

--------------------------------------------------------------------------------
## MP-1 -- pack-downloaded mods auto-enable on Default after Cancel/Unload (HIGH)
--------------------------------------------------------------------------------
Mods downloaded during an apply have no stored profile keys; `entry["enabled"] =
profile == "Default"` in _apply_profile_to_entries then silently turns them ON in
the user's Default profile after a Cancel or an Unload. The #1 rage-trigger class
(silent state change); shipped in beta.1 as a documented Known Limitation.
PROPOSED FIX: track the profile_keys of mods downloaded during apply (known per
item), and (a) on the cancel return path, write explicit enabled=false entries
for them into the ACTIVE profile's .enabled section; (b) at backup time, write
the same explicit-false entries into the backup slot so Unload restores them
disabled. Additive cfg writes, no reorder -- but it mutates cfg on a path that
today mutates nothing, so it needs your sign-off + a real-download test.

--------------------------------------------------------------------------------
## MP-7 -- materialize failure strands active_modpack flag for the session (MEDIUM)
--------------------------------------------------------------------------------
The active_modpack flag is deliberately written EARLY (crash revert-trigger);
if _materialize_modpack_profile then fails (zip deleted/locked between validate
and materialize), the apply aborts with the flag set: UI shows "[Modpack: X]"
locked/ACTIVE while the old profile is live. Boot reconciler heals it next
launch; Unload also works. PROPOSED FIX: on materialize failure, invert the
step-1 writes before returning (clear active_modpack + modpack_backup_profile,
erase the just-written backup sections) -- a scoped compensating write.

--------------------------------------------------------------------------------
## SN-2-FULL -- abort or confirm when the restore point cannot be written (MEDIUM)
--------------------------------------------------------------------------------
8f3b36f made snapshot failure LOUD (log + no fake restore point), but apply
still proceeds without one. PROPOSED FIX: _apply_modpack_inner checks the ""
return and shows "Could not save a restore point -- apply anyway?" confirm
(or aborts). Touches the apply step-0 flow -> your call on dialog vs abort.

--------------------------------------------------------------------------------
## MP-4 -- unload aborts forever for the zero-local-mods first-run persona (MEDIUM)
--------------------------------------------------------------------------------
A fresh install with no mods produces an empty pre-apply Default -> no backup
sections -> unload's missing-backup corruption guard fires every time. 8f3b36f
improved the error text (points at Restore backup). PROPOSED FULL FIX: write a
`settings.modpack_backup_taken=true` marker at backup time; unload treats
missing-sections-with-marker as a legitimately-empty profile (restores to
empty) and only aborts when the marker is also absent (true corruption).

--------------------------------------------------------------------------------
Below the line (analysis only, no proposal yet): MP-10 reconciler restores to
alphabetically-first profile instead of the recorded pre-apply one; MP-12
case-sensitivity mismatch between pack profile_keys and the installed-mod
lookup; SN-7/SN-8 narrower crash-window variants around the early flag write;
RW-3 registry whole-file transforms fire on filename match without a [registry]
opt-in (contradicts its gate comment -- worth a look before more registry mods
exist); RW-4 safe-mode sentinel unreachable from Pass 2; LC1 restart counter.
Full detail in FABLE_READINESS_REVIEW_20260701.md.

================================================================================
# 2026-07-06 fix-wave deferrals
================================================================================
Deferred by the audit fix-wave finalizer. Finding numbers reference
confirmed-findings.json (1-indexed) and the finalizer review list.
Note: the review's hooks_api.gd add_hook wildcard-sentinel gap (findings
25/31 residue) was FIXED in this wave, not deferred.

--------------------------------------------------------------------------------
## FW-1 -- Finding 24 residue: _set_ui_cfg_value ignores cfg.load() failure (ui.gd)
--------------------------------------------------------------------------------
Same ignored-load pattern as the fixed _persist_mod_sources_for_entries, feeding
_persist_ui_cfg (which copies live over .bak before saving). PROPOSED FIX:
capture `var load_err := cfg.load(UI_CONFIG_PATH)`; if load_err != OK and
FileAccess.file_exists(UI_CONFIG_PATH): _log_critical (file exists but failed to
load; skipped write so the backup stays usable) and return before any
set_value/_persist_ui_cfg. Alternative: harden inside _persist_ui_cfg itself --
verify the live file still parses on a scratch ConfigFile before refreshing
.bak; skip the .bak refresh (still save) when it does not.

--------------------------------------------------------------------------------
## FW-2 -- Finding 26 residue: case-sensitive duplicate skip in load_all_mods
--------------------------------------------------------------------------------
mod_loading.gd:~123 `_loaded_mod_ids.has(mod_id)` is case-sensitive; after the
dedupe fix case-twins cannot normally reach it (defense-in-depth only).
PROPOSED FIX (safe minimal): keep raw-cased _loaded_mod_ids keys and add a
parallel lowercased set for the skip check only (two lines, zero public-API
impact). Option (b): normalize storage keys AND hooks_api.gd
has_mod/mod_info lookups to to_lower() in one coordinated change. Do either in
the same wave as any hooks_api.gd edit to avoid cross-agent conflicts.

--------------------------------------------------------------------------------
## FW-3 -- override.cfg.old manual recovery doc (review finding 3, residual)
--------------------------------------------------------------------------------
The safe-replace sequence in boot.gd _write_override_cfg leaves a two-rename
crash window: if the process dies between the park rename (override.cfg ->
override.cfg.old) and the promote rename (.tmp -> override.cfg), no live
override.cfg exists and nothing self-heals (modloader code cannot run without
it). PROPOSED FIX (docs only): add a README/troubleshooting note -- "if the
loader stops loading and an override.cfg.old sits next to RTV.exe, rename it
back to override.cfg". Optionally mention it in install instructions.

--------------------------------------------------------------------------------
## FW-4 -- v4 pck guidance in modder-facing docs (g47 item 1, second half)
--------------------------------------------------------------------------------
Add a short "Exporting .pck mods" note to README.md and the wiki Mod-Format
page: mod .pck files must be exported with Godot 4.6.x because Godot 4.7+
writes pack format v4 which the 4.6 game cannot read; .zip mods are immune to
pack format versions and are the recommended distribution format.

--------------------------------------------------------------------------------
## FW-5 -- Findings 18/4 second half: retry_failed_downloads cancel + reentrancy
--------------------------------------------------------------------------------
ESC is now swallowed on the retry progress dialog, but retry has no Cancel and
no reentrancy guard (a concurrent Apply could interleave downloads/cfg writes;
a hung download leaves the user stuck). PROPOSED FIX (touches the apply/unload
state machine): (a) reentrancy -- set _modpack_apply_in_progress at
retry_failed_downloads entry/exits (the flag apply_modpack's guard checks), or
a dedicated _modpack_retry_in_progress checked by apply_modpack and the Launch
loop; (b) cancellation -- Cancel button in _run_modpack_retry mirroring
_build_modpack_progress_dialog (pressed sets _modpack_apply_cancelled), and
`if _modpack_apply_cancelled: break` at the top of the per-failure loop (reset
at entry, same as apply_modpack). ~6 lines ui.gd + ~8 modpacks.gd; needs the
modpacks owner's review of the flag lifecycle.

--------------------------------------------------------------------------------
## FW-6 -- Finding 20 pagination half / review finding 5: filter re-fetch drops loaded pages
--------------------------------------------------------------------------------
After a successful Browse download in filter mode, the queue-drain re-fetch
calls do_filter_fetch(false), collapsing "Load more" pages back to page 1 (the
restored scroll then clamps to page-1 height). Mixed-batch failures now sync in
place via _refresh_browse_installed_rows (landed this wave), so the remaining
gap is the all-success drain only. PROPOSED FIX: replace the post-download
re-fetch entirely with _refresh_browse_installed_rows(list) -- zero network,
zero layout churn; the restore_scroll plumbing becomes dead code to remove.
Tradeoff: the just-installed row shows a disabled "Installed" button instead of
converting to the "Enabled in <profile>" checkbox until the next real
fetch/tab re-entry -- deliberate UX call, decide before implementing.

--------------------------------------------------------------------------------
## FW-7 -- Finding 6 adjacent hole: unload + boot reconciler leak MCM when user://MCM/ was absent at apply
--------------------------------------------------------------------------------
Apply's _snapshot_mcm_to(backup_profile) creates nothing when user://MCM/ does
not exist, so unload step 5 and the reconciler's _has_mcm_snapshot check skip
the MCM rollback and leave the pack's MCM live after unload (Restore-button leg
was fixed via the snapshot.json mcm_absent flag). PROPOSED FIX: at backup time,
when MCM_SOURCE_DIR is absent, write a marker file (e.g. MCM_ABSENT inside
MCM_SNAPSHOT_BASE/<backup_profile>/); unload step 5 and the reconciler treat
"marker present" as "wipe user://MCM/ then delete the marker" where they
currently require _has_mcm_snapshot. Touches the apply/unload state machine.

--------------------------------------------------------------------------------
## FW-8 -- _remove_dir_recursive skips dot-files on Linux/macOS
--------------------------------------------------------------------------------
ui.gd _remove_dir_recursive walks with the default hidden-excluded DirAccess
listing; on Linux/macOS dot-prefixed files survive and the final
remove_absolute fails on the non-empty dir (Windows deploy target mostly
unaffected). PROPOSED FIX: one line -- `dir.include_hidden = true` after
DirAccess.open(path). Deferred because the walker is shared by
profile-swap/MCM/snapshot-prune call sites; changing deletion breadth for all
of them deserves its own reviewed pass.
