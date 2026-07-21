## ----- ui.gd -----
## The launcher window shown before the game starts.
##   - Mods tab: per-mod enable checkbox + load-order spin, profile selector
##     (switch / create / delete), and a live load-order preview.
##   - Browse tab: ModWorkshop catalog + install.
##   - Modpacks tab: apply/unload modpack zips, save the current profile
##     as a modpack, and restore automatic pre-apply backups.
##   - Updates tab: ModWorkshop version checking + downloads.
##   - Bottom bar has "Launch Vanilla" (one-shot bypass via the
##     DISABLED_ONCE_FILE sentinel) alongside the main Launch Game button.
##   - Profiles live in UI_CONFIG_PATH under `profile.<name>.enabled` and
##     `profile.<name>.priority`; the active profile is stored in
##     `[settings] active_profile`. VANILLA_PROFILE is kept only as a
##     legacy migration target -- pre-3.2.2 users may have it stored,
##     and _load_ui_config rewrites it to the first real profile.
## Closing the window (or clicking Launch Game) hands control back to
## _run_pass_1.

# -- Design tokens (.research/UI_DESIGN_SPEC.md sections 2-4) ------------------
# Single source of truth for launcher colors, type sizes, and spacing.
# make_dark_theme and the style_* helpers consume these; styled call sites
# map onto them instead of raw values. One amber, one green, one red.

# Base surfaces
const COL_BG         := Color(0.04, 0.04, 0.04)  # window/panel floor
const COL_SURFACE    := Color(0.07, 0.07, 0.07)  # buttons, inputs, rows
const COL_SURFACE_2  := Color(0.10, 0.10, 0.10)  # hover, elevated rows
const COL_BORDER     := Color(0.18, 0.18, 0.18)  # 1px structural borders
const COL_BORDER_DIM := Color(0.12, 0.12, 0.12)  # disabled/unselected
# Text
const COL_TEXT       := Color(0.84, 0.84, 0.84)  # body
const COL_TEXT_HI    := Color(0.95, 0.95, 0.93)  # emphasis/hover (warm, not pure white)
const COL_TEXT_DIM   := Color(0.52, 0.52, 0.50)  # secondary/meta
const COL_TEXT_FAINT := Color(0.38, 0.38, 0.36)  # disabled only
# Signal amber (THE accent -- exactly these two)
const COL_AMBER      := Color(0.95, 0.67, 0.26)  # focus, selected, primary, progress, badges
const COL_AMBER_DIM  := Color(0.55, 0.38, 0.16)  # amber borders/washes, banner edges
# Semantics (exactly one green, one red)
const COL_OK         := Color(0.58, 0.74, 0.46)  # enabled, success
const COL_OK_DIM     := Color(0.33, 0.42, 0.27)
const COL_ERR        := Color(0.91, 0.44, 0.38)  # errors, blocked, danger
const COL_ERR_DIM    := Color(0.45, 0.22, 0.19)

# Type scale (five sizes, no exceptions)
const FS_META  := 10   # timestamps, counts, fine print
const FS_BODY  := 11   # default body, buttons, rows
const FS_EMPH  := 12   # emphasized row titles, dialog body
const FS_HEAD  := 13   # section headings, dialog titles
const FS_TITLE := 16   # the window header plate only

# Spacing scale
const SP_XS := 2   # hairline gaps (badge-to-label)
const SP_S  := 4   # intra-row gaps
const SP_M  := 8   # between controls in a group
const SP_L  := 12  # between groups; container padding
const SP_XL := 16  # dialog outer padding, tab content padding

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		# Live config missing or corrupt. This runs BEFORE collect_mod_metadata
		# (which drops dev-folder mods when developer_mode is off) and before
		# _load_ui_config recovers the profiles from the rolling .bak -- so read
		# developer_mode from that same backup here. Without this, a recoverable
		# corrupt config silently turns dev mode off and strands every folder mod
		# for the session even though the rest of the config recovers fine.
		var bak := UI_CONFIG_PATH + ".bak"
		if not (FileAccess.file_exists(bak) and cfg.load(bak) == OK):
			return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	_active_profile = "Default"
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		# The live config is missing OR failed to parse (corrupt / half-written
		# by a crash mid-save). Before falling through to a fresh Default -- which
		# overwrites and would wipe every other stored profile -- try the rolling
		# backup written by _persist_ui_cfg.
		var bak := UI_CONFIG_PATH + ".bak"
		var bak_cfg := ConfigFile.new()
		if FileAccess.file_exists(bak) and bak_cfg.load(bak) == OK:
			_log_warning("[Config] " + UI_CONFIG_PATH + " unreadable; recovered from .bak")
			# Preserve the unreadable file for inspection, then write the
			# recovered state back as the live config. Raw save (not
			# _persist_ui_cfg) so the corrupt live file is not copied over the
			# good backup we just read.
			if FileAccess.file_exists(UI_CONFIG_PATH):
				DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt")
			cfg = bak_cfg
			cfg.save(UI_CONFIG_PATH)
			# Fall through and process the recovered cfg normally.
		else:
			# Genuinely fresh install (or the backup is also unreadable):
			# materialize the placeholder Default profile so it is a real on-disk
			# profile from the first UI render (see the comment at the tail of
			# this function for rationale). If a corrupt live config exists,
			# preserve it as .corrupt for inspection first -- the .bak is already
			# bad in this branch, so there is nothing good left to lose, and it
			# matches the recovery branch above.
			if FileAccess.file_exists(UI_CONFIG_PATH):
				DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt")
			_save_ui_config()
			return

	# Migrate legacy flat [enabled]/[priority] layout into profile.Default.* on
	# the first post-upgrade load. The next _save_ui_config writes the file back
	# without the flat sections, so the migration only runs once per install.
	var has_any_profile := false
	for sec: String in cfg.get_sections():
		if sec.begins_with("profile."):
			has_any_profile = true
			break
	if not has_any_profile:
		if cfg.has_section("enabled"):
			for key: String in cfg.get_section_keys("enabled"):
				cfg.set_value("profile.Default.enabled", key, cfg.get_value("enabled", key))
		if cfg.has_section("priority"):
			for key: String in cfg.get_section_keys("priority"):
				cfg.set_value("profile.Default.priority", key, cfg.get_value("priority", key))

	var stored := str(cfg.get_value("settings", "active_profile", "Default"))
	var profiles := _list_profiles_in_cfg(cfg)
	# Legacy: pre-Vanilla-removal users have stored = VANILLA_PROFILE in their
	# config. Treat it as missing so we fall through to the first user profile
	# rather than a sentinel value with no UI presence.
	if stored == VANILLA_PROFILE:
		stored = ""
	if stored in profiles:
		_active_profile = stored
	elif not profiles.is_empty():
		_active_profile = profiles[0]
	else:
		_active_profile = "Default"

	# Reconcile modpack state. A managed slot (modpack__X) is a legitimate
	# active profile ONLY while that pack is genuinely applied (active_modpack
	# names it). Resolving into a managed slot with no matching active_modpack
	# means we were stranded -- a crash mid-apply, a quit during unload, or a
	# delete that fell into a managed slot. And a lingering active_modpack flag
	# whose slot we're no longer in is just stale. Either way, recover to a
	# real user profile / clear the flag instead of letting the user edit a
	# pack-managed slot invisibly.
	var active_mp := str(cfg.get_value("settings", "active_modpack", ""))
	var mp_dirty := false
	if _is_modpack_managed_profile(_active_profile) \
			and _active_profile != MODPACK_PROFILE_PREFIX + active_mp:
		# Stranded in a managed slot whose pack isn't active (crash mid-apply,
		# or a quit during unload). Restore override files AND roll live MCM back
		# to the pre-apply snapshot -- keyed off the slot name, since active_mp
		# may be blank here -- then recover to a real user profile. Without the
		# MCM rollback, a crash mid-unload leaves the modpack's MCM live, and the
		# next profile switch would capture it into a user slot and corrupt it.
		# Both restores no-op when their backup is absent, so this is safe even
		# when nothing was applied.
		if _active_profile.begins_with(MODPACK_PROFILE_PREFIX):
			var bslot := MODPACK_BACKUP_PREFIX + _active_profile.trim_prefix(MODPACK_PROFILE_PREFIX)
			_restore_modpack_overrides(bslot)
			if _has_mcm_snapshot(bslot):
				_restore_mcm_from(bslot)
		var users := _list_user_profiles_in_cfg(cfg)
		_active_profile = users[0] if not users.is_empty() else "Default"
		cfg.set_value("settings", "active_profile", _active_profile)
		active_mp = ""
		mp_dirty = true
		_log_warning("[Modpack] Recovered from a stranded managed slot -> profile '%s'" % _active_profile)
	elif active_mp != "" and _active_profile != MODPACK_PROFILE_PREFIX + active_mp:
		# Revert trigger set but we never reached the pack's slot: a crash after
		# the apply set active_modpack but before _switch_profile. Best-effort
		# restore of override files via the manifest, then clear the stale flag.
		# (A crash mid-apply, before _apply_modpack_overrides writes its manifest,
		# is covered instead by the independent pre-apply snapshot + Restore
		# button -- the manifest-driven path is a no-op in that narrow window.)
		_restore_modpack_overrides(MODPACK_BACKUP_PREFIX + active_mp)
		active_mp = ""
		mp_dirty = true
	if mp_dirty:
		cfg.set_value("settings", "active_modpack", active_mp)
		_persist_ui_cfg(cfg)

	_apply_profile_to_entries(cfg, _active_profile)

	# Materialize the placeholder Default profile when it's the resolved
	# active and wasn't on disk at load time. Without this, "Default"
	# appears in the dropdown only as a UI-level placeholder (see the
	# profile selector build in build_mods_tab) and vanishes the first
	# time the user creates a named profile -- confusing, and also leaves
	# a silent-overwrite gap where an imported profile named "Default"
	# would write without the overwrite confirm (since _list_profiles()
	# wouldn't yet include the untoggled placeholder). Writing the section
	# here makes Default a persistent profile like every other launcher
	# (Firefox, Minecraft, Steam). Users can rename or delete it if they
	# want.
	#
	# Uses the has_any_profile flag captured BEFORE migration rather than
	# cfg.has_section, because the legacy [enabled]/[priority] migration
	# populates profile.Default.* in-memory -- cfg.has_section would
	# return true from the in-memory state and we'd skip the save,
	# leaving disk still without the section.
	if _active_profile == "Default" and not has_any_profile:
		_save_ui_config()

func _apply_profile_to_entries(cfg: ConfigFile, profile: String) -> void:
	# VANILLA_PROFILE has no stored sections -- treating it as "all mods off"
	# lets Reset to Vanilla avoid touching the user's other profiles.
	var is_vanilla := profile == VANILLA_PROFILE
	_load_per_profile_settings(cfg, profile)
	var en_sec := _profile_sec(profile, ".enabled")
	var pr_sec := _profile_sec(profile, ".priority")
	var ig_sec := _profile_sec(profile, ".dep_ignore")
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		entry.erase("profile_version_mismatch")
		# Resolve once, reuse for both enabled and priority lookups. Exact
		# profile_key match first; if missing, fall back to id-prefix match
		# ("<mod_id>@*") so a version bump doesn't silently drop the entry --
		# we carry over the stored state and flag the mismatch for the UI.
		var resolved_key := ""
		if cfg.has_section_key(en_sec, pk) or cfg.has_section_key(pr_sec, pk):
			resolved_key = pk
		elif not pk.begins_with("zip:"):
			resolved_key = _find_stored_key_for_mod_id(cfg, profile, entry["mod_id"])
			if resolved_key != "" and resolved_key != pk:
				entry["profile_version_mismatch"] = {
					"stored":  _version_from_profile_key(resolved_key),
					"current": entry["version"],
				}
		if is_vanilla:
			entry["enabled"] = false
		elif resolved_key != "" and cfg.has_section_key(en_sec, resolved_key):
			entry["enabled"] = bool(cfg.get_value(en_sec, resolved_key))
		else:
			# Auto-enable on Default only. On any other profile (named, renamed,
			# imported), a freshly-discovered mod is treated as user opt-in --
			# adding a mod meant for one profile shouldn't silently turn it on
			# in every other profile. Imports already write explicit disables
			# for unlisted local mods at import time; this catches the symmetric
			# case where a user drops a new mod AFTER importing/creating.
			entry["enabled"] = profile == "Default"
		if resolved_key != "" and cfg.has_section_key(pr_sec, resolved_key):
			entry["priority"] = int(str(cfg.get_value(pr_sec, resolved_key)))
		# "Load anyway" dependency override -- sparse per-profile section,
		# only ever written for keys the user explicitly overrode.
		if is_vanilla:
			entry["dependency_ignored"] = false
		else:
			var ig_key := pk if cfg.has_section_key(ig_sec, pk) else resolved_key
			entry["dependency_ignored"] = ig_key != "" \
					and bool(cfg.get_value(ig_sec, ig_key, false))
	_refresh_dependency_status()

# Per-profile UI settings live in profile.<name>.settings, separate from the
# .enabled / .priority sections so _save_ui_config's erase-and-rewrite pass
# leaves them alone. Vanilla has no stored profile, so its settings fall back
# to defaults rather than materializing a ghost section.
func _load_per_profile_settings(cfg: ConfigFile, profile: String) -> void:
	if profile == VANILLA_PROFILE:
		_mods_hide_disabled = false
		return
	var sec := _profile_sec(profile, ".settings")
	_mods_hide_disabled = bool(cfg.get_value(sec, "hide_disabled", false))

func _save_per_profile_setting(key: String, value: Variant) -> void:
	# Vanilla is a sentinel -- never materialize a profile.__vanilla__.* section.
	if _active_profile == VANILLA_PROFILE:
		return
	_set_ui_cfg_value(_profile_sec(_active_profile, ".settings"), key, value)
	# Deliberately does NOT set _dirty_since_boot: the per-profile settings
	# here are pure VIEW filters (hide_disabled, read only by
	# _mods_entry_visible). Marking dirty would restart the game on the
	# post-boot reopen path just because the user toggled a list filter.

# True when the entry passes the active mods-tab filters (W2/W3). Used by
# row rendering, the All/None toggle handlers, and the empty-state message
# so the three stay in sync. Name match is case-insensitive substring.
func _mods_entry_visible(entry: Dictionary) -> bool:
	if _mods_hide_disabled and not bool(entry.get("enabled", false)):
		return false
	if _mods_filter_text != "":
		var needle := _mods_filter_text.to_lower()
		var hay := str(entry.get("mod_name", "")).to_lower()
		if not hay.contains(needle):
			return false
	return true

# Find a stored profile key matching an entry's mod_id but with a different
# version, so a version bump doesn't orphan the profile entry. Returns "" if
# no such key exists. The "@" sentinel guards against partial-id collisions
# (e.g., "foo" matching "foobar@1.0").
func _find_stored_key_for_mod_id(cfg: ConfigFile, profile: String, mod_id: String) -> String:
	var prefix := mod_id + "@"
	for suffix: String in [".enabled", ".priority"]:
		var sec := _profile_sec(profile, suffix)
		if cfg.has_section(sec):
			for key: String in cfg.get_section_keys(sec):
				if key.begins_with(prefix):
					return key
	return ""

func _version_from_profile_key(key: String) -> String:
	var at := key.find("@")
	if at < 0:
		return ""
	return key.substr(at + 1)

func _list_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	var prefix := "profile."
	var suffix := ".enabled"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - suffix.length())
			# Skip VANILLA_PROFILE -- it's a sentinel, not a real profile, and
			# leaked ghost sections (e.g. from pre-guard auto-save bugs) must
			# not appear in the dropdown.
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	# Also include profiles that only have a priority section (shouldn't happen
	# in practice, but guards against partial state).
	var pr_suffix := ".priority"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(pr_suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - pr_suffix.length())
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	names.sort()
	return names

func _list_profiles() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	return _list_profiles_in_cfg(cfg)

# User-selectable profiles only -- excludes modpack-managed slots (modpack__X
# active slots and _before_modpack_X backups). Any code that picks a profile
# for the user to LAND ON (delete-fallback, etc.) must use this, never the raw
# list, or the user can be switched into a pack-managed slot and corrupt it.
func _list_user_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	return _list_profiles_in_cfg(cfg).filter(
			func(n: String): return not _is_modpack_managed_profile(n))

# Coalesce rapid priority edits into at most one save per ~0.4s window. The
# in-memory e["priority"] is already current; whenever the timer fires it
# persists the latest state. A burst of 200 arrow-ticks collapses to a couple
# of saves instead of 200 ConfigFile rewrites.
func _schedule_priority_save() -> void:
	if _priority_save_pending:
		return
	_priority_save_pending = true
	await get_tree().create_timer(0.4).timeout
	# A profile switch (or other flush) may have already persisted and cleared
	# the pending flag during the wait -- don't re-save now-stale in-memory state
	# (which would belong to a different profile) on top of it.
	if not _priority_save_pending:
		return
	_priority_save_pending = false
	_save_ui_config()

# Maps used by the stored-key preservation pass: "live" = profile_key of every
# entry currently in _ui_mod_entries (these get rewritten from in-memory
# state), "ids" = mod_id of every installed non-zip-keyed entry (used to drop
# stale versioned keys whose state already migrated to a new key).
func _collect_live_profile_key_maps() -> Dictionary:
	var live_keys: Dictionary = {}
	var installed_ids: Dictionary = {}
	for entry in _ui_mod_entries:
		var lk: String = str(entry["profile_key"])
		live_keys[lk] = true
		if not lk.begins_with("zip:"):
			installed_ids[str(entry["mod_id"])] = true
	return {"live": live_keys, "ids": installed_ids}

# True when a stored profile key must survive _save_ui_config's erase+rewrite
# of the active profile's sections. Keys with a live entry are rewritten from
# in-memory state, so they are not preserved here. Everything else is state
# the entry list cannot represent and a save must not silently drop:
#   - folder mods hidden by developer-mode-off (_hidden_folder_profile_keys),
#   - missing mods (file deleted, or a modpack reference not downloaded yet)
#     that feed the Missing-from-this-profile recovery rows.
# Those keys are only removed by the explicit Remove flows
# (_delete_mod_file_and_cleanup, _remove_missing_entry_from_profile and its
# bulk variant). The one exception: a stale versioned key whose id prefix
# resolves to an installed mod is dropped, because _apply_profile_to_entries
# already migrated its state onto the installed mod's current key and keeping
# both would spawn duplicate rows if the mod is later deleted.
func _preserve_stored_profile_key(key: String, live_keys: Dictionary, installed_ids: Dictionary) -> bool:
	if live_keys.has(key):
		return false
	if _hidden_folder_profile_keys.has(key):
		return true
	var at := key.find("@")
	if at > 0 and installed_ids.has(key.substr(0, at)):
		return false
	return true

func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)

	# Drop legacy flat sections if they linger after migration.
	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")

	# Skip profile-section writes while the Vanilla sentinel is active -- it's
	# not a real profile and must not materialize stored sections, even from
	# the Launch-time save in lifecycle.gd.
	if _active_profile != VANILLA_PROFILE:
		# Rewrite the active profile's sections fresh so removed mods don't linger.
		var en_sec := _profile_sec(_active_profile, ".enabled")
		var pr_sec := _profile_sec(_active_profile, ".priority")
		var ig_sec := _profile_sec(_active_profile, ".dep_ignore")
		# Snapshot stored state for every key with no live entry backing it --
		# folder mods that dev-mode-off filtered out of _ui_mod_entries AND
		# missing mods (file deleted, or modpack references not downloaded
		# yet). Otherwise the erase+rewrite below would silently drop them on
		# any save, killing the Missing-mods recovery rows and their
		# confirm-gated Remove flow. See _preserve_stored_profile_key.
		var key_maps := _collect_live_profile_key_maps()
		var live_keys: Dictionary = key_maps["live"]
		var installed_ids: Dictionary = key_maps["ids"]
		var preserved_enabled: Dictionary = {}
		var preserved_priority: Dictionary = {}
		if cfg.has_section(en_sec):
			for key: String in cfg.get_section_keys(en_sec):
				if _preserve_stored_profile_key(key, live_keys, installed_ids):
					preserved_enabled[key] = cfg.get_value(en_sec, key)
		if cfg.has_section(pr_sec):
			for key: String in cfg.get_section_keys(pr_sec):
				if _preserve_stored_profile_key(key, live_keys, installed_ids):
					preserved_priority[key] = cfg.get_value(pr_sec, key)
		var preserved_ignored: Dictionary = {}
		if cfg.has_section(ig_sec):
			for key: String in cfg.get_section_keys(ig_sec):
				if _preserve_stored_profile_key(key, live_keys, installed_ids):
					preserved_ignored[key] = cfg.get_value(ig_sec, key)
		if cfg.has_section(en_sec):
			cfg.erase_section(en_sec)
		if cfg.has_section(pr_sec):
			cfg.erase_section(pr_sec)
		if cfg.has_section(ig_sec):
			cfg.erase_section(ig_sec)
		for entry in _ui_mod_entries:
			var pk: String = entry["profile_key"]
			cfg.set_value(en_sec, pk, entry["enabled"])
			cfg.set_value(pr_sec, pk, entry["priority"])
			# Sparse on purpose: a row of dep_ignore=false for every mod is
			# config noise; only overrides the user actually set are stored.
			if bool(entry.get("dependency_ignored", false)):
				cfg.set_value(ig_sec, pk, true)
		for k in preserved_enabled.keys():
			cfg.set_value(en_sec, k, preserved_enabled[k])
		for k in preserved_priority.keys():
			cfg.set_value(pr_sec, k, preserved_priority[k])
		for k in preserved_ignored.keys():
			cfg.set_value(ig_sec, k, preserved_ignored[k])

	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	if _boot_complete:
		_dirty_since_boot = true

# Persist the UI config with a single rolling backup. ConfigFile.save rewrites in
# place (truncate then write), so a crash mid-write can leave a half-file; we
# cannot do a Windows-safe atomic rename from GDScript, so instead we copy the
# current good file to <path>.bak BEFORE each write and _load_ui_config falls
# back to it if the live file fails to parse. The backup is best-effort -- a
# failed copy never blocks the save. Returns the ConfigFile.save error code.
func _persist_ui_cfg(cfg: ConfigFile) -> int:
	if FileAccess.file_exists(UI_CONFIG_PATH):
		DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")
	return cfg.save(UI_CONFIG_PATH)

func _profile_sec(name: String, suffix: String) -> String:
	return "profile." + name + suffix

# Every per-profile config section suffix. Use only when wiping or renaming a
# WHOLE profile -- the 2-element [".enabled", ".priority"] loops elsewhere
# scan just those two sections by design.
const PROFILE_SUBSECTIONS := [".enabled", ".priority", ".settings", ".dep_ignore"]

