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

# User-chosen launcher zoom, as a content_scale_factor. 1.0 = native (the
# 3.3.0 look). Read straight from the config rather than cached in a var so the
# reopen path picks up a change made in an earlier session. Clamped because a
# hand-edited config could otherwise produce a window nobody can click out of.
func _ui_scale_setting() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return 1.0
	return clampf(float(cfg.get_value("settings", "ui_scale", 1.0)), 1.0, 2.0)

# Apply a launcher zoom to the window: content scale plus a matching window
# size. Also used when the user changes the setting live, so it must be safe to
# call on an already-sized window -- min_size is dropped to zero first, since
# shrinking the scale while the old (larger) minimum is still in force would
# clamp the new size back up.
func _apply_ui_scale(win: Window, ui_scale: float) -> void:
	if not is_instance_valid(win):
		return
	win.content_scale_factor = ui_scale
	var want := Vector2i(roundi(960.0 * ui_scale), roundi(640.0 * ui_scale))
	var want_min := Vector2i(roundi(640.0 * ui_scale), roundi(420.0 * ui_scale))
	# A scaled window must still FIT the display: clamp to the usable area
	# (minus room for taskbar/chrome) so the Launch bar can never land
	# off-screen, and keep min_size <= size or Godot rejects the pair.
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen).size
	if usable.x > 0 and usable.y > 0:
		want.x = mini(want.x, maxi(320, usable.x - 40))
		want.y = mini(want.y, maxi(240, usable.y - 40))
	want_min.x = mini(want_min.x, want.x)
	want_min.y = mini(want_min.y, want.y)
	win.min_size = Vector2i.ZERO
	win.size = want
	win.min_size = want_min

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
		var migrated := false
		if cfg.has_section("enabled"):
			for key: String in cfg.get_section_keys("enabled"):
				cfg.set_value("profile.Default.enabled", key, cfg.get_value("enabled", key))
			migrated = true
		if cfg.has_section("priority"):
			for key: String in cfg.get_section_keys("priority"):
				cfg.set_value("profile.Default.priority", key, cfg.get_value("priority", key))
			migrated = true
		# Persist immediately: _save_ui_config reloads the cfg from DISK and
		# rebuilds profile.Default from live entries, so its preservation pass
		# can only protect migrated keys (deleted mods, dev-hidden folder mods)
		# if the profile.Default.* sections already exist on disk. Without this
		# write, those keys are dropped for good on the first post-upgrade save.
		if migrated:
			_persist_ui_cfg(cfg)

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
	# Flush a pending debounced priority edit BEFORE reloading. A load-order
	# drag arms the 0.4s _schedule_priority_save timer and the edit lives only
	# in _ui_mod_entries until it fires; the reload below replaces those dicts
	# from the on-disk config, so an async download completing mid-window would
	# silently revert the edit -- and the late timer would then persist the
	# reverted state. Same flush _switch_profile does for the same race.
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
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
	# Refresh the outgoing profile's MCM snapshot before switching, same as
	# _switch_profile -- otherwise MCM edits made
	# while it was active are captured only into the NEW profile's slot, and
	# switching back later restores a stale snapshot over them.
	var old := _active_profile
	if old != VANILLA_PROFILE and old != name:
		_snapshot_mcm_to(old)
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
				# store_buffer returns bool since 4.3 -- a full disk can leave a
				# truncated file behind. Log it so an incomplete MCM restore
				# (which wipes user://MCM first) isn't silently invisible.
				if not dst_f.store_buffer(bytes):
					_log_warning("[MCM] Failed writing " + dst_full + " (disk full?) -- copy incomplete")
				dst_f.close()
				any = true
			else:
				_log_warning("[MCM] Cannot open " + dst_full + " for write -- copy incomplete")
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