# Read a single value from mod_config.cfg. Returns `default` when the file is
# missing or unparseable, matching the early-return the hand-rolled accessors
# used before this was centralized.
func _get_ui_cfg_value(section: String, key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return default
	return cfg.get_value(section, key, default)

# Write a single value into mod_config.cfg via the backup-then-save path.
# Mirrors the load (result ignored) / set / _persist_ui_cfg dance the accessors
# shared; a missing file loads empty and is created on save.
func _set_ui_cfg_value(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	cfg.set_value(section, key, value)
	_persist_ui_cfg(cfg)

# Resolve a mod's CURRENT on-disk path from the live entry list by profile key.
# _ui_mod_entries is reassigned (collect_mod_metadata) whenever any surface
# updates a mod, which orphans a full_path captured when a row/button was built;
# downloading to that stale or renamed path is the repeatable "Update Failed".
# Returns `fallback` unchanged when the mod is not in the current scan.
func _live_full_path(profile_key: String, fallback: String) -> String:
	if profile_key == "":
		return fallback
	for cur in _ui_mod_entries:
		if str(cur.get("profile_key", "")) == profile_key:
			return str(cur.get("full_path", fallback))
	return fallback

# Same staleness hazard as _live_full_path, for whole entry dicts: an awaited
# confirm dialog can outlive a rescan (_reload_entries_for_active_profile
# reassigns _ui_mod_entries to FRESH dicts, e.g. when a Browse download lands
# mid-dialog), orphaning the dict captured at row build time -- a write to it
# then mutates state nothing reads and the next _save_ui_config drops the
# change. Re-resolve the live dict by profile key after any await; falls back
# to the captured dict when the mod left the scan (write becomes a no-op).
func _live_entry_for_profile_key(profile_key: String, fallback: Dictionary) -> Dictionary:
	if profile_key == "":
		return fallback
	for cur in _ui_mod_entries:
		if str(cur.get("profile_key", "")) == profile_key:
			return cur
	return fallback

# Re-scan mods from disk and re-apply the active profile's enable/priority state
# onto the fresh entry list. Called after any surface adds/removes/updates a mod
# file so _ui_mod_entries reflects on-disk reality before the Mods tab rebuilds.
# Callers keep their own (divergent) _rebuild_mods_tab guard after this returns.
func _reload_entries_for_active_profile() -> void:
	_ui_mod_entries = collect_mod_metadata()
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)

# Profile management: snapshot the current in-memory state to a new profile
# and switch to it. Caller is responsible for validating `name` (unique,
# non-empty, not "Vanilla"). Seeds the new profile's MCM slot from whatever
# is currently in user://MCM/ so the user's tweaks-so-far become the new
# profile's starting state instead of getting lost.
func _create_profile(name: String) -> void:
	_active_profile = name
	_save_ui_config()
	_snapshot_mcm_to(name)

# Delete the active profile's sections and switch to whichever profile remains
# first in alphabetical order. Caller must ensure at least one other profile
# exists before calling this. Also wipes the deleted profile's MCM snapshot.
func _delete_active_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	var target := _active_profile
	for suffix: String in PROFILE_SUBSECTIONS:
		var sec := _profile_sec(target, suffix)
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	_delete_mcm_snapshot(target)
	# Land on a real user profile only -- never a modpack-managed slot, which
	# would silently switch the user into pack-owned state and corrupt its MCM.
	var remaining := _list_user_profiles_in_cfg(cfg)
	if remaining.is_empty():
		_active_profile = "Default"
	else:
		_active_profile = remaining[0]
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	# Restore the new active profile's MCM if it has one. Skip for Vanilla
	# (no slot, no swap -- user://MCM/ left alone).
	if _active_profile != VANILLA_PROFILE and _has_mcm_snapshot(_active_profile):
		_restore_mcm_from(_active_profile)
	if _boot_complete:
		_dirty_since_boot = true

# Swap in-memory mod state to an existing profile. Snapshots the outgoing
# profile's MCM, restores the incoming profile's MCM (or seeds it from
# current contents on first switch). Vanilla incoming leaves user://MCM/
# alone since vanilla = no mods active and MCM is harmless without them.
# Same-profile early-return: switching to the currently active profile is
# a no-op. The naive flow (snapshot OUT, restore IN) would clobber any
# unsaved MCM edits because the snapshot dir lags user://MCM/ until the
# next outgoing-snapshot fires.
func _switch_profile(name: String) -> void:
	var old := _active_profile
	if old == name:
		return
	# Flush a pending debounced priority edit for the OUTGOING profile first.
	# A load-priority drag arms a 0.4s _schedule_priority_save timer; switching
	# inside that window would let _apply_profile_to_entries below overwrite the
	# in-memory priorities with the incoming profile's before the timer fires,
	# silently discarding the edit (and the late save would then write it under
	# the wrong profile). Persist now while _active_profile is still `old`.
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
	if old != VANILLA_PROFILE and old != name:
		_snapshot_mcm_to(old)
	_active_profile = name
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	if name != VANILLA_PROFILE:
		if _has_mcm_snapshot(name):
			_restore_mcm_from(name)
		else:
			# First-time switch to this profile: seed its slot from the
			# outgoing user://MCM/ contents so subsequent switches will
			# preserve per-profile MCM state.
			_snapshot_mcm_to(name)
	if _boot_complete:
		_dirty_since_boot = true

# Rename the active profile. We just save under the new name (which materializes
# the sections from current in-memory state, matching what the old profile
# held), then erase the old sections. Handles fresh-install placeholder cleanly
# since _save_ui_config doesn't care whether sections existed previously.
# Also renames the MCM snapshot dir so the per-profile MCM stays bound.
func _rename_profile(new_name: String) -> void:
	var old := _active_profile
	if old == new_name:
		return
	_active_profile = new_name
	_save_ui_config()
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	# Carry over per-profile UI settings (e.g. hide_disabled). The .enabled /
	# .priority sections were already materialized under new_name by the save
	# above; .settings has no in-memory backing, so we copy it explicitly.
	var old_settings := _profile_sec(old, ".settings")
	var new_settings := _profile_sec(new_name, ".settings")
	if cfg.has_section(old_settings):
		for key: String in cfg.get_section_keys(old_settings):
			cfg.set_value(new_settings, key, cfg.get_value(old_settings, key))
	# The save above wrote the new sections from in-memory entries plus the
	# preservation pass -- but that pass read the NEW name's sections, which
	# were empty, so stored keys with no live entry (dev-mode-hidden folder
	# mods, missing mods) still live only under the OLD name. Carry them
	# across before the old sections are erased below.
	var key_maps := _collect_live_profile_key_maps()
	var live_keys: Dictionary = key_maps["live"]
	var installed_ids: Dictionary = key_maps["ids"]
	for suffix: String in [".enabled", ".priority", ".dep_ignore"]:
		var old_sec := _profile_sec(old, suffix)
		if not cfg.has_section(old_sec):
			continue
		var new_sec := _profile_sec(new_name, suffix)
		for key: String in cfg.get_section_keys(old_sec):
			if cfg.has_section_key(new_sec, key):
				continue
			if _preserve_stored_profile_key(key, live_keys, installed_ids):
				cfg.set_value(new_sec, key, cfg.get_value(old_sec, key))
	for suffix: String in PROFILE_SUBSECTIONS:
		var sec := _profile_sec(old, suffix)
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	_persist_ui_cfg(cfg)
	_rename_mcm_snapshot(old, new_name)

# --- MCM snapshot mechanic ------------------------------------------------
#
# Each user-defined profile owns a private snapshot of user://MCM/, stored at
# user://.profile_snapshots/<profile>/MCM/. Switching profiles snapshots the
# outgoing profile's MCM, then restores (or seeds, on first switch) the
# incoming profile's MCM. Vanilla is special-cased: switching TO Vanilla
# leaves user://MCM/ untouched (vanilla = no mods active, so MCM is
# harmlessly orphaned), but the outgoing profile's MCM is still snapshotted
# so coming back to it later is lossless.

func _mcm_snapshot_dir(profile_name: String) -> String:
	return MCM_SNAPSHOT_BASE.path_join(profile_name).path_join("MCM")

func _has_mcm_snapshot(profile_name: String) -> bool:
	return DirAccess.dir_exists_absolute(_mcm_snapshot_dir(profile_name))

# Recursively copy src/ -> dst/, replacing dst/ if it already existed. Used
# both ways during a profile swap. Returns true when the source had at least
# one entry; false if the source dir didn't exist or was empty (caller may
# choose to skip the swap entirely in that case).
func _copy_dir_recursive(src: String, dst: String) -> bool:
	if not DirAccess.dir_exists_absolute(src):
		return false
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return false
	var any := false
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		# Skip hidden entries (".profile_snapshots" lives here too if MCM
		# accidentally got nested; defensive).
		if name.begins_with("."):
			continue
		var src_full := src.path_join(name)
		var dst_full := dst.path_join(name)
		if dir.current_is_dir():
			_copy_dir_recursive(src_full, dst_full)
			any = true
		else:
			var src_f := FileAccess.open(src_full, FileAccess.READ)
			if src_f == null:
				continue
			var bytes := src_f.get_buffer(src_f.get_length())
			src_f.close()
			var dst_f := FileAccess.open(dst_full, FileAccess.WRITE)
			if dst_f != null:
				dst_f.store_buffer(bytes)
				dst_f.close()
				any = true
	dir.list_dir_end()
	return any

# Recursively delete a directory and its contents. Used for snapshot removal
# during profile delete + before restore (so a stale entry from a prior
# config doesn't survive a swap).
func _remove_dir_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		var full := path.path_join(name)
		if dir.current_is_dir():
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _snapshot_mcm_to(profile_name: String) -> bool:
	var dst := _mcm_snapshot_dir(profile_name)
	# Wipe stale snapshot first so deleted-from-MCM files don't survive.
	_remove_dir_recursive(dst)
	return _copy_dir_recursive(MCM_SOURCE_DIR, dst)

func _restore_mcm_from(profile_name: String) -> bool:
	var src := _mcm_snapshot_dir(profile_name)
	# Replace user://MCM/ contents wholesale -- partial overlay would leak
	# leftover files from the previous profile.
	_remove_dir_recursive(MCM_SOURCE_DIR)
	return _copy_dir_recursive(src, MCM_SOURCE_DIR)

func _delete_mcm_snapshot(profile_name: String) -> void:
	# Also clean up the parent profile dir if it ends up empty after removing
	# MCM/, so .profile_snapshots/ doesn't accumulate empty husks.
	_remove_dir_recursive(_mcm_snapshot_dir(profile_name))
	var parent := MCM_SNAPSHOT_BASE.path_join(profile_name)
	if DirAccess.dir_exists_absolute(parent):
		DirAccess.remove_absolute(parent)

func _rename_mcm_snapshot(old_name: String, new_name: String) -> void:
	var old_parent := MCM_SNAPSHOT_BASE.path_join(old_name)
	var new_parent := MCM_SNAPSHOT_BASE.path_join(new_name)
	if not DirAccess.dir_exists_absolute(old_parent):
		return
	# Rename via DirAccess.rename works on directories too in Godot 4 when
	# the parent doesn't exist; create base dir defensively.
	DirAccess.make_dir_recursive_absolute(MCM_SNAPSHOT_BASE)
	var da := DirAccess.open(MCM_SNAPSHOT_BASE)
	if da != null:
		da.rename(old_name, new_name)

# --- Profile <-> zip serialization -----------------------------------------
#
# File-based save/load. The zip layout is "profile.json" at the root plus an
# optional "MCM/" tree mirroring user://MCM/. No new file extension is
# introduced; the modloader sniffs the contents on load. Format chosen so
# someone with a zip viewer can inspect what they're about to import.

# Per-mod MWS source URLs derived from the [updates] modworkshop= field +
# [mod] version= in each mod.txt. Embedded in saved profile.json under
# "sources" so an import can look up where to fetch missing mods AND pin
# the exact version the modpack author had installed (download_new_mod
# uses /files/{version} when version is set, else /files/primary). Forward-
# compatible v1 metroprofile field -- old parsers ignore it.
func _build_profile_sources() -> Dictionary:
	var sources: Dictionary = {}
	for entry in _ui_mod_entries:
		var cfg2: ConfigFile = entry.get("cfg")
		if cfg2 == null:
			continue
		if not cfg2.has_section_key("updates", "modworkshop"):
			continue
		var mws_id := int(str(cfg2.get_value("updates", "modworkshop", "0")))
		if mws_id <= 0:
			continue
		var pk: String = entry["profile_key"]
		var src_entry: Dictionary = {"modworkshop_id": mws_id}
		var version_str := str(cfg2.get_value("mod", "version", "")).strip_edges()
		if not version_str.is_empty():
			src_entry["version"] = version_str
		sources[pk] = src_entry
	return sources

# Read the persisted preferred author name from mod_config.cfg. Used to
# auto-fill the author field in the save-as-modpack dialog so users don't
# retype their handle every time. Empty string when not yet set.
func _load_preferred_author() -> String:
	return str(_get_ui_cfg_value("settings", "preferred_author", ""))

# Persist the preferred author for future modpack saves. Pass empty to
# clear -- the next save dialog will open with an empty field.
func _save_preferred_author(author: String) -> void:
	_set_ui_cfg_value("settings", "preferred_author", author)


# Mods that are enabled in the active profile but whose mod.txt doesn't
# carry [updates] modworkshop=N. These get written to profile.enabled in the
# exported modpack zip but NOT to profile.sources, so anyone applying the
# modpack on a clean install would see them as unresolved missing-mod stubs.
# Returned for the save-as-modpack pre-confirm so the user is warned before
# sharing a partial modpack. Each entry is {mod_name, profile_key}.
func _enabled_mods_without_modworkshop_id() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if not bool(entry.get("enabled", false)):
			continue
		var cfg2: ConfigFile = entry.get("cfg")
		var has_id := false
		if cfg2 != null and cfg2.has_section_key("updates", "modworkshop"):
			has_id = int(str(cfg2.get_value("updates", "modworkshop", "0"))) > 0
		if not has_id:
			out.append({
				"mod_name": str(entry.get("mod_name", "?")),
				"profile_key": str(entry.get("profile_key", "?")),
			})
	return out

# Save-as-modpack dialog. Shows the profile being saved, a description
# input, and (when applicable) a warning section listing enabled mods that
# lack [updates] modworkshop=N -- these get written without download info,
# so recipients have to source them manually. The OK button text + tint
# shift between "Save" and "Save Anyway" based on whether orphans exist.
# Whole body is wrapped in a single ScrollContainer with a fixed max
# height so the orphan list can't push the dialog past the launcher's
# bottom edge on a long list.
func _show_save_modpack_dialog(profile_to_save: String, orphans: Array, tabs: TabContainer) -> void:
	var has_orphans := not orphans.is_empty()
	var d := ConfirmationDialog.new()
	d.title = "Save partial modpack?" if has_orphans else "Save as modpack"
	# Sized so name + author + description all fit without the outer scroll
	# swallowing the description (the name field pushed content past the old
	# 220px). Still capped to sit inside the 640-tall launcher.
	d.min_size = Vector2i(600, 520 if has_orphans else 420)
	d.max_size = Vector2i(780, 600)

	var outer_scroll := ScrollContainer.new()
	outer_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(outer_scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", SP_M)
	outer_scroll.add_child(box)

	# Modpack name, decoupled from the profile name -- one profile can be saved
	# as differently-named packs. Defaults to the profile name so the old
	# behavior is one Enter away.
	var name_hdr := Label.new()
	name_hdr.text = "Modpack name:"
	name_hdr.add_theme_font_size_override("font_size", FS_BODY)
	name_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(name_hdr)

	var name_input := LineEdit.new()
	name_input.placeholder_text = "Name for this modpack"
	name_input.text = profile_to_save
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(name_input)

	var from_lbl := Label.new()
	from_lbl.text = "Mods taken from profile: " + profile_to_save
	from_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	from_lbl.add_theme_font_size_override("font_size", FS_META)
	box.add_child(from_lbl)

	var author_hdr := Label.new()
	author_hdr.text = "Author (optional):"
	author_hdr.add_theme_font_size_override("font_size", FS_BODY)
	author_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(author_hdr)

	var author_input := LineEdit.new()
	author_input.placeholder_text = "Your modder name or handle"
	author_input.text = _load_preferred_author()
	author_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(author_input)

	var desc_hdr := Label.new()
	desc_hdr.text = "Description (optional, shown in the Modpacks tab):"
	desc_hdr.add_theme_font_size_override("font_size", FS_BODY)
	desc_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(desc_hdr)

	var desc_input := TextEdit.new()
	desc_input.placeholder_text = "e.g. \"Tarkov-style loot economy + harder AI\""
	desc_input.custom_minimum_size = Vector2(520, 100)
	desc_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_input.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	desc_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(desc_input)

	if has_orphans:
		box.add_child(HSeparator.new())
		var warn_hdr := Label.new()
		warn_hdr.text = "%d enabled mod(s) lack [updates] modworkshop= in mod.txt:" % orphans.size()
		warn_hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn_hdr.add_theme_color_override("font_color", COL_AMBER)
		box.add_child(warn_hdr)

		# Footer above the list so the consequence is visible without
		# scrolling. The orphan list can grow naturally; outer_scroll handles
		# overflow if the list is long.
		var footer := Label.new()
		footer.text = "Without a ModWorkshop ID, these mods can't auto-download when someone applies the modpack -- recipients install them manually."
		footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		footer.add_theme_color_override("font_color", COL_TEXT_DIM)
		footer.add_theme_font_size_override("font_size", FS_BODY)
		box.add_child(footer)

		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", SP_XS)
		box.add_child(list)

		for o_v in orphans:
			if not (o_v is Dictionary):
				continue
			var o: Dictionary = o_v
			var lbl := Label.new()
			lbl.text = "  - %s  (%s)" % [str(o.get("mod_name", "?")), str(o.get("profile_key", "?"))]
			lbl.add_theme_font_size_override("font_size", FS_BODY)
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			lbl.tooltip_text = lbl.text.strip_edges()
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			list.add_child(lbl)

	d.ok_button_text = "Save anyway" if has_orphans else "Save modpack"
	_attach_ui_dialog(d)
	# "Save anyway" is a caution (this modpack cannot fully auto-download),
	# not an encouraged action -- keep the danger voice on the orphan path.
	if has_orphans:
		style_dialog_danger_button(d.get_ok_button())
	else:
		style_dialog_primary_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			var pack_name := name_input.text.strip_edges()
			var desc := desc_input.text
			var author := author_input.text.strip_edges()
			d.queue_free()
			if pack_name == "":
				pack_name = profile_to_save
			# Remember author across saves -- avoids forcing the user to
			# retype their handle every modpack. Cleared if they explicitly
			# blank it out.
			_save_preferred_author(author)
			var result := save_profile_as_modpack(profile_to_save, pack_name, desc, author)
			if not bool(result.get("ok", false)):
				_show_error_dialog("Could not save modpack", str(result.get("error", "unknown")))
				return
			_rebuild_modpacks_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()

# Walk the source tree and write every file into the zip under zip_prefix.
# Subdirectories are recursed; symlinks aren't followed (DirAccess never
# does in Godot 4). Hidden entries (starts with ".") are skipped.
func _add_dir_to_zip(packer: ZIPPacker, fs_path: String, zip_prefix: String) -> void:
	var dir := DirAccess.open(fs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var src_full := fs_path.path_join(name)
		var zip_path := zip_prefix + "/" + name
		if dir.current_is_dir():
			_add_dir_to_zip(packer, src_full, zip_path)
		else:
			var f := FileAccess.open(src_full, FileAccess.READ)
			if f == null:
				continue
			var bytes := f.get_buffer(f.get_length())
			f.close()
			if packer.start_file(zip_path) == OK:
				packer.write_file(bytes)
				packer.close_file()
	dir.list_dir_end()

# Build a profile zip at output_path. Includes profile.json (with sources) +
# MCM/ snapshot of user://MCM/. Returns {"ok": true} or {"error": "..."}.
# Cleans up partial output on any failure path so a corrupt half-zip
# doesn't survive to confuse the user (or block a retry).
func _export_profile_to_zip(profile_name: String, output_path: String, description: String = "", author: String = "", display_name: String = "") -> Dictionary:
	var json_str := _profile_to_json_string(profile_name, description, author, display_name)
	if json_str == "":
		return {"error": "Active profile has no data to save."}

	var packer := ZIPPacker.new()
	if packer.open(output_path) != OK:
		return {"error": "Cannot write to that location."}

	if packer.start_file("profile.json") != OK:
		packer.close()
		if FileAccess.file_exists(output_path):
			DirAccess.remove_absolute(output_path)
		return {"error": "Failed to write profile.json."}
	packer.write_file(json_str.to_utf8_buffer())
	packer.close_file()

	if DirAccess.dir_exists_absolute(MCM_SOURCE_DIR):
		_add_dir_to_zip(packer, MCM_SOURCE_DIR, "MCM")

	packer.close()
	return {"ok": true}

# UNUSED: no callers since the Modpacks tab replaced the share-profile flow.
# Kept pending the delete-or-rewire decision (see quality plan follow-up).
# Read a profile zip and apply it as a profile, including any MCM/ tree.
# Returns {"ok": true, "name": "..."} on success or {"error": "..."} on
# failure. The actual profile data is routed through the same
# _import_profile_from_parsed path the clipboard import uses; the only
# difference is the optional MCM payload that lands in the new profile's
# snapshot slot before the swap completes.
func _import_profile_from_zip(zip_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"error": "Cannot open file."}

	var files := reader.get_files()
	if not ("profile.json" in files):
		reader.close()
		return {"error": "Not a profile file (no profile.json inside)."}

	var profile_bytes := reader.read_file("profile.json")
	if profile_bytes.is_empty():
		reader.close()
		return {"error": "profile.json is empty."}

	var parsed_v: Variant = JSON.parse_string(profile_bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		reader.close()
		return {"error": "profile.json is not valid JSON."}
	var parsed: Dictionary = parsed_v
	if int(parsed.get("metroprofile", 0)) != 1:
		reader.close()
		return {"error": "Unsupported profile schema version."}
	if not (parsed.get("name") is String):
		reader.close()
		return {"error": "Profile missing name."}
	if not (parsed.get("enabled") is Dictionary):
		reader.close()
		return {"error": "Profile missing enabled data."}

	# Pull MCM tree out of the zip into a {relative_path: bytes} map. Reject
	# any entry whose path tries to escape the MCM/ subtree.
	var mcm_data: Dictionary = {}
	for f in files:
		if not f.begins_with("MCM/") or f.ends_with("/"):
			continue
		var rel: String = f.substr(4)
		if rel.contains("..") or rel.begins_with("/") or rel.is_empty():
			continue
		mcm_data[rel] = reader.read_file(f)
	reader.close()

	_import_profile_from_parsed(parsed, mcm_data)
	return {"ok": true, "name": str(parsed["name"])}

# Write an MCM data map (relative_path -> bytes) into a profile's snapshot
# slot. Replaces any existing snapshot. Used by the zip-import path before
# the profile swap restores from this slot. Always creates the destination
# directory even when mcm_data is empty -- otherwise _has_mcm_snapshot
# returns false for the modpack profile and _switch_profile falls through
# to seeding MCM from the previous profile's user://MCM/ contents (wrong,
# the modpack should override with its own EMPTY MCM).
func _write_mcm_snapshot_from_data(profile_name: String, mcm_data: Dictionary) -> void:
	var dst_base := _mcm_snapshot_dir(profile_name)
	_remove_dir_recursive(dst_base)
	DirAccess.make_dir_recursive_absolute(dst_base)
	if mcm_data.is_empty():
		return
	for rel_v in mcm_data.keys():
		var rel: String = str(rel_v)
		var bytes: PackedByteArray = mcm_data[rel]
		var dst := dst_base.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			continue
		f.store_buffer(bytes)
		f.close()


# UNUSED: no callers since the Modpacks tab replaced the share-profile flow.
# Kept pending the delete-or-rewire decision (see quality plan follow-up).
# Parse a shared payload back into the fields needed to reconstruct a profile.
# Returns either {"error": "..."} on failure or the parsed metroprofile dict
# on success. Validates the MTRPRF1 magic, checksum, and JSON shape.
func _parse_profile_payload(raw: String) -> Dictionary:
	var parts := raw.strip_edges().split(".")
	if parts.size() != 3:
		return {"error": "Invalid format -- expected MTRPRF1.<body>.<checksum>"}
	if parts[0] != "MTRPRF1":
		return {"error": "Unknown payload type \"" + parts[0] + "\""}
	var body: String = parts[1]
	var check: String = parts[2]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body.to_utf8_buffer())
	if check != ctx.finish().hex_encode().substr(0, 8):
		return {"error": "Payload is corrupted -- checksum mismatch"}
	var json_str := Marshalls.base64_to_utf8(body)
	if json_str == "":
		return {"error": "Payload body is not valid base64"}
	var obj = JSON.parse_string(json_str)
	if typeof(obj) != TYPE_DICTIONARY:
		return {"error": "Payload JSON is not an object"}
	var d: Dictionary = obj
	if int(d.get("metroprofile", 0)) != 1:
		return {"error": "Unsupported metroprofile schema version"}
	if not (d.get("name") is String):
		return {"error": "Payload missing name"}
	if not (d.get("enabled") is Dictionary):
		return {"error": "Payload missing enabled data"}
	return d

# Apply a parsed payload as a profile. Overwrites any existing profile with
# the same name (caller is expected to have confirmed), switches to it, and
# syncs in-memory entries. incoming_mcm_data is the optional MCM tree from a
# zip import (relative_path -> bytes); empty for clipboard-string imports.
func _import_profile_from_parsed(parsed: Dictionary, incoming_mcm_data: Dictionary = {}) -> void:
	var name := _sanitize_profile_name(parsed["name"])
	if name == "" or name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return
	# Snapshot the OUTGOING profile's MCM before any of the import logic
	# touches state. Capturing before reassign means coming back to the
	# previous profile later restores its MCM intact.
	var old_profile := _active_profile
	if old_profile != VANILLA_PROFILE and old_profile != name:
		_snapshot_mcm_to(old_profile)

	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	var en_sec := _profile_sec(name, ".enabled")
	var pr_sec := _profile_sec(name, ".priority")
	if cfg.has_section(en_sec):
		cfg.erase_section(en_sec)
	if cfg.has_section(pr_sec):
		cfg.erase_section(pr_sec)
	var enabled_dict: Dictionary = parsed["enabled"]
	for key in enabled_dict.keys():
		cfg.set_value(en_sec, str(key), bool(enabled_dict[key]))
	var priority_dict: Dictionary = parsed.get("priority", {})
	for key in priority_dict.keys():
		# Clamp defensively -- payload came from the clipboard and a crafted
		# or corrupted entry could set an out-of-range priority that breaks
		# load-order invariants (UI spinbox is [-999, 999]; anything outside
		# that range couldn't have been authored through the UI anyway).
		var pv := int(priority_dict[key])
		cfg.set_value(pr_sec, str(key), clampi(pv, PRIORITY_MIN, PRIORITY_MAX))
	# Materialize dep_ignore ("Load anyway") overrides from the payload. Sparse
	# (true-only), optional field -- a payload from an older exporter simply has
	# none, so the imported profile starts with no overrides rather than failing.
	var ig_sec := _profile_sec(name, ".dep_ignore")
	if cfg.has_section(ig_sec):
		cfg.erase_section(ig_sec)
	var dep_ignore_dict: Dictionary = parsed.get("dep_ignore", {})
	for key in dep_ignore_dict.keys():
		if bool(dep_ignore_dict[key]):
			cfg.set_value(ig_sec, str(key), true)
	# Explicit manifest: any local mod NOT in the imported payload is written
	# as disabled. Without this, _apply_profile_to_entries falls through to
	# its default-true branch for unknown keys (ergonomic for "newly-dropped
	# mod in existing profile") and imports would silently enable every
	# local mod the exporter didn't have -- including dev folders, which is
	# the opposite of what a shared profile means. Handles id-prefix matches
	# (foo@2.0 local resolving to foo@1.0 in payload) so version bumps
	# inherit the payload's state rather than getting disabled.
	var payload_mod_ids: Dictionary = {}
	for key in enabled_dict.keys():
		var key_str := str(key)
		var at := key_str.find("@")
		if at > 0:
			payload_mod_ids[key_str.substr(0, at)] = true
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		if enabled_dict.has(pk):
			continue
		if not pk.begins_with("zip:") and payload_mod_ids.has(entry["mod_id"]):
			continue
		cfg.set_value(en_sec, pk, false)
	_active_profile = name
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	_apply_profile_to_entries(cfg, _active_profile)

	# Place INCOMING MCM into this profile's snapshot slot. Two cases:
	#   1. Zip import with MCM/ tree -- write the bytes from the zip.
	#   2. Clipboard import (no MCM data) -- if no slot exists yet, seed
	#      from current user://MCM/ so the new profile starts at "whatever
	#      MCM was active when imported" rather than empty.
	if not incoming_mcm_data.is_empty():
		_write_mcm_snapshot_from_data(name, incoming_mcm_data)
	elif not _has_mcm_snapshot(name):
		_snapshot_mcm_to(name)
	# Now restore: copy the slot we just established (or already had) into
	# user://MCM/ so the live state matches the new profile.
	if _has_mcm_snapshot(name):
		_restore_mcm_from(name)

	if _boot_complete:
		_dirty_since_boot = true

# Metroprofile v1 schema is LOCKED at 3.0.1. Full spec (wrapper format, JSON
# shape, profile key format, forward-compat rules, round-trip guarantees) is
# in the wiki: docs/wiki/Profile-Format.md. Changes to the export/import
# shape require bumping the schema version so old parsers reject cleanly.

# UNUSED: no callers since the Modpacks tab replaced the share-profile flow.
# Kept pending the delete-or-rewire decision (see quality plan follow-up).
# Build the shareable opaque payload for the given profile. Shape:
#     MTRPRF1.<base64-encoded JSON>.<first 8 hex chars of SHA-256(body)>
# The magic prefix identifies the schema version, the body is the profile's
# JSON, and the suffix lets a future import path detect copy/paste corruption
# without full cryptographic verification. Empty string if the profile has
# nothing to export.
func _profile_to_payload(profile_name: String) -> String:
	var json := _profile_to_json_string(profile_name)
	if json == "":
		return ""
	var body := Marshalls.utf8_to_base64(json)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body.to_utf8_buffer())
	var check := ctx.finish().hex_encode().substr(0, 8)
	return "MTRPRF1." + body + "." + check

# Serialize the named profile to a JSON string. Used as the inner layer of
# _profile_to_payload; exposed separately in case we need it for debugging
# or tests. Empty string if the profile has no stored sections.
# CONTRACT: this is the ONE writer of the metroprofile v1 payload, but the
# payload is parsed independently in several places. Profile-STATE fields
# (the enabled/priority/dep_ignore family, materialized into config
# sections) must be read by BOTH consumers -- _import_profile_from_parsed
# (share/zip import, below) and _materialize_modpack_profile (modpacks.gd,
# modpack apply) -- or the field silently drops on one path. Metadata
# fields may instead need their own readers ("sources", for example, is
# read only by _missing_mod_sources_combined, _get_missing_mods_for_modpack
# and the modpack detail dialog, not by either consumer above), and
# _validate_modpack (modpacks.gd) pre-checks schema/name/enabled. Keep new
# fields optional (docs/wiki/Profile-Format.md forward-compat rules) and
# document them there.
func _profile_to_json_string(profile_name: String, description: String = "", author: String = "", display_name: String = "") -> String:
	# display_name is the modpack's own name (the payload "name" field). When
	# empty it falls back to the profile name -- so the share-string path and any
	# caller that doesn't name the pack keep the old behavior. profile_name still
	# selects which profile's config sections we read.
	var src := ConfigFile.new()
	if src.load(UI_CONFIG_PATH) != OK:
		return ""
	var en_sec := _profile_sec(profile_name, ".enabled")
	var pr_sec := _profile_sec(profile_name, ".priority")
	if not src.has_section(en_sec):
		return ""
	# A modpack is the set of mods you actually run, so only ENABLED mods go in.
	# Disabled-but-installed mods are excluded, so applying the pack never
	# downloads or tracks mods the author wasn't using. (Previously every key in
	# the profile was serialized, including key=false disabled entries.)
	var enabled: Dictionary = {}
	for key: String in src.get_section_keys(en_sec):
		if bool(src.get_value(en_sec, key)):
			enabled[key] = true
	# Priority + dep_ignore + sources below are all scoped to the enabled set
	# via enabled.has(key), so nothing about a disabled mod leaks into the pack.
	var priority: Dictionary = {}
	if src.has_section(pr_sec):
		for key: String in src.get_section_keys(pr_sec):
			if enabled.has(key):
				priority[key] = int(str(src.get_value(pr_sec, key)))
	# dep_ignore ("Load anyway") overrides, sparse -- only the true entries are
	# stored. Optional v1 field; old parsers ignore it (forward-compat rule), so
	# round-tripping through an older import just drops the overrides, never
	# rejects. Without this the share string silently loses a deliberate
	# Load-anyway and the mod re-renders blocked on the other end.
	var dep_ignore: Dictionary = {}
	var ig_sec := _profile_sec(profile_name, ".dep_ignore")
	if src.has_section(ig_sec):
		for key: String in src.get_section_keys(ig_sec):
			if bool(src.get_value(ig_sec, key)) and enabled.has(key):
				dep_ignore[key] = true
	var payload := {
		"metroprofile":      1,
		"name":              display_name.strip_edges() if display_name.strip_edges() != "" else profile_name,
		"modloader_version": MODLOADER_VERSION,
		"exported_at":       Time.get_datetime_string_from_system(),
		"enabled":           enabled,
		"priority":          priority,
	}
	var desc_clean := description.strip_edges()
	if not desc_clean.is_empty():
		payload["description"] = desc_clean
	var author_clean := author.strip_edges()
	if not author_clean.is_empty():
		payload["author"] = author_clean
	# Auto-derived MWS source URLs for any installed mod with [updates]
	# modworkshop= in mod.txt. Optional v1 metroprofile field; old parsers
	# ignore it per the forward-compat rule. Lets a future import fetch
	# missing mods automatically.
	# Only enabled mods' sources -- a pack must not ship download info for mods
	# it doesn't include (else applying it fetches mods the author had disabled).
	# `enabled` keys come from the on-disk config section; source keys are live
	# profile_keys. They can disagree on version (stale disk key after an
	# external mod swap, resynced only on the next _save_ui_config) or on id
	# casing/format (see _get_missing_mods_for_modpack). Match on a lowercased
	# id-prefix too, so an enabled mod's source is never silently dropped.
	var sources := _build_profile_sources()
	var enabled_ids: Dictionary = {}
	for k: String in enabled:
		var at := k.find("@")
		if at > 0:
			enabled_ids[k.substr(0, at).to_lower()] = true
	var enabled_sources: Dictionary = {}
	for src_key: String in sources:
		var s_at := src_key.find("@")
		if enabled.has(src_key) \
				or (s_at > 0 and enabled_ids.has(src_key.substr(0, s_at).to_lower())):
			enabled_sources[src_key] = sources[src_key]
	if not enabled_sources.is_empty():
		payload["sources"] = enabled_sources
	if not dep_ignore.is_empty():
		payload["dep_ignore"] = dep_ignore
	return JSON.stringify(payload, "  ")

# Profile keys that the active profile references but whose mod isn't in
# _ui_mod_entries (archives deleted, or renamed ZIPs for mods without a
# mod.txt id). Keys whose id prefix matches an installed mod with a different
# version are treated as present -- _apply_profile_to_entries resolves those
# via id-prefix fallback and flags the mismatch. Rendered as red stub rows.
func _missing_mods_in_active_profile() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	var en_sec := _profile_sec(_active_profile, ".enabled")
	if not cfg.has_section(en_sec):
		return []
	var present: Dictionary = {}
	var ids_installed: Dictionary = {}
	for entry in _ui_mod_entries:
		present[entry["profile_key"]] = true
		if not entry["profile_key"].begins_with("zip:"):
			ids_installed[entry["mod_id"]] = true
	# Folder mods filtered out by dev-mode-off are on disk but hidden from
	# _ui_mod_entries; treat them as present so the user doesn't see every
	# dev mod flagged as deleted when they toggle the setting.
	for key in _hidden_folder_profile_keys.keys():
		present[key] = true
	for mid in _hidden_folder_ids.keys():
		ids_installed[mid] = true
	var missing: Array[String] = []
	for key: String in cfg.get_section_keys(en_sec):
		if present.has(key):
			continue
		var at := key.find("@")
		if at > 0 and ids_installed.has(key.substr(0, at)):
			continue
		missing.append(key)
	missing.sort()
	return missing

# Combined source map for missing-mod stubs. Layered:
#   1. Persisted [mod_sources] cache (every mod we've ever scanned with
#      [updates] modworkshop=) -- works for any profile, even after the
#      mod file is deleted.
#   2. Active modpack's profile.json sources -- overlays the cache, since
#      the modpack zip is canonical for the currently-active modpack.
# Returns Dictionary{profile_key -> {modworkshop_id, version}}.
func _missing_mod_sources_combined() -> Dictionary:
	var out: Dictionary = _get_persisted_mod_sources()
	var active := get_active_modpack()
	if active.is_empty():
		return out
	for entry in _modpack_entries:
		if str(entry.get("sanitized_name", "")) != active:
			continue
		var file_path: String = str(entry.get("file_path", ""))
		if file_path.is_empty() or not FileAccess.file_exists(file_path):
			return out
		var reader := ZIPReader.new()
		if reader.open(file_path) != OK:
			return out
		var bytes := reader.read_file("profile.json")
		reader.close()
		if bytes.is_empty():
			return out
		var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not (parsed_v is Dictionary):
			return out
		var sources_v: Variant = (parsed_v as Dictionary).get("sources", {})
		if sources_v is Dictionary:
			for k in (sources_v as Dictionary).keys():
				out[str(k)] = (sources_v as Dictionary)[k]
		return out
	return out

# Strip an orphaned stored key from the active profile's sections. Called
# from the "Remove" button on a missing-mod stub row.
func _remove_missing_entry_from_profile(stored_key: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority", ".dep_ignore"]:
		var sec := _profile_sec(_active_profile, suffix)
		if cfg.has_section(sec) and cfg.has_section_key(sec, stored_key):
			cfg.erase_section_key(sec, stored_key)
	_persist_ui_cfg(cfg)

# Bulk variant of _remove_missing_entry_from_profile: strips every orphaned
# key in one config write. Called by the "Remove all" button on the
# missing-from-this-profile header so users with a long migration trail of
# uninstalled mods don't have to click Remove dozens of times.
func _remove_all_missing_entries_from_profile() -> void:
	var missing := _missing_mods_in_active_profile()
	if missing.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority", ".dep_ignore"]:
		var sec := _profile_sec(_active_profile, suffix)
		if not cfg.has_section(sec):
			continue
		for key: String in missing:
			if cfg.has_section_key(sec, key):
				cfg.erase_section_key(sec, key)
	_persist_ui_cfg(cfg)

# Keep only letters, digits, space, underscore, hyphen. Strip edges. Reject
# dots (they would collide with the `profile.<name>.enabled` section path).
func _sanitize_profile_name(raw: String) -> String:
	var trimmed := raw.strip_edges()
	var out := ""
	for i in trimmed.length():
		var c := trimmed.substr(i, 1)
		var u := trimmed.unicode_at(i)
		var is_alpha := (u >= 65 and u <= 90) or (u >= 97 and u <= 122)
		var is_digit := u >= 48 and u <= 57
		if is_alpha or is_digit or c == " " or c == "-" or c == "_":
			out += c
	return out

# Launch Vanilla: one-shot vanilla boot. Writes DISABLED_ONCE_FILE to the
# game directory so the next launch skips the modloader entirely (no UI, no
# mod loading) and lets the game start clean. lifecycle.gd clears the
# sentinel during _ready so subsequent launches resume normal modded flow.
# Active profile is untouched -- the user comes back to their last loadout
# next time they boot.
#
# Important: we do NOT call _save_ui_config here. That would rewrite the
# currently-active profile's sections from the in-memory _ui_mod_entries
# state.

func _launch_vanilla_once(win: Window) -> void:
	_log_info("[LaunchVanilla] User triggered one-shot vanilla launch")
	var exe_dir := OS.get_executable_path().get_base_dir()
	var sentinel := exe_dir.path_join(DISABLED_ONCE_FILE)
	var f := FileAccess.open(sentinel, FileAccess.WRITE)
	if f != null:
		f.store_string("Launch Vanilla -- this file is auto-cleared on next launch")
		f.close()
	else:
		_log_warning("[LaunchVanilla] Could not write sentinel at %s -- aborting" % sentinel)
		return
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI Launch Vanilla button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1, not a Pass 2
	# that would expect pass state we just deleted.
	_modloader_restart(true)

# Tear down and rebuild the Mods tab in place. Called whenever profile state
# changes (switch, create, delete) or Developer Mode toggles, so rows and the
# profile bar reflect fresh _ui_mod_entries + _active_profile state.
# Preserves the user's current tab so a Browse-row enable toggle doesn't
# yank them onto the Mods tab mid-flow.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_MODS)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	# Carry the list scroll position across the teardown -- a rebuild from a
	# checkbox halfway down a long list must not snap the view to the top.
	var saved_scroll := 0
	if is_instance_valid(_ui_mods_scroll):
		saved_scroll = _ui_mods_scroll.scroll_vertical
	var idx := old.get_index()
	# Capture which tab the user was on by NAME, since remove_child below
	# shifts sibling indices and tabs.current_tab can drift in the meantime.
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = UI_TAB_MODS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	# Restore by name. If the previous tab was Mods itself, we land back on
	# the rebuilt one. If it was Browse/Modpacks/Updates, the user stays
	# where they were.
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	# Profile switches / dev-mode toggles change enable state without
	# hitting the per-row checkbox handler.
	refresh_launch_button_label()
	if saved_scroll > 0:
		_restore_mods_scroll(saved_scroll)

# Restore one frame later: the fresh rows haven't been laid out yet when
# _rebuild_mods_tab returns, so setting scroll_vertical immediately clamps
# against a zero-height list and lands back at the top.
func _restore_mods_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_mods_scroll):
		_ui_mods_scroll.scroll_vertical = saved_scroll

# Swap the Updates tab for a freshly built one. build_updates_tab snapshots
# _ui_mod_entries at build time and never updates in place, so a mod updated via
# the Mods-tab badge (renamed archive -> new version-embedding profile_key) or
# installed mid-session (Browse Get / modpack apply) leaves this tab showing
# stale rows: a wrong "update available" flag whose Download then targets a
# vanished file. Rebuilding on tab-show re-reads live entries. Mirrors
# _rebuild_mods_tab's tab-swap and preserves the user's current tab by name.
func _rebuild_updates_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_UPDATES)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	var idx := old.get_index()
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_updates_tab()
	new_tab.name = UI_TAB_UPDATES
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false

# Modpack-apply failure summary with per-mod rows. Each failure shows the
# profile_key + reason + an "Open MWS page" button (when an mws_id is
# known, which is every case except sourceless legacy modpacks). The
# bottom bar has a "Retry failed" button that re-runs only the failed
# downloads, plus the auto-OK Close. Replaces the simple text dialog
# that handled this before -- a flat string can't fit 30+ lines and
# offers no recovery action.
func _show_modpack_failure_dialog(downloaded: int, failures: Array, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpack applied with issues"
	d.ok_button_text = "Close"
	d.min_size = Vector2i(540, 420)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	d.add_child(box)

	var hdr := Label.new()
	hdr.text = "Downloaded %d mod(s), %d failed." % [downloaded, failures.size()]
	box.add_child(hdr)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 280)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)

	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", SP_S)
	list_wrap.add_child(list)

	for f_v in failures:
		if not (f_v is Dictionary):
			continue
		var f: Dictionary = f_v
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", SP_M)
		list.add_child(row)

		var info_col := VBoxContainer.new()
		info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info_col)

		var name_lbl := Label.new()
		name_lbl.text = str(f.get("profile_key", "?"))
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.tooltip_text = name_lbl.text
		name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		info_col.add_child(name_lbl)

		var err_lbl := Label.new()
		err_lbl.text = str(f.get("error", "unknown"))
		err_lbl.add_theme_font_size_override("font_size", FS_BODY)
		err_lbl.add_theme_color_override("font_color", COL_ERR)
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(err_lbl)

		var mws_id: int = int(f.get("mws_id", 0))
		if mws_id > 0:
			var open_btn := Button.new()
			open_btn.text = "Open ModWorkshop page"
			open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(open_btn)
			open_btn.pressed.connect(func():
				OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(mws_id))
			)

	# Footer: Retry button via add_button so it sits in the dialog's native
	# button bar alongside the Close button. Disabled if there's no failure
	# with a known mws_id (nothing to retry).
	var retry_btn: Button = null
	var any_retryable := false
	for f_v in failures:
		if f_v is Dictionary and int((f_v as Dictionary).get("mws_id", 0)) > 0:
			any_retryable = true
			break
	if any_retryable:
		retry_btn = d.add_button("Retry failed", false, "")
		style_primary_button(retry_btn)
		var captured_failures := failures
		retry_btn.pressed.connect(func():
			d.queue_free()
			_run_modpack_retry(captured_failures, tabs)
		)

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Run a retry pass on previously-failed modpack downloads. Shows a progress
# dialog during, then re-shows the failure dialog if anything still failed
# (with one fewer entry typically -- successfully retried mods drop off).
func _run_modpack_retry(failures: Array, tabs: TabContainer) -> void:
	var pd := AcceptDialog.new()
	pd.title = "Retrying failed downloads"
	pd.min_size = Vector2i(440, 120)
	# Build content BEFORE _attach so the helper reparents it into the
	# root VBox with the injected title -- adding after _attach would
	# leave the status label outside the layout.
	var status_lbl := Label.new()
	status_lbl.text = "Preparing..."
	status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_lbl.custom_minimum_size.x = 400
	pd.add_child(status_lbl)
	_attach_ui_dialog(pd)
	# Swallow ESC while downloads run, same as the apply progress dialog:
	# a hidden (not cancelled) exclusive dialog would lift the input block
	# and let the user Launch / apply another modpack mid-retry.
	pd.dialog_close_on_escape = false
	var pd_ok := pd.get_ok_button()
	if pd_ok != null:
		pd_ok.visible = false
	pd.popup_centered()

	var progress_cb := func(p: Dictionary):
		if not is_instance_valid(status_lbl):
			return
		var cur := int(p.get("current", 0))
		var tot := int(p.get("total", 0))
		var nm := str(p.get("mod_name", ""))
		if nm != "":
			status_lbl.text = "Retrying %d of %d:\n%s" % [cur, tot, nm]
		else:
			status_lbl.text = "Retrying..."

	var result := await retry_failed_downloads(failures, progress_cb)

	if is_instance_valid(pd):
		pd.queue_free()

	# Refresh Mods tab so newly-downloaded mods aren't stuck in the
	# missing-mod stub list.
	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	var still_failed: Array = result.get("failures", [])
	var dl: int = int(result.get("downloaded", 0))
	if still_failed.is_empty():
		# Everything recovered -- short success dialog instead of the
		# error-styled failure one.
		var ok_d := AcceptDialog.new()
		ok_d.title = "Retry complete"
		ok_d.dialog_text = "Downloaded %d mod(s) on retry." % dl
		ok_d.ok_button_text = "Close"
		_attach_ui_dialog(ok_d)
		_wire_accept_dismiss(ok_d)
		ok_d.popup_centered()
	else:
		_show_modpack_failure_dialog(dl, still_failed, tabs)


# Build and show a borderless accept dialog with a single dismiss button.
# Backs _show_error_dialog / _show_info_toast, which differ only in title,
# button text, and minimum width.
func _show_accept_dialog(title: String, message: String, ok_text := "OK", min_w := 360) -> void:
	var d := AcceptDialog.new()
	d.title = title
	d.dialog_text = message
	d.ok_button_text = ok_text
	d.min_size = Vector2i(min_w, 0)
	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Free an AcceptDialog on both OK (confirmed) and the window close button
# (close_requested). The AcceptDialog analog of _connect_dialog_exits; the
# connect order matches the hand-rolled dismiss sites it replaces.
func _wire_accept_dismiss(d: AcceptDialog) -> void:
	d.confirmed.connect(func(): d.queue_free())
	d.close_requested.connect(func(): d.queue_free())

# Show a simple error dialog. Replaces ad-hoc push_warning calls in user-
# facing flows so failures actually surface in the UI instead of just the
# log. Used by modpack apply/unload, profile import, etc.
func _show_error_dialog(title: String, message: String) -> void:
	_show_accept_dialog(title, message, "Close", 400)


# Neutral one-line info dialog. Same shape as _show_error_dialog but framed
# without the "error" connotation -- used for benign confirmations like
# "all mods up to date" after a check.
func _show_info_toast(message: String) -> void:
	_show_accept_dialog("Mod Loader", message, "Close")


# All launcher dialogs flow through this. Renders as a borderless dark
# card: theme applied, OS chrome dropped, title + dialog_text consumed
# into a labeled header, and every caller-added child reparented into a
# single root VBox so layout flows unambiguously regardless of size_flags
# quirks in AcceptDialog's content area.
func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	# Theme before add_child so the first draw is styled (set-after-add
	# sometimes lands the first frame with default chrome).
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme
	d.transparent = false
	d.transparent_bg = false
	d.always_on_top = true
	d.transient = true
	d.exclusive = true
	d.borderless = true
	d.add_theme_stylebox_override("panel", _make_dialog_panel_stylebox())

	# Consume title + dialog_text into a single header VBox. AcceptDialog's
	# internal dialog_text label is absolutely positioned -- leaving it
	# active and adding sibling Labels at "child index 0" makes them
	# render at the same y. So we clear both and re-emit them in a
	# regular VBox where flow layout is honored.
	var title_text := str(d.title)
	var body_text := ""
	if d is AcceptDialog:
		body_text = str((d as AcceptDialog).dialog_text)
		(d as AcceptDialog).dialog_text = ""
	d.title = ""

	if title_text != "" or body_text != "":
		var existing := d.get_children()
		for c in existing:
			d.remove_child(c)
		var root := VBoxContainer.new()
		root.add_theme_constant_override("separation", SP_M)
		root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		root.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if title_text != "":
			var title_lbl := Label.new()
			title_lbl.text = title_text
			title_lbl.add_theme_font_size_override("font_size", FS_HEAD)
			title_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
			title_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			root.add_child(title_lbl)
		if body_text != "":
			var body_lbl := Label.new()
			body_lbl.text = body_text
			body_lbl.add_theme_font_size_override("font_size", FS_EMPH)
			body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			body_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			body_lbl.custom_minimum_size.x = 400
			root.add_child(body_lbl)
		for c in existing:
			root.add_child(c)
		d.add_child(root)

	parent.add_child(d)


# Set all four border widths of a freshly-built StyleBoxFlat to `w`. Covers the
# uniform 1px-border idiom repeated across the theme styleboxes; non-uniform
# borders (e.g. the TabContainer's bottom=0) stay inline.
func _sb_border(s: StyleBoxFlat, w := 1) -> void:
	s.border_width_top = w
	s.border_width_bottom = w
	s.border_width_left = w
	s.border_width_right = w

# Dialog panel background. Centralized so _attach_ui_dialog and any future
# place that needs a matching look (e.g. inline cards) use the same style.
func _make_dialog_panel_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = COL_SURFACE
	s.border_color = COL_BORDER
	_sb_border(s)
	s.content_margin_left = SP_XL
	s.content_margin_right = SP_XL
	s.content_margin_top = SP_L
	s.content_margin_bottom = SP_L
	return s

# Connect the same handler to both signals and a shared free-and-forget exit
# path. ConfirmationDialog fires `canceled` on Cancel and `close_requested` on
# ESC / window-X -- callers want both to behave the same.
func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

# Make a Control swap the bottom-bar hint label to `text` while hovered and
# restore the original on exit. Stand-in for Godot tooltips, which are popups
# that render behind our always_on_top launcher window.
func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	# mouse_entered/exited never fire on a MOUSE_FILTER_IGNORE control (Labels
	# default to IGNORE), so guarantee our own precondition rather than relying
	# on every caller to have set PASS.
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	var default_text := _ui_hint_label.text
	c.mouse_entered.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = text
	)
	c.mouse_exited.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = default_text
	)

# Modal opens from the red "suspicious code" tag on a mod row. Lists the
# specific patterns the scanner matched. Dismiss-only -- the actual
# launch-time gate lives in _confirm_red_launch.
func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	d.title = "Suspicious code in " + mod_name
	d.ok_button_text = "Close"
	d.min_size = Vector2(580, 420)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 380)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", SP_L)
	scroll.add_child(body)

	var intro := Label.new()
	intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
			+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
			+ "If you don't trust this mod, do not enable it."
	intro.add_theme_color_override("font_color", COL_ERR)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", FS_BODY)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", SP_S)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.add_theme_color_override("font_color", COL_ERR)
		rule_lbl.add_theme_font_size_override("font_size", FS_HEAD)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		loc_lbl.add_theme_font_size_override("font_size", FS_META)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.add_theme_color_override("font_color", COL_OK)
			pre_lbl.add_theme_font_size_override("font_size", FS_BODY)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			pre_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			pre_lbl.tooltip_text = preview
			pre_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Mod entries that are currently enabled AND scored RED by the scanner.
# Used to gate Launch when the user has any of these toggled on.
func _enabled_red_mods() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and int(entry.get("risk_level", 0)) == 2:
			out.append(entry)
	return out

# Launch-time confirmation when one or more enabled mods are scored RED.
# Returns true if the user confirms launch, false if they go back. Loading
# is never silently bypassed; the user must explicitly acknowledge.
#
# Uses plain dialog_text so Godot auto-sizes the window to its content.
# A custom VBoxContainer body would let the window grow off-screen.
func _confirm_red_launch(red_mods: Array) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Suspicious mods enabled"
	d.ok_button_text = "Launch anyway"
	d.cancel_button_text = "Go back"
	d.dialog_autowrap = true
	# Width floor so the autowrap doesn't squeeze the text into a narrow
	# column; height left to grow with the mod list.
	d.min_size = Vector2(560, 120)

	var lines := PackedStringArray()
	lines.append("The scanner found patterns in the following mod(s) that are commonly used by malware. If you don't trust them, go back and disable them before launching.")
	lines.append("")
	for entry: Dictionary in red_mods:
		lines.append("    " + str(entry.get("mod_name", "?")))
	d.dialog_text = "\n".join(lines)

	_attach_ui_dialog(d)
	# Force dialog above the always_on_top launcher. Without this, clicking
	# the launcher's X (which routes to the same Launch handler) sometimes
	# parents-off the dialog behind the launcher and leaves input frozen.
	d.exclusive = true
	d.always_on_top = true
	# Red text on the destructive button so "Launch anyway" reads as the
	# risky option. Dialog OK buttons stay on modulate -- a theme
	# font-color override didn't take effect here when tried (see
	# style_dialog_danger_button for the shared rationale).
	style_dialog_danger_button(d.get_ok_button())

	return await _await_dialog_choice(d)

# Show an already-attached ConfirmationDialog and await the user's choice.
# Single-result polling: lambdas mark done + capture the choice; an Array is
# used because GDScript closures hold object references. Frees the dialog
# and returns true on confirm, false on cancel/close.
func _await_dialog_choice(d: ConfirmationDialog) -> bool:
	var state := [false, false]  # [done, confirmed]
	d.confirmed.connect(func():
		state[0] = true
		state[1] = true)
	d.canceled.connect(func(): state[0] = true)
	d.close_requested.connect(func(): state[0] = true)
	d.popup_centered()
	d.grab_focus()
	while not state[0]:
		await get_tree().process_frame
	d.queue_free()
	return state[1]

# Yes/no confirm shown when the user disables a mod that registers game content.
# Returns true to proceed with the disable, false to keep it enabled. Modeled on
# _confirm_red_launch's flow; the shared await-poll lives in _await_dialog_choice.
# `count` > 1 switches to batch wording for bulk actions (the None button);
# `mod_name` then names one affected mod as an example.
func _confirm_disable_content_mod(mod_name: String, count: int = 1) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Disable content mod?" if count <= 1 else "Disable content mods?"
	d.ok_button_text = "Disable anyway"
	d.cancel_button_text = "Keep enabled"
	d.dialog_autowrap = true
	d.min_size = Vector2(520, 120)
	if count > 1:
		d.dialog_text = "%d of these mods (including \"%s\") add game content (items, recipes, and similar). Disabling them can stop an existing save that uses their content from loading until you re-enable them. Your saves are not deleted -- re-enabling the mods restores them.\n\nDisable anyway?" % [count, mod_name]
	else:
		d.dialog_text = "\"%s\" adds game content (items, recipes, and similar). Disabling or removing it can stop an existing save that uses its content from loading until you re-enable it. Your save is not deleted -- re-enabling the mod restores it.\n\nDisable anyway?" % mod_name
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	# Red "Disable anyway" button: the spec assigns this confirm the DANGER
	# voice (same as Delete/Unload). Uses the modulate path like the other
	# dialog OK buttons (see style_dialog_danger_button's rationale).
	style_dialog_danger_button(d.get_ok_button())
	return await _await_dialog_choice(d)

# Validate a candidate profile name against the rules shared by the New and
# Rename dialogs. Returns the user-facing error string, or "" when the name is
# acceptable. `current` lets Rename treat renaming to its own name as valid here
# (the caller turns that into a silent no-op rather than a commit).
func _validate_profile_name(name: String, existing: Array, current := "") -> String:
	if name == "":
		return "Name cannot be empty or all invalid characters."
	if name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return "That name is reserved."
	if name == current:
		return ""
	# Case-insensitive, matching the vanilla check above: MCM snapshot dirs
	# are keyed by profile name on a case-insensitive filesystem (Windows),
	# so two profiles differing only by case would share one snapshot dir
	# and deleting one would wipe the other's MCM state.
	var lowered := name.to_lower()
	for other_v in existing:
		# Skip the profile being renamed: a case-only rename (Main -> MAIN)
		# is safe -- it keeps ONE profile and one snapshot dir, and
		# DirAccess.rename handles a case-only rename on NTFS -- so it must
		# not be rejected as a duplicate of itself. New Profile passes
		# current == "", so collision blocking there is unchanged.
		if current != "" and str(other_v) == current:
			continue
		if str(other_v).to_lower() == lowered:
			return "Profile \"" + str(other_v) + "\" already exists."
	return ""

# New Profile dialog: prompt for a name + initial state, validate, write the
# chosen state into the new profile, switch to it. Cancel leaves everything
# unchanged. Initial state radio defaults to Empty -- "fresh profile = nothing
# on" matches the mental model wyldbylli flagged on MWS (creating a profile
# previously cloned the current selection silently, which surprised users
# expecting a blank slate).
func _show_new_profile_dialog(tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "New profile"
	d.ok_button_text = "Create profile"
	d.dialog_hide_on_ok = false  # keep open until we validate the name

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "Profile name (letters, digits, spaces, _-):"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	form.add_child(name_edit)

	var state_lbl := Label.new()
	state_lbl.text = "Initial state:"
	form.add_child(state_lbl)

	# CheckBox + ButtonGroup is the Godot 4 idiom for radio buttons. Set
	# button_group BEFORE button_pressed so the group registers the default.
	var state_group := ButtonGroup.new()

	var state_empty := CheckBox.new()
	state_empty.text = "Empty (no mods enabled)"
	state_empty.button_group = state_group
	state_empty.button_pressed = true
	form.add_child(state_empty)

	var state_all := CheckBox.new()
	state_all.text = "All enabled"
	state_all.button_group = state_group
	form.add_child(state_all)

	var state_copy := CheckBox.new()
	state_copy.text = "Copy current selection"
	state_copy.button_group = state_group
	form.add_child(state_copy)

	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_create := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing)
		if err != "":
			err_lbl.text = err
		else:
			d.queue_free()
			# Mutate in-memory entries to match the chosen initial state, then
			# _create_profile snapshots them into profile.<name>.* sections.
			# Priorities are intentionally left untouched -- they're a load-
			# order preference that survives an enable-state reset.
			if state_all.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = true
			elif state_empty.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = false
			# state_copy: leave _ui_mod_entries as-is so the new profile
			# inherits whatever was visible when the user clicked +.
			_create_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_create.call())
	_connect_dialog_exits(d, try_create, func(): d.queue_free())
	d.popup_centered()
	name_edit.grab_focus()

# Rename dialog. Same validation rules as New (letters/digits/space/_-, not
# empty, not "Vanilla", not colliding with another profile). Renaming to the
# same name is a silent no-op.
func _show_rename_profile_dialog(tabs: TabContainer) -> void:
	var current := _active_profile
	var d := ConfirmationDialog.new()
	d.title = "Rename profile"
	d.ok_button_text = "Rename profile"
	d.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "New name for \"" + current + "\":"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	name_edit.text = current
	form.add_child(name_edit)

	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_rename := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing, current)
		if err != "":
			err_lbl.text = err
		elif name == current:
			d.queue_free()  # no-op
		else:
			d.queue_free()
			_rename_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_rename.call())
	_connect_dialog_exits(d, try_rename, func(): d.queue_free())
	d.popup_centered()
	name_edit.select_all()
	name_edit.grab_focus()

# Modpacks tab. Lists modpack zips discovered in <game>/mods/, each with an
# Apply / Unload button. A modpack is a curated profile + MCM bundle in zip
# form (profile.json at root, MCM/ tree). Drop the file in /mods/ and it
# shows up here. Apply runs the modpack's profile + MCM and backs up the
# user's previous state; Unload restores the backup. Edits while a modpack
# is active save into the modpack's profile slot and persist across applies.
# The standard 8/8/6/6 outer margin shared by the top-level tab builders
# (Profile, Browse, Updates). Divergent margins (e.g. the Mods tab's 10/10/8/10)
# stay inline on purpose.
func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m

# Restore-point picker: lists the automatic pre-apply snapshots (newest first)
# and, after a confirm, restores the chosen one over live state -- a full revert
# of mod_config.cfg + MCM + saved override files to how things were before that
# apply. Re-reads state from the restored cfg and rebuilds the tabs.
func _show_restore_snapshot_dialog(tabs: TabContainer) -> void:
	# Restore points are always captured while NO pack is active, so restoring
	# one while a pack IS active would rewrite cfg to a no-pack state and leave
	# the active pack's override files live with nothing tracking them (and the
	# user's originals stranded in the backup slot). Require a clean unload
	# first -- its manifest-driven revert is the correct path out.
	var active_pack := get_active_modpack()
	if active_pack != "":
		_show_error_dialog("Modpack active",
				"Unload the active modpack (\"" + active_pack + "\") before restoring a backup. Unload reverts the pack's files first; restoring on top of an active pack would leave its files behind.")
		return
	var snaps := _list_apply_snapshots()
	if snaps.is_empty():
		_show_error_dialog("No restore points",
				"No automatic restore points have been saved yet. One is created before each modpack apply.")
		return

	var d := ConfirmationDialog.new()
	d.title = "Restore backup"
	d.ok_button_text = "Restore backup"
	d.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(440, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "Restore your mod state to a point saved automatically before a modpack was applied. This overwrites your current profiles, mod settings (MCM), and any files a modpack replaced."
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(prompt)

	var picker := OptionButton.new()
	for s: Dictionary in snaps:
		var created: String = str(s.get("created", ""))
		var label: String = str(s.get("pack", "modpack"))
		if created != "":
			label += "   (" + created + ")"
		picker.add_item(label)
	if picker.item_count > 0:
		picker.select(0)
	form.add_child(picker)

	_attach_ui_dialog(d)
	style_dialog_primary_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			var idx := picker.selected
			if idx < 0 or idx >= snaps.size():
				d.queue_free()
				return
			var chosen: Dictionary = snaps[idx]
			var result := _restore_apply_snapshot(str(chosen["path"]))
			d.queue_free()
			if not bool(result.get("ok", false)):
				_show_error_dialog("Could not restore backup", str(result.get("error", "unknown")))
				return
			# Re-read state from the restored cfg and rebuild the UI.
			var rcfg := ConfigFile.new()
			rcfg.load(UI_CONFIG_PATH)
			_active_profile = str(rcfg.get_value("settings", "active_profile", _active_profile))
			_reload_entries_for_active_profile()
			_rebuild_mods_tab(tabs)
			_rebuild_modpacks_tab(tabs)
			# The restore rewrote cfg + MCM on disk; a post-boot session must
			# restart into it or the running game keeps the old mods live
			# against the restored config (same convention as _switch_profile).
			if _boot_complete:
				_dirty_since_boot = true
			_show_accept_dialog("Backup restored", "Your mod state was restored from the selected backup."),
		func():
			d.queue_free())
	d.popup_centered()

func build_modpacks_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Refresh discovery up-front so the toolbar header (which queries
	# active_modpack to decide whether Save is enabled) has fresh state.
	# Cheap -- one DirAccess scan + one ZIPReader open per zip.
	_modpack_entries = collect_modpack_metadata()
	var active_modpack := get_active_modpack()

	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", SP_M)
	container.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "Modpacks in your mods folder"
	hdr.add_theme_font_size_override("font_size", FS_HEAD)
	hdr.add_theme_color_override("font_color", COL_TEXT_HI)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	# Export current profile as a modpack zip in <game>/mods/. Filename is
	# the sanitized profile name. Disabled when a modpack is active (the
	# active profile is "modpack__X" -- saving it would write a confusingly-
	# named zip; user should unload first).
	var save_modpack_btn := Button.new()
	save_modpack_btn.text = "Save current profile as modpack"
	save_modpack_btn.tooltip_text = "Write a modpack zip into /mods/ with profile.json + MCM snapshot"
	var save_disabled_reason := ""
	if active_modpack != "":
		save_disabled_reason = "Unload the active modpack first"
	save_modpack_btn.disabled = save_disabled_reason != ""
	if save_disabled_reason != "":
		save_modpack_btn.tooltip_text = save_disabled_reason
	hdr_row.add_child(save_modpack_btn)
	save_modpack_btn.pressed.connect(func():
		var profile_to_save := _active_profile
		var orphans := _enabled_mods_without_modworkshop_id()
		_show_save_modpack_dialog(profile_to_save, orphans, tabs)
	)

	var open_folder_btn := Button.new()
	open_folder_btn.text = "Open mods folder"
	open_folder_btn.tooltip_text = "Drop modpack zips here. They appear automatically on next launcher open."
	hdr_row.add_child(open_folder_btn)
	open_folder_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)

	# Restore from an automatic pre-apply snapshot. Disabled until at least one
	# exists (one is written before every modpack apply).
	var restore_btn := Button.new()
	restore_btn.text = "Restore backup"
	var apply_snaps := _list_apply_snapshots()
	restore_btn.disabled = apply_snaps.is_empty()
	restore_btn.tooltip_text = ("No restore points yet -- one is saved automatically before each modpack apply" \
			if apply_snaps.is_empty() \
			else "Roll back profiles, mod settings, and overwritten files to a point saved before a modpack was applied")
	hdr_row.add_child(restore_btn)
	restore_btn.pressed.connect(func():
		_show_restore_snapshot_dialog(tabs)
	)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)
	# Kept on self so _rebuild_modpacks_tab can carry the scroll position
	# across teardown (same pattern as _ui_mods_scroll).
	_ui_modpacks_scroll = scroll

	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", SP_S)
	list_wrap.add_child(list)

	if _modpack_entries.is_empty():
		var empty := Label.new()
		empty.text = "No modpacks yet.\n\nDrop a modpack zip into your mods folder, or save your current profile as one."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		list.add_child(empty)
		return margin

	for entry in _modpack_entries:
		list.add_child(_modpacks_render_row(entry, active_modpack, tabs))
		list.add_child(HSeparator.new())

	return margin


# Unload the active modpack and surface the outcome: error dialog on failure,
# and always rebuild the Modpacks tab -- on success to remove the ACTIVE row
# state, on error to correct the stale view that likely triggered the click.
func _unload_modpack_with_feedback(tabs: TabContainer) -> void:
	var result := unload_modpack(tabs)
	if not bool(result.get("ok", false)):
		_show_error_dialog("Could not unload modpack", str(result.get("error", "unknown")))
	_rebuild_modpacks_tab(tabs)

# Render one modpack row: name + filename/mod-count meta + Apply or
# Active+Unload button. Apply is disabled when ANOTHER modpack is active
# (single-slot constraint -- user has to unload first).
func _modpacks_render_row(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Name is a heading. Author (if any) appears next to it as "by X" in a
	# dimmer tone. The Details button in the action area is the canonical
	# way to open the modal -- a chevron on the name didn't read as
	# interactive in testing.
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", SP_M)
	info_col.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = str(entry.get("raw_name", "?"))
	name_lbl.add_theme_font_size_override("font_size", FS_HEAD)
	name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
	name_row.add_child(name_lbl)

	var author: String = str(entry.get("author", "")).strip_edges()
	if not author.is_empty():
		var author_lbl := Label.new()
		author_lbl.text = "by " + author
		author_lbl.add_theme_font_size_override("font_size", FS_BODY)
		author_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		author_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
		name_row.add_child(author_lbl)

	# Description, if set at save time. Wraps to fit the available row
	# width. Empty when modpack pre-dates the description field or the
	# author left it blank.
	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(desc_lbl)

	# Surface dedupe results so the user knows other same-name zips exist
	# in /mods/ but aren't shown. Without this they'd wonder where the
	# other file went and we'd risk both rows tagging as ACTIVE.
	var dups: Array = entry.get("duplicates_hidden", [])
	if not dups.is_empty():
		var dup_names := PackedStringArray()
		for d_v in dups:
			if d_v is Dictionary:
				dup_names.append(str((d_v as Dictionary).get("file_name", "?")))
		var dup_lbl := Label.new()
		dup_lbl.text = "Duplicate file(s) hidden: " + ", ".join(dup_names)
		dup_lbl.add_theme_color_override("font_color", COL_AMBER)
		dup_lbl.add_theme_font_size_override("font_size", FS_BODY)
		dup_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(dup_lbl)

	var enabled_count: int = int(entry.get("enabled_count", 0))
	var total_count: int = int(entry.get("total_count", 0))
	var meta_lbl := Label.new()
	if total_count > 0:
		meta_lbl.text = "%d of %d mods enabled - %s" % [enabled_count, total_count, str(entry.get("file_name", ""))]
	else:
		meta_lbl.text = str(entry.get("file_name", ""))
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels default
	# to MOUSE_FILTER_IGNORE, which silently suppresses tooltips).
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

	# Details button always visible, before the Apply/Unload action so it
	# reads as the discoverable "tell me more" affordance.
	var details_btn := Button.new()
	details_btn.text = "Details"
	details_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(details_btn)
	var captured_entry_for_detail := entry
	var captured_active := active_modpack
	details_btn.pressed.connect(func():
		_show_modpack_detail_dialog(captured_entry_for_detail, captured_active, tabs)
	)
	_wire_hint(details_btn, "Open the modpack's full mod list and description.")

	if is_active:
		var active_lbl := Label.new()
		active_lbl.text = "Active"
		active_lbl.add_theme_font_size_override("font_size", FS_META)
		active_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
		active_lbl.add_theme_stylebox_override("normal", _make_badge_stylebox(COL_OK, COL_OK_DIM))
		active_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(active_lbl)

		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		unload_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
	else:
		var apply_btn := Button.new()
		apply_btn.text = "Apply"
		# Bare theme voice: N modpack rows would mean N amber buttons on one
		# surface (spec caps primary at one per surface, same call as Browse
		# row Download buttons). Primary lives on the detail dialog's Apply
		# and the apply-confirm OK.
		apply_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		apply_btn.disabled = another_active
		if another_active:
			apply_btn.tooltip_text = "Unload \"" + active_modpack + "\" before applying another modpack"
		row.add_child(apply_btn)
		var captured_entry := entry
		apply_btn.pressed.connect(func():
			_apply_modpack_with_ui_flow(captured_entry, tabs)
		)

	return row


# Run the full modpack-apply UX: validate -> preview-confirm -> progress
# dialog -> apply -> rebuild tab -> failure dialog if any download failed.
# Extracted from the row's apply lambda so the detail modal can reuse the
# same flow without duplicating the logic.
func _apply_modpack_with_ui_flow(entry: Dictionary, tabs: TabContainer) -> void:
	# Validate the zip up front so the confirmation dialog can show a real
	# preview ("Apply 38-mod modpack?") and bail early if the zip is
	# malformed -- before the user commits.
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		_show_error_dialog("Cannot apply modpack", str(validation.get("error", "unknown")))
		return
	var apply_enabled := int(validation.get("enabled_count", 0))
	var apply_total := int(validation.get("total_count", 0))
	var name_str := str(entry.get("raw_name", "?"))
	# Preview download count so the user knows up-front whether this is a
	# "click and go" (everything already installed) or a long download op.
	var missing_preview := _get_missing_mods_for_modpack(entry)
	var dl_count := missing_preview.size()
	var msg := "Apply \"%s\"?\n\nActivates %d of %d mods and replaces MCM settings." % [name_str, apply_enabled, apply_total]
	if dl_count > 0:
		msg += "\nWill download %d mod(s) from ModWorkshop." % dl_count
	msg += "\n\nYour current state is backed up -- click Unload to restore."
	msg += "\nA restore point is also saved automatically (Restore backup) in case anything goes wrong."
	var cd := ConfirmationDialog.new()
	cd.title = "Apply modpack"
	cd.dialog_text = msg
	cd.ok_button_text = "Apply modpack"
	_attach_ui_dialog(cd)
	style_dialog_primary_button(cd.get_ok_button())
	_connect_dialog_exits(cd,
		func():
			cd.queue_free()
			# Skip the progress dialog entirely when there's nothing to
			# download -- the apply is a near-instant cfg flip and a
			# pop-and-vanish dialog looks broken. Failure dialog still
			# opens at the end if anything fails.
			var needs_progress := dl_count > 0
			var pd: AcceptDialog = null
			var pd_bar: ProgressBar = null
			var pd_status: Label = null
			var pd_cancel: Button = null
			if needs_progress:
				var progress_ui := _build_modpack_progress_dialog(name_str)
				pd = progress_ui["dialog"]
				pd_bar = progress_ui["bar"]
				pd_status = progress_ui["status"]
				pd_cancel = progress_ui["cancel"]
				pd_cancel.pressed.connect(func():
					if is_instance_valid(pd_status):
						pd_status.text = "Cancelling after current download..."
					if is_instance_valid(pd_cancel):
						pd_cancel.disabled = true
						pd_cancel.text = "Cancelling..."
					_modpack_apply_cancelled = true
				)
				pd.popup_centered()

			var progress_cb := func(p: Dictionary):
				if pd_status == null or not is_instance_valid(pd_status):
					return
				var cur := int(p.get("current", 0))
				var tot := int(p.get("total", 0))
				var nm := str(p.get("mod_name", ""))
				var act := str(p.get("action", ""))
				if is_instance_valid(pd_bar) and tot > 0:
					pd_bar.value = float(cur) / float(tot) * 100.0
				var prefix := "Downloading"
				if act == "skipped": prefix = "Skipping (no source)"
				elif act == "applying": prefix = "Applying modpack"
				elif act == "retrying": prefix = "Retrying"
				if nm != "":
					pd_status.text = "%s %d of %d:\n%s" % [prefix, cur, tot, nm]
				else:
					pd_status.text = "%s..." % prefix

			var result := await apply_modpack(entry, tabs, progress_cb)
			var was_cancelled: bool = bool(result.get("cancelled", false))
			var dl: int = int(result.get("downloaded", 0))
			var dl_failed: int = int(result.get("failed_downloads", 0))
			var failures: Array = result.get("failures", [])

			# Cancelled: the apply aborted BEFORE any state mutation -- the pack
			# was NOT applied. Say exactly that instead of routing to the
			# "Applied with Issues" dialog, which would claim the opposite.
			if was_cancelled:
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				var cancel_msg := "Apply cancelled -- the modpack was not applied and your profiles are unchanged."
				if dl > 0:
					cancel_msg += "\n%d downloaded mod(s) remain in your mods folder." % dl
				if dl_failed > 0:
					cancel_msg += "\n%d download(s) had already failed before the cancel." % dl_failed
				_show_accept_dialog("Apply cancelled", cancel_msg)
				return
			# Partial: tear down progress, route to failure dialog which has
			# its own dismiss-on-OK flow.
			if dl_failed > 0:
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				_show_modpack_failure_dialog(dl, failures, tabs)
				return
			if not bool(result.get("ok", false)):
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				_show_error_dialog("Could not apply modpack", str(result.get("error", "unknown")))
				return
			if is_instance_valid(tabs):
				_rebuild_modpacks_tab(tabs)
			# Full success. If a progress dialog was shown, switch it to
			# completion state (filled bar, summary line, OK button) so
			# the user dismisses on their own time. With no downloads
			# there was no dialog to begin with -- silent apply.
			if pd != null and is_instance_valid(pd):
				if is_instance_valid(pd_bar):
					pd_bar.value = 100
				if is_instance_valid(pd_status):
					pd_status.text = "Modpack applied. Downloaded %d mod(s)." % dl
				if is_instance_valid(pd_cancel):
					pd_cancel.visible = false
				pd.dialog_close_on_escape = true
				var pd_ok := pd.get_ok_button()
				if pd_ok != null:
					pd_ok.visible = true
				pd.confirmed.connect(func():
					if is_instance_valid(pd):
						pd.queue_free()
				)
				pd.close_requested.connect(func():
					if is_instance_valid(pd):
						pd.queue_free()
				),
		func(): cd.queue_free())
	cd.popup_centered()


# Construct the modpack-apply progress dialog: ProgressBar + status label +
# Cancel button. Returns the dialog plus references to the controls so
# callers can wire signals + update them. Build content BEFORE _attach_ui_dialog
# so the helper's reparent-children step folds them into the root VBox.
func _build_modpack_progress_dialog(raw_name: String) -> Dictionary:
	var pd := AcceptDialog.new()
	pd.title = "Applying modpack \"" + raw_name + "\""
	pd.min_size = Vector2i(520, 200)
	pd.ok_button_text = "Close"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	pd.add_child(box)

	var status := Label.new()
	status.text = "Preparing..."
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(status)

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 0
	bar.custom_minimum_size = Vector2(500, 18)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(bar)

	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(btn_row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	btn_row.add_child(cancel_btn)

	# Attach AFTER content so _attach_ui_dialog's reparent step picks up
	# the box and folds it into the root VBox with the injected title.
	# Progress is non-dismissible while running; hide the native OK until
	# the caller flips it on at completion, and swallow ESC too -- a hidden
	# (not cancelled) dialog would lift the exclusive input block and let the
	# user Launch / switch profiles mid-apply. Cancel is the only way out.
	_attach_ui_dialog(pd)
	pd.dialog_close_on_escape = false
	var pd_ok := pd.get_ok_button()
	if pd_ok != null:
		pd_ok.visible = false

	return {"dialog": pd, "bar": bar, "status": status, "cancel": cancel_btn}


# Read the modpack zip's profile.json into a parsed Dictionary. Empty dict
# on any failure (missing zip, corrupt zip, missing profile.json, bad JSON).
func _read_modpack_profile_json(entry: Dictionary) -> Dictionary:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty() or not FileAccess.file_exists(file_path):
		return {}
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


# Detail modal for a Modpacks-tab row. Shows zip size, mod counts, and the
# full mod list with installed/missing/downloadable indicators. The Apply
# (or Unload) button mirrors the row's inline button via the shared apply
# flow helper so behavior stays in sync.
func _show_modpack_detail_dialog(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = str(entry.get("raw_name", "?"))
	d.ok_button_text = "Close"
	d.min_size = Vector2i(660, 540)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 480)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Meta header
	var file_path: String = str(entry.get("file_path", ""))
	var author: String = str(entry.get("author", "")).strip_edges()
	var file_lbl := Label.new()
	var file_text := str(entry.get("file_name", "?"))
	if not author.is_empty():
		file_text = "by " + author + "  -  " + file_text
	file_lbl.text = file_text
	file_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	file_lbl.add_theme_font_size_override("font_size", FS_META)
	file_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	file_lbl.tooltip_text = file_text
	file_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(file_lbl)

	# Description -- prominent if present, omitted otherwise to keep the
	# modal compact for modpacks that pre-date the field.
	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_EMPH)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(desc_lbl)

	var zip_size := 0
	if FileAccess.file_exists(file_path):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			zip_size = f.get_length()
			f.close()

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

	var parsed := _read_modpack_profile_json(entry)
	var enabled_map: Dictionary = parsed.get("enabled", {}) if parsed.get("enabled") is Dictionary else {}
	var sources_map: Dictionary = parsed.get("sources", {}) if parsed.get("sources") is Dictionary else {}
	var total := enabled_map.size()
	var enabled_count := 0
	var installed_count := 0
	var missing_count := 0

	var installed_keys: Dictionary = {}
	for ient in _ui_mod_entries:
		installed_keys[str(ient.get("profile_key", ""))] = true

	for k_v in enabled_map.keys():
		if bool(enabled_map[k_v]):
			enabled_count += 1
		if installed_keys.has(str(k_v)):
			installed_count += 1
		else:
			missing_count += 1

	var counts_lbl := Label.new()
	var counts_parts := PackedStringArray()
	counts_parts.append("%d mods" % total)
	counts_parts.append("%d enabled" % enabled_count)
	counts_parts.append("%d installed" % installed_count)
	if missing_count > 0:
		counts_parts.append("%d missing" % missing_count)
	if zip_size > 0:
		counts_parts.append(_format_size(zip_size))
	if is_active:
		counts_parts.append("active")
	counts_lbl.text = " - ".join(counts_parts)
	counts_lbl.add_theme_color_override("font_color", COL_OK if is_active else COL_TEXT)
	counts_lbl.add_theme_font_size_override("font_size", FS_EMPH)
	box.add_child(counts_lbl)

	box.add_child(HSeparator.new())

	var list_hdr := Label.new()
	list_hdr.text = "Mods"
	list_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	box.add_child(list_hdr)

	if enabled_map.is_empty():
		var empty := Label.new()
		empty.text = "This modpack lists no mods."
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_BODY)
		box.add_child(empty)
	else:
		var sorted_keys: Array = enabled_map.keys()
		sorted_keys.sort()
		for k_v in sorted_keys:
			var k: String = str(k_v)
			var en: bool = bool(enabled_map[k_v])
			var installed: bool = installed_keys.has(k)
			var src_data: Dictionary = sources_map.get(k_v, {}) if sources_map.get(k_v) is Dictionary else {}
			var has_source: bool = int(src_data.get("modworkshop_id", 0)) > 0

			var mod_row := HBoxContainer.new()
			mod_row.add_theme_constant_override("separation", SP_M)
			box.add_child(mod_row)

			var en_lbl := Label.new()
			en_lbl.text = "[on]" if en else "[off]"
			en_lbl.add_theme_font_size_override("font_size", FS_BODY)
			en_lbl.add_theme_color_override("font_color", COL_OK if en else COL_TEXT_DIM)
			en_lbl.custom_minimum_size.x = 40
			mod_row.add_child(en_lbl)

			var key_lbl := Label.new()
			key_lbl.text = k
			key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			key_lbl.clip_text = true
			# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels
			# default to MOUSE_FILTER_IGNORE, which suppresses tooltips).
			key_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			key_lbl.tooltip_text = k
			key_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			mod_row.add_child(key_lbl)

			var status_lbl := Label.new()
			if installed:
				status_lbl.text = "Installed"
				status_lbl.add_theme_color_override("font_color", COL_OK)
			elif has_source:
				status_lbl.text = "Will download"
				status_lbl.add_theme_color_override("font_color", COL_AMBER)
			else:
				status_lbl.text = "No source"
				status_lbl.add_theme_color_override("font_color", COL_ERR)
			status_lbl.add_theme_font_size_override("font_size", FS_BODY)
			status_lbl.custom_minimum_size.x = 110
			mod_row.add_child(status_lbl)

	# Action button on the dialog's native button bar.
	if is_active:
		var unload_btn := d.add_button("Unload", true, "")
		style_danger_button(unload_btn)
		unload_btn.pressed.connect(func():
			d.queue_free()
			_unload_modpack_with_feedback(tabs)
		)
	else:
		var apply_btn_d := d.add_button("Apply", true, "")
		style_primary_button(apply_btn_d)
		apply_btn_d.disabled = another_active
		if another_active:
			apply_btn_d.tooltip_text = "Unload \"" + active_modpack + "\" first"
		var captured_entry := entry
		apply_btn_d.pressed.connect(func():
			d.queue_free()
			_apply_modpack_with_ui_flow(captured_entry, tabs)
		)

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Mirror of _rebuild_mods_tab. Replaces the Modpacks tab control in place
# preserving current_tab so the user doesn't get yanked to a different tab
# during the swap. _rebuilding_modpacks_tab guards against recursion: the
# remove_child shifts current_tab to a sibling which fires tab_changed,
# whose listener calls back here -- the flag short-circuits the second
# call. Also breaks recursion when we explicitly restore current_tab at
# the end (fires another tab_changed).
func _rebuild_modpacks_tab(tabs: TabContainer) -> void:
	if _rebuilding_modpacks_tab:
		return
	_rebuilding_modpacks_tab = true
	var old := tabs.get_node_or_null(UI_TAB_MODPACKS)
	if old == null:
		_rebuilding_modpacks_tab = false
		return
	_rebuilding_tab_in_place = true
	# Carry the list scroll position across the teardown -- a row action
	# halfway down a long modpack list must not snap the view to the top.
	var saved_scroll := 0
	if is_instance_valid(_ui_modpacks_scroll):
		saved_scroll = _ui_modpacks_scroll.scroll_vertical
	var idx := old.get_index()
	var was_current := tabs.current_tab == idx
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_modpacks_tab(tabs)
	new_tab.name = UI_TAB_MODPACKS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	if was_current:
		tabs.current_tab = idx
	_rebuilding_tab_in_place = false
	_rebuilding_modpacks_tab = false
	if saved_scroll > 0:
		_restore_modpacks_scroll(saved_scroll)

# Restore one frame later: the fresh rows haven't been laid out yet when
# _rebuild_modpacks_tab returns, so setting scroll_vertical immediately
# clamps against a zero-height list and lands back at the top (mirror of
# _restore_mods_scroll).
func _restore_modpacks_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_modpacks_scroll):
		_ui_modpacks_scroll.scroll_vertical = saved_scroll

# Delete-profile confirmation. The trash button is already disabled when the
# active profile is Vanilla or the last remaining user profile; the guard in
# _delete_active_profile is belt-and-suspenders.
func _show_delete_confirm(tabs: TabContainer) -> void:
	var target := _active_profile
	var d := ConfirmationDialog.new()
	d.title = "Delete profile"
	d.dialog_text = "Delete profile \"" + target + "\"?\n\nThe mod selection stored in this profile will be discarded. Your other profiles are not affected."
	d.ok_button_text = "Delete profile"
	_attach_ui_dialog(d)
	style_dialog_danger_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			_delete_active_profile()
			_rebuild_mods_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()


# Remove a mod file from disk and strip its profile entries from every
# profile in mod_config.cfg. profile_key (not file_name) drives the cleanup
# so a renamed archive's profile state still gets cleaned up correctly.
# Returns true on a successful file delete, false otherwise -- caller decides
# whether to surface the failure or carry on.
func _delete_mod_file_and_cleanup(entry: Dictionary) -> bool:
	var path: String = str(entry["full_path"])
	if FileAccess.file_exists(path):
		if DirAccess.remove_absolute(path) != OK:
			return false
	var profile_key: String = str(entry["profile_key"])
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) == OK:
		for section in cfg.get_sections():
			if not section.begins_with("profile."):
				continue
			if not (section.ends_with(".enabled") or section.ends_with(".priority") \
					or section.ends_with(".dep_ignore")):
				continue
			if cfg.has_section_key(section, profile_key):
				cfg.erase_section_key(section, profile_key)
		_persist_ui_cfg(cfg)
	return true


# Per-row Remove confirmation. Shows mod name + filename + size so the user
# can sanity-check before committing. On Delete: deletes the file, strips
# profile state across all profiles, re-runs discovery, and rebuilds the
# Mods tab in place so the row vanishes immediately.
func _show_remove_mod_confirm(entry: Dictionary, tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Remove mod"
	var size_line := ""
	var path: String = str(entry.get("full_path", ""))
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size_line = "\nSize: " + _format_size(f.get_length())
			f.close()
	d.dialog_text = "Permanently delete \"%s\"?\n\nFile: %s%s\n\nThis will:\n  - Delete the file from disk\n  - Remove the mod from EVERY profile, not just \"%s\"\n\nThis cannot be undone." % [
		str(entry.get("mod_name", "?")),
		str(entry.get("file_name", "?")),
		size_line,
		_active_profile,
	]
	d.ok_button_text = "Delete mod"
	style_dialog_danger_button(d.get_ok_button())
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			if _delete_mod_file_and_cleanup(entry):
				_reload_entries_for_active_profile()
				_rebuild_mods_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()


# UI

func show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	# Borderless: drop Godot's native title bar, which duplicated the in-panel
	# header plate ("ROAD TO VOSTOK -- MOD LOADER") and stacked a second title +
	# close X above it. The plate below carries the title, and the close X moves
	# into the plate (built there). Header drag is added by hand since a
	# borderless Window has no bar to grab. Title string kept for taskbar/alt-tab.
	win.borderless = true
	# Embed sub-windows (tooltips, dropdowns, dialogs) INSIDE this window's
	# viewport instead of as separate OS windows. Separate windows aren't
	# always_on_top, so they stranded behind this always_on_top launcher -- the
	# tooltip-behind-window bug, and the reason dropdowns needed always_on_top
	# hacks. Embedded, they render on top of the launcher content and can't fall
	# behind it, fixing every tooltip at once.
	win.gui_embed_subwindows = true
	win.size = Vector2i(960, 640)
	win.min_size = Vector2i(640, 420)
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()
	# Stash for dialogs triggered by profile-bar controls. Cleared on close.
	_ui_window = win

	# Kill the default Godot gray on the Window itself (embedded_border is the
	# stylebox that paints the window's own background area).
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = COL_BG
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Solid dark background so Godot's default gray theme doesn't show through.
	# The 0.92-alpha black is a near-opaque scrim over the window floor, not a
	# surface token; the outline snaps to COL_BORDER (was pure white glare).
	# Was 0.6, but at 40% game bleed-through the text got hard to read over
	# bright scenes -- 0.92 keeps only a faint hint of the game behind and is
	# easier on OLED (less bright content under static UI).
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.92)
	bg_s.border_color = COL_BORDER
	_sb_border(bg_s)
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	# Assign the dark theme on the Window itself so child Windows (OptionButton
	# popup + dialogs spawned from the profile bar) inherit it via the scene
	# tree. Setting it only on the MarginContainer misses sub-Windows.
	var dark_theme := make_dark_theme()
	win.theme = dark_theme

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", SP_L)
	margin.add_theme_constant_override("margin_right", SP_L)
	margin.add_theme_constant_override("margin_top", SP_M)
	margin.add_theme_constant_override("margin_bottom", SP_L)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = dark_theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", SP_M)
	margin.add_child(root)

	# Equipment plate header: ALL-CAPS title with the version beside it on a
	# COL_SURFACE strip with a 1px amber-dim bottom border. The one FS_TITLE
	# use in the UI (spec section 6).
	var header := PanelContainer.new()
	var header_s := StyleBoxFlat.new()
	header_s.bg_color = COL_SURFACE
	header_s.border_color = COL_AMBER_DIM
	header_s.border_width_bottom = 1
	header_s.content_margin_left = SP_L
	header_s.content_margin_right = SP_L
	header_s.content_margin_top = SP_M
	header_s.content_margin_bottom = SP_M
	header.add_theme_stylebox_override("panel", header_s)
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", SP_M)
	header.add_child(header_row)
	var plate_title := Label.new()
	plate_title.text = "ROAD TO VOSTOK -- MOD LOADER"
	plate_title.add_theme_font_size_override("font_size", FS_TITLE)
	plate_title.add_theme_color_override("font_color", COL_TEXT_HI)
	header_row.add_child(plate_title)

	# Version / self-update alert beside the title. Default state shows the
	# installed version in dim meta text; the _check_modloader_update_async
	# coroutine flips it amber and rewrites the text when ModWorkshop reports
	# a newer release. Click opens the mod page in the system browser
	# regardless of state.
	var alert := LinkButton.new()
	alert.text = "v" + MODLOADER_VERSION
	alert.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	alert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alert.add_theme_font_size_override("font_size", FS_META)
	alert.add_theme_color_override("font_color", COL_TEXT_DIM)
	alert.add_theme_color_override("font_hover_color", COL_TEXT)
	alert.pressed.connect(func():
		OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(MODLOADER_MODWORKSHOP_ID))
	)
	header_row.add_child(alert)
	_ui_update_alert_btn = alert

	# Push the close control to the far right of the plate.
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Pure layout -- must not swallow mouse events, or it kills header drag over
	# the widest stretch of the plate (plain Control defaults to STOP).
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(header_spacer)

	# Close (X) lives in the plate now the window is borderless. Wired below to
	# the same path as the old native close (X == Launch, by design), after
	# launch_btn is built.
	var close_btn := Button.new()
	close_btn.flat = true
	close_btn.icon = _make_close_icon(COL_TEXT_DIM)
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(close_btn)

	# Borderless windows have no bar to grab, so let the header plate drag the
	# whole window. Labels + the expanding spacer ignore mouse input so events
	# fall through to the header; the version link and close button keep clicks.
	# Anchor the grab offset and track ABSOLUTE mouse position: using ev.relative
	# would self-cancel (moving the window shifts local coords back) and trail
	# the cursor at half speed with jitter.
	var drag := {"on": false, "grab": Vector2i.ZERO}
	header.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				drag["grab"] = Vector2i(ev.global_position)
		elif ev is InputEventMouseMotion and drag["on"]:
			win.position = DisplayServer.mouse_get_position() - drag["grab"]
	)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	# Bottom bar: instructions + launch button
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", SP_M)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Required dependencies from mod.txt must be enabled and load first."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", FS_BODY)
	hint.add_theme_color_override("font_color", COL_TEXT_DIM)
	bottom.add_child(hint)
	# Expose for _wire_hint so toolbar/dropdown hovers can temporarily repurpose
	# this label as a status-line substitute for broken Godot tooltips.
	_ui_hint_label = hint

	var launch_btn := Button.new()
	# Text is set by refresh_launch_button_label below (called after tabs
	# build), which picks "Launch modded" or "Launch" based on enabled
	# state. Starting empty avoids a one-frame placeholder flash.
	launch_btn.text = ""
	launch_btn.custom_minimum_size = Vector2(160, 36)
	# PRIMARY voice: the one amber-emphasis action on this surface. Boxes,
	# margins and the focus ring come from the theme.
	style_primary_button(launch_btn)

	# The version/self-update alert lives in the header plate (built above);
	# the bottom bar keeps only the hint and the action cluster.

	# Visual separator between the informational hint and the action cluster
	# (Launch vanilla + Launch) so the eye keeps the grouping.
	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = SP_XL
	bottom.add_child(bar_gap)

	# Vanilla: one-shot bypass via sentinel + restart. Bare theme voice and
	# sized smaller than the primary Launch button so the visual hierarchy
	# reads correctly -- Launch is the common action, vanilla is the
	# diagnostic one. Hover hint communicates the restart.
	var vanilla_btn := Button.new()
	vanilla_btn.text = "Launch vanilla"
	vanilla_btn.custom_minimum_size = Vector2(90, 36)
	var win_for_vanilla := win
	vanilla_btn.pressed.connect(func(): _launch_vanilla_once(win_for_vanilla))
	bottom.add_child(vanilla_btn)
	_wire_hint(vanilla_btn, "Launch without mods for this session. Restarts the game.")

	bottom.add_child(launch_btn)
	_ui_launch_btn = launch_btn
	_wire_hint(launch_btn, "Launch the game with the active profile's mods. Restarts the game.")

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())
	# The in-plate X does exactly what the old native title-bar X did.
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# Status-line hint, kept for the launcher's consistent hover-hint UX.
	# (Historically raw tooltips stranded behind this always_on_top window;
	# win.gui_embed_subwindows now embeds tooltips so that's fixed -- the hint is
	# a deliberate style choice, not a workaround.) _wire_hint needs
	# _ui_hint_label, which the bottom bar sets above -- so wire it here, after.
	_wire_hint(close_btn, "Close and launch")

	# Fire-and-forget self-update check. Updates _ui_update_alert_btn and may
	# pop the one-shot dialog when the API returns. Guards on
	# is_instance_valid so a launcher close mid-flight is harmless.
	_check_modloader_update_async()

	# --- Tab contract ---------------------------------------------------
	# Each tab is built by a build_*_tab(tabs) -> Control function and added
	# here under a stable node name (UI_TAB_*). That name is load-bearing:
	# TabContainer shows it as the tab title, the in-place rebuild helpers
	# (_rebuild_mods_tab, _rebuild_modpacks_tab) find the tab via
	# get_node_or_null(name), and the tab_changed listener below matches on
	# it. (_rebuild_mods_tab also restores the user's current tab by name;
	# _rebuild_modpacks_tab restores it by index.)
	# To add a tab: (1) write build_x_tab(tabs) returning its root Control,
	# (2) add + name it below, (3) if other surfaces can change its state,
	# add a _rebuild_x_tab helper (copy the recursion-guard pattern from
	# _rebuild_modpacks_tab) and/or an on-show refresh via the tab_changed
	# listener below. build_updates_tab takes no tabs arg only because it
	# never rebuilds in place; prefer the (tabs) signature for new tabs.

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = UI_TAB_MODS
	tabs.add_child(mods_tab)

	var browse_tab := build_browse_tab(tabs)
	browse_tab.name = UI_TAB_BROWSE
	tabs.add_child(browse_tab)

	var modpacks_tab := build_modpacks_tab(tabs)
	modpacks_tab.name = UI_TAB_MODPACKS
	tabs.add_child(modpacks_tab)

	var updates_tab := build_updates_tab()
	updates_tab.name = UI_TAB_UPDATES
	tabs.add_child(updates_tab)

	# Refresh the Modpacks tab whenever the user switches to it. State can
	# change behind the tab's back -- e.g. banner Unload from Mods tab --
	# and without this listener the Modpacks tab keeps showing stale
	# ACTIVE/Apply state until UI close/reopen. _rebuild_modpacks_tab now
	# preserves current_tab and short-circuits recursion via the
	# _rebuilding_modpacks_tab flag, so the rebuild-during-tab-show that
	# broke things in the earlier revision no longer applies.
	tabs.tab_changed.connect(func(idx: int):
		# Bail on re-entrant tab_changed fired mid-rebuild. An in-place rebuild
		# does remove_child/add_child/move_child, each of which re-fires
		# tab_changed while the TabContainer is busy; dispatching another rebuild
		# here corrupts the tree (nodes freed mid-op -> tabs vanish).
		if _rebuilding_tab_in_place:
			return
		var ctrl := tabs.get_tab_control(idx)
		if ctrl != null and ctrl.name == UI_TAB_MODPACKS:
			_rebuild_modpacks_tab(tabs)
		# Browse rows bake profile name + enabled state at render time and
		# the tab never rebuilds, so sync them in place on show (profile
		# switch / modpack apply / Mods-tab edits happen behind its back).
		elif ctrl != null and ctrl.name == UI_TAB_BROWSE:
			_refresh_browse_installed_rows(ctrl)
		# The Updates tab is a build-time snapshot of the mod list; rebuild it
		# on show so mid-session updates/installs aren't shown as stale rows.
		elif ctrl != null and ctrl.name == UI_TAB_UPDATES:
			_rebuild_updates_tab(tabs)
		# An Updates-tab check may have changed the badge state while the Mods
		# tab was off-screen; rebuild once so the per-row badges appear.
		elif ctrl != null and ctrl.name == UI_TAB_MODS and _mods_badges_dirty:
			_mods_badges_dirty = false
			_rebuild_mods_tab(tabs)
	)

	refresh_launch_button_label()

	# Launch loop. If any enabled mod has the scanner's RED risk_level,
	# show a confirmation dialog before proceeding. Cancel returns the
	# user to the launcher so they can disable the flagged mod or
	# reconsider; confirm proceeds. No gate when no red mods are enabled.
	while true:
		await launch_btn.pressed
		var red_mods := _enabled_red_mods()
		if red_mods.is_empty():
			break
		var proceed: bool = await _confirm_red_launch(red_mods)
		if proceed:
			break
		# else: loop and wait for Launch again
	_ui_window = null
	_ui_hint_label = null
	_ui_launch_btn = null
	_ui_update_alert_btn = null
	_ui_mods_scroll = null
	_ui_modpacks_scroll = null
	# Drop the Browse-tab API response cache. It's a session optimization,
	# not durable state -- the modloader autoload survives across launcher
	# open/close (rare in practice) and we don't want the dict to accumulate
	# across sessions. Disk-cached thumbnails stay (immutable storage keys
	# are valid indefinitely; they're how we make repeat browsing snappy).
	# In-flight HTTPRequests (list + thumbnail fetches) are parented to self
	# and self-queue_free on completion, so no node-leak cleanup is needed.
	_mws_cache.clear()
	win.queue_free()

# Launch button label reflects whether anything will load. Both this and
# the bottom-bar Launch Vanilla button restart the game, so the "(Restart)"
# suffix added no signal -- dropped to avoid noise.
func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	# Count what will actually LOAD, not what's checked -- with every enabled
	# mod dependency-blocked, "Launch modded" would promise a modded
	# session and deliver vanilla.
	var pick := _loadable_enabled_entries()
	var loadable_count: int = (pick["loadable"] as Array).size()
	var enabled_count := int(pick["enabled_count"])
	if loadable_count > 0:
		_ui_launch_btn.text = "Launch modded"
	elif enabled_count > 0:
		_ui_launch_btn.text = "Launch unmodded (%d blocked)" % enabled_count
	else:
		_ui_launch_btn.text = "Launch"

# -- Sub-label / row-action factories -----------------------------------------
# The launcher's small-print conventions, encoded once: font 11, ellipsis
# trim instead of a mid-word cut, and working tooltips (Labels default to
# MOUSE_FILTER_IGNORE, which silently suppresses them). Hand-built labels
# kept forgetting one of these -- that's how the order-panel overflow and
# the never-firing tooltips shipped. New sub-labels go through here.
func _make_sub_label(text: String, color: Color, tip := "") -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", FS_BODY)
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if tip != "":
		lbl.tooltip_text = tip
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	return lbl

# Flat inline action button for row sub-lines (Enable dependency, Load
# anyway, Re-check). Same shape as the suspicious-code tag button.
func _make_row_action(text: String, color: Color, tip := "") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", color)
	# Flat buttons draw no hover stylebox, so a brightened hover font color
	# is the only visible hover cue these row actions get.
	btn.add_theme_color_override("font_hover_color", color.lerp(COL_TEXT_HI, 0.35))
	btn.add_theme_color_override("font_pressed_color", color)
	btn.add_theme_font_size_override("font_size", FS_BODY)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	if tip != "":
		btn.tooltip_text = tip
	return btn

# Shared tail for every dependency quick action: recompute status, persist,
# retruth the launch button, rebuild the tab -- deferred, so the control
# that's mid-signal isn't torn down under the cursor.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

# Runtime-generated 16x16 pencil icon. Monochrome outline in button-text
# gray so it matches the rest of the UI -- a colored pencil looks like an
# emoji in this context.
func _make_pencil_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	# Body outline: rectangle from (1,5) to (12,9).
	for x in range(1, 13):
		img.set_pixel(x, 5, line)
		img.set_pixel(x, 9, line)
	for y in range(5, 10):
		img.set_pixel(1, y, line)
		img.set_pixel(12, y, line)
	# Divider between eraser compartment and main body.
	for y in range(5, 10):
		img.set_pixel(4, y, line)
	# Triangular tip sticking off the right side.
	img.set_pixel(13, 6, line)
	img.set_pixel(13, 7, line)
	img.set_pixel(13, 8, line)
	img.set_pixel(14, 7, line)
	return ImageTexture.create_from_image(img)

# Runtime-generated 16x16 trashcan: lid handle on top, rectangular body with
# three vertical slots.
func _make_trashcan_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	# Lid handle (short bar on top).
	for x in range(6, 10):
		img.set_pixel(x, 2, line)
	# Lid (wider bar).
	for x in range(3, 13):
		img.set_pixel(x, 4, line)
	# Body sides + floor.
	for y in range(5, 14):
		img.set_pixel(4, y, line)
		img.set_pixel(11, y, line)
	for x in range(5, 11):
		img.set_pixel(x, 13, line)
	# Three vertical slots for texture.
	for y in range(6, 12):
		img.set_pixel(6, y, line)
		img.set_pixel(8, y, line)
		img.set_pixel(10, y, line)
	return ImageTexture.create_from_image(img)

func make_dark_theme() -> Theme:
	var t := Theme.new()
	# Default control font size. Without this, every control that doesn't set
	# its own font_size falls back to the engine's 16px default -- which is
	# FS_TITLE, the window-header size -- flattening the whole FS_* type scale
	# (body text ends up as large as headings). Pin the default to FS_BODY so
	# the scale reads as designed; larger surfaces opt up explicitly.
	t.default_font_size = FS_BODY

	# -- Button ----------------------------------------------------------------
	var bn := _make_button_stylebox(COL_SURFACE, COL_BORDER)
	var bh := _make_button_stylebox(COL_SURFACE_2, COL_TEXT_HI)
	var bp := _make_button_stylebox(COL_BG, COL_BORDER)
	var bd := _make_button_stylebox(COL_BG, COL_BORDER_DIM)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", _make_focus_stylebox())
	t.set_color("font_color",          "Button", COL_TEXT)
	t.set_color("font_hover_color",    "Button", COL_TEXT_HI)
	t.set_color("font_pressed_color",  "Button", COL_TEXT)
	t.set_color("font_focus_color",    "Button", COL_TEXT)
	t.set_color("font_disabled_color", "Button", COL_TEXT_FAINT)

	# -- CheckBox (code-drawn glyphs; the stock ones are light-theme) -----------
	t.set_color("font_color",       "CheckBox", COL_TEXT)
	t.set_color("font_hover_color", "CheckBox", COL_TEXT_HI)
	t.set_stylebox("focus", "CheckBox", _make_focus_stylebox())
	var cb_checked := _make_checkbox_icon(true, COL_BORDER, COL_AMBER)
	var cb_unchecked := _make_checkbox_icon(false, COL_BORDER, COL_AMBER)
	t.set_icon("checked",   "CheckBox", cb_checked)
	t.set_icon("unchecked", "CheckBox", cb_unchecked)
	t.set_icon("checked_disabled",   "CheckBox", _make_checkbox_icon(true, COL_BORDER_DIM, COL_TEXT_FAINT))
	t.set_icon("unchecked_disabled", "CheckBox", _make_checkbox_icon(false, COL_BORDER_DIM, COL_TEXT_FAINT))
	# Radio variants: the profile-state picker uses CheckBox + ButtonGroup,
	# which switches CheckBox to its radio_* icons.
	var rb_checked := _make_radio_icon(true, COL_BORDER, COL_AMBER)
	var rb_unchecked := _make_radio_icon(false, COL_BORDER, COL_AMBER)
	t.set_icon("radio_checked",   "CheckBox", rb_checked)
	t.set_icon("radio_unchecked", "CheckBox", rb_unchecked)
	t.set_icon("radio_checked_disabled",   "CheckBox", _make_radio_icon(true, COL_BORDER_DIM, COL_TEXT_FAINT))
	t.set_icon("radio_unchecked_disabled", "CheckBox", _make_radio_icon(false, COL_BORDER_DIM, COL_TEXT_FAINT))

	# -- Label -----------------------------------------------------------------
	t.set_color("font_color", "Label", COL_TEXT)

	# -- Panel / PanelContainer ------------------------------------------------
	var ps := StyleBoxFlat.new(); ps.bg_color = COL_BG
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# -- TabContainer ----------------------------------------------------------
	# Selected tab carries the signature 2px amber roofline (an indicator
	# lamp over the active tab). StyleBoxFlat has a single border color, so
	# the selected tab's side borders go to 0 and the roofline carries the
	# whole selected state; the seamless merge into the panel below stays.
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = COL_BG
	ts.border_color = COL_AMBER
	ts.border_width_top = 2; ts.border_width_left = 0; ts.border_width_right = 0
	ts.border_width_bottom = 0
	ts.content_margin_left = SP_L; ts.content_margin_right = SP_L
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := StyleBoxFlat.new()   # unselected tab
	tu.bg_color = Color(0.02, 0.02, 0.02)  # a step below COL_BG so inactive tabs recede
	tu.border_color = COL_BORDER_DIM
	_sb_border(tu)
	tu.content_margin_left = SP_L; tu.content_margin_right = SP_L
	tu.content_margin_top = 5;   tu.content_margin_bottom = 5
	var tc_panel := StyleBoxFlat.new(); tc_panel.bg_color = COL_BG
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", COL_TEXT_HI)
	t.set_color("font_unselected_color", "TabContainer", COL_TEXT_DIM)
	t.set_color("font_hovered_color",    "TabContainer", COL_TEXT)

	# -- HSeparator ------------------------------------------------------------
	var sep := StyleBoxFlat.new(); sep.bg_color = COL_BORDER_DIM
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	# -- LineEdit (SpinBox uses this internally) --------------------------------
	var le := StyleBoxFlat.new()
	le.bg_color = COL_SURFACE
	le.border_color = COL_BORDER
	_sb_border(le)
	le.content_margin_left = 6
	le.content_margin_right = 6
	le.content_margin_top = 3
	le.content_margin_bottom = 3
	var le_focus: StyleBoxFlat = le.duplicate()
	le_focus.border_color = COL_AMBER
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", COL_TEXT)

	# -- TextEdit (multi-line; the modpack description box) ----------------------
	# Mirror LineEdit so the only TextEdit in the UI matches the square-cornered
	# dark system instead of falling back to the stock rounded light-theme box.
	t.set_stylebox("normal", "TextEdit", le)
	t.set_stylebox("focus",  "TextEdit", le_focus)
	t.set_color("font_color", "TextEdit", COL_TEXT)

	# -- SpinBox arrows (stock glyph is light-theme) -----------------------------
	t.set_icon("updown", "SpinBox", _make_updown_icon(COL_TEXT_DIM))

	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# -- ScrollBars (slim dark track; stock ones glare) -------------------------
	# Width is driven by stylebox minimum sizes: track margins (1+1) +
	# grabber margins (3+3) = 8px nominal.
	var track_v := StyleBoxFlat.new()
	track_v.bg_color = COL_BG
	track_v.border_color = COL_BORDER_DIM
	track_v.border_width_left = 1
	track_v.content_margin_left = 1
	track_v.content_margin_right = 1
	var grab_v := StyleBoxFlat.new()
	grab_v.bg_color = COL_BORDER
	grab_v.content_margin_left = 3
	grab_v.content_margin_right = 3
	var grab_v_hi: StyleBoxFlat = grab_v.duplicate()
	grab_v_hi.bg_color = COL_TEXT_DIM
	t.set_stylebox("scroll",            "VScrollBar", track_v)
	t.set_stylebox("grabber",           "VScrollBar", grab_v)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_v_hi)
	t.set_stylebox("grabber_pressed",   "VScrollBar", grab_v_hi.duplicate())
	var track_h := StyleBoxFlat.new()
	track_h.bg_color = COL_BG
	track_h.border_color = COL_BORDER_DIM
	track_h.border_width_top = 1
	track_h.content_margin_top = 1
	track_h.content_margin_bottom = 1
	var grab_h := StyleBoxFlat.new()
	grab_h.bg_color = COL_BORDER
	grab_h.content_margin_top = 3
	grab_h.content_margin_bottom = 3
	var grab_h_hi: StyleBoxFlat = grab_h.duplicate()
	grab_h_hi.bg_color = COL_TEXT_DIM
	t.set_stylebox("scroll",            "HScrollBar", track_h)
	t.set_stylebox("grabber",           "HScrollBar", grab_h)
	t.set_stylebox("grabber_highlight", "HScrollBar", grab_h_hi)
	t.set_stylebox("grabber_pressed",   "HScrollBar", grab_h_hi.duplicate())

	# -- ProgressBar (modpack apply / download progress) -------------------------
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = COL_SURFACE
	pb_bg.border_color = COL_BORDER
	_sb_border(pb_bg)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = COL_AMBER_DIM
	pb_fill.border_color = COL_AMBER
	_sb_border(pb_fill)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill",       "ProgressBar", pb_fill)
	t.set_font_size("font_size", "ProgressBar", FS_META)
	t.set_color("font_color",    "ProgressBar", COL_TEXT)

	# -- PopupMenu (OptionButton dropdown) -------------------------------------
	var pm_panel := StyleBoxFlat.new()
	pm_panel.bg_color = COL_SURFACE
	pm_panel.border_color = COL_BORDER
	_sb_border(pm_panel)
	pm_panel.content_margin_left = SP_S
	pm_panel.content_margin_right = SP_S
	pm_panel.content_margin_top = SP_S
	pm_panel.content_margin_bottom = SP_S
	t.set_stylebox("panel", "PopupMenu", pm_panel)
	var pm_hover := StyleBoxFlat.new()
	pm_hover.bg_color = COL_SURFACE_2
	t.set_stylebox("hover", "PopupMenu", pm_hover)
	var pm_sep := StyleBoxFlat.new()
	pm_sep.bg_color = COL_BORDER_DIM
	pm_sep.content_margin_top = 1; pm_sep.content_margin_bottom = 1
	t.set_stylebox("separator", "PopupMenu", pm_sep)
	t.set_color("font_color",           "PopupMenu", COL_TEXT)
	t.set_color("font_hover_color",     "PopupMenu", COL_TEXT_HI)
	t.set_color("font_disabled_color",  "PopupMenu", COL_TEXT_FAINT)
	t.set_color("font_separator_color", "PopupMenu", COL_TEXT_DIM)
	# Checked menu items reuse the checkbox glyphs (stock marks are light).
	t.set_icon("checked",         "PopupMenu", cb_checked)
	t.set_icon("unchecked",       "PopupMenu", cb_unchecked)
	t.set_icon("radio_checked",   "PopupMenu", rb_checked)
	t.set_icon("radio_unchecked", "PopupMenu", rb_unchecked)

	# -- OptionButton (themed like Button but needs its own panel stylebox
	#    because OptionButton uses a separate theme type from Button) ----------
	t.set_stylebox("normal",   "OptionButton", bn.duplicate())
	t.set_stylebox("hover",    "OptionButton", bh.duplicate())
	t.set_stylebox("pressed",  "OptionButton", bp.duplicate())
	t.set_stylebox("disabled", "OptionButton", bd.duplicate())
	t.set_stylebox("focus",    "OptionButton", _make_focus_stylebox())
	t.set_color("font_color",         "OptionButton", COL_TEXT)
	t.set_color("font_hover_color",   "OptionButton", COL_TEXT_HI)
	t.set_color("font_pressed_color", "OptionButton", COL_TEXT)

	# -- Tooltip (hover hint panel) --------------------------------------------
	# Without these our tooltips render with the default light theme and get
	# lost behind the always_on_top launcher window.
	var tt_panel := StyleBoxFlat.new()
	tt_panel.bg_color = COL_SURFACE_2
	tt_panel.border_color = COL_BORDER
	_sb_border(tt_panel)
	tt_panel.content_margin_left = SP_M
	tt_panel.content_margin_right = SP_M
	tt_panel.content_margin_top = SP_S
	tt_panel.content_margin_bottom = SP_S
	t.set_stylebox("panel", "TooltipPanel", tt_panel)
	t.set_color("font_color", "TooltipLabel", COL_TEXT)
	t.set_font_size("font_size", "TooltipLabel", FS_META)

	# -- AcceptDialog / ConfirmationDialog -------------------------------------
	# The dialog's own panel background + embedded-window border styleboxes.
	var dlg_panel := StyleBoxFlat.new()
	dlg_panel.bg_color = COL_SURFACE
	dlg_panel.border_color = COL_BORDER
	_sb_border(dlg_panel)
	dlg_panel.content_margin_left = 10
	dlg_panel.content_margin_right = 10
	dlg_panel.content_margin_top = 8
	dlg_panel.content_margin_bottom = 8
	t.set_stylebox("panel", "AcceptDialog", dlg_panel)
	t.set_stylebox("panel", "ConfirmationDialog", dlg_panel.duplicate())
	t.set_stylebox("embedded_border",           "Window", dlg_panel.duplicate())
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel.duplicate())
	t.set_color("title_color", "Window", COL_TEXT_HI)

	return t

# -- Theme building blocks + component voices (UI_DESIGN_SPEC.md sections 5-6) --
# These are owned by the theme layer. Call sites opt into a voice via the
# style_* helpers; default buttons take the theme untouched.

# Uniform 1px-border box with the theme's 10/4 button content margins. All
# Button/OptionButton state boxes flow through here so the accent voices
# below can rebuild matching boxes with their own border color.
func _make_button_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	_sb_border(s)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s

# Keyboard-focus ring: 1px amber border, no fill, drawn over the control's
# own stylebox. One amber, everywhere.
func _make_focus_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = COL_AMBER
	_sb_border(s)
	return s

# PRIMARY button voice (Launch Modded, Apply, Get, Save): amber text +
# amber hover border. Outline emphasis only -- never a filled amber CTA.
# At most one per surface.
func style_primary_button(b: Button) -> void:
	_style_accent_button(b, COL_AMBER)

# DANGER button voice (Delete, Unload, disable-content confirm): red text +
# red hover border.
func style_danger_button(b: Button) -> void:
	_style_accent_button(b, COL_ERR)

# Accent voices for DIALOG action buttons (get_ok_button() results). Kept on
# modulate, not the style_* helpers above: a theme font-color override on a
# dialog OK button did not take effect when it was last tried (see
# _confirm_red_launch) and this pass cannot runtime-verify a change, so the
# proven modulate path stays. If a live run shows style_danger_button
# rendering red on a dialog OK button, collapse these two into the style_*
# helpers and delete this note.
func style_dialog_primary_button(b: Button) -> void:
	b.modulate = COL_AMBER

func style_dialog_danger_button(b: Button) -> void:
	b.modulate = COL_ERR

# Shared body of the two accent voices. Everything not overridden here
# (normal/pressed/disabled boxes, focus ring) stays on the theme.
func _style_accent_button(b: Button, accent: Color) -> void:
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", accent)
	b.add_theme_color_override("font_pressed_color", accent)
	# Keep the accent while keyboard-focused: without this the button falls
	# back to the theme's font_focus_color and loses its amber/red the moment
	# it receives focus (e.g. tabbing onto Launch/Apply/Delete).
	b.add_theme_color_override("font_focus_color", accent)
	b.add_theme_font_size_override("font_size", FS_BODY)
	b.add_theme_stylebox_override("hover", _make_button_stylebox(COL_SURFACE_2, accent))

# Badge chip stylebox (update counts, dependency state). Defaults to the
# amber notice look; pass COL_ERR/COL_ERR_DIM for error badges. Pair with
# FS_META + COL_TEXT_HI text at the call site.
func _make_badge_stylebox(border: Color = COL_AMBER, bg: Color = COL_AMBER_DIM) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	_sb_border(s)
	s.content_margin_left = SP_S
	s.content_margin_right = SP_S
	s.content_margin_top = SP_XS
	s.content_margin_bottom = SP_XS
	return s

# Banner builder (offline/cached notice, active modpack, update available):
# a COL_SURFACE strip with a 3px colored left edge -- COL_AMBER for notice,
# COL_ERR for error. Returns {"panel": PanelContainer, "row": HBoxContainer,
# "label": Label} so callers can append action buttons to the row.
func _make_banner(text: String, edge_color: Color) -> Dictionary:
	var panel := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = COL_SURFACE
	s.border_color = edge_color
	s.border_width_left = 3
	s.content_margin_left = SP_L
	s.content_margin_right = SP_L
	s.content_margin_top = SP_M
	s.content_margin_bottom = SP_M
	panel.add_theme_stylebox_override("panel", s)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)
	panel.add_child(row)
	var lbl := Label.new()
	lbl.text = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", FS_BODY)
	row.add_child(lbl)
	return {"panel": panel, "row": row, "label": lbl}

# Relative age for cache timestamps ("just now", "12m ago", "3h ago",
# "2d ago"). Coarse on purpose -- it qualifies how stale cached data is,
# it is not a clock. Input is unix seconds (see _mws_discover_snapshot).
func _format_age(saved_at_unix: int) -> String:
	var delta := int(Time.get_unix_time_from_system()) - saved_at_unix
	if delta < 60:
		return "just now"
	if delta < 60 * 60:
		return "%dm ago" % int(delta / 60.0)
	if delta < 24 * 60 * 60:
		return "%dh ago" % int(delta / 3600.0)
	return "%dd ago" % int(delta / 86400.0)

# Runtime-generated 14x14 checkbox glyph, same code-drawn pattern as the
# pencil/trashcan icons: 1px box on a COL_SURFACE well; checked adds a
# 2px-weight check stroke.
func _make_checkbox_icon(checked: bool, box_color: Color, mark_color: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(1, 13):
		for x in range(1, 13):
			img.set_pixel(x, y, COL_SURFACE)
	for i in range(1, 13):
		img.set_pixel(i, 1, box_color)
		img.set_pixel(i, 12, box_color)
		img.set_pixel(1, i, box_color)
		img.set_pixel(12, i, box_color)
	if checked:
		# Short down-stroke into a long up-stroke, doubled for weight.
		var pts := [
			Vector2i(3, 7), Vector2i(4, 8), Vector2i(5, 9),
			Vector2i(6, 8), Vector2i(7, 7), Vector2i(8, 6),
			Vector2i(9, 5), Vector2i(10, 4),
		]
		for p in pts:
			img.set_pixel(p.x, p.y, mark_color)
			img.set_pixel(p.x, p.y + 1, mark_color)
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 radio glyph (CheckBox in ButtonGroup mode): ring
# on a COL_SURFACE well; checked adds a center dot. Distance-field drawn --
# an octagon-ish ring reads as a circle at this size.
func _make_radio_icon(checked: bool, ring_color: Color, mark_color: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(6.5, 6.5)
	for y in range(14):
		for x in range(14):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if checked and d <= 2.2:
				img.set_pixel(x, y, mark_color)
			elif d <= 4.5:
				img.set_pixel(x, y, COL_SURFACE)
			elif d <= 5.5:
				img.set_pixel(x, y, ring_color)
	return ImageTexture.create_from_image(img)

# Runtime-generated 9x14 SpinBox up/down arrows -- the stock glyph is
# light-theme gray and glares on the dark inputs.
func _make_updown_icon(line: Color) -> ImageTexture:
	var img := Image.create(9, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for row in range(3):
		for x in range(4 - row, 5 + row):
			img.set_pixel(x, 2 + row, line)   # up triangle, apex on top
			img.set_pixel(x, 11 - row, line)  # down triangle, apex on bottom
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 close "X" glyph. Drawn as two ~3px diagonals rather
# than a unicode multiply-sign, so the source stays plain ASCII.
func _make_close_icon(line: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(14):
		for t in range(-1, 2):
			var a := i + t
			if a >= 0 and a < 14:
				img.set_pixel(a, i, line)
				img.set_pixel(a, 13 - i, line)
	return ImageTexture.create_from_image(img)

# Best-effort cached ModWorkshop summary for a mod id, from the Browse discover
# snapshot (popular + latest). Gives the Mods tab an instant thumbnail + author
# for mods already seen in Browse, with no network. {} when not cached -- the
# caller then fetches by id.
func _mods_cached_summary_by_id(mod_id: int) -> Dictionary:
	if mod_id <= 0:
		return {}
	var data_v: Variant = mws_discover_snapshot().get("data")
	if not (data_v is Dictionary):
		return {}
	for key in ["popular", "latest"]:
		var arr_v: Variant = (data_v as Dictionary).get(key)
		if not (arr_v is Array):
			continue
		for row_v in (arr_v as Array):
			if row_v is Dictionary and int((row_v as Dictionary).get("id", 0)) == mod_id:
				return row_v
	return {}

# Populate an installed mod row's ModWorkshop thumbnail + author, and stash the
# mod object so the name link can open the Browse detail dialog (description +
# file history). Cache-first (Browse snapshot), then a by-id fetch only for mods
# the snapshot doesn't cover. All async and best-effort: offline or a failed
# fetch just leaves the gray placeholder and the name link shows a gentle
# notice -- no error, no log spam. The holder Dictionary is captured by the name
# link's lambda, so filling it here wires the click up once data arrives (never
# capture the mod object by value into the lambda -- it isn't known at build).
func _mods_load_mws_meta(mod_id: int, thumb_rect: TextureRect, name_col: VBoxContainer, holder: Dictionary) -> void:
	var data: Dictionary = _mods_mws_meta_by_id.get(mod_id, {})
	if data.is_empty():
		# Skip if a recent attempt failed or is still in flight. The retry window
		# is armed BEFORE the await, so quick racing rebuilds don't each fire a
		# request; successes are memoed for the session below.
		if Time.get_ticks_msec() < int(_mods_mws_meta_retry_at.get(mod_id, 0)):
			return
		_mods_mws_meta_retry_at[mod_id] = Time.get_ticks_msec() + 60000
		data = _mods_cached_summary_by_id(mod_id)
		if data.is_empty():
			var fetched: Variant = await mws_get_mod(mod_id)
			if fetched is Dictionary:
				var obj: Variant = (fetched as Dictionary).get("data", fetched)
				if obj is Dictionary:
					data = obj
		if not data.is_empty():
			_mods_mws_meta_by_id[mod_id] = data
	if data.is_empty():
		return
	holder["data"] = data
	if is_instance_valid(thumb_rect):
		var thumb_record: Variant = data.get("thumbnail")
		if thumb_record is Dictionary:
			_browse_load_thumbnail_async(thumb_rect, thumb_record)
	if is_instance_valid(name_col):
		var user_dict: Dictionary = data.get("user", {}) if data.get("user") is Dictionary else {}
		var author := str(user_dict.get("name", ""))
		if author != "":
			var author_lbl := _make_sub_label("by " + author, COL_TEXT_DIM, "")
			name_col.add_child(author_lbl)
			name_col.move_child(author_lbl, 1)  # right under the name

# Click handler for a Mods-row ModWorkshop name link. Opens the same detail
# dialog the Browse tab uses (banner/thumbnail + author + description + file
# history) once the async load has filled `holder`; until then (or offline) it
# says so instead of opening an empty dialog. Bound with the row's holder dict,
# which _mods_load_mws_meta fills in place.
func _open_mods_mws_detail(holder: Dictionary) -> void:
	if holder.has("data"):
		_show_browse_mod_detail_dialog(holder["data"], func(_d, _b): pass)
	else:
		_show_accept_dialog("ModWorkshop details",
				"Still loading this mod's ModWorkshop page (or it's unavailable offline). Try again in a moment.",
				"Close", 380)

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Active-modpack banner. When a modpack is applied, surface it loudly so
	# the user knows their mod selection isn't their own configuration -- and
	# can unload back to it with one click. Hidden when no modpack is active.
	var active_modpack := get_active_modpack()
	if active_modpack != "":
		var banner := _make_banner(
				"Modpack \"" + active_modpack + "\" is active. Edits save to this modpack's slot.",
				COL_AMBER)
		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		var banner_row: HBoxContainer = banner["row"]
		banner_row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
		outer.add_child(banner["panel"])

	# -- Toolbar (profile selector + folder shortcut + dev toggle) ------------
	# Single row: Open Mods Folder | Profile: [dropdown] [+] [pencil] [trash] | ... | Developer Mode

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open mods folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	# Small visual gap between folder button and profile controls.
	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = SP_L
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window. Our modloader Window is always_on_top,
	# which leaves the popup stranded behind it (invisible on click). Mark the
	# popup always_on_top and transient so it layers over us correctly. Theme
	# assignment is explicit -- theme lookup doesn't always cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Fresh install has no profile sections yet -- show Default as a placeholder
	# that gets materialized on the first _save_ui_config (Launch or any toggle).
	# Filter modpack-managed profiles ("modpack__*", "_before_modpack_*") so
	# they don't appear in the user-facing dropdown -- those are handled by
	# the Modpacks tab and are not user-named profiles.
	var profiles := _list_profiles().filter(func(n: String): return not _is_modpack_managed_profile(n))
	if profiles.is_empty():
		profiles = ["Default"]
	var active_idx := 0  # fall back to first user profile if no match
	for name: String in profiles:
		profile_opt.add_item(name)
		var idx := profile_opt.item_count - 1
		profile_opt.set_item_metadata(idx, name)
		if name == _active_profile:
			active_idx = idx
	profile_opt.selected = active_idx

	# When a modpack is active, the active profile is "modpack__X" which the
	# filter above hides -- so the dropdown's selection defaults back to
	# Vanilla which is misleading. Disable the dropdown (and replace its
	# label) so it's clear the user has to Unload the modpack via the banner
	# to interact with regular profiles.
	if active_modpack != "":
		profile_opt.clear()
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true

	# Profile-mutation buttons. Delete needs at least one other profile to
	# switch to. ALL profile mutations are disabled while a modpack is
	# active -- the active profile slot is modpack-managed (modpack__X) and
	# shouldn't be renamed/deleted/created-from.
	var modpack_locked := active_modpack != ""
	# Whether mod state in the active profile can be edited at all. Vanilla is
	# the all-off sentinel (no stored profile to write to) and a modpack-locked
	# slot is managed by the pack -- in both, the per-row dependency quick
	# actions (Enable dependency / Load anyway / Re-check) would mutate state
	# that _save_ui_config won't persist, so they're hidden. (Restores the
	# on_vanilla gate the Modpacks merge dropped, now also covering the lock.)
	var profile_editable := _active_profile != VANILLA_PROFILE and not modpack_locked

	var new_profile_btn := Button.new()
	new_profile_btn.text = "+"
	new_profile_btn.tooltip_text = "New profile from current mod selection" if not modpack_locked else "Unload the active modpack first"
	new_profile_btn.disabled = modpack_locked
	new_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(new_profile_btn)
	_wire_hint(new_profile_btn, "New profile from current mod selection.")

	var rename_btn := Button.new()
	rename_btn.icon = _make_pencil_icon()
	rename_btn.tooltip_text = "Rename the active profile" if not modpack_locked else "Unload the active modpack first"
	rename_btn.disabled = modpack_locked
	rename_btn.custom_minimum_size.x = 28
	toolbar.add_child(rename_btn)
	_wire_hint(rename_btn, "Rename the active profile.")

	# Delete needs at least one other profile to switch to.
	var del_profile_btn := Button.new()
	del_profile_btn.icon = _make_trashcan_icon()
	del_profile_btn.tooltip_text = "Delete the active profile" if not modpack_locked else "Unload the active modpack first"
	del_profile_btn.disabled = profiles.size() <= 1 or modpack_locked
	del_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(del_profile_btn)
	_wire_hint(del_profile_btn, "Delete the active profile.")

	# Share/save/load lives in the Modpacks tab.

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", FS_BODY)
	dev_check.add_theme_color_override("font_color", COL_TEXT_DIM)
	toolbar.add_child(dev_check)
	_wire_hint(dev_check, "Developer mode: verbose logging, conflict report, and loose folder loading.")

	profile_opt.item_selected.connect(func(idx: int):
		var meta = profile_opt.get_item_metadata(idx)
		_switch_profile(str(meta))
		_rebuild_mods_tab(tabs)
	)
	new_profile_btn.pressed.connect(func(): _show_new_profile_dialog(tabs))
	rename_btn.pressed.connect(func(): _show_rename_profile_dialog(tabs))
	del_profile_btn.pressed.connect(func(): _show_delete_confirm(tabs))

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		# Persist the new developer_mode (load-affecting: it changes which
		# mods are eligible). The boot launcher is rescued by the Launch-time
		# save, but the post-boot reopen path has no closing save, so without
		# this the toggle silently reverts next launch.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: filter bar + mod list ------------------------------------------

	# Sticky filter bar above the scroll so it stays in view while the user
	# scrolls a long mod list.
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)

	# Filter bar (W2/W3): name search + All / None toggles + Hide disabled.
	# The All/None handlers respect the active filter so a search-narrowed
	# list only toggles the visible subset. Hide disabled is per-profile;
	# Vanilla disables the toggles since rows are forced off there anyway.
	var filter_bar := HBoxContainer.new()
	filter_bar.add_theme_constant_override("separation", SP_M)
	left_col.add_child(filter_bar)

	var filter_edit := LineEdit.new()
	filter_edit.placeholder_text = "Filter mods..."
	filter_edit.text = _mods_filter_text
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_bar.add_child(filter_edit)

	var all_btn := Button.new()
	all_btn.text = "Enable all"
	all_btn.tooltip_text = "Enable every visible mod"
	filter_bar.add_child(all_btn)
	_wire_hint(all_btn, "Enable every visible mod (respects the search filter).")

	var none_btn := Button.new()
	none_btn.text = "Disable all"
	none_btn.tooltip_text = "Disable every visible mod"
	filter_bar.add_child(none_btn)
	_wire_hint(none_btn, "Disable every visible mod (respects the search filter).")

	var hide_check := CheckBox.new()
	hide_check.text = "Hide disabled"
	hide_check.tooltip_text = "Hide rows for mods that are disabled in this profile"
	hide_check.button_pressed = _mods_hide_disabled
	hide_check.add_theme_font_size_override("font_size", FS_BODY)
	filter_bar.add_child(hide_check)
	_wire_hint(hide_check, "Hide rows for mods that are disabled in this profile.")

	# Check Updates: queries ModWorkshop for every installed mod with valid
	# [updates] modworkshop= + version. Populates _mod_updates_state so the
	# rows below show per-mod "update available" badges without users having
	# to switch to the Updates tab. The Updates tab stays around for the
	# bulk-status view.
	var check_btn := Button.new()
	# "Checking..." not "Checking for updates..." here: the filter bar is
	# space-constrained and a wide button squeezes the filter box mid-check.
	check_btn.text = "Check for updates"
	if _mod_updates_check_in_progress:
		check_btn.disabled = true
		check_btn.text = "Checking..."
	filter_bar.add_child(check_btn)
	_wire_hint(check_btn, "Query ModWorkshop for newer versions of every installed mod with update info.")
	check_btn.pressed.connect(func():
		if _mod_updates_check_in_progress:
			return
		check_btn.disabled = true
		check_btn.text = "Checking..."
		var summary := await _run_updates_check_for_mods()
		# A mid-check rebuild (filter keystroke, toggle) frees the original
		# button -- only skip the direct button touches then; the rebuild and
		# the toast must still run or the completed check's results are
		# silently dropped and the NEW button (created disabled while the
		# flag was up) strands at "Checking...".
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		# Surface a one-liner so the user knows something happened even when
		# nothing is out of date -- and be honest when checks ERRORED rather
		# than counting unreachable mods as "up to date".
		var n := int(summary.get("with_updates", 0))
		var ck := int(summary.get("checked", 0))
		var er := int(summary.get("errors", 0))
		var msg := ""
		if ck == 0:
			msg = "No mods have [updates] modworkshop= + version set."
		elif er >= ck:
			msg = "Could not reach ModWorkshop. Check your connection and try again."
		elif n == 0:
			msg = "Everything is up to date. Checked %d mod(s)." % (ck - er)
			if er > 0:
				msg += " %d could not be checked." % er
		else:
			msg = "%d update(s) available." % n
			if er > 0:
				msg += " %d could not be checked." % er
		# Only toast while the launcher window still exists. If the user
		# clicked Launch (or closed the launcher) mid-check, _ui_window is
		# null and _attach_ui_dialog would parent an exclusive always-on-top
		# dialog to the game's root -- stealing input mid-game. The rebuild
		# above already covered the surviving-UI case.
		if is_instance_valid(_ui_window):
			_show_info_toast(msg)
	)

	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		# Each text_changed rebuilds the tab; restore focus afterward so the
		# user can keep typing. Flag is consumed on the next build below.
		_mods_filter_focus_pending = true
		_rebuild_mods_tab(tabs)
	)
	all_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		# Bulk None disables content mods too -- run the same save-compatibility
		# confirm the per-row checkbox uses, once for the whole batch.
		var content_count := 0
		var content_name := ""
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry) and bool(entry.get("enabled", false)) \
					and bool(entry.get("has_registry", false)):
				content_count += 1
				if content_name == "":
					content_name = str(entry.get("mod_name", "this mod"))
		if content_count > 0:
			var ok: bool = await _confirm_disable_content_mod(content_name, content_count)
			if not ok:
				return
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = false
		_save_ui_config()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	hide_check.toggled.connect(func(on: bool):
		_mods_hide_disabled = on
		_save_per_profile_setting("hide_disabled", on)
		_rebuild_mods_tab(tabs)
	)

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(left_scroll)
	_ui_mods_scroll = left_scroll

	# Right padding keeps the load-order SpinBox arrows from sitting flush
	# against the vertical scrollbar -- users were hitting the spin arrows
	# while trying to drag the scrollbar handle.
	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", SP_XL)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_child(list)

	# -- Right: live load order preview ----------------------------------------

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load order"
	order_header.add_theme_font_size_override("font_size", FS_HEAD)
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	# Dark panel behind the load order list for visual separation.
	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_SURFACE_2
	panel_style.content_margin_left = SP_M
	panel_style.content_margin_right = SP_M
	panel_style.content_margin_top = SP_M
	panel_style.content_margin_bottom = SP_M
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Belt-and-suspenders against the autowrap/scrollbar layout-oscillation bug
	# guarded below: pin the scrollbar to always-visible so it can't flip on/off
	# at the bistable height threshold. With this set, even if a future change
	# reintroduces autowrap on the order labels, the inner width stays constant
	# (no width oscillation -> no reshape feedback loop). See refresh_order.
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	# Rebuilds the right-side order list from current entry state.
	var refresh_order := func():
		_refresh_dependency_status()
		for child in order_list.get_children():
			child.queue_free()
		# Same pick the loader itself uses -- the panel shows the EFFECTIVE
		# order (priority sort + dependency hoist), so what you see is what
		# mounts.
		var pick := _loadable_enabled_entries()
		var loadable: Array = pick["loadable"]
		var enabled_count := int(pick["enabled_count"])
		if enabled_count == 0:
			var lbl := Label.new()
			lbl.text = "No mods enabled"
			lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			order_list.add_child(lbl)
			return
		if loadable.is_empty():
			# This panel is narrow: short lines with a MANUAL break
			# (deterministic -- never autowrap here, see the oscillation fix).
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_AMBER,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", FS_EMPH)
			lbl.add_theme_color_override("font_color", COL_TEXT)
			# Previously AUTOWRAP_WORD_SMART. That combo (autowrap label inside
			# a fixed-width ScrollContainer) hits a Godot 4.6 layout-oscillation
			# bug: at certain (label count, text width) combinations the vertical
			# scrollbar's appearance shrinks the inner width by ~16px, which
			# triggers re-wrap, which changes total height, which flips scrollbar
			# visibility, etc. The oscillation floods the message queue with
			# deferred resize notifications and crashes with "Message queue out
			# of memory" + "Object was deleted while awaiting a callback" --
			# reproducible at 9 enabled mods with long names like
			# "RTVModLib Compatibility Layer". clip_text + tooltip preserves the
			# visual intent without engaging autowrap.
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Status-line hint, kept for the launcher's consistent hover-hint UX
			# (the old strand-behind-the-window tooltip bug is gone now that the
			# window embeds sub-windows). Full name shows in the bottom hint.
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			order_list.add_child(lbl)
			_wire_hint(lbl, str(e["mod_name"]))
		if bool(pick["adjusted"]):
			var reorder_lbl := _make_sub_label("reordered for dependencies", COL_TEXT_DIM)
			order_list.add_child(reorder_lbl)
			_wire_hint(reorder_lbl, "A required dependency sat below its dependent in priority order, so it was hoisted. Priorities otherwise unchanged.")
		var blocked_count := enabled_count - loadable.size()
		if blocked_count > 0:
			var blocked_lbl := _make_sub_label("%d blocked (deps)" % blocked_count, COL_AMBER)
			order_list.add_child(blocked_lbl)
			_wire_hint(blocked_lbl, "Blocked mods stay checked but don't load. See the orange row warnings for fixes.")

	# -- Updates available ----------------------------------------------------
	# Compact triage list of mods with newer versions on ModWorkshop. Source
	# is _mod_updates_state which is populated by Check Updates in this tab
	# or in the Updates tab. Compact rows here so a long list (20+) stays
	# scannable; the regular mod rows below are unchanged (no bubbling, no
	# extra subsection) so this view doesn't compete with mod management.
	var update_keys: Array = []
	for entry_v in _ui_mod_entries:
		var pk_check: String = str(entry_v.get("profile_key", ""))
		if _mod_updates_state.has(pk_check):
			update_keys.append(pk_check)
	if not update_keys.is_empty():
		var u_hdr_row := HBoxContainer.new()
		u_hdr_row.add_theme_constant_override("separation", SP_S)
		list.add_child(u_hdr_row)
		var u_hdr := Label.new()
		u_hdr.text = "Updates available"
		u_hdr.add_theme_color_override("font_color", COL_AMBER)
		# FS_HEAD to match the "Missing from this profile" header on this
		# same list (spec: section headings at FS_HEAD; color carries the
		# semantic difference).
		u_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		u_hdr_row.add_child(u_hdr)
		# Count as an amber badge chip (the spec's one update-badge look).
		var u_badge := Label.new()
		u_badge.text = str(update_keys.size())
		u_badge.add_theme_stylebox_override("normal", _make_badge_stylebox())
		u_badge.add_theme_font_size_override("font_size", FS_META)
		u_badge.add_theme_color_override("font_color", COL_TEXT_HI)
		u_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		u_hdr_row.add_child(u_badge)
		list.add_child(HSeparator.new())

		for pk: String in update_keys:
			var upd: Dictionary = _mod_updates_state[pk]
			var upd_row := HBoxContainer.new()
			upd_row.add_theme_constant_override("separation", SP_L)
			list.add_child(upd_row)

			var u_name := Label.new()
			u_name.text = str(upd.get("mod_name", "?"))
			u_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			u_name.clip_text = true
			u_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_name.tooltip_text = str(upd.get("mod_name", "?"))
			# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
			u_name.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_name)

			var u_ver := Label.new()
			u_ver.text = "v%s  ->  v%s" % [str(upd.get("current_version", "?")), str(upd.get("latest_version", "?"))]
			u_ver.add_theme_color_override("font_color", COL_TEXT)
			u_ver.add_theme_font_size_override("font_size", FS_BODY)
			u_ver.custom_minimum_size.x = 160
			upd_row.add_child(u_ver)

			var u_btn := Button.new()
			u_btn.text = "Update"
			upd_row.add_child(u_btn)
			_wire_hint(u_btn, "Download the latest version and replace the file in place.")
			var captured_pk := pk
			var captured_upd := upd
			# If a download for this pk is already running (this row was rebuilt
			# mid-download), render the button inert instead of a fresh "Update".
			if _mod_update_in_flight.has(pk):
				u_btn.disabled = true
				u_btn.text = "Updating..."
			u_btn.pressed.connect(func():
				if not is_instance_valid(u_btn):
					return
				# Refuse a second concurrent download of the same mod.
				if _mod_update_in_flight.has(captured_pk):
					return
				_mod_update_in_flight[captured_pk] = true
				u_btn.disabled = true
				u_btn.text = "Updating..."
				var mw_id: int = int(captured_upd.get("mw_id", 0))
				# Re-resolve the path live: another surface (Updates tab) may have
				# updated/renamed this file since the badge row was built, which
				# would leave the captured path pointing at a file that no longer
				# exists (the repeatable "Update Failed").
				var full_path: String = _live_full_path(captured_pk, str(captured_upd.get("full_path", "")))
				var result: Dictionary = await download_and_replace_mod(full_path, mw_id)
				_mod_update_in_flight.erase(captured_pk)
				if bool(result.get("ok", false)):
					_mod_updates_state.erase(captured_pk)
					_reload_entries_for_active_profile()
					if is_instance_valid(tabs):
						_rebuild_mods_tab(tabs)
				else:
					if is_instance_valid(u_btn):
						u_btn.disabled = false
						u_btn.text = "Update"
					# Error pattern: what happened + what to do next; never a
					# bare "unknown".
					var err_name := str(captured_upd.get("mod_name", "this mod"))
					var err_msg := "Could not download %s. Check your connection and try again." % err_name
					var err_detail := str(result.get("error", ""))
					if err_detail != "" and err_detail != "unknown":
						err_msg += "\n\nDetails: " + err_detail
					# Only surface the dialog if the launcher is still open. If the
					# user hit Launch mid-download, _ui_window is freed and
					# _attach_ui_dialog would parent an exclusive, always-on-top
					# dialog to the game root, stealing input mid-session (same
					# guard the check-updates toast uses).
					if is_instance_valid(_ui_window):
						_show_error_dialog("Update failed", err_msg)
			)
			list.add_child(HSeparator.new())

	# -- Missing from this profile --------------------------------------------
	# Mods the active profile references but that aren't on disk. Shown at the
	# top of the list so they get attention before the regular mod rows; each
	# has a Remove button to strip the orphaned keys from the profile. Future:
	# offer to download via modworkshop if an id is stored.
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		# Header row: label on the left, "Remove all" on the right (W4) so a
		# user with a long migration trail can clear every orphan in one click
		# instead of hammering per-row Remove buttons.
		var missing_hdr_row := HBoxContainer.new()
		list.add_child(missing_hdr_row)
		var missing_hdr := Label.new()
		missing_hdr.text = "Missing from this profile"
		missing_hdr.add_theme_color_override("font_color", COL_ERR)
		missing_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		missing_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		missing_hdr_row.add_child(missing_hdr)
		var remove_all_btn := Button.new()
		remove_all_btn.text = "Remove all"
		remove_all_btn.tooltip_text = "Strip every missing-mod entry from the active profile"
		missing_hdr_row.add_child(remove_all_btn)
		_wire_hint(remove_all_btn, "Strip every missing-mod entry from the active profile.")
		remove_all_btn.pressed.connect(func():
			var n := missing_files.size()
			var d := ConfirmationDialog.new()
			d.title = "Remove missing-mod entries"
			d.dialog_text = "Strip %d missing-mod entr%s from \"%s\"?\n\nOnly the active profile is affected. Other profiles keep their references." % [
				n, ("y" if n == 1 else "ies"), _active_profile,
			]
			d.ok_button_text = "Remove"
			_attach_ui_dialog(d)
			style_dialog_danger_button(d.get_ok_button())
			_connect_dialog_exits(d,
				func():
					d.queue_free()
					_remove_all_missing_entries_from_profile()
					_rebuild_mods_tab(tabs),
				func(): d.queue_free())
			d.popup_centered()
		)
		list.add_child(HSeparator.new())
		# Compute sources once per Mods-tab build, not per row. Covers
		# persisted cache (any profile) + active modpack zip overlay.
		var missing_sources := _missing_mod_sources_combined()
		for fn: String in missing_files:
			var miss_row := HBoxContainer.new()
			list.add_child(miss_row)
			var miss_lbl := Label.new()
			var display := fn.trim_prefix("zip:")
			miss_lbl.text = display + "  --  not installed"
			miss_lbl.add_theme_color_override("font_color", COL_ERR)
			miss_lbl.clip_text = true
			miss_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			miss_lbl.tooltip_text = miss_lbl.text
			miss_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			miss_row.add_child(miss_lbl)

			# Download button when the active modpack carries source info for
			# this entry. Falls back to just Remove when no source is known --
			# e.g. user manually disabled a mod then deleted the file, or the
			# modpack zip is gone.
			var src_v: Variant = missing_sources.get(fn)
			var src_mws_id: int = 0
			var src_version: String = ""
			if src_v is Dictionary:
				var src: Dictionary = src_v
				src_mws_id = int(src.get("modworkshop_id", 0))
				src_version = str(src.get("version", ""))
			if src_mws_id > 0:
				var dl_btn := Button.new()
				dl_btn.text = "Download"
				dl_btn.tooltip_text = "Download this mod from ModWorkshop"
				miss_row.add_child(dl_btn)
				_wire_hint(dl_btn, "Download this mod from ModWorkshop.")
				var captured_mws_id := src_mws_id
				var captured_version := src_version
				dl_btn.pressed.connect(func():
					if not is_instance_valid(dl_btn):
						return
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
					# allow_rename_on_collision=true: a different version may
					# already exist under the same filename. Dedup at scan time.
					var r: Dictionary = await download_new_mod(captured_mws_id, captured_version, true)
					if bool(r.get("ok", false)):
						_reload_entries_for_active_profile()
						if is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
					else:
						if is_instance_valid(dl_btn):
							dl_btn.disabled = false
							dl_btn.text = "Download"
						# Suppress the dialog if the launcher closed mid-download
						# (Launch pressed): _attach_ui_dialog would otherwise pop an
						# exclusive always-on-top window over the running game.
						if is_instance_valid(_ui_window):
							_show_error_dialog("Download failed", str(r.get("error", "unknown")))
				)
			else:
				# No source info -- name what's unavailable, not the data we
				# lack. Matches r2modman/Vortex pattern of action-clear
				# state strings. Label defaults to MOUSE_FILTER_IGNORE in
				# Godot 4, so explicit STOP is required for hover signals.
				var no_src_lbl := Label.new()
				no_src_lbl.text = "Download unavailable"
				no_src_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
				no_src_lbl.add_theme_font_size_override("font_size", FS_BODY)
				no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
				miss_row.add_child(no_src_lbl)
				_wire_hint(no_src_lbl,
					"This mod has no recorded ModWorkshop source. Reinstall it manually, or set [updates] modworkshop=N in its mod.txt if you have a local copy.")

			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Strip this entry from the active profile"
			miss_row.add_child(remove_btn)
			_wire_hint(remove_btn, "Strip this entry from the active profile.")
			var captured := fn
			remove_btn.pressed.connect(func():
				_remove_missing_entry_from_profile(captured)
				_rebuild_mods_tab(tabs)
			)
			list.add_child(HSeparator.new())

	# -- Column headers --------------------------------------------------------

	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.add_theme_font_size_override("font_size", FS_META)
	h_on.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	# Spacer over the per-row ModWorkshop thumbnail column so "Mod" stays above
	# the name text rather than the thumbnails.
	var h_thumb := Control.new()
	h_thumb.custom_minimum_size.x = 96
	header_row.add_child(h_thumb)

	var h_name := Label.new()
	h_name.text = "Mod"
	h_name.add_theme_font_size_override("font_size", FS_META)
	h_name.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "Load order"
	h_prio.add_theme_font_size_override("font_size", FS_META)
	h_prio.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	# Spacer matching the per-row trash button (28px) so the Load order
	# header sits over the SpinBox column instead of the trash column.
	var h_tail := Control.new()
	h_tail.custom_minimum_size.x = 28
	header_row.add_child(h_tail)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(empty)

	# Track whether any row passed the filter so we can show a hint when a
	# search or hide-disabled toggle narrows the list to zero rows.
	var rendered_any := false
	for entry in _ui_mod_entries:
		if not _mods_entry_visible(entry):
			continue
		rendered_any = true
		var row := HBoxContainer.new()
		list.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 30
		row.add_child(check)

		# ModWorkshop info column, for mods that declare [updates] modworkshop=N.
		# Thumbnail (filled async) + author line + the name as a click-through to
		# the same detail dialog the Browse tab uses -- so a mod's page,
		# screenshots and description read in-app without hunting it down in
		# Browse. Non-MWS mods get a same-width spacer so the name column stays
		# aligned across every row.
		var row_cfg: ConfigFile = entry.get("cfg")
		var row_mws_id := 0
		if row_cfg != null and row_cfg.has_section_key("updates", "modworkshop"):
			row_mws_id = int(str(row_cfg.get_value("updates", "modworkshop", "0")))
		var mws_holder: Dictionary = {}
		var thumb_ref: TextureRect = null
		if row_mws_id > 0:
			var thumb_wrap := PanelContainer.new()
			thumb_wrap.custom_minimum_size = Vector2(96, 54)
			thumb_wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var thumb_style := StyleBoxFlat.new()
			thumb_style.bg_color = COL_SURFACE_2
			thumb_wrap.add_theme_stylebox_override("panel", thumb_style)
			row.add_child(thumb_wrap)
			var thumb_rect := TextureRect.new()
			thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			thumb_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			thumb_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
			thumb_wrap.add_child(thumb_rect)
			thumb_ref = thumb_rect
		else:
			var thumb_gap := Control.new()
			thumb_gap.custom_minimum_size.x = 96
			row.add_child(thumb_gap)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_col)

		# name_ctrl is a LinkButton (MWS mods -> click for details) or a plain
		# Label; both take the enabled/blocked font-color overrides below.
		var name_ctrl: Control
		if row_mws_id > 0:
			# Flat Button (not LinkButton) so clip_text keeps a long name from
			# inflating the row's min width and forcing a horizontal scrollbar on
			# the whole list. Hover color is the click cue in place of underline.
			var name_lnk := Button.new()
			name_lnk.flat = true
			name_lnk.text = entry["mod_name"]
			name_lnk.clip_text = true
			name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
			name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lnk.tooltip_text = str(entry["mod_name"]) + "  --  click for ModWorkshop details"
			name_lnk.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
			name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
			name_col.add_child(name_lnk)
			name_lnk.pressed.connect(_open_mods_mws_detail.bind(mws_holder))
			_mods_load_mws_meta(row_mws_id, thumb_ref, name_col, mws_holder)
			name_ctrl = name_lnk
		else:
			var name_lbl := Label.new()
			name_lbl.text = entry["mod_name"]
			name_lbl.clip_text = true
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lbl.tooltip_text = str(entry["mod_name"])
			# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
			name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			name_lbl.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
			name_col.add_child(name_lbl)
			name_ctrl = name_lbl

		if entry["ext"] == "folder":
			var dev_lbl := Label.new()
			dev_lbl.text = "[dev folder]"
			dev_lbl.add_theme_color_override("font_color", COL_ERR)
			dev_lbl.add_theme_font_size_override("font_size", FS_BODY)
			name_col.add_child(dev_lbl)
		# -- Dependencies ------------------------------------------------------
		# One compact clipped line when the mod declares dependencies (names
		# over raw ids, full detail in the tooltip); the actionable blocked
		# row renders further down, after the generic warnings. No autowrap
		# anywhere in rows -- see the order-panel oscillation fix.
		var required_deps: Array = entry.get("required_dependencies", [])
		var optional_deps: Array = entry.get("optional_dependencies", [])
		var blockers_info: Array = entry.get("dependency_blockers_info", [])
		var dep_ignored := bool(entry.get("dependency_ignored", false))
		var dep_blocked: bool = entry["enabled"] \
				and not (entry.get("dependency_blockers", []) as Array).is_empty()
		if dep_blocked:
			# The green "enabled" tint would lie -- this mod won't load.
			name_ctrl.add_theme_color_override("font_color", COL_AMBER)
		if required_deps.size() > 0 or optional_deps.size() > 0:
			var named := PackedStringArray()
			for d in required_deps:
				named.append(_dependency_display_for_id(str(d)))
			var dep_line := ""
			if named.size() > 0:
				dep_line = "needs: " + ", ".join(named)
			if optional_deps.size() > 0:
				if dep_line != "":
					dep_line += "  (+%d optional)" % optional_deps.size()
				else:
					dep_line = "%d optional integration(s)" % optional_deps.size()
			var tip := PackedStringArray()
			for d in required_deps:
				tip.append("requires %s (%s)" % [_dependency_display_for_id(str(d)), str(d)])
			for d in optional_deps:
				tip.append("optional: %s (%s)" % [_dependency_display_for_id(str(d)), str(d)])
			name_col.add_child(_make_sub_label(dep_line, COL_TEXT_DIM, "\n".join(tip)))
		for warn_text: String in entry.get("warnings", []):
			name_col.add_child(_make_sub_label(warn_text, COL_AMBER, warn_text))
		for warn_text: String in entry.get("dependency_warnings", []):
			name_col.add_child(_make_sub_label(warn_text, COL_AMBER, warn_text))

		# Blocked: one orange line that says WHY + buttons that FIX it.
		# A warning the user can't act on is just decoration.
		if dep_blocked and not blockers_info.is_empty():
			var block_row := HBoxContainer.new()
			block_row.add_theme_constant_override("separation", SP_M)
			name_col.add_child(block_row)
			var first: Dictionary = blockers_info[0]
			# display already reads "Name (id)" for installed deps; a dash, not
			# another paren, so it doesn't render "...(id) (installed but...)".
			var why := "%s -- %s" % [str(first.get("display", "")),
					_dependency_status_label(str(first.get("status", "")))]
			if blockers_info.size() > 1:
				why += "  +%d more" % (blockers_info.size() - 1)
			var btip := PackedStringArray()
			for b in blockers_info:
				btip.append("%s -- %s" % [str(b.get("display", "")),
						_dependency_status_label(str(b.get("status", "")))])
				if str(b.get("status", "")) == "hidden_folder":
					btip.append("  (turn on Developer mode to load folder mods)")
			var bl := _make_sub_label("won't load -- needs " + why, COL_AMBER, "\n".join(btip))
			bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			block_row.add_child(bl)
			var fixable_count := 0
			for b in blockers_info:
				if bool(b.get("fixable", false)):
					fixable_count += 1
			var e_dep := entry
			if fixable_count > 0 and profile_editable:
				var fix_btn := _make_row_action(
						"Enable " + ("%d dependencies" % fixable_count \
								if fixable_count > 1 else "dependency"),
						COL_OK,
						"Turn on the required mod(s) -- installed, just disabled.")
				block_row.add_child(fix_btn)
				fix_btn.pressed.connect(func():
					_enable_required_deps(e_dep)
					_after_dep_action(tabs)
				)
			if profile_editable:
				var anyway_btn := _make_row_action("Load anyway", COL_TEXT_DIM,
						"Skip the dependency check for this mod in this profile.\nFor when a requirement is declared wrong or you know better.")
				block_row.add_child(anyway_btn)
				anyway_btn.pressed.connect(func():
					e_dep["dependency_ignored"] = true
					_after_dep_action(tabs)
				)
		elif dep_ignored and not blockers_info.is_empty():
			# Override active while requirements are still unmet: show what's
			# being ignored and the way back.
			var ov_row := HBoxContainer.new()
			ov_row.add_theme_constant_override("separation", SP_M)
			name_col.add_child(ov_row)
			var missing_names := PackedStringArray()
			for b in blockers_info:
				missing_names.append(str(b.get("display", "")))
			var ov := _make_sub_label("dependency check off -- missing: " + ", ".join(missing_names),
					COL_TEXT_DIM,
					"This mod loads even though requirements are unmet\n(per-profile override). Re-check restores the normal rule.")
			ov.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ov_row.add_child(ov)
			if profile_editable:
				var e_dep2 := entry
				var recheck_btn := _make_row_action("Re-check", COL_TEXT_DIM)
				ov_row.add_child(recheck_btn)
				recheck_btn.pressed.connect(func():
					e_dep2["dependency_ignored"] = false
					_after_dep_action(tabs)
				)

		# Older same-id archives the dedup pass hid. Surface the filename
		# so the user knows which one to delete from the mods/ folder.
		for dup: Dictionary in entry.get("duplicates_hidden", []):
			var dup_v_raw: String = str(dup.get("version", ""))
			var dup_v: String = ("v" + dup_v_raw) if dup_v_raw != "" else "(unversioned)"
			var hide_text := "older version hidden: " + str(dup["file_name"]) + " (" + dup_v + ")"
			name_col.add_child(_make_sub_label(hide_text, COL_AMBER, hide_text))

		# Profile was saved with a different version of this mod. Surface the
		# change so the user knows their enabled/priority state was carried
		# over across the upgrade/downgrade rather than silently re-defaulted.
		var vm: Dictionary = entry.get("profile_version_mismatch", {})
		if not vm.is_empty():
			var stored_v: String = str(vm.get("stored", ""))
			var current_v: String = str(vm.get("current", ""))
			var stored_disp := stored_v if stored_v != "" else "(unset)"
			var current_disp := current_v if current_v != "" else "(unset)"
			var vm_text := "profile version: " + stored_disp + " -> " + current_disp
			name_col.add_child(_make_sub_label(vm_text, COL_AMBER, vm_text))

		# Scanner indicator. Only renders for RED risk -- mods whose source
		# combines patterns that are nearly diagnostic of malware (dropper
		# trinity, anti-debug crash, ransomware setup). Yellow ("uses
		# notable APIs") is computed and logged but deliberately not shown
		# in the UI: most legit mods have at least one elevated API and
		# surfacing every one would just generate help-channel noise.
		# Loading is never blocked either way; the user judges.
		var risk: int = int(entry.get("risk_level", 0))
		if risk == 2:
			var sec_btn := Button.new()
			sec_btn.text = "suspicious code"
			sec_btn.flat = true
			sec_btn.tooltip_text = "Show what the scanner flagged in this mod"
			sec_btn.add_theme_color_override("font_color", COL_ERR)
			# Brightened on hover: flat buttons have no hover stylebox, so
			# the font shift is the only hover cue (matches _make_row_action).
			sec_btn.add_theme_color_override("font_hover_color", COL_ERR.lerp(COL_TEXT_HI, 0.35))
			sec_btn.add_theme_font_size_override("font_size", FS_BODY)
			sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(sec_btn)
			var captured_entry := entry
			sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		row.add_child(spin)

		# Per-row Remove. Folder mods (dev) skip the file delete because
		# DirAccess.remove_absolute is for files only and recursive deletion
		# of a working directory is too risky to do casually -- the user
		# can use Open Mods Folder for those.
		var remove_btn := Button.new()
		remove_btn.icon = _make_trashcan_icon()
		remove_btn.flat = true
		remove_btn.custom_minimum_size.x = 28
		remove_btn.disabled = entry["ext"] == "folder"
		if entry["ext"] == "folder":
			remove_btn.tooltip_text = "Use Open mods folder to remove dev folders"
		else:
			remove_btn.tooltip_text = "Permanently delete this mod"
		row.add_child(remove_btn)
		var captured_remove_entry := entry
		remove_btn.pressed.connect(func():
			_show_remove_mod_confirm(captured_remove_entry, tabs)
		)

		list.add_child(HSeparator.new())

		# Capture entry by reference (Dictionaries are reference types in GDScript)
		var e := entry
		check.toggled.connect(func(on: bool):
			# Disabling a mod that registers game content can stop an existing
			# save that uses it from loading (the content lives only in the
			# per-launch registry -- see Limitations). Confirm first; if the user
			# backs out, revert the checkbox without re-firing toggled.
			if not on and bool(e.get("has_registry", false)):
				var ok: bool = await _confirm_disable_content_mod(str(e.get("mod_name", "this mod")))
				if not ok:
					# An async rebuild (e.g. an updates check finishing) may
					# have freed this checkbox while the dialog was open; the
					# rebuilt row already renders from the unchanged entry.
					if is_instance_valid(check):
						check.set_pressed_no_signal(true)
					return
			# Apply to the LIVE entry dict regardless of whether the original
			# checkbox survived a mid-dialog rebuild. The captured dict stays
			# live across rebuilds, but a mid-dialog RESCAN (e.g. a Browse
			# download finishing) replaces _ui_mod_entries with fresh dicts --
			# re-resolve so a confirmed disable is never dropped.
			var live := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
			live["enabled"] = on
			# Full rebuild via the shared tail: dependency state on OTHER
			# rows changes with the new enabled set.
			_after_dep_action(tabs)
		)
		spin.value_changed.connect(func(val: float):
			e["priority"] = int(val)
			# No rebuild here: value_changed fires per step while the arrows
			# are held, and rebuilding would destroy the SpinBox under the
			# cursor. refresh_order recomputes dependency status for the
			# order panel; per-row order warnings catch up on the next
			# rebuild (toggle, filter, profile switch, tab re-entry).
			refresh_order.call()
			# Debounce the disk save: holding/scrolling the arrow fires
			# value_changed per step (200+ over one drag), and each
			# _save_ui_config is a full ConfigFile load+rewrite. Coalesce to a
			# save shortly after activity settles; the launch-time save in
			# lifecycle catches the final value regardless.
			_schedule_priority_save()
		)

	# Filter narrowed every row out -- distinguish from "no mods installed"
	# (handled above by the _ui_mod_entries.is_empty() branch) so the user
	# knows the filter, not a missing folder, is the cause.
	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match. Try a shorter search or turn off Hide disabled."
		no_match.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_match.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(no_match)

	# Restore focus to the search input after a filter-driven rebuild.
	# Deferred so the new tab is in the tree before grab_focus runs.
	# Cleared on consume so unrelated rebuilds (profile switch, dev toggle)
	# don't steal focus from whatever the user is interacting with.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text resets the caret to column 0 (Godot 4.6
		# LineEdit::_set_text), and FOCUS_ENTER doesn't move it -- so without
		# this every keystroke after the first inserts at the FRONT ("dep"
		# typed -> "ped"). Restore the caret to end-of-text after focus lands.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	# Wrap in the shared tab margin like build_browse_tab / build_modpacks_tab /
	# build_updates_tab, so the Mods tab has the same content padding and the
	# view doesn't visibly shift when switching between tabs.
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin

func build_browse_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Shared mutable state. Lambdas capture primitives by VALUE in GDScript;
	# routing through a Dictionary lets all the closures (search/sort/category
	# handlers, load-more, do_get) read and mutate the same fields. "discover"
	# mode hits popular-and-latest; any user input flips to "filter" mode which
	# uses the paginated list_mods endpoint.
	var state := {
		"mode": "discover",
		"query": "",
		"sort": "bumped_at",
		"category_id": 0,
		"next_page": 1,
		"has_more": false,
		# fetch_seq: monotonic counter incremented at the START of every list
		# fetch (discover or filter). Each fetch captures its own seq, then
		# checks it after await; if state["fetch_seq"] has advanced, a newer
		# fetch is in flight and this one's result must NOT render. Without
		# this guard, rapid sort/category clicks let the slowest response win
		# whichever finishes last -- so the UI shows results that don't match
		# the dropdown's current value.
		"fetch_seq": 0,
		# downloading_id: mws_id currently being downloaded. -1 = idle.
		# Singletons (not concurrent) because the temp-file + collect rebuild
		# would race; additional Get clicks land in download_queue and run
		# sequentially after the current one finishes.
		"downloading_id": -1,
		# download_queue: Array of {mod_data, get_btn} dicts awaiting their
		# turn. on_get drains this FIFO once the current download completes.
		"download_queue": [],
	}

	# -- Toolbar: search + sort + category --
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	var search_input := LineEdit.new()
	search_input.placeholder_text = "Search mods..."
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size.x = 200
	toolbar.add_child(search_input)

	var sort_dropdown := OptionButton.new()
	# Index -> API sort enum. Search honors this sort (no best_match override) --
	# default "Recently bumped" keeps most-recently-updated mods on top.
	sort_dropdown.add_item("Recently bumped")
	sort_dropdown.add_item("Most downloaded")
	sort_dropdown.add_item("Most liked")
	sort_dropdown.add_item("Most viewed")
	sort_dropdown.add_item("Newest")
	var sort_keys := ["bumped_at", "downloads", "likes", "views", "published_at"]
	toolbar.add_child(sort_dropdown)

	var category_dropdown := OptionButton.new()
	category_dropdown.add_item("All categories")
	category_dropdown.set_item_metadata(0, 0)  # category_id 0 = no filter
	toolbar.add_child(category_dropdown)

	# OptionButton popups are sub-Windows; the launcher's always_on_top leaves
	# them stranded behind the main window unless we explicitly raise them.
	# Theme assignment is also explicit because theme inheritance does not
	# always cross Window boundaries in Godot 4. Same fix the profile_opt
	# dropdown applies in build_mods_tab. Unfolded rather than looped because
	# iterating over an Array literal makes the loop variable untyped Variant
	# and `var popup := dd.get_popup()` then fails type inference at parse time.
	var sort_popup := sort_dropdown.get_popup()
	sort_popup.always_on_top = true
	sort_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		sort_popup.theme = _ui_window.theme

	var cat_popup := category_dropdown.get_popup()
	cat_popup.always_on_top = true
	cat_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		cat_popup.theme = _ui_window.theme

	container.add_child(HSeparator.new())

	# Offline-grace banner slot. show_browse_banner (below) fills it when a
	# list fetch fails (cached results / unreachable / rate limit) and the
	# success paths clear it. Hidden when empty so it costs no height on the
	# happy path; it sits above the list as a sibling, never over it, so it
	# cannot block interaction with rendered rows.
	var banner_slot := VBoxContainer.new()
	banner_slot.visible = false
	container.add_child(banner_slot)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", FS_BODY)
	status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(status_lbl)

	# One status-text pattern (spec section 6): every Browse state change
	# routes through here so the color always matches the message --
	# COL_AMBER in-progress, COL_OK success, COL_ERR failure, COL_TEXT_DIM
	# neutral/meta. font_color override, never modulate (modulate would
	# also tint child icons; spec jank class 5). Assigned BEFORE every
	# closure that calls it, so by-value capture picks up a real Callable
	# (handoff bug class 1).
	var set_status := func(text: String, color: Color):
		if not is_instance_valid(status_lbl):
			return
		status_lbl.text = text
		status_lbl.add_theme_color_override("font_color", color)

	# Failure reason for the offline banner. The 429 cooldown owns the copy
	# while it is armed (rate-limited is actionable-by-waiting, unreachable
	# is not); otherwise the generic unreachable line.
	var browse_fail_reason := func() -> String:
		# Single source for the rate-limit sentence: mws_error_status() returns
		# the "rate limit reached, try again in Ns" copy when a cooldown is armed
		# and the unreachable line otherwise -- identical to the old inline
		# duplicate, but now the wording can't drift from the status label's.
		return mws_error_status("ModWorkshop is unreachable.")

	var clear_browse_banner := func():
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		banner_slot.visible = false

	# Banner with a Retry action (spec section 6: banner via the one
	# builder; edge_color COL_AMBER = notice such as showing-cached-results,
	# COL_ERR = error such as no-cached-data, matching the adjacent status
	# label's color). saved_at_unix > 0 adds a
	# "Last refreshed Xm ago" note in FS_META COL_TEXT_DIM (spec section 7:
	# meta info never parenthetical in the body label). Retry re-runs the
	# CURRENT view's fetch through `state`: this lambda is created before
	# do_discover_fetch / do_filter_fetch are assigned, and lambdas capture
	# locals by value at creation (handoff bug class 1), so the state
	# dictionary is the only route to their real bodies.
	var show_browse_banner := func(text: String, saved_at_unix: int, edge_color: Color):
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		var banner := _make_banner(text, edge_color)
		var banner_row: HBoxContainer = banner["row"]
		if saved_at_unix > 0:
			var age_lbl := Label.new()
			age_lbl.text = "Last refreshed " + _format_age(saved_at_unix)
			age_lbl.add_theme_font_size_override("font_size", FS_META)
			age_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			banner_row.add_child(age_lbl)
		var retry_btn := Button.new()
		retry_btn.text = "Retry"
		banner_row.add_child(retry_btn)
		retry_btn.pressed.connect(func():
			if str(state["mode"]) == "discover":
				(state["fn_discover_fetch"] as Callable).call()
			else:
				(state["fn_filter_fetch"] as Callable).call(false)
		)
		banner_slot.add_child(banner["panel"])
		banner_slot.visible = true

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	# Right margin clears the vertical scrollbar so the Get button on each row
	# doesn't sit underneath it. ScrollContainer in Godot 4 lays content out
	# at full width and OVERLAYS the scrollbar -- without this margin the
	# rightmost pixels of every row hide behind it.
	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_wrap.add_child(list)

	var load_more_btn := Button.new()
	load_more_btn.text = "Load more"
	load_more_btn.visible = false
	container.add_child(load_more_btn)

	# Map mws_id -> entry (or absent if not installed). Recomputed every
	# render because re-discovery after a successful Get rewrites
	# _ui_mod_entries; rows flip from Get -> enable-toggle next render
	# without a UI close/reopen.
	var compute_install_map := func() -> Dictionary:
		var out: Dictionary = {}
		for entry in _ui_mod_entries:
			var cfg: ConfigFile = entry.get("cfg")
			if cfg == null:
				continue
			if not cfg.has_section_key("updates", "modworkshop"):
				continue
			var mws_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
			if mws_id > 0:
				out[mws_id] = entry
		return out

	# Forward declarations: on_get's success branch + queue processor re-
	# render the current view to flip duplicate Get buttons, so the fetch
	# callables must be in scope. Bodies are assigned below.
	var do_discover_fetch: Callable
	var do_filter_fetch: Callable

	# Enable/disable toggle from the Browse row. Mutates the entry in
	# _ui_mod_entries (Dictionary references), saves via _save_ui_config,
	# rebuilds the Mods tab so its row reflects the change.
	var on_toggle := func(mws_id: int, enabled: bool, check: CheckBox):
		for entry in _ui_mod_entries:
			var cfg: ConfigFile = entry.get("cfg")
			if cfg == null:
				continue
			if not cfg.has_section_key("updates", "modworkshop"):
				continue
			var entry_mws := int(str(cfg.get_value("updates", "modworkshop", "0")))
			if entry_mws != mws_id:
				continue
			# Same content-mod guard as the Mods-tab checkbox: disabling a
			# mod that registers game content can stop an existing save that
			# uses it from loading. Confirm first; if the user backs out,
			# revert the checkbox without re-firing toggled.
			var live_entry: Dictionary = entry
			if not enabled and bool(entry.get("has_registry", false)):
				var ok: bool = await _confirm_disable_content_mod(str(entry.get("mod_name", "this mod")))
				if not ok:
					if is_instance_valid(check):
						check.set_pressed_no_signal(true)
					return
				# The launcher window can close while the dialog is open;
				# the controls may be freed. A rescan while the dialog was
				# open (e.g. a queued download landing) replaces
				# _ui_mod_entries with fresh dicts, so write the confirmed
				# state to the LIVE entry, not the orphaned capture.
				live_entry = _live_entry_for_profile_key(str(entry.get("profile_key", "")), entry)
			live_entry["enabled"] = enabled
			_save_ui_config()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)
			set_status.call(("Enabled " if enabled else "Disabled ") + str(live_entry.get("mod_name", "?")) + " in profile " + _active_profile, COL_TEXT_DIM)
			return

	# Forward decl so on_get + queue processor can reference each other.
	var perform_download_for_item: Callable

	perform_download_for_item = func(item: Dictionary):
		var mod_data: Dictionary = item["mod_data"]
		var get_btn = item.get("get_btn")
		var mws_id := int(mod_data.get("id", 0))
		state["downloading_id"] = mws_id
		if is_instance_valid(get_btn):
			get_btn.disabled = true
			get_btn.text = "Downloading..."
		var queue: Array = state["download_queue"]
		var qsuffix := (" (" + str(queue.size()) + " queued)") if not queue.is_empty() else ""
		set_status.call("Downloading " + str(mod_data.get("name", "?")) + qsuffix + "...", COL_AMBER)

		var result: Dictionary = await download_new_mod(mws_id)
		state["downloading_id"] = -1

		# The launcher window can be closed (Launch / X) during the multi-second
		# download -- Browse downloads pop no modal. Everything below touches
		# freed nodes (status_lbl, the Browse list, the tab). The file already
		# landed on disk inside download_new_mod, so just stop cleanly.
		if not is_instance_valid(status_lbl):
			return

		if bool(result.get("ok", false)):
			# Remember that this queued batch installed at least one mod, so
			# the drain below can still sync duplicate rows when a LATER item
			# in the batch fails (the re-fetch is gated on the last result).
			state["queue_any_success"] = true
			_reload_entries_for_active_profile()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)
			if is_instance_valid(get_btn):
				get_btn.text = "Installed"
				get_btn.disabled = true
			set_status.call("Installed " + str(result.get("file_name", "")), COL_OK)
		else:
			if is_instance_valid(get_btn):
				get_btn.disabled = false
				get_btn.text = "Download"
			# Error copy pattern (spec section 7): what happened + what to do
			# next; fall back to the connection hint when the downloader gave
			# no detail rather than saying "unknown".
			var err_detail := str(result.get("error", "")).strip_edges()
			if err_detail.is_empty():
				err_detail = "Check your connection and try again."
			set_status.call("Could not download " + str(mod_data.get("name", "mod")) + ". " + err_detail, COL_ERR)

		# Drain queue or re-render. Re-rendering frees button refs in the
		# queue, so we only re-render once the queue is empty -- otherwise
		# subsequent items lose their "Queued" button state mid-flight.
		#
		# Call through `state`, NOT the captured locals. GDScript lambdas
		# capture locals BY VALUE at creation time; this lambda was created
		# (line ~4015) before perform_download_for_item / do_discover_fetch /
		# do_filter_fetch were assigned, so the captured copies are empty
		# Callables. `state` is a Dictionary (reference type), so the bindings
		# stored on it at the end of build_browse_tab are visible here.
		var remaining: Array = state["download_queue"]
		if not remaining.is_empty():
			var next_item: Dictionary = remaining.pop_front()
			(state["fn_perform_download"] as Callable).call(next_item)
		elif bool(result.get("ok", false)):
			# Re-render only after a SUCCESS. The re-fetch exists to flip
			# duplicate Get buttons to Installed; on failure it would
			# synchronously overwrite the "Download failed: ..." status with
			# "Loading..." before it ever rendered a frame, and nothing
			# changed on disk anyway -- so keep the failure visible instead.
			#
			# Carry the scroll position across the re-render: the full
			# re-render resets the ScrollContainer to the top. The fetch
			# lambdas consume restore_scroll and re-apply it one frame after
			# rendering.
			state["queue_any_success"] = false
			if is_instance_valid(scroll):
				state["restore_scroll"] = int(scroll.scroll_vertical)
			if str(state["mode"]) == "discover":
				(state["fn_discover_fetch"] as Callable).call()
			else:
				(state["fn_filter_fetch"] as Callable).call(false)
		elif bool(state.get("queue_any_success", false)):
			# Mixed batch: earlier queued downloads installed but the FINAL
			# one failed, so the success-only re-fetch above is skipped and
			# duplicate rows (same mod in popular AND latest) of the installed
			# mods would keep a live Download button. Sync those rows in place
			# -- no re-fetch, so the failure status text stays visible.
			state["queue_any_success"] = false
			if is_instance_valid(scroll):
				_refresh_browse_installed_rows(scroll)

	var on_get: Callable
	on_get = func(mod_data: Dictionary, get_btn: Button):
		var mws_id := int(mod_data.get("id", 0))
		if int(state["downloading_id"]) != -1:
			# Another download is in flight. Queue this one (unless it's the
			# same mod already in-flight or already queued -- silent dedup).
			if int(state["downloading_id"]) == mws_id:
				set_status.call("Already downloading this mod", COL_TEXT_DIM)
				return
			var queue: Array = state["download_queue"]
			for q_v in queue:
				if int((q_v as Dictionary).get("mod_data", {}).get("id", 0)) == mws_id:
					set_status.call("Already queued", COL_TEXT_DIM)
					return
			queue.append({"mod_data": mod_data, "get_btn": get_btn})
			if is_instance_valid(get_btn):
				get_btn.disabled = true
				get_btn.text = "Queued"
			set_status.call("Queued " + str(mod_data.get("name", "?")) + " (" + str(queue.size()) + " in queue)", COL_TEXT_DIM)
			return
		perform_download_for_item.call({"mod_data": mod_data, "get_btn": get_btn})

	var render_mod_rows := func(mods: Array, append: bool):
		if not append:
			for child in list.get_children():
				child.queue_free()
		var install_map: Dictionary = compute_install_map.call()
		for mod_data in mods:
			if not (mod_data is Dictionary):
				continue
			var mws_id := int((mod_data as Dictionary).get("id", 0))
			var entry_or_null: Variant = install_map.get(mws_id)
			list.add_child(_browse_render_mod_row(mod_data, entry_or_null, on_get, on_toggle))
			list.add_child(HSeparator.new())

	do_discover_fetch = func():
		# Stamp this fetch with a fresh seq so any earlier in-flight fetch's
		# completion handler sees the mismatch and bails. Snapshot into a
		# local `my_seq` because state["fetch_seq"] will keep advancing if
		# the user clicks again before our await returns.
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		# Consume any pending scroll carry (set by the post-download
		# re-render) up front so a failed or superseded fetch cannot leak it
		# into a later user-initiated fetch.
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		state["mode"] = "discover"
		state["next_page"] = 1
		state["has_more"] = false
		load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading...", COL_TEXT_DIM)
		var data: Variant = await mws_get_popular_and_latest()
		# Stale completion: another fetch was started while we awaited.
		# Newer fetch's render owns the UI; drop ours.
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		# Offline grace: a failed live fetch falls back to the last-good
		# snapshot (this session's or a previous launch's, via disk) and
		# renders it behind a cached-results banner instead of leaving the
		# tab empty. No snapshot -> the old failure status, plus the
		# banner's Retry affordance so recovery doesn't need a tab switch.
		var cached_at := 0
		if not (data is Dictionary):
			var snap: Dictionary = mws_discover_snapshot()
			if snap.is_empty():
				set_status.call(mws_error_status("Could not load mods. Check your connection and try again."), COL_ERR)
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
				return
			data = snap["data"]
			cached_at = int(snap["saved_at_unix"])
		var popular: Array = (data as Dictionary).get("popular", [])
		var latest: Array = (data as Dictionary).get("latest", [])
		for child in list.get_children():
			child.queue_free()
		var install_map: Dictionary = compute_install_map.call()
		if not popular.is_empty():
			var pop_hdr := Label.new()
			pop_hdr.text = "Popular"
			pop_hdr.add_theme_font_size_override("font_size", FS_HEAD)
			pop_hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(pop_hdr)
			list.add_child(HSeparator.new())
			for mod_data in popular:
				if not (mod_data is Dictionary):
					continue
				var mws_id := int((mod_data as Dictionary).get("id", 0))
				list.add_child(_browse_render_mod_row(mod_data, install_map.get(mws_id), on_get, on_toggle))
				list.add_child(HSeparator.new())
		if not latest.is_empty():
			var spacer := Control.new()
			spacer.custom_minimum_size.y = SP_M
			list.add_child(spacer)
			var lat_hdr := Label.new()
			lat_hdr.text = "Latest"
			lat_hdr.add_theme_font_size_override("font_size", FS_HEAD)
			lat_hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(lat_hdr)
			list.add_child(HSeparator.new())
			for mod_data in latest:
				if not (mod_data is Dictionary):
					continue
				var mws_id := int((mod_data as Dictionary).get("id", 0))
				list.add_child(_browse_render_mod_row(mod_data, install_map.get(mws_id), on_get, on_toggle))
				list.add_child(HSeparator.new())
		if cached_at > 0:
			show_browse_banner.call("Showing cached results. " + str(browse_fail_reason.call()), cached_at, COL_AMBER)
		else:
			clear_browse_banner.call()
		set_status.call("%d popular, %d latest" % [popular.size(), latest.size()], COL_TEXT_DIM)
		# Restore the pre-refetch scroll position one frame later: the fresh
		# rows have no layout yet on this frame, so setting scroll_vertical
		# now would clamp against a zero-height list (handoff bug class 6).
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	do_filter_fetch = func(append: bool):
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		# Same pending-scroll-carry consumption as do_discover_fetch.
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		state["mode"] = "filter"
		var page: int = int(state["next_page"]) if append else 1
		if not append:
			state["next_page"] = 1
			state["has_more"] = false
			load_more_btn.visible = false
		# Disable Load more for the duration of the fetch so a rapid second
		# click can't enqueue a redundant page request. The completion path
		# re-derives visible/disabled from has_more.
		load_more_btn.disabled = true
		set_status.call("Loading..." if not append else "Loading more...", COL_TEXT_DIM)
		# Search honors the chosen sort (default "Recently bumped" = bumped_at)
		# instead of silently switching to best_match relevance. best_match pinned
		# an exact-name match (e.g. an outdated "Ryhon Item Spawner") to the top
		# regardless of upload date; a user searching wants most-recent first.
		var sort: String = str(state["sort"])
		var data: Variant = await mws_list_mods(str(state["query"]), sort, int(state["category_id"]), page)
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		if not (data is Dictionary):
			set_status.call(mws_error_status("Could not search. Check your connection and try again."), COL_ERR)
			# Only the discover landing has an offline snapshot (filter/search
			# results are never cached), so a failed search gets the Retry
			# banner but no cached rows. Append failures skip the banner: the
			# already-rendered pages stay on screen and the re-enabled Load
			# more button below IS the retry affordance.
			if not append:
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
			load_more_btn.disabled = not bool(state["has_more"])
			return
		var rows: Array = _mws_data_rows(data)
		# MWS ignores the sort param when a text query is present -- it always
		# returns relevance order, so an outdated exact-name match pins to the
		# top no matter the dropdown. Re-sort client-side by the selected field.
		# LIMITATION: on Load-more (append) each fetched PAGE is sorted on its
		# own and appended, so a multi-page query result is per-page sawtoothed,
		# not globally sorted. Left as-is -- a true cross-page sort needs a
		# fetch/render rework, and RTV searches essentially always fit one page.
		# ISO date strings compare chronologically.
		if str(state["query"]) != "":
			var sort_key := str(state["sort"])
			var numeric := sort_key == "downloads" or sort_key == "likes" or sort_key == "views"
			rows.sort_custom(func(a, b):
				if not (a is Dictionary):
					return false
				if not (b is Dictionary):
					return true
				if numeric:
					# .get() default only covers ABSENT keys; a present-but-null
					# counter would make int(null) a runtime error. JSON numbers
					# parse as float, so accept int/float and coerce junk to 0.
					var av: Variant = (a as Dictionary).get(sort_key)
					var bv: Variant = (b as Dictionary).get(sort_key)
					var ai: int = int(av) if (av is int or av is float) else 0
					var bi: int = int(bv) if (bv is int or bv is float) else 0
					return ai > bi
				return str((a as Dictionary).get(sort_key, "")) > str((b as Dictionary).get(sort_key, ""))
			)
		# .get()'s default only covers an ABSENT key; a present-but-null (or
		# non-dict) meta would crash the typed assignment. Same guard shape
		# as _mws_data_rows applies to the sibling data field.
		var meta_v: Variant = (data as Dictionary).get("meta")
		var meta: Dictionary = meta_v if meta_v is Dictionary else {}
		var current_page: int = int(meta.get("current_page", page))
		var last_page: int = int(meta.get("last_page", current_page))
		var total: int = int(meta.get("total", rows.size()))
		state["next_page"] = current_page + 1
		state["has_more"] = current_page < last_page
		clear_browse_banner.call()
		render_mod_rows.call(rows, append)
		# Count from the data, not the scene tree. render_mod_rows clears a
		# non-append view with queue_free(), which Godot defers to end-of-frame,
		# so list.get_child_count() in this same synchronous block still counts
		# the just-freed old rows -- inflating "N of M mods" and (worse) keeping
		# shown_so_far > 0 so the new "No results" empty state never appears.
		if append:
			state["shown_count"] = int(state.get("shown_count", 0)) + rows.size()
		else:
			state["shown_count"] = rows.size()
		var shown_so_far: int = int(state["shown_count"])
		# Empty state as an invitation (spec section 7), not a bare zero.
		if shown_so_far == 0:
			set_status.call("No results. Try fewer filters.", COL_TEXT_DIM)
		else:
			set_status.call("%d of %d mods" % [shown_so_far, total], COL_TEXT_DIM)
		load_more_btn.visible = bool(state["has_more"])
		load_more_btn.disabled = not bool(state["has_more"])
		# Restore the pre-refetch scroll position one frame later: the fresh
		# rows have no layout yet on this frame, so setting scroll_vertical
		# now would clamp against a zero-height list (handoff bug class 6).
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	# Debounce: Godot 4 LineEdit's text_changed fires per keystroke. A timer
	# armed on each keystroke and only the timeout actually queries the API
	# means a 300ms typing pause before the network kicks in -- well within
	# the 90 req/min/IP rate budget even when the user types fast.
	var search_debounce := Timer.new()
	search_debounce.one_shot = true
	search_debounce.wait_time = 0.3
	container.add_child(search_debounce)
	search_debounce.timeout.connect(func():
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and str(state["sort"]) == "bumped_at":
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	search_input.text_changed.connect(func(new_text: String):
		state["query"] = new_text.strip_edges()
		search_debounce.stop()
		search_debounce.start()
	)
	search_input.text_submitted.connect(func(_t: String):
		search_debounce.stop()
		do_filter_fetch.call(false)
	)

	sort_dropdown.item_selected.connect(func(idx: int):
		state["sort"] = sort_keys[idx] if idx >= 0 and idx < sort_keys.size() else "bumped_at"
		# A non-default sort means we're in filter mode now even with empty
		# query; routes through list_mods with the chosen sort.
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and str(state["sort"]) == "bumped_at":
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	category_dropdown.item_selected.connect(func(idx: int):
		var cid_var = category_dropdown.get_item_metadata(idx)
		state["category_id"] = int(cid_var) if cid_var != null else 0
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and str(state["sort"]) == "bumped_at":
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	load_more_btn.pressed.connect(func():
		do_filter_fetch.call(true)
	)

	# Populate categories asynchronously after the tab is visible. Each entry's
	# metadata holds the API category_id; the visible label is just the name.
	# Skip child categories for the first pass -- a flat list of 40 items in a
	# dropdown is already a stretch UX-wise, so we surface only top-level
	# (parent_id == null) and rely on search to find sub-category mods.
	var populate_categories := func():
		var data: Variant = await mws_get_categories()
		if not is_instance_valid(category_dropdown):
			return
		if not (data is Dictionary):
			return
		var rows: Array = _mws_data_rows(data)
		for cat in rows:
			if not (cat is Dictionary):
				continue
			var cd: Dictionary = cat
			# Only top-level for now.
			if cd.get("parent_id") != null:
				continue
			var cat_name := str(cd.get("name", ""))
			var cat_id := int(cd.get("id", 0))
			if cat_name.is_empty() or cat_id == 0:
				continue
			category_dropdown.add_item(cat_name)
			var idx := category_dropdown.item_count - 1
			category_dropdown.set_item_metadata(idx, cat_id)
	populate_categories.call()

	# Bind the forward-referenced lambdas onto `state` so the
	# perform_download lambda (created before these were assigned) can reach
	# their real values by reference at call time. See the capture note in
	# perform_download_for_item's queue-drain block.
	state["fn_perform_download"] = perform_download_for_item
	state["fn_discover_fetch"] = do_discover_fetch
	state["fn_filter_fetch"] = do_filter_fetch

	# Initial fetch is the curated landing page.
	do_discover_fetch.call()

	return margin


# Refresh the baked-at-render-time state of Browse rows in place. The
# "Enabled in <profile>" checkboxes bake the profile name and enabled state
# when rendered, and profile switches, modpack apply/unload, and Mods-tab
# edits all change that state behind the Browse tab's back (the tab has no
# rebuild path by design -- its content is network-fetched). Called from the
# tab_changed listener when Browse is shown. In-place (no re-fetch, no
# re-render) so search text, caret, scroll position, and loaded pages all
# survive. Rows are found via the browse_mws_id meta tag set at render time.
func _refresh_browse_installed_rows(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	# mws_id -> entry for every installed mod that declares one. Last-wins,
	# matching compute_install_map in build_browse_tab.
	var by_id: Dictionary = {}
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		if not cfg.has_section_key("updates", "modworkshop"):
			continue
		var mws_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
		if mws_id > 0:
			by_id[mws_id] = entry
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not node.has_meta("browse_mws_id"):
			continue
		var entry_v: Variant = by_id.get(int(node.get_meta("browse_mws_id")))
		if node is CheckBox:
			var cb := node as CheckBox
			if entry_v is Dictionary:
				cb.disabled = false
				cb.text = "Enabled in " + _active_profile
				cb.tooltip_text = "Toggle this mod in profile: " + _active_profile + "."
				# set_pressed_no_signal: this is a display sync, not a user
				# toggle -- firing toggled here would re-save the profile.
				cb.set_pressed_no_signal(bool((entry_v as Dictionary).get("enabled", false)))
			else:
				# The mod was uninstalled behind the tab's back (Mods-tab Remove).
				# Leave the row but make it inert: an enabled checkbox here toggles
				# nothing (on_toggle finds no matching entry and falls through) yet
				# still flips visually, falsely claiming a now-uninstalled mod was
				# enabled/disabled in the profile.
				cb.set_pressed_no_signal(false)
				cb.disabled = true
				cb.text = "Removed"
				cb.tooltip_text = "This mod is no longer installed. Re-download it from its Browse entry."
		elif node is Button and entry_v is Dictionary:
			# A Download button whose mod is now installed (modpack apply or
			# retry landed it). Skip in-flight buttons (Downloading/Queued,
			# both disabled); the download path re-renders on its own.
			var btn := node as Button
			if not btn.disabled:
				btn.text = "Installed"
				btn.disabled = true


# Render one row in the Browse tab list. Pulls from a ModSummary dict (live
# response shape from /games/{id}/mods or /games/{id}/popular-and-latest).
# Thumbnail loads asynchronously via _browse_load_thumbnail_async; the row
# returns immediately with a gray placeholder. installed=true swaps the Get
# button for a disabled "Installed" indicator -- update detection (delta vs
# MWS' current version) lives in the Updates tab for now and isn't surfaced
# here in this iteration.
func _browse_render_mod_row(mod_data: Dictionary, install_entry: Variant, on_get: Callable, on_toggle: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	# Thumbnail wrapper. PanelContainer gives us a solid background so the
	# placeholder looks intentional rather than "missing image" before the
	# texture loads. ColorRect would also work but PanelContainer composes
	# better with the dark theme's stylebox conventions.
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.custom_minimum_size = Vector2(96, 54)
	var thumb_style := StyleBoxFlat.new()
	thumb_style.bg_color = COL_SURFACE_2
	thumb_wrap.add_theme_stylebox_override("panel", thumb_style)
	row.add_child(thumb_wrap)

	var thumb_rect := TextureRect.new()
	thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thumb_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	thumb_wrap.add_child(thumb_rect)

	var thumb_record = mod_data.get("thumbnail")
	if thumb_record is Dictionary:
		_browse_load_thumbnail_async(thumb_rect, thumb_record)

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Mod name doubles as the click target for the detail modal. LinkButton
	# matches the bottom-bar self-update affordance: text by default, underlines
	# on hover. Discoverable without crowding the row with a separate "Details"
	# button next to Get.
	var name_lnk := LinkButton.new()
	name_lnk.text = str(mod_data.get("name", "?"))
	name_lnk.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	name_lnk.add_theme_font_size_override("font_size", FS_EMPH)
	name_lnk.add_theme_color_override("font_color", COL_TEXT)
	name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
	name_lnk.tooltip_text = name_lnk.text
	var captured_data_for_detail := mod_data
	name_lnk.pressed.connect(func():
		_show_browse_mod_detail_dialog(captured_data_for_detail, on_get)
	)
	info_col.add_child(name_lnk)

	var user_dict: Dictionary = mod_data.get("user", {}) if mod_data.get("user") is Dictionary else {}
	var category_dict: Dictionary = mod_data.get("category", {}) if mod_data.get("category") is Dictionary else {}
	var author: String = str(user_dict.get("name", ""))
	var version: String = str(mod_data.get("version", "")).strip_edges()
	var downloads: int = int(mod_data.get("downloads", 0))
	var likes: int = int(mod_data.get("likes", 0))
	var category: String = str(category_dict.get("name", ""))
	var bumped_raw: String = str(mod_data.get("bumped_at", ""))
	var bumped_short: String = _format_iso_datetime(bumped_raw)

	var meta_parts := PackedStringArray()
	if author != "":
		meta_parts.append("by " + author)
	if version != "":
		meta_parts.append("v" + version)
	meta_parts.append(str(downloads) + " downloads")
	if likes > 0:
		meta_parts.append(str(likes) + " likes")
	if category != "":
		meta_parts.append(category)
	if bumped_short != "":
		meta_parts.append("updated " + bumped_short)

	var meta_lbl := Label.new()
	meta_lbl.text = " - ".join(meta_parts)
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels default
	# to MOUSE_FILTER_IGNORE, which silently suppresses tooltips).
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	# Installed mods get an enable toggle bound to the active profile. The
	# checkbox's existence implies install (un-installed mods show a Download
	# button instead, never both), and the label embeds the profile name so
	# users know what they're toggling.
	var installed := install_entry is Dictionary
	if installed:
		var entry: Dictionary = install_entry as Dictionary
		var enable_check := CheckBox.new()
		enable_check.text = "Enabled in " + _active_profile
		enable_check.button_pressed = bool(entry.get("enabled", false))
		enable_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# Tag with the mws id so _refresh_browse_installed_rows can re-derive
		# this baked-at-render-time state when the tab is shown again.
		enable_check.set_meta("browse_mws_id", int(mod_data.get("id", 0)))
		var captured_mws_id := int(mod_data.get("id", 0))
		var captured_check := enable_check
		enable_check.toggled.connect(func(on: bool):
			on_toggle.call(captured_mws_id, on, captured_check)
		)
		row.add_child(enable_check)
		_wire_hint(enable_check, "Toggle this mod in profile: " + _active_profile + ".")
	else:
		var get_btn := Button.new()
		get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		get_btn.text = "Download"
		# Tag with the mws id so _refresh_browse_installed_rows can flip this
		# to Installed if the mod arrives behind the tab's back (modpack
		# apply, retry downloads).
		get_btn.set_meta("browse_mws_id", int(mod_data.get("id", 0)))
		var captured := mod_data
		var captured_btn := get_btn
		get_btn.pressed.connect(func():
			on_get.call(captured, captured_btn)
		)
		row.add_child(get_btn)
		_wire_hint(get_btn, "Download this mod from ModWorkshop.")

	return row


# Async thumbnail loader. Cache layout: user://mws_cache/thumbs/<storage_filename>.
# Filenames from MWS are opaque/immutable per upload, so the storage filename
# IS the cache key -- a thumbnail replaced by the author gets a different file
# name and we naturally fetch fresh. No TTL needed, no manual cache busting.
# Failures are silent: the row's gray placeholder stays visible. 1MB hard
# cap (download_body_size_limit below) defends against malformed responses
# without limiting real thumbnails (typical MWS thumbs are 10-80KB).
func _browse_load_thumbnail_async(rect: TextureRect, image_record: Dictionary) -> void:
	var fn: String = str(image_record.get("file", ""))
	if fn.is_empty():
		return
	# Server-provided name: accept only a bare basename so path_join cannot
	# escape the cache dir (same never-trust-a-server-name posture as the
	# _is_safe_mod_filename gate on mod download names). get_file() only
	# splits on "/", so reject backslashes and ".." explicitly too.
	if fn != fn.get_file() or fn.contains("\\") or fn.contains(".."):
		return

	var cache_dir := "user://mws_cache/thumbs"
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var cache_path := cache_dir.path_join(fn)

	# Cache hit: try to deserialize bytes. load_*_from_buffer returns OK on
	# match, so fall through to refetch on any decode error rather than
	# trusting the on-disk file unconditionally.
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var bytes := f.get_buffer(f.get_length())
			f.close()
			if bytes.size() > 0:
				var img := Image.new()
				if img.load_webp_from_buffer(bytes) == OK \
						or img.load_jpg_from_buffer(bytes) == OK \
						or img.load_png_from_buffer(bytes) == OK:
					if is_instance_valid(rect):
						rect.texture = ImageTexture.create_from_image(img)
					return

	# Cache miss: fetch from CDN. The /mods/images/thumbs/ path returns 404
	# in practice even when the record claims has_thumb=true, so use the
	# full-size image URL. Mod thumbnails are typically 100-300KB; 1MB cap
	# gives margin for higher-res covers without letting a malformed response
	# eat memory.
	var url := mws_image_url(image_record, false)
	if url.is_empty():
		return

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	req.download_body_size_limit = 1024 * 1024
	add_child(req)
	var headers := PackedStringArray([
		"User-Agent: " + (MWS_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
	])
	var err := req.request(url, headers)
	if err != OK:
		req.queue_free()
		return

	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return
	var body: PackedByteArray = res[3]
	if body.is_empty():
		return

	var img := Image.new()
	var ok := img.load_webp_from_buffer(body) == OK \
			or img.load_jpg_from_buffer(body) == OK \
			or img.load_png_from_buffer(body) == OK
	if not ok:
		return

	# Stash for next launch. Failure to write is non-fatal -- we still display
	# the texture this session, just refetch next time.
	var out := FileAccess.open(cache_path, FileAccess.WRITE)
	if out != null:
		out.store_buffer(body)
		out.close()

	if is_instance_valid(rect):
		rect.texture = ImageTexture.create_from_image(img)


# Format a byte count as a compact human-readable string. Used by the mod
# detail modal's file list and the Remove confirmation dialog.
func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


# Format a MWS ISO-8601 string ("2026-04-12T17:42:11.000000Z") as a compact
# "2026-04-12 17:42" -- date plus HH:MM, dropping seconds + microsecond noise
# and the Z suffix. UTC; the dropdown labels in the UI don't claim a timezone.
# Returns the input unchanged if it doesn't look like an ISO timestamp.
func _format_iso_datetime(iso: String) -> String:
	if iso.is_empty():
		return ""
	if not iso.contains("T"):
		return iso
	var parts := iso.split("T")
	var date_part: String = parts[0]
	if parts.size() < 2:
		return date_part
	var time_part: String = parts[1]
	# "17:42:11.000000Z" -> "17:42"; safe even if the seconds segment is short.
	var hm: String = time_part.substr(0, 5) if time_part.length() >= 5 else time_part
	return date_part + " " + hm


# Detail modal for a Browse-tab row. Opens with whatever ModSummary fields the
# list endpoint returned (name, desc, image, downloads, etc.) and async-loads
# the file history (/mods/{id}/files) into a separate section once available.
# The Get button forwards to the same on_get callback the list rows use, so
# install state stays consistent between the row and the modal.
## Replace every match of `re` in `s` using a callable that maps a RegExMatch to
## its replacement. Avoids RegEx.sub's backreference syntax (unused elsewhere in
## this codebase) -- get_string()/get_start()/get_end() are unambiguous.
func _re_replace(re: RegEx, s: String, repl: Callable) -> String:
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		out += str(repl.call(m))
		last = m.get_end()
	out += s.substr(last)
	return out

## Convert ModWorkshop's Markdown-flavored description into Godot BBCode for a
## RichTextLabel: headings, bold/italic/strikethrough, bullet lists, blockquotes,
## horizontal rules, links, and MWS's {#hex}(text) / :::{#hex}(...):::
## color spans. Inline images (![alt](url)) collapse to their alt text --
## RichTextLabel can't load remote images inline without extra async work.
## Best-effort and non-crashing: malformed input just renders imperfectly.
func _markdown_to_bbcode(md: String) -> String:
	# Sentinels stand in for our own '[' / ']' while we escape the user's literal
	# brackets, so escaping can't mangle tags we generate. STX/ETX never appear
	# in real descriptions.
	var LB := char(2)
	var RB := char(3)
	var s := md.replace("\r\n", "\n").replace("\r", "\n")
	# Untrusted remote input must NOT contain our sentinels -- the final restore
	# would turn them into real brackets and inject BBCode past the [lb] escape.
	s = s.replace(LB, "").replace(RB, "")
	s = s.replace(":::", "")  # drop MWS colored-block delimiters; keep {#hex}(..)

	# Bracket/paren constructs, converted BEFORE escaping literal '['. Images
	# first (a link with a leading '!').
	var re_img := RegEx.new()
	re_img.compile("!\\[([^\\]]*)\\]\\([^)]*\\)")
	s = _re_replace(re_img, s, func(m): return m.get_string(1))
	var re_link := RegEx.new()
	re_link.compile("\\[([^\\]]*)\\]\\(([^)\\s]+)\\)")
	# Percent-encode BBCode/markdown-sensitive chars in the URL so the later '['
	# escape + emphasis passes can't corrupt the url= parameter (a literal ']'
	# would end the tag early). '_' and '~' are RFC-3986 unreserved; %2A/%5B/%5D
	# are handled identically by servers and OS.shell_open. Never encode '%'.
	s = _re_replace(re_link, s, func(m): return LB + "url=" + m.get_string(2).replace("[", "%5B").replace("]", "%5D").replace("_", "%5F").replace("*", "%2A").replace("~", "%7E") + RB + m.get_string(1) + LB + "/url" + RB)
	var re_color := RegEx.new()
	re_color.compile("\\{#([0-9a-fA-F]{3,8})\\}\\(([^)]*)\\)")
	s = _re_replace(re_color, s, func(m): return LB + "color=#" + m.get_string(1) + RB + m.get_string(2) + LB + "/color" + RB)

	# Escape remaining literal '[' so stray user brackets aren't read as tags.
	# Only '[' matters to the parser; a lone ']' renders literally.
	s = s.replace("[", "[lb]")

	# Block level: strip line markers, wrap in sentinel tags. Done BEFORE inline
	# emphasis so a bullet's leading '*' is gone before the '*italic*' rule runs.
	var re_h := RegEx.new()
	re_h.compile("^(#{1,6})\\s+(.*)$")
	var re_li := RegEx.new()
	re_li.compile("^\\s*[-*+]\\s+(.*)$")
	var lines := PackedStringArray()
	for line in s.split("\n"):
		var t := line.strip_edges()
		if t == "---" or t == "***" or t == "___":
			lines.append(LB + "color=#555555" + RB + "--------------------" + LB + "/color" + RB)
			continue
		var mh := re_h.search(line)
		if mh != null:
			var lvl := mh.get_string(1).length()
			var sz := 22 if lvl == 1 else (19 if lvl == 2 else 17)
			lines.append(LB + "font_size=" + str(sz) + RB + LB + "b" + RB + mh.get_string(2) + LB + "/b" + RB + LB + "/font_size" + RB)
			continue
		if line.begins_with(">"):
			lines.append(LB + "indent" + RB + LB + "color=#a0a0a0" + RB + line.substr(1).strip_edges() + LB + "/color" + RB + LB + "/indent" + RB)
			continue
		var ml := re_li.search(line)
		if ml != null:
			lines.append(LB + "indent" + RB + "- " + ml.get_string(1) + LB + "/indent" + RB)
			continue
		lines.append(line)
	s = "\n".join(lines)

	# Inline emphasis, whole string. Bold before italic so '**' isn't eaten by '*'.
	var re_bold := RegEx.new()
	re_bold.compile("\\*\\*([^*]+)\\*\\*")
	s = _re_replace(re_bold, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	var re_bold2 := RegEx.new()
	re_bold2.compile("__([^_]+)__")
	s = _re_replace(re_bold2, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	var re_strike := RegEx.new()
	re_strike.compile("~~([^~]+)~~")
	s = _re_replace(re_strike, s, func(m): return LB + "s" + RB + m.get_string(1) + LB + "/s" + RB)
	var re_ital := RegEx.new()
	re_ital.compile("(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])")
	s = _re_replace(re_ital, s, func(m): return LB + "i" + RB + m.get_string(1) + LB + "/i" + RB)

	# Restore our tags to real brackets, last, so escaping never touched them.
	s = s.replace(LB, "[").replace(RB, "]")
	return s

func _show_browse_mod_detail_dialog(mod_data: Dictionary, on_get: Callable) -> void:
	var d := AcceptDialog.new()
	d.title = str(mod_data.get("name", "?"))
	d.ok_button_text = "Close"
	d.min_size = Vector2i(660, 540)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 480)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	# Right-margin wrap so content doesn't sit under the scrollbar -- same
	# trick the Browse tab's main list uses.
	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_L)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Banner first if available, fall back to thumbnail. Both are Image
	# records at /mods/images/{file}; the loader caches by filename so a
	# thumbnail viewed here shares cache with the row's smaller render.
	var banner_record = mod_data.get("banner")
	var thumb_record = mod_data.get("thumbnail")
	var img_record = banner_record if banner_record is Dictionary else thumb_record
	if img_record is Dictionary:
		var banner_wrap := PanelContainer.new()
		banner_wrap.custom_minimum_size = Vector2(0, 220)
		var banner_style := StyleBoxFlat.new()
		banner_style.bg_color = COL_SURFACE_2
		banner_wrap.add_theme_stylebox_override("panel", banner_style)
		box.add_child(banner_wrap)
		var banner_rect := TextureRect.new()
		banner_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		banner_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		banner_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		banner_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		banner_wrap.add_child(banner_rect)
		_browse_load_thumbnail_async(banner_rect, img_record)

	var user_dict: Dictionary = mod_data.get("user", {}) if mod_data.get("user") is Dictionary else {}
	var category_dict: Dictionary = mod_data.get("category", {}) if mod_data.get("category") is Dictionary else {}
	var meta := Label.new()
	var parts := PackedStringArray()
	var author := str(user_dict.get("name", ""))
	if author != "":
		parts.append("by " + author)
	var version := str(mod_data.get("version", "")).strip_edges()
	if version != "":
		parts.append("v" + version)
	parts.append(str(int(mod_data.get("downloads", 0))) + " downloads")
	parts.append(str(int(mod_data.get("likes", 0))) + " likes")
	if category_dict.has("name"):
		parts.append(str(category_dict["name"]))
	var bumped := _format_iso_datetime(str(mod_data.get("bumped_at", "")))
	if bumped != "":
		parts.append("updated " + bumped)
	meta.text = " - ".join(parts)
	meta.add_theme_font_size_override("font_size", FS_META)
	meta.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(meta)

	# Description: prefer the long-form `desc`, fall back to `short_desc`.
	# ModWorkshop descriptions are Markdown (plus its {#hex}(...) color
	# extension). Convert to BBCode and render in a RichTextLabel so headings,
	# bold, lists, quotes, colors and links show instead of raw markup.
	var desc_str := str(mod_data.get("desc", "")).strip_edges()
	if desc_str.is_empty():
		desc_str = str(mod_data.get("short_desc", "")).strip_edges()
	if desc_str != "":
		box.add_child(HSeparator.new())
		var desc_hdr := Label.new()
		desc_hdr.text = "Description"
		desc_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		desc_hdr.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(desc_hdr)
		var desc_rt := RichTextLabel.new()
		desc_rt.bbcode_enabled = true
		desc_rt.text = _markdown_to_bbcode(desc_str)
		desc_rt.fit_content = true
		desc_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_rt.selection_enabled = true
		desc_rt.meta_underlined = true
		desc_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc_rt.add_theme_color_override("default_color", COL_TEXT)
		# Markdown links become [url=...]; open them in the system browser.
		# Allowlist web schemes only. The URL comes from an untrusted remote
		# description; OS.shell_open is ShellExecute on Windows, so an unchecked
		# file://, UNC (\\host\share\x.exe), or custom-scheme link could launch
		# arbitrary handlers off a link whose visible text looks harmless.
		desc_rt.meta_clicked.connect(func(meta):
			var u := str(meta).strip_edges()
			if u.to_lower().begins_with("http://") or u.to_lower().begins_with("https://"):
				OS.shell_open(u)
		)
		box.add_child(desc_rt)

	box.add_child(HSeparator.new())
	var files_hdr := Label.new()
	files_hdr.text = "Files"
	files_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	files_hdr.add_theme_color_override("font_color", COL_TEXT)
	box.add_child(files_hdr)
	var files_status := Label.new()
	files_status.text = "Loading file list..."
	files_status.add_theme_font_size_override("font_size", FS_BODY)
	files_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(files_status)
	var files_list := VBoxContainer.new()
	files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(files_list)

	var mod_id := int(mod_data.get("id", 0))
	# Pin Get + Open-page to the dialog's native button bar (alongside Close)
	# so they stay visible regardless of scroll position. add_button returns
	# the actual Button so we can update its text/disabled during the install
	# flow. right=false puts a button to the LEFT of the OK/Close button;
	# right=true puts it on the right.
	var page_btn := d.add_button("Open mod page in browser", false, "")
	page_btn.pressed.connect(func():
		OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(mod_id))
	)
	# Check install state inline (no access to the build_browse_tab closures
	# from here). If installed, render Get as disabled "Installed" so the
	# button reflects reality -- enable toggling lives on the list row.
	var already_installed := false
	for entry in _ui_mod_entries:
		var cfg_e: ConfigFile = entry.get("cfg")
		if cfg_e == null or not cfg_e.has_section_key("updates", "modworkshop"):
			continue
		if int(str(cfg_e.get_value("updates", "modworkshop", "0"))) == mod_id:
			already_installed = true
			break
	var get_btn := d.add_button("Installed" if already_installed else "Download", true, "")
	if already_installed:
		get_btn.disabled = true
	else:
		# The dialog's one primary action (spec section 6). List rows keep
		# bare-theme Download buttons -- primary is at most one per surface.
		style_primary_button(get_btn)
		var captured_data := mod_data
		get_btn.pressed.connect(func():
			on_get.call(captured_data, get_btn)
		)

	var primary_file_id := int(mod_data.get("download_id", 0))
	var load_files := func():
		var files_resp: Variant = await mws_list_files(mod_id)
		if not is_instance_valid(files_status):
			return
		if not (files_resp is Dictionary):
			files_status.text = mws_error_status("Could not load file history. Check your connection and try again.")
			files_status.add_theme_color_override("font_color", COL_ERR)
			return
		var files: Array = _mws_data_rows(files_resp)
		if files.is_empty():
			files_status.text = "No downloadable files yet."
			return
		files_status.queue_free()
		for file_v in files:
			if not (file_v is Dictionary):
				continue
			var fd: Dictionary = file_v
			var f_row := HBoxContainer.new()
			f_row.add_theme_constant_override("separation", SP_L)
			files_list.add_child(f_row)

			var v_lbl := Label.new()
			var v_str: String = "v" + str(fd.get("version", ""))
			if int(fd.get("id", 0)) == primary_file_id and primary_file_id > 0:
				v_str += " (primary)"
			v_lbl.text = v_str
			v_lbl.custom_minimum_size.x = 140
			f_row.add_child(v_lbl)

			var size_lbl := Label.new()
			size_lbl.text = _format_size(int(fd.get("size", 0)))
			size_lbl.custom_minimum_size.x = 80
			size_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(size_lbl)

			var date_str := str(fd.get("created_at", ""))
			if date_str.contains("T"):
				date_str = date_str.split("T")[0]
			var date_lbl := Label.new()
			date_lbl.text = date_str
			date_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(date_lbl)
	load_files.call()

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


func build_updates_tab() -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# The tab's one primary action.
	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	style_primary_button(check_btn)
	toolbar.add_child(check_btn)

	container.add_child(HSeparator.new())

	# Column headers: quiet meta labels over the list.
	var header_row := HBoxContainer.new()
	container.add_child(header_row)

	var h_mod := Label.new()
	h_mod.text = "Mod"
	h_mod.add_theme_font_size_override("font_size", FS_META)
	h_mod.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_mod)

	var h_ver := Label.new()
	h_ver.text = "Version"
	h_ver.add_theme_font_size_override("font_size", FS_META)
	h_ver.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_ver.custom_minimum_size.x = 90
	header_row.add_child(h_ver)

	var h_status := Label.new()
	h_status.text = "Status"
	h_status.add_theme_font_size_override("font_size", FS_META)
	h_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_status.custom_minimum_size.x = 160
	header_row.add_child(h_status)

	var h_action := Label.new()
	h_action.text = "Action"
	h_action.add_theme_font_size_override("font_size", FS_META)
	h_action.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_action.custom_minimum_size.x = 90
	header_row.add_child(h_action)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, mw_id, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var mw_id := 0
		if cfg.has_section_key("updates", "modworkshop"):
			mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

		var row := HBoxContainer.new()
		list.add_child(row)

		# Name column: mod name + last-modified date sub-label.
		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.tooltip_text = str(entry["mod_name"])
		# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
		name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		name_col.add_child(name_lbl)

		var mtime := FileAccess.get_modified_time(entry["full_path"])
		if mtime > 0:
			var dt := Time.get_datetime_dict_from_unix_time(mtime)
			var date_str := "%04d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
			var mod_lbl := Label.new()
			mod_lbl.text = "modified " + date_str
			mod_lbl.add_theme_font_size_override("font_size", FS_META)
			mod_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			name_col.add_child(mod_lbl)

		var ver_lbl := Label.new()
		ver_lbl.text = "v" + version if version != "" else "--"
		# A long prerelease string ("v2026.1.0-beta.3") must not push the
		# Status/Action columns out of alignment -- trim it to the column.
		ver_lbl.clip_text = true
		ver_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		ver_lbl.tooltip_text = ver_lbl.text
		ver_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		# Status text is state-driven ("Update: v...") and can outgrow the
		# column with long version strings; trim instead of shoving the
		# Action column sideways.
		status_lbl.clip_text = true
		status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		# PASS unconditionally: labels default to MOUSE_FILTER_IGNORE which
		# silently suppresses tooltips, and the check flow writes long state
		# text ("Update: v...") whose ellipsis needs a full-text tooltip.
		status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		if entry["ext"] == "folder":
			# Dev folders are the user's working copy on disk; downloading an
			# archive would land a duplicate next to the folder. Explain why
			# there is no Download button instead of offering one that misfires.
			status_lbl.text = "Dev folder"
			status_lbl.tooltip_text = "Dev folders update from your working copy. Update downloads only apply to archive mods."
		else:
			status_lbl.text = "No update info" if mw_id == 0 or version == "" else "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width. Use modulate.a to
		# hide it visually without collapsing its layout slot.
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if mw_id > 0 and version != "" and entry["ext"] != "folder":
			# Hold a reference to the underlying _ui_mod_entries dict so the
			# download callback can update full_path / file_name in place
			# when a successful update lands the archive under a new name.
			# GDScript dicts are reference-typed, so writing through here
			# mutates the canonical entry the next discovery pass sees.
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "mw_id": mw_id,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"], "entry": entry,
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods with update info yet.\nAdd [updates] modworkshop=<id> and version=<x.y.z> to mod.txt to enable update checks."
		lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	# -- Activity log ----------------------------------------------------------

	container.add_child(HSeparator.new())

	var log_hdr := Label.new()
	log_hdr.text = "Activity"
	log_hdr.add_theme_font_size_override("font_size", FS_BODY)
	log_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(log_hdr)

	var log_bg := PanelContainer.new()
	log_bg.custom_minimum_size.y = 72
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = COL_SURFACE_2
	log_style.content_margin_left = SP_M
	log_style.content_margin_right = SP_M
	log_style.content_margin_top = SP_S
	log_style.content_margin_bottom = SP_S
	log_bg.add_theme_stylebox_override("panel", log_style)
	container.add_child(log_bg)

	var log_scroll := ScrollContainer.new()
	log_bg.add_child(log_scroll)

	var log_list := VBoxContainer.new()
	log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_list)

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var lbl := Label.new()
		lbl.text = "[" + t + "] " + msg
		lbl.add_theme_font_size_override("font_size", FS_BODY)
		lbl.add_theme_color_override("font_color", COL_TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_list.add_child(lbl)
		log_scroll.scroll_vertical = 999999

	check_btn.pressed.connect(func():
		check_btn.disabled = true
		check_btn.text = "Checking for updates..."
		for fn in status_info:
			var info: Dictionary = status_info[fn]
			(info["label"] as Label).text = "Checking..."
			(info["label"] as Label).tooltip_text = "Checking..."
			(info["label"] as Label).add_theme_color_override("font_color", COL_TEXT_DIM)
			var btn: Button = info["dl_btn"]
			btn.modulate.a = 0.0
			btn.disabled = true
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.text = "Download"
		await check_updates_for_ui(status_info, add_log, check_btn)
		# The launcher can close (Launch clicked) while the check is in
		# flight; the button is freed with it. Mirrors the Mods-tab guard.
		if not is_instance_valid(check_btn):
			return
		check_btn.disabled = false
		check_btn.text = "Check for updates"
	)

	return margin

# Run an update check against every installed mod with valid [updates]
# modworkshop=N + version=. Populates the module-scope _mod_updates_state
# with entries for mods that have a newer version available. Returns a
# summary dict {checked, with_updates, errors}. Safe to call from any tab.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0}
	_mod_updates_check_in_progress = true
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	# Build a list of mods worth checking: must have both modworkshop= and version=.
	var pending: Array = []
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		# Dev folders cannot take a downloaded archive (it would land as a
		# duplicate beside the folder), so never flag them for updates.
		if str(entry.get("ext", "")) == "folder":
			continue
		if not cfg.has_section_key("updates", "modworkshop"):
			continue
		var mw_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
		if mw_id <= 0:
			continue
		var version := str(cfg.get_value("mod", "version", "")).strip_edges()
		if version == "":
			continue
		pending.append({
			"profile_key": str(entry.get("profile_key", "")),
			"mw_id": mw_id,
			"version": version,
			"full_path": str(entry.get("full_path", "")),
			"mod_name": str(entry.get("mod_name", "?")),
		})
	if pending.is_empty():
		_mod_updates_check_in_progress = false
		return summary
	# Batched fetch through the existing helper (handles batching, retry,
	# user-agent, etc.).
	var ids: Array[int] = []
	for p in pending:
		ids.append(int((p as Dictionary)["mw_id"]))
	var latest := await fetch_latest_modworkshop_versions(ids)
	for p in pending:
		summary["checked"] += 1
		var info: Dictionary = p
		var raw = latest.get(str(info["mw_id"]), null)
		if raw == null:
			summary["errors"] += 1
			continue
		var latest_v := str(raw)
		if latest_v.is_empty():
			continue
		var cmp := compare_versions(str(info["version"]), latest_v)
		if cmp >= 0:
			# Up to date -- drop any stale entry from a prior check.
			_mod_updates_state.erase(info["profile_key"])
			continue
		summary["with_updates"] += 1
		_mod_updates_state[info["profile_key"]] = {
			"latest_version": latest_v,
			"current_version": info["version"],
			"mw_id": info["mw_id"],
			"full_path": info["full_path"],
			"mod_name": info["mod_name"],
		}
	_mod_updates_check_in_progress = false
	return summary


func check_updates_for_ui(status_info: Dictionary, add_log: Callable, check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		return

	var latest := await fetch_latest_modworkshop_versions(ids)

	if not is_instance_valid(check_btn):
		return

	# A check just ran, so _mod_updates_state may have gained or lost entries.
	# This function runs from the Updates tab, where the Mods tab isn't visible
	# to refresh its own badges -- flag it so a later switch to the Mods tab
	# rebuilds and shows the promised per-row update badges.
	_mods_badges_dirty = true

	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var dl_btn: Button = info["dl_btn"]
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			lbl.text = "Check failed"
			# Rate-limit hint (spec section 7: what happened + what to do)
			# lives in the tooltip -- the full sentence would ellipsize in
			# this narrow column. Falls back to the plain text when no MWS
			# cooldown is armed.
			lbl.tooltip_text = mws_error_status(lbl.text)
			lbl.add_theme_color_override("font_color", COL_ERR)
			continue

		# Also surface state via _mod_updates_state so the Mods tab can show
		# the per-row badge without re-querying.
		var pre_entry: Dictionary = info.get("entry", {})
		var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			lbl.text = "Up to date"
			lbl.tooltip_text = lbl.text
			lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			if pk != "":
				_mod_updates_state.erase(pk)
		else:
			# Server has a newer version. Amber = the update signal. Tooltip
			# mirrors the text: long prerelease strings ellipsize in the
			# 160px column (label is MOUSE_FILTER_PASS at creation).
			lbl.text = "Update: v" + str(latest_v)
			lbl.tooltip_text = lbl.text
			lbl.add_theme_color_override("font_color", COL_AMBER)
			dl_btn.modulate.a = 1.0
			dl_btn.disabled = false
			dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			if pk != "":
				_mod_updates_state[pk] = {
					"latest_version": str(latest_v),
					"current_version": str(info["version"]),
					"mw_id": int(info["mw_id"]),
					"full_path": str(info["full_path"]),
					"mod_name": str(info["mod_name"]),
				}
			var full_path: String = info["full_path"]
			var mw_id: int = info["mw_id"]
			var mod_name: String = info["mod_name"]
			var new_ver: String = str(latest_v)
			# Disconnect previous connections so repeated checks don't stack callbacks.
			for c in dl_btn.pressed.get_connections():
				dl_btn.pressed.disconnect(c["callable"])
			dl_btn.pressed.connect(func():
				dl_btn.disabled = true
				dl_btn.text = "Downloading..."
				lbl.text = "Downloading..."
				lbl.tooltip_text = lbl.text
				lbl.add_theme_color_override("font_color", COL_AMBER)
				check_btn.disabled = true
				# Re-resolve live: the Mods-tab badge may have updated/renamed this
				# file since the Updates tab was built, orphaning the captured path.
				var live_path: String = _live_full_path(pk, full_path)
				var result: Dictionary = await download_and_replace_mod(live_path, mw_id)
				if not is_instance_valid(check_btn):
					return
				if not is_instance_valid(dl_btn):
					return
				check_btn.disabled = false
				if result.get("ok", false):
					lbl.text = "Updated -- restart to apply"
					lbl.tooltip_text = lbl.text
					lbl.add_theme_color_override("font_color", COL_OK)
					dl_btn.modulate.a = 0.0
					dl_btn.disabled = true
					dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
					dl_btn.text = "Download"
					# Update cached version so next Check won't re-flag this mod.
					info["version"] = new_ver
					(info["ver_lbl"] as Label).text = "v" + new_ver
					(info["ver_lbl"] as Label).tooltip_text = "v" + new_ver
					# Drop the shared badge state so the Mods tab stops
					# offering an update that was just installed (mirrors the
					# badge-path erase after a successful download).
					if pk != "":
						_mod_updates_state.erase(pk)
					# Reflect the on-disk rename in the in-memory entry so the
					# next discovery pass (and any subsequent UI rebuild before
					# relaunch) point at the right archive instead of the old
					# filename that no longer exists.
					var new_path: String = result.get("new_path", full_path)
					var new_fn: String = result.get("new_file_name", full_path.get_file())
					info["full_path"] = new_path
					var entry_ref: Dictionary = info.get("entry", {})
					if not entry_ref.is_empty():
						entry_ref["full_path"] = new_path
						entry_ref["file_name"] = new_fn
					var rename_note: String = (" (renamed to " + new_fn + ")") if new_fn != full_path.get_file() else ""
					add_log.call(mod_name + " -- updated to v" + new_ver + rename_note + ". Restart game to apply.")
				else:
					lbl.text = "Download failed"
					lbl.tooltip_text = lbl.text
					lbl.add_theme_color_override("font_color", COL_ERR)
					dl_btn.disabled = false
					dl_btn.text = "Retry"
					add_log.call("Could not download " + mod_name + ". Check your connection and try again.")
			)

# ----- modloader self-update check ----------------------------------------

# Fire-and-forget from show_mod_ui. Hits the ModWorkshop versions API for
# our own mod id, compares the result against MODLOADER_VERSION, and on a
# newer release: recolors the always-visible launch-row version LinkButton
# (and rewrites its text), and pops a one-shot
# dialog the first session each new version is detected. All UI mutations
# guard on is_instance_valid because the launcher may close before the
# HTTP request returns.
func _check_modloader_update_async() -> void:
	if MODLOADER_MODWORKSHOP_ID <= 0:
		return
	var ids: Array[int] = [MODLOADER_MODWORKSHOP_ID]
	var latest_map: Dictionary = await fetch_latest_modworkshop_versions(ids)
	var raw = latest_map.get(str(MODLOADER_MODWORKSHOP_ID), null)
	if raw == null:
		return
	var latest := str(raw)
	if latest.is_empty():
		return
	_modloader_latest_version = latest
	# Exact match first: when ModWorkshop publishes the very version we are
	# running (including a prerelease like "3.3.0-beta.1"), there is nothing
	# to update to -- without this the base-version compare below would flag
	# our own version as an update every session.
	if latest == MODLOADER_VERSION:
		return
	# Prerelease-aware gate. compare_versions() mis-parses "3.3.0-beta.1" as
	# 3.3.0.1, which ranks it ABOVE the eventual "3.3.0" stable (muting the
	# prompt forever) AND above an older "3.3.0-beta.2" install (offering a
	# downgrade). Semver rule: a prerelease precedes its release. So compare
	# base versions first, then break equal-base ties on the prerelease tails:
	# a stable supersedes any same-base prerelease; between two prereleases,
	# only a strictly higher one is an update. Dormant on stable builds (no
	# "-" in MODLOADER_VERSION -> installed_pre empty -> identical behavior).
	var installed_base := MODLOADER_VERSION.split("-")[0]
	var latest_base := latest.split("-")[0]
	var base_cmp := compare_versions(latest_base, installed_base)
	if base_cmp < 0:
		return  # installed base is newer
	if base_cmp == 0:
		# Same base version -- decide on the prerelease suffixes. compare_versions
		# can't do this: it parses "3.3.0-beta.1" as 3.3.0.1 (the "-beta" segment
		# reads as 0), which would rank ANY same-base prerelease above the base
		# and even flag an OLDER prerelease as an update (a downgrade prompt).
		var installed_pre := MODLOADER_VERSION.substr(installed_base.length()).lstrip("-")
		var latest_pre := latest.substr(latest_base.length()).lstrip("-")
		if installed_pre == "":
			return  # installed is the stable base; a same-base prerelease is not an upgrade
		if latest_pre == "":
			pass  # latest is the stable release of our prerelease -> offer it
		elif _compare_prerelease(latest_pre, installed_pre) <= 0:
			return  # latest prerelease is the same as or older than installed

	if is_instance_valid(_ui_update_alert_btn):
		_ui_update_alert_btn.text = "v%s available, click to update" % latest
		# Amber is the update signal (spec: the one accent); an available
		# update is a notice, not an error, so no red here.
		_ui_update_alert_btn.add_theme_color_override("font_color", COL_AMBER)
		_ui_update_alert_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)

	# Pop the dialog only the first session this specific new version is
	# seen. Stays quiet on subsequent launches until ModWorkshop ships a
	# newer one. The launch-row alert remains visible regardless.
	var last_seen := _modloader_update_last_seen_version()
	if last_seen != latest:
		_show_modloader_update_dialog(latest)

func _modloader_update_last_seen_version() -> String:
	return str(_get_ui_cfg_value("modloader_update", "last_seen_version", ""))

func _modloader_update_mark_seen(latest: String) -> void:
	_set_ui_cfg_value("modloader_update", "last_seen_version", latest)

# One-shot popup the first session each new modloader version is detected.
# "Open Page" launches the ModWorkshop browser tab; either action writes the
# latest version into mod_config.cfg so the dialog stays quiet on subsequent
# launches until ModWorkshop ships another version.
func _show_modloader_update_dialog(latest: String) -> void:
	if not is_instance_valid(_ui_window):
		return
	var d := ConfirmationDialog.new()
	d.title = "Mod Loader update available"
	d.ok_button_text = "Open page"
	d.cancel_button_text = "Dismiss"
	d.dialog_autowrap = true
	d.min_size = Vector2(440, 120)
	d.dialog_text = "A newer version of the Mod Loader is available on ModWorkshop.\n\n" \
			+ "    Installed: v%s\n    Available: v%s\n\n" % [MODLOADER_VERSION, latest] \
			+ "Open the ModWorkshop page to download?"
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	_connect_dialog_exits(d,
		func():
			OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(MODLOADER_MODWORKSHOP_ID))
			_modloader_update_mark_seen(latest)
			d.queue_free(),
		func():
			_modloader_update_mark_seen(latest)
			d.queue_free()
	)
	d.popup_centered()
