## ----- ui.gd -----
## The launcher window: Mods, Browse, Modpacks and Updates tabs plus the Launch
## bar. Profiles live in UI_CONFIG_PATH under profile.<name>.*; the active one
## in [settings] active_profile. Closing the window is the same as Launch.

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		# Read from the same .bak _load_ui_config recovers from; otherwise a
		# recoverable corrupt config strands every folder mod for the session.
		var bak := UI_CONFIG_PATH + ".bak"
		if not (FileAccess.file_exists(bak) and cfg.load(bak) == OK):
			return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

# Launcher zoom, read from config each call so the reopen path sees changes.
func _ui_scale_setting() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return 1.0
	return clampf(float(cfg.get_value("settings", "ui_scale", 1.0)), 1.0, 2.0)

# Apply a launcher zoom: content scale plus matching window size. min_size
# is dropped first so shrinking is not clamped back up by the old minimum.
func _apply_ui_scale(win: Window, ui_scale: float) -> void:
	if not is_instance_valid(win):
		return
	win.content_scale_factor = ui_scale
	var want := Vector2i(roundi(960.0 * ui_scale), roundi(640.0 * ui_scale))
	var want_min := Vector2i(roundi(640.0 * ui_scale), roundi(420.0 * ui_scale))
	# Clamp to the usable display area so the Launch bar stays on-screen;
	# keep min_size <= size or Godot rejects the pair.
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
		# Live config missing or corrupt. Try the rolling .bak before falling
		# through to a fresh Default, which would wipe every stored profile.
		var bak := UI_CONFIG_PATH + ".bak"
		var bak_cfg := ConfigFile.new()
		if FileAccess.file_exists(bak) and bak_cfg.load(bak) == OK:
			_log_warning("[Config] " + UI_CONFIG_PATH + " unreadable; recovered from .bak")
			# Keep the unreadable file as .corrupt, then write the recovered state
			# back with a raw save so the corrupt file is not copied over the backup.
			if FileAccess.file_exists(UI_CONFIG_PATH):
				DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt")
			cfg = bak_cfg
			cfg.save(UI_CONFIG_PATH)
		else:
			# Fresh install, or the backup is also unreadable: materialize the
			# Default profile on disk, preserving any corrupt live config as .corrupt.
			if FileAccess.file_exists(UI_CONFIG_PATH):
				if DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt") == OK:
					# Remove the live copy so _load_ui_cfg_for_write's unreadable-file
					# guard does not refuse this save and every later one.
					DirAccess.remove_absolute(UI_CONFIG_PATH)
			_save_ui_config()
			return

	# Migrate legacy flat [enabled]/[priority] into profile.Default.* on the
	# first post-upgrade load; the next save drops the flat sections.
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
		# Persist now: _save_ui_config reloads from disk, so its preservation
		# pass only protects migrated keys once profile.Default.* is on disk.
		if migrated:
			_persist_ui_cfg(cfg)

	var stored := str(cfg.get_value("settings", "active_profile", "Default"))
	var profiles := _list_profiles_in_cfg(cfg)
	# Older configs may store VANILLA_PROFILE; treat it as missing.
	if stored == VANILLA_PROFILE:
		stored = ""
	if stored in profiles:
		_active_profile = stored
	elif not profiles.is_empty():
		_active_profile = profiles[0]
	else:
		_active_profile = "Default"

	# Reconcile modpack state. A managed slot (modpack__X) is a legitimate
	# active profile only while active_modpack names it; a mismatch means a
	# crash mid-apply/unload. Recover to a user profile and clear stale flags.
	var active_mp := str(cfg.get_value("settings", "active_modpack", ""))
	var mp_dirty := false
	if _is_modpack_managed_profile(_active_profile) \
			and _active_profile != MODPACK_PROFILE_PREFIX + active_mp:
		# Restore override files and roll live MCM back to the pre-apply
		# snapshot, keyed off the slot name since active_mp may be blank; without
		# the rollback the next profile switch would capture the pack's MCM.
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
		# active_modpack set but its slot never reached (crash between apply and
		# _switch_profile): best-effort restore via the manifest, then clear the flag.
		_restore_modpack_overrides(MODPACK_BACKUP_PREFIX + active_mp)
		active_mp = ""
		mp_dirty = true
	if mp_dirty:
		cfg.set_value("settings", "active_modpack", active_mp)
		_persist_ui_cfg(cfg)

	_apply_profile_to_entries(cfg, _active_profile)

	# Materialize Default on disk when it resolved as active but was not
	# stored; otherwise it is only a placeholder that vanishes when a named
	# profile is created. has_any_profile predates the in-memory migration.
	if _active_profile == "Default" and not has_any_profile:
		_save_ui_config()

func _apply_profile_to_entries(cfg: ConfigFile, profile: String) -> void:
	# VANILLA_PROFILE has no stored sections and reads as all mods off.
	var is_vanilla := profile == VANILLA_PROFILE
	_load_per_profile_settings(cfg, profile)
	var en_sec := _profile_sec(profile, ".enabled")
	var pr_sec := _profile_sec(profile, ".priority")
	var ig_sec := _profile_sec(profile, ".dep_ignore")
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		entry.erase("profile_version_mismatch")
		# Exact profile_key match first; else id-prefix match ("<mod_id>@*")
		# so a version bump carries the stored state, flagged for the UI.
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
		else:
			# No declared id, so the stored key is the old filename; match on stem
			# so a re-package does not orphan the settings.
			resolved_key = _find_stored_key_for_zip_stem(cfg, profile, entry["file_name"])
		if is_vanilla:
			entry["enabled"] = false
		elif resolved_key != "" and cfg.has_section_key(en_sec, resolved_key):
			entry["enabled"] = bool(cfg.get_value(en_sec, resolved_key))
		else:
			# Auto-enable on Default only; on any other profile a freshly
			# discovered mod is opt-in.
			entry["enabled"] = profile == "Default"
		if resolved_key != "" and cfg.has_section_key(pr_sec, resolved_key):
			entry["priority"] = int(str(cfg.get_value(pr_sec, resolved_key)))
		# "Load anyway" overrides are sparse: only keys the user set are stored.
		if is_vanilla:
			entry["dependency_ignored"] = false
		else:
			var ig_key := pk if cfg.has_section_key(ig_sec, pk) else resolved_key
			entry["dependency_ignored"] = ig_key != "" \
					and bool(cfg.get_value(ig_sec, ig_key, false))
	_refresh_dependency_status()

# Per-profile UI settings live in profile.<name>.settings, separate from
# .enabled/.priority so _save_ui_config's erase-and-rewrite leaves them alone.
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
	# No _dirty_since_boot: these are view filters, and marking dirty would
	# restart the game on the reopen path over a list toggle.

# True when the entry passes the active mods-tab filters.
func _mods_entry_visible(entry: Dictionary) -> bool:
	if _mods_hide_disabled and not bool(entry.get("enabled", false)):
		return false
	if _mods_filter_text != "":
		var needle := _mods_filter_text.to_lower()
		var hay := str(entry.get("mod_name", "")).to_lower()
		if not hay.contains(needle):
			return false
	return true

# Stored profile key matching mod_id at a different version; "" if none.
# The "@" guards against partial-id collisions ("foo" vs "foobar@1.0").
func _find_stored_key_for_mod_id(cfg: ConfigFile, profile: String, mod_id: String) -> String:
	var prefix := mod_id + "@"
	for suffix: String in [".enabled", ".priority"]:
		var sec := _profile_sec(profile, suffix)
		if cfg.has_section(sec):
			for key: String in cfg.get_section_keys(sec):
				if key.begins_with(prefix):
					return key
	return ""

# Stored "zip:<file_name>" key for a mod with no declared id, matched on
# the normalized stem. Two stored keys reducing to the same stem return ""
# so the mod falls through to the new-mod path rather than guess.
func _find_stored_key_for_zip_stem(cfg: ConfigFile, profile: String, file_name: String) -> String:
	var want := _normalized_mod_stem(file_name)
	if want.is_empty():
		return ""
	var hit := ""
	for suffix: String in [".enabled", ".priority"]:
		var sec := _profile_sec(profile, suffix)
		if not cfg.has_section(sec):
			continue
		for key: String in cfg.get_section_keys(sec):
			if not key.begins_with("zip:"):
				continue
			if _normalized_mod_stem(key.trim_prefix("zip:")) != want:
				continue
			if hit != "" and hit != key:
				return ""
			hit = key
	return hit

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
			# VANILLA_PROFILE is a sentinel; leaked ghost sections must not show.
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	# Profiles with only a priority section (partial state) count too.
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

# User-selectable profiles only, excluding modpack-managed slots. Any code
# that picks a profile for the user to land on must use this, or the user
# can be switched into a pack-managed slot and corrupt it.
func _list_user_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	return _list_profiles_in_cfg(cfg).filter(
			func(n: String): return not _is_modpack_managed_profile(n))

# Coalesce rapid priority edits into one save per ~0.4s window.
func _schedule_priority_save() -> void:
	if _priority_save_pending:
		return
	_priority_save_pending = true
	await get_tree().create_timer(0.4).timeout
	# A profile switch may have flushed during the wait; do not re-save stale state.
	if not _priority_save_pending:
		return
	_priority_save_pending = false
	_save_ui_config()

# Maps for the stored-key preservation pass: live profile_keys, and mod_ids
# of installed non-zip-keyed entries (to drop stale versioned keys).
func _collect_live_profile_key_maps() -> Dictionary:
	var live_keys: Dictionary = {}
	var installed_ids: Dictionary = {}
	for entry in _ui_mod_entries:
		var lk: String = str(entry["profile_key"])
		live_keys[lk] = true
		if not lk.begins_with("zip:"):
			installed_ids[str(entry["mod_id"])] = true
	return {"live": live_keys, "ids": installed_ids}

# True when a stored profile key must survive _save_ui_config's erase and
# rewrite: keys with a live entry are rewritten from memory; everything else
# (dev-hidden folder mods, missing mods) is kept, except a stale versioned
# key whose id resolves to an installed mod, whose state already migrated.
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
	# Only the active profile's sections are rebuilt; the rest are carried
	# over from the loaded file, so an unreadable cfg must not be written.
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return

	# Drop legacy flat sections if they linger after migration.
	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")

	# The Vanilla sentinel must never materialize stored sections.
	if _active_profile != VANILLA_PROFILE:
		var en_sec := _profile_sec(_active_profile, ".enabled")
		var pr_sec := _profile_sec(_active_profile, ".priority")
		var ig_sec := _profile_sec(_active_profile, ".dep_ignore")
		# Keep stored keys with no live entry (see _preserve_stored_profile_key).
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

# Persist the UI config with a rolling backup: ConfigFile.save truncates
# then writes and there is no Windows-safe atomic rename, so copy the good
# file to .bak first. Best-effort; returns the ConfigFile.save error.
func _persist_ui_cfg(cfg: ConfigFile) -> int:
	if FileAccess.file_exists(UI_CONFIG_PATH):
		DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")
	return cfg.save(UI_CONFIG_PATH)

func _profile_sec(name: String, suffix: String) -> String:
	return "profile." + name + suffix

# Every per-profile section suffix; use only when wiping or renaming a whole
# profile. The [".enabled", ".priority"] loops elsewhere are intentional.
const PROFILE_SUBSECTIONS := [".enabled", ".priority", ".settings", ".dep_ignore"]

# Read a single value from mod_config.cfg; `default` when missing/unparseable.
func _get_ui_cfg_value(section: String, key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return default
	return cfg.get_value(section, key, default)

# Load mod_config.cfg for a partial write. Persisting a cfg that failed to
# load would replace every profile with the caller's few keys, so any load
# error other than a missing file returns null and the change stays
# in-memory; the refusal is surfaced once in the launcher.
var _ui_cfg_refusal_notified := false

func _load_ui_cfg_for_write() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := cfg.load(UI_CONFIG_PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		_log_warning("mod_config.cfg exists but could not be read (error %d) -- refusing to overwrite it. This change is not saved." % err)
		if not _ui_cfg_refusal_notified and is_instance_valid(_ui_window):
			_ui_cfg_refusal_notified = true
			_show_error_dialog("Settings cannot be saved",
					"Your settings file (mod_config.cfg) cannot be read right now, so changes made in this session will not be saved. Your existing profiles are untouched. Restart the game to recover.")
		return null
	return cfg

func _set_ui_cfg_value(section: String, key: String, value: Variant) -> void:
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	cfg.set_value(section, key, value)
	_persist_ui_cfg(cfg)

# Resolve a mod's current on-disk path by profile key. _ui_mod_entries is
# reassigned on any rescan, orphaning a full_path captured at row build
# time. Returns `fallback` when the mod is not in the current scan.
func _live_full_path(profile_key: String, fallback: String) -> String:
	if profile_key == "":
		return fallback
	for cur in _ui_mod_entries:
		if str(cur.get("profile_key", "")) == profile_key:
			return str(cur.get("full_path", fallback))
	return fallback

# Same staleness hazard for whole entry dicts: re-resolve by profile key
# after any await; falls back to the captured dict when the mod left the scan.
func _live_entry_for_profile_key(profile_key: String, fallback: Dictionary) -> Dictionary:
	if profile_key == "":
		return fallback
	for cur in _ui_mod_entries:
		if str(cur.get("profile_key", "")) == profile_key:
			return cur
	return fallback

# Re-scan mods from disk and re-apply the active profile's state. Called
# after any surface adds, removes or updates a mod file.
func _reload_entries_for_active_profile() -> void:
	# Flush a pending debounced priority edit first: the reload replaces the
	# entry dicts, and the late timer would persist the reverted state.
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
	_ui_mod_entries = collect_mod_metadata()
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)
	_mark_mod_set_changed()

# The on-disk mod set changed after boot; a post-boot session restarts into
# it on close, the same convention as a profile switch.
func _mark_mod_set_changed() -> void:
	if _boot_complete:
		_dirty_since_boot = true

# Snapshot the in-memory state to a new profile and switch to it. Caller
# validates `name`. Seeds the new profile's MCM slot from user://MCM/.
func _create_profile(name: String) -> void:
	# Refresh the outgoing profile's MCM snapshot first, as _switch_profile does.
	var old := _active_profile
	if old != VANILLA_PROFILE and old != name:
		_snapshot_mcm_to(old)
	_active_profile = name
	_save_ui_config()
	_snapshot_mcm_to(name)

# Delete the active profile's sections and its MCM snapshot, then switch to
# the first remaining profile. Caller ensures another profile exists.
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
	# Land on a real user profile only, never a modpack-managed slot.
	var remaining := _list_user_profiles_in_cfg(cfg)
	if remaining.is_empty():
		_active_profile = "Default"
	else:
		_active_profile = remaining[0]
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	# Restore the new active profile's MCM if it has one (Vanilla has none).
	if _active_profile != VANILLA_PROFILE and _has_mcm_snapshot(_active_profile):
		_restore_mcm_from(_active_profile)
	if _boot_complete:
		_dirty_since_boot = true

# Swap in-memory mod state to an existing profile: snapshot the outgoing
# MCM, restore (or first-switch seed) the incoming one. Same-profile is a
# no-op; snapshot-then-restore on one name would clobber unsaved MCM edits.
func _switch_profile(name: String) -> void:
	var old := _active_profile
	if old == name:
		return
	# Flush a pending debounced priority edit while _active_profile is still
	# `old`, or the late timer would save under the wrong profile.
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
	if old != VANILLA_PROFILE and old != name:
		_snapshot_mcm_to(old)
	_active_profile = name
	var cfg := _load_ui_cfg_for_write()
	if cfg != null:
		cfg.set_value("settings", "active_profile", _active_profile)
		_persist_ui_cfg(cfg)
	else:
		# Unreadable cfg: do not rewrite it, but still apply what is readable.
		cfg = ConfigFile.new()
		cfg.load(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)
	if name != VANILLA_PROFILE:
		if _has_mcm_snapshot(name):
			_restore_mcm_from(name)
		else:
			# First-time switch: seed the slot from current user://MCM/.
			_snapshot_mcm_to(name)
	if _boot_complete:
		_dirty_since_boot = true

# Rename the active profile: save under the new name, then erase the old
# sections and rename the MCM snapshot dir.
func _rename_profile(new_name: String) -> void:
	var old := _active_profile
	if old == new_name:
		return
	_active_profile = new_name
	_save_ui_config()
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	# .settings has no in-memory backing, so copy it explicitly.
	var old_settings := _profile_sec(old, ".settings")
	var new_settings := _profile_sec(new_name, ".settings")
	if cfg.has_section(old_settings):
		for key: String in cfg.get_section_keys(old_settings):
			cfg.set_value(new_settings, key, cfg.get_value(old_settings, key))
	# Stored keys with no live entry still live only under the old name;
	# carry them across before erasing the old sections.
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
# Each user profile owns a snapshot of user://MCM/ at
# user://.profile_snapshots/<profile>/MCM/. Switching snapshots the outgoing
# profile's MCM, then restores (or seeds) the incoming one; switching to
# Vanilla leaves user://MCM/ untouched.

func _mcm_snapshot_dir(profile_name: String) -> String:
	return MCM_SNAPSHOT_BASE.path_join(profile_name).path_join("MCM")

func _has_mcm_snapshot(profile_name: String) -> bool:
	return DirAccess.dir_exists_absolute(_mcm_snapshot_dir(profile_name))

# Recursively copy src/ -> dst/, replacing dst/. Returns true when the source
# had at least one entry; false if it didn't exist or was empty. Dot-prefixed
# entries are skipped unless include_hidden is set; the profile and MCM swaps
# rely on the skip, the modpack restore points need the hidden files back.
func _copy_dir_recursive(src: String, dst: String, include_hidden: bool = false) -> bool:
	if not DirAccess.dir_exists_absolute(src):
		return false
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return false
	# On Linux/macOS dot entries are hidden and omitted by default.
	dir.include_hidden = include_hidden
	var any := false
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if name.begins_with(".") and not include_hidden:
			continue
		var src_full := src.path_join(name)
		var dst_full := dst.path_join(name)
		if dir.current_is_dir():
			_copy_dir_recursive(src_full, dst_full, include_hidden)
			any = true
		else:
			var src_f := FileAccess.open(src_full, FileAccess.READ)
			if src_f == null:
				continue
			var bytes := src_f.get_buffer(src_f.get_length())
			src_f.close()
			var dst_f := FileAccess.open(dst_full, FileAccess.WRITE)
			if dst_f != null:
				# A full disk can leave a truncated file; log it.
				if not dst_f.store_buffer(bytes):
					_log_warning("[MCM] Failed writing " + dst_full + " (disk full?) -- copy incomplete")
				dst_f.close()
				any = true
			else:
				_log_warning("[MCM] Cannot open " + dst_full + " for write -- copy incomplete")
	dir.list_dir_end()
	return any

# Recursively delete a directory and its contents.
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
	# Replace user://MCM/ wholesale; a partial overlay would leak old files.
	_remove_dir_recursive(MCM_SOURCE_DIR)
	return _copy_dir_recursive(src, MCM_SOURCE_DIR)

func _delete_mcm_snapshot(profile_name: String) -> void:
	_remove_dir_recursive(_mcm_snapshot_dir(profile_name))
	var parent := MCM_SNAPSHOT_BASE.path_join(profile_name)
	if DirAccess.dir_exists_absolute(parent):
		DirAccess.remove_absolute(parent)

func _rename_mcm_snapshot(old_name: String, new_name: String) -> void:
	var old_parent := MCM_SNAPSHOT_BASE.path_join(old_name)
	var new_parent := MCM_SNAPSHOT_BASE.path_join(new_name)
	if not DirAccess.dir_exists_absolute(old_parent):
		return
	DirAccess.make_dir_recursive_absolute(MCM_SNAPSHOT_BASE)
	var da := DirAccess.open(MCM_SNAPSHOT_BASE)
	if da != null:
		da.rename(old_name, new_name)

# --- Profile <-> zip serialization -----------------------------------------
# Zip layout: "profile.json" at the root plus an optional "MCM/" tree
# mirroring user://MCM/. No new file extension; contents are sniffed on load.

## The host reference an installed mod resolves to: mod.txt's source= (or
## legacy modworkshop=), else the [mod_sources] record cached at install
## time. {} when neither names a host. `persisted` is _get_persisted_mod_sources().
func _entry_host_ref(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var rec := _entry_source_record(entry, persisted)
	if str(rec["provider"]) == "":
		return {}
	return host_ref(str(rec["provider"]), str(rec["id"]))


## The full source record behind _entry_host_ref: {provider, id, version},
## provider "" when the mod has no known host. mod.txt wins.
func _entry_source_record(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var rec := _mod_source_from_cfg(entry.get("cfg"))
	if str(rec["provider"]) == "":
		rec = _normalize_source_record(persisted.get(str(entry.get("profile_key", ""))))
	return rec


func _build_profile_sources() -> Dictionary:
	var sources: Dictionary = {}
	var persisted := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var rec := _entry_source_record(entry, persisted)
		if str(rec["provider"]) == "":
			continue
		sources[str(entry["profile_key"])] = _mod_source_payload(rec)
	return sources

# Persisted author name auto-filling the save-as-modpack dialog; "" if unset.
func _load_preferred_author() -> String:
	return str(_get_ui_cfg_value("settings", "preferred_author", ""))

# Persist the preferred author for future modpack saves; empty clears it.
func _save_preferred_author(author: String) -> void:
	_set_ui_cfg_value("settings", "preferred_author", author)


# Enabled mods with no known host. They export without download info, so
# the save-as-modpack confirm warns about them. Each is {mod_name, profile_key}.
func _enabled_mods_without_source() -> Array:
	var out: Array = []
	var persisted := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		if not bool(entry.get("enabled", false)):
			continue
		if _entry_host_ref(entry, persisted).is_empty():
			out.append({
				"mod_name": str(entry.get("mod_name", "?")),
				"profile_key": str(entry.get("profile_key", "?")),
			})
	return out

# Build a profile zip at output_path: profile.json plus the MCM snapshot.
# Returns {"ok": true, "mod_count": int} or {"error": "..."}; cleans up partial output.
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
	var wrote_json := packer.write_file(json_str.to_utf8_buffer())
	packer.close_file()
	if wrote_json != OK:
		packer.close()
		if FileAccess.file_exists(output_path):
			DirAccess.remove_absolute(output_path)
		return {"error": "Failed while writing the modpack (out of disk space?)."}

	var mcm_ok := true
	if DirAccess.dir_exists_absolute(MCM_SOURCE_DIR):
		mcm_ok = _zip_folder_recursive(packer, MCM_SOURCE_DIR, "MCM")

	# close() writes the central directory; a failure here or an incomplete
	# MCM snapshot means a corrupt pack, so do not report success.
	var close_err := packer.close()
	if close_err != OK or not mcm_ok:
		if FileAccess.file_exists(output_path):
			DirAccess.remove_absolute(output_path)
		return {"error": "The modpack could not be written completely. Check disk space and try again."}
	# Count enabled mods from the payload just written; a parse failure reads as 0.
	var mod_count := 0
	var parsed_v: Variant = JSON.parse_string(json_str)
	if parsed_v is Dictionary and (parsed_v as Dictionary).get("enabled") is Dictionary:
		mod_count = ((parsed_v as Dictionary)["enabled"] as Dictionary).size()
	return {"ok": true, "mod_count": mod_count}

# Write an MCM data map (relative_path -> bytes) into a profile's snapshot
# slot. Creates the dir even when mcm_data is empty, or _has_mcm_snapshot
# would be false and _switch_profile would seed from the previous profile.
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
		if not f.store_buffer(bytes):
			_log_warning("[MCM] Failed writing " + dst + " (disk full?) -- snapshot incomplete")
		f.close()

# The metroprofile v1 schema is fixed; docs/wiki/Profile-Format.md has the
# full spec. Changes to the export/import shape require a schema version
# bump so old parsers reject cleanly.

# Serialize the named profile to a JSON string; "" if it has no stored
# sections. Sole writer of the metroprofile v1 payload: profile-state fields
# must be read by _materialize_modpack_profile (modpacks.gd) or they drop.
# New fields stay optional per docs/wiki/Profile-Format.md.
func _profile_to_json_string(profile_name: String, description: String = "", author: String = "", display_name: String = "") -> String:
	# display_name is the payload "name"; profile_name selects the sections read.
	var src := ConfigFile.new()
	if src.load(UI_CONFIG_PATH) != OK:
		return ""
	var en_sec := _profile_sec(profile_name, ".enabled")
	var pr_sec := _profile_sec(profile_name, ".priority")
	if not src.has_section(en_sec):
		return ""
	# Only enabled mods go in; the pack never tracks mods the author was not using.
	var enabled: Dictionary = {}
	for key: String in src.get_section_keys(en_sec):
		if bool(src.get_value(en_sec, key)):
			enabled[key] = true
	var priority: Dictionary = {}
	if src.has_section(pr_sec):
		for key: String in src.get_section_keys(pr_sec):
			if enabled.has(key):
				priority[key] = int(str(src.get_value(pr_sec, key)))
	# dep_ignore overrides, sparse; optional v1 field.
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
	# Sources for enabled mods only. `enabled` keys come from disk and source
	# keys are live profile_keys; the two can disagree on version or id casing,
	# so also match on a lowercased id-prefix.
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

# Profile keys the active profile references whose mod is not in
# _ui_mod_entries. Keys whose id prefix matches an installed mod at another
# version count as present (_apply_profile_to_entries flags those). Red stub rows.
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
	# Dev-hidden folder mods are still on disk; not missing.
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

# Source map for missing-mod stubs: the persisted [mod_sources] cache
# overlaid by the active modpack's sources. {profile_key -> record}, normalized.
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
			# A modpack zip may carry either era's record shape; normalize.
			for k in (sources_v as Dictionary).keys():
				var rec := _normalize_source_record((sources_v as Dictionary)[k])
				if str(rec["provider"]) != "":
					out[str(k)] = rec
		return out
	return out

# Strip an orphaned stored key from the active profile (stub-row Remove).
func _remove_missing_entry_from_profile(stored_key: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority", ".dep_ignore"]:
		var sec := _profile_sec(_active_profile, suffix)
		if cfg.has_section(sec) and cfg.has_section_key(sec, stored_key):
			cfg.erase_section_key(sec, stored_key)
	_persist_ui_cfg(cfg)

# Bulk form of _remove_missing_entry_from_profile, one config write.
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
		# A cased letter in any script changes under case folding, so this
		# admits Cyrillic/Greek names (RTV has a large Russian community).
		var is_letter := c.to_lower() != c.to_upper()
		var is_digit := u >= 48 and u <= 57
		if is_letter or is_digit or c == " " or c == "-" or c == "_":
			out += c
	return out

# One-shot vanilla boot: writes DISABLED_ONCE_FILE so the next launch skips
# the loader; _ready clears the sentinel. No _save_ui_config here, which
# would rewrite the active profile's sections from in-memory state.

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
		_show_error_dialog("Could not launch vanilla",
			"Could not write " + sentinel + "\n\nCheck the game folder's permissions and try again.")
		return
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI Launch Vanilla button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1.
	_modloader_restart(true)

# Enabled mods the scanner scored red; gates Launch.
func _enabled_red_mods() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and int(entry.get("risk_level", 0)) == 2:
			out.append(entry)
	return out

# Launch-time confirmation for red-scored mods; true = launch. Plain
# dialog_text so Godot auto-sizes the window.
func _confirm_red_launch(red_mods: Array) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Suspicious mods enabled"
	d.ok_button_text = "Launch anyway"
	d.cancel_button_text = "Go back"
	d.dialog_autowrap = true
	d.min_size = Vector2(560, 120)

	var lines := PackedStringArray()
	lines.append("The scanner found patterns in the following mod(s) that are commonly used by malware. If you don't trust them, go back and disable them before launching.")
	lines.append("")
	for entry: Dictionary in red_mods:
		lines.append("    " + str(entry.get("mod_name", "?")))
	d.dialog_text = "\n".join(lines)

	_attach_ui_dialog(d)
	# Force above the always_on_top launcher or the dialog can land behind it.
	d.exclusive = true
	d.always_on_top = true
	# Red text so "Launch anyway" reads as the risky option.
	style_dialog_danger_button(d.get_ok_button())

	return await _await_dialog_choice(d)

# The standard 8/8/6/6 outer margin shared by all top-level tab builders.
func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m


# Remove a mod file from disk and strip its entries from every profile,
# keyed by profile_key so a renamed archive still cleans up. True on delete.
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



func show_mod_ui() -> void:
	var win := _ui_create_window()
	var root := _ui_window_root(win)
	var close_btn := _ui_build_header(root, win)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())
	var launch_btn := _ui_build_bottom_bar(root, win)

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# _wire_hint needs _ui_hint_label, which the bottom bar set above.
	_wire_hint(close_btn, "Close the launcher and launch the game (same as Launch).")

	# Fire-and-forget self-update check; guards on is_instance_valid after the await.
	_check_modloader_update_async()

	_ui_add_tabs(tabs)
	refresh_launch_button_label()

	# Launch loop: red-scored enabled mods require an explicit confirm;
	# cancel returns to the launcher.
	while true:
		await launch_btn.pressed
		var red_mods := _enabled_red_mods()
		if red_mods.is_empty():
			break
		var proceed: bool = await _confirm_red_launch(red_mods)
		if proceed:
			break
	_ui_window = null
	_ui_hint_label = null
	_ui_launch_btn = null
	_ui_update_alert_btn = null
	_ui_mods_scroll = null
	_ui_modpacks_scroll = null
	_ui_updates_scroll = null
	_ui_updates_check_btn = null
	# Drop the host API response cache (session-only). Disk-cached thumbnails
	# stay: immutable storage keys are valid indefinitely.
	_host_cache.clear()
	# Row nodes die with the window; a meta fetch resolving after close paints nothing.
	_mods_meta_nodes.clear()
	win.queue_free()


# The borderless, always-on-top launcher Window with its scrim and theme.
func _ui_create_window() -> Window:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	# Borderless: the header plate carries the title, close X and drag. Title kept for alt-tab.
	win.borderless = true
	# Embed sub-windows; separate OS windows strand behind the always_on_top launcher.
	win.gui_embed_subwindows = true
	# UI scale is never derived from screen DPI: RTV's stretch/mode=canvas_items
	# against a 1920x1080 base already scales the launcher with window size, and
	# a DPI factor on top is unusably large on 4K.
	_apply_ui_scale(win, _ui_scale_setting())
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()
	# Stash for dialogs triggered by profile-bar controls. Cleared on close.
	_ui_window = win

	var win_style := StyleBoxFlat.new()
	win_style.bg_color = COL_BG
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Near-opaque scrim: 0.92 keeps a hint of the game behind while staying readable.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.92)
	bg_s.border_color = COL_BORDER
	_sb_border(bg_s)
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	# Theme on the Window itself so child Windows (popups, dialogs) inherit it.
	var dark_theme := make_dark_theme()
	win.theme = dark_theme
	return win


# The padded root VBox every launcher section hangs off.
func _ui_window_root(win: Window) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", SP_L)
	margin.add_theme_constant_override("margin_right", SP_L)
	margin.add_theme_constant_override("margin_top", SP_M)
	margin.add_theme_constant_override("margin_bottom", SP_L)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = win.theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", SP_M)
	margin.add_child(root)
	return root


# Header plate: title, version link, close button and window drag. Returns
# the close button so the caller can wire it to Launch.
func _ui_build_header(root: VBoxContainer, win: Window) -> Button:
	# Equipment plate header; the one FS_TITLE use in the UI.
	var header := PanelContainer.new()
	var header_s := StyleBoxFlat.new()
	header_s.bg_color = COL_SURFACE
	header_s.border_color = COL_ACCENT_DIM
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

	# Version / self-update alert; _check_modloader_update_async flips it to the
	# accent color when a newer release exists. Click opens the release page.
	var alert := LinkButton.new()
	alert.text = "v" + MODLOADER_VERSION
	alert.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	alert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alert.add_theme_font_size_override("font_size", FS_META)
	alert.add_theme_color_override("font_color", COL_TEXT_DIM)
	alert.add_theme_color_override("font_hover_color", COL_TEXT)
	alert.pressed.connect(func():
		OS.shell_open(_modloader_release_page_url())
	)
	header_row.add_child(alert)
	_ui_update_alert_btn = alert

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Must not swallow mouse events or it kills header drag.
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(header_spacer)

	# In-plate close (X); wired below to the Launch path (X == Launch).
	var close_btn := Button.new()
	close_btn.flat = true
	close_btn.icon = _make_close_icon(COL_TEXT_DIM)
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(close_btn)

	# Header plate drags the window. Track absolute mouse position: ev.relative
	# would self-cancel as the window moves and trail the cursor at half speed.
	var drag := {"on": false, "grab": Vector2i.ZERO}
	header.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				# ev.global_position is in Control space (shrunk by content_scale_factor);
				# mouse_get_position() is raw screen pixels.
				drag["grab"] = Vector2i(ev.global_position * win.content_scale_factor)
		elif ev is InputEventMouseMotion and drag["on"]:
			win.position = DisplayServer.mouse_get_position() - drag["grab"]
	)
	return close_btn


# Hint line, Launch vanilla and Launch. Returns the Launch button, which the
# caller awaits.
func _ui_build_bottom_bar(root: VBoxContainer, win: Window) -> Button:
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", SP_M)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Required dependencies must be enabled or the mod won't load."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", FS_BODY)
	hint.add_theme_color_override("font_color", COL_TEXT_DIM)
	bottom.add_child(hint)
	# Exposed for _wire_hint's hover-hint mechanic.
	_ui_hint_label = hint

	var launch_btn := Button.new()
	# Text set by refresh_launch_button_label after the tabs build; empty avoids a flash.
	launch_btn.text = ""
	launch_btn.custom_minimum_size = Vector2(160, 36)
	style_primary_button(launch_btn)

	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = SP_XL
	bottom.add_child(bar_gap)

	# Vanilla: one-shot bypass via sentinel and restart; smaller than Launch.
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
	return launch_btn


	# --- Tab contract ---
	# Each tab is built by a build_*_tab(tabs) -> Control function and added
	# under a stable node name (UI_TAB_*). TabContainer shows the name as the
	# tab title, the in-place rebuild helpers find the tab through
	# get_node_or_null(name), and the tab_changed listener below matches on
	# it. To add a tab: build_x_tab(tabs) + a UI_TAB_X const (constants.gd),
	# add and name it below, and add a rebuild or on-show refresh if other
	# surfaces can change its state. A name mismatch fails silently: the
	# rebuild helpers skip and the tab goes stale.
func _ui_add_tabs(tabs: TabContainer) -> void:
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

	# Refresh tabs on show: state can change behind a tab's back.
	tabs.tab_changed.connect(func(idx: int):
		# Re-entrant tab_changed fired mid-rebuild; another rebuild here corrupts the tree.
		if _rebuilding_tab_in_place:
			return
		var ctrl := tabs.get_tab_control(idx)
		if ctrl != null and ctrl.name == UI_TAB_MODPACKS:
			_rebuild_modpacks_tab(tabs)
		# Browse rows bake profile state at render time and never rebuild; sync in place.
		elif ctrl != null and ctrl.name == UI_TAB_BROWSE:
			_refresh_browse_installed_rows(ctrl)
		# The Updates tab is a build-time snapshot; rebuild on show.
		elif ctrl != null and ctrl.name == UI_TAB_UPDATES:
			_rebuild_updates_tab(tabs)
		# An Updates-tab check may have changed badge state off-screen.
		elif ctrl != null and ctrl.name == UI_TAB_MODS and _mods_badges_dirty:
			_mods_badges_dirty = false
			_rebuild_mods_tab(tabs)
	)

# Launch button label reflects whether anything will load.
func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	# Count what will actually load, not what's checked: with everything
	# dependency-blocked, "Launch modded" would deliver vanilla.
	var pick := _loadable_enabled_entries()
	var loadable_count: int = (pick["loadable"] as Array).size()
	var enabled_count := int(pick["enabled_count"])
	if loadable_count > 0:
		_ui_launch_btn.text = "Launch modded"
	elif enabled_count > 0:
		_ui_launch_btn.text = "Launch unmodded (%d blocked)" % enabled_count
	else:
		_ui_launch_btn.text = "Launch"

# Coarse relative age for cache timestamps ("12m ago"); input unix seconds.
func _format_age(saved_at_unix: int) -> String:
	var delta := int(Time.get_unix_time_from_system()) - saved_at_unix
	if delta < 60:
		return "just now"
	if delta < 60 * 60:
		return "%dm ago" % int(delta / 60.0)
	if delta < 24 * 60 * 60:
		return "%dh ago" % int(delta / 3600.0)
	return "%dd ago" % int(delta / 86400.0)


# Guarded truthiness for one untrusted JSON value (bool(null) is a runtime
# error). _count_truthy (modpacks.gd) is the same rule over a dictionary.
func _json_truthy(v: Variant) -> bool:
	return (v is bool and v) or ((v is int or v is float) and v != 0)


# Decode an image buffer by sniffing its magic bytes rather than trying every
# decoder in turn: each failed attempt pushes engine errors into the console,
# and an HTML error page or truncated download would print nine of them.
# Returns null when the buffer is not a supported format.
func _decode_image_buffer(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	# PNG: 89 'P' 'N' 'G'
	if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		return img if img.load_png_from_buffer(bytes) == OK else null
	# JPEG: FF D8 FF
	if bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return img if img.load_jpg_from_buffer(bytes) == OK else null
	# WebP: "RIFF" <4-byte size> "WEBP"
	if bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
			and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		return img if img.load_webp_from_buffer(bytes) == OK else null
	return null

# Visible terminal state for a thumbnail cell: overlays a centered dim label
# ("load failed" when a fetch or decode broke, "no image" when there is
# nothing to fetch) into the cell's parent PanelContainer, so those states
# do not look like "still loading". Safe to call after awaits and idempotent
# per cell.
func _set_thumb_failed(rect: TextureRect, failed: bool) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if not is_instance_valid(wrap):
		return
	# Cells start captioned "no thumbnail"; update the existing label, never skip it.
	if wrap.has_node("ThumbStateLabel"):
		var existing := wrap.get_node("ThumbStateLabel") as Label
		if existing != null:
			existing.text = "load failed" if failed else "no thumbnail"
		return
	var lbl := Label.new()
	lbl.name = "ThumbStateLabel"
	lbl.text = "load failed" if failed else "no thumbnail"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	lbl.add_theme_font_size_override("font_size", FS_META)
	wrap.add_child(lbl)

# Paint a texture into a thumbnail cell, clearing the state caption first.
# Every texture-setting path goes through here.
func _set_thumb_ready(rect: TextureRect, tex: Texture2D) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if is_instance_valid(wrap) and wrap.has_node("ThumbStateLabel"):
		var stale := wrap.get_node("ThumbStateLabel")
		wrap.remove_child(stale)
		stale.queue_free()
	rect.texture = tex

# Build an image cell: a surface-coloured PanelContainer holding a TextureRect,
# captioned "no thumbnail" until an image lands. Every image cell in the
# launcher (Mods rows, Browse rows, the detail banner) comes from here.
# cover=true crops to fill, for small row tiles; cover=false letterboxes so
# the whole image stays visible (the detail banner). shrink_center keeps the
# cell at its natural height. Returns the TextureRect to paint into.
func _make_thumb_cell(parent: Control, min_size: Vector2, cover: bool = true,
		shrink_center: bool = false) -> TextureRect:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = min_size
	if shrink_center:
		wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = COL_SURFACE_2
	wrap.add_theme_stylebox_override("panel", style)
	parent.add_child(wrap)
	var rect := TextureRect.new()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if cover \
			else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(rect)
	_set_thumb_failed(rect, false)
	return rect


# Session memo of decoded thumbnail textures keyed by storage filename, so a
# Mods-tab rebuild or Browse re-render does not re-read and re-decode every
# image. FIFO-bounded (Dictionary preserves insertion order).
var _thumb_texture_cache: Dictionary = {}
const _THUMB_TEXTURE_CACHE_MAX := 256

func _thumb_texture_cache_store(fn: String, tex: Texture2D) -> void:
	while _thumb_texture_cache.size() >= _THUMB_TEXTURE_CACHE_MAX:
		_thumb_texture_cache.erase(_thumb_texture_cache.keys()[0])
	_thumb_texture_cache[fn] = tex


# Async thumbnail loader for an ImageRef {url, thumb_url, cache_key}. A
# non-empty cache_key is the on-disk cache filename under user://mws_cache/thumbs/;
# "" means the host promises nothing, so the image lives only in the session memo.
func _browse_load_thumbnail_async(rect: TextureRect, image: Dictionary) -> void:
	var url := str(image.get("url", ""))
	if url.is_empty():
		_set_thumb_failed(rect, false)
		return
	# Host-provided key headed into a path: accept only a bare basename.
	var cache_key := str(image.get("cache_key", ""))
	if cache_key != "" and not _is_safe_basename(cache_key):
		cache_key = ""
	var memo_key := cache_key if cache_key != "" else url

	var memo_tex_v: Variant = _thumb_texture_cache.get(memo_key)
	if memo_tex_v is Texture2D:
		_set_thumb_ready(rect, memo_tex_v as Texture2D)
		return

	var cache_path := ""
	if cache_key != "":
		var cache_dir := "user://mws_cache/thumbs"
		DirAccess.make_dir_recursive_absolute(cache_dir)
		cache_path = cache_dir.path_join(cache_key)
		# Disk hit; a decode error falls through to a refetch.
		if FileAccess.file_exists(cache_path):
			var f := FileAccess.open(cache_path, FileAccess.READ)
			if f != null:
				var bytes := f.get_buffer(f.get_length())
				f.close()
				if bytes.size() > 0:
					var img := _decode_image_buffer(bytes)
					if img != null:
						var disk_tex := ImageTexture.create_from_image(img)
						_thumb_texture_cache_store(memo_key, disk_tex)
						_set_thumb_ready(rect, disk_tex)
						return

	# 1MB cap defends against a malformed response; real covers run 100-300KB.
	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	req.download_body_size_limit = 1024 * 1024
	add_child(req)
	var err := req.request(url, PackedStringArray(["User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION)]))
	if err != OK:
		req.queue_free()
		_set_thumb_failed(rect, true)
		return

	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		_set_thumb_failed(rect, true)
		return
	var body: PackedByteArray = res[3]
	if body.is_empty():
		_set_thumb_failed(rect, true)
		return

	var img := _decode_image_buffer(body)
	if img == null:
		_set_thumb_failed(rect, true)
		return

	# The CDN serves full-size images while row cells render at 96x54, so
	# downscale before caching. The detail banner reads the same cache at
	# about 220px tall, so cap the longest side at 640px rather than keying
	# a separate small variant. Re-encoded as lossy WebP; the cache-hit
	# reader sniffs the format, so the container swap is safe.
	var thumb_cache_max := 640
	var cache_bytes := body
	if maxi(img.get_width(), img.get_height()) > thumb_cache_max:
		var scale := float(thumb_cache_max) / float(maxi(img.get_width(), img.get_height()))
		img.resize(
			maxi(1, int(round(img.get_width() * scale))),
			maxi(1, int(round(img.get_height() * scale))),
			Image.INTERPOLATE_LANCZOS
		)
		var resized := img.save_webp_to_buffer(true, 0.85)
		if resized.size() > 0:
			cache_bytes = resized

	# Stash for next launch; a failed write only means a refetch next time.
	# store_buffer returns bool; drop a partial file rather than leave a
	# truncated cache entry.
	if cache_path != "":
		var out := FileAccess.open(cache_path, FileAccess.WRITE)
		if out != null:
			var wrote := out.store_buffer(cache_bytes)
			out.close()
			if not wrote:
				DirAccess.remove_absolute(cache_path)

	var net_tex := ImageTexture.create_from_image(img)
	_thumb_texture_cache_store(memo_key, net_tex)
	_set_thumb_ready(rect, net_tex)


# Format a byte count as a compact human-readable string.
func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


# Format an ISO-8601 string ("2026-04-12T17:42:11.000000Z") as "2026-04-12 17:42",
# UTC. Returns the input unchanged if it does not look like a timestamp.
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
	var hm: String = time_part.substr(0, 5) if time_part.length() >= 5 else time_part
	return date_part + " " + hm


## Replace every match of `re` in `s` with repl(match); avoids RegEx.sub's backreference syntax.
func _re_replace(re: RegEx, s: String, repl: Callable) -> String:
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		out += str(repl.call(m))
		last = m.get_end()
	out += s.substr(last)
	return out

## Convert ModWorkshop's Markdown-flavored description into BBCode: headings,
## emphasis, lists, blockquotes, rules, links and MWS color spans. Inline images
## collapse to their alt text. Best-effort: malformed input renders imperfectly.
func _markdown_to_bbcode(md: String) -> String:
	# Sentinels stand in for generated brackets while the user's literal ones are
	# escaped. STX/ETX never appear in real descriptions.
	var LB := char(2)
	var RB := char(3)
	var s := md.replace("\r\n", "\n").replace("\r", "\n")
	# Strip the sentinels from the untrusted input, or the final restore injects BBCode.
	s = s.replace(LB, "").replace(RB, "")
	s = s.replace(":::", "")  # drop MWS colored-block delimiters; keep {#hex}(..)

	# Bracket/paren constructs, converted before escaping literal '['. Images
	# first (a link with a leading '!').
	var re_img := RegEx.new()
	re_img.compile("!\\[([^\\]]*)\\]\\([^)]*\\)")
	s = _re_replace(re_img, s, func(m): return m.get_string(1))
	var re_link := RegEx.new()
	re_link.compile("\\[([^\\]]*)\\]\\(([^)\\s]+)\\)")
	# Percent-encode BBCode-sensitive chars in the URL so the later passes cannot
	# corrupt url= (a literal ']' ends the tag). Never encode '%'.
	s = _re_replace(re_link, s, func(m): return LB + "url=" + m.get_string(2).replace("[", "%5B").replace("]", "%5D").replace("_", "%5F").replace("*", "%2A").replace("~", "%7E") + RB + m.get_string(1) + LB + "/url" + RB)
	var re_color := RegEx.new()
	re_color.compile("\\{#([0-9a-fA-F]{3,8})\\}\\(([^)]*)\\)")
	s = _re_replace(re_color, s, func(m): return LB + "color=#" + m.get_string(1) + RB + m.get_string(2) + LB + "/color" + RB)

	# Escape remaining literal '['; a lone ']' renders literally.
	s = s.replace("[", "[lb]")

	# Block level first, so a bullet's '*' is gone before the italic rule runs.
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

	# Restore generated tags to real brackets last, so escaping never touched them.
	s = s.replace(LB, "[").replace(RB, "]")
	return s

# ----- modloader self-update check ----------------------------------------

# Where the version button and the update dialog send the user: the release
# the check found, else the repository's latest-release page.
func _modloader_release_page_url() -> String:
	if _modloader_release_url != "":
		return _modloader_release_url
	return MODLOADER_RELEASES_PAGE_URL % MODLOADER_GITHUB_REPO

# Fire-and-forget from show_mod_ui: reads the latest GitHub release, compares
# it against MODLOADER_VERSION, recolors the version button and pops a
# one-shot dialog. UI mutations guard on is_instance_valid after the await.
func _check_modloader_update_async() -> void:
	if MODLOADER_GITHUB_REPO == "":
		return
	# "github" is not a mod host, but its unauthenticated budget is worth honoring.
	var res := await _hnet_get_json("github", MODLOADER_RELEASES_API_URL % MODLOADER_GITHUB_REPO)
	if not res["ok"] or not (res["data"] is Dictionary):
		return
	var release: Dictionary = res["data"]
	var latest := _host_str(release.get("tag_name")).strip_edges().trim_prefix("v")
	if latest.is_empty():
		return
	var page := _host_str(release.get("html_url"))
	if page.begins_with("https://github.com/"):
		_modloader_release_url = page
	_modloader_latest_version = latest
	# Exact match first: a running prerelease that is the latest release has
	# nothing to update to; the base-version compare below would flag it.
	if latest == MODLOADER_VERSION:
		return
	# Prerelease-aware gate. compare_versions() reads "3.3.0-beta.1" as 3.3.0.1,
	# ranking it above the "3.3.0" stable and above an older beta. Semver: a
	# prerelease precedes its release. Compare base versions first, then break
	# equal-base ties on the prerelease tails: a stable supersedes any same-base
	# prerelease; between two prereleases only a strictly higher one is an
	# update. No-op on stable builds (no "-" in MODLOADER_VERSION).
	var installed_base := MODLOADER_VERSION.split("-")[0]
	var latest_base := latest.split("-")[0]
	var base_cmp := compare_versions(latest_base, installed_base)
	if base_cmp < 0:
		return  # installed base is newer
	if base_cmp == 0:
		var installed_pre := MODLOADER_VERSION.substr(installed_base.length()).lstrip("-")
		var latest_pre := latest.substr(latest_base.length()).lstrip("-")
		if installed_pre == "":
			return  # installed is the stable base; a same-base prerelease is not an upgrade
		if latest_pre == "":
			pass  # latest is the stable release of our prerelease -> offer it
		elif _compare_prerelease(latest_pre, installed_pre) <= 0:
			return  # latest prerelease is the same as or older than installed

	if is_instance_valid(_ui_update_alert_btn):
		_ui_update_alert_btn.text = "v%s available -- click to open the release page" % latest
		# An available update is a notice, not an error: accent, not red.
		_ui_update_alert_btn.add_theme_color_override("font_color", COL_ACCENT)
		_ui_update_alert_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)

	# Pop the dialog only the first session this version is seen.
	var last_seen := _modloader_update_last_seen_version()
	if last_seen != latest:
		_show_modloader_update_dialog(latest)

func _modloader_update_last_seen_version() -> String:
	return str(_get_ui_cfg_value("modloader_update", "last_seen_version", ""))

func _modloader_update_mark_seen(latest: String) -> void:
	_set_ui_cfg_value("modloader_update", "last_seen_version", latest)

# One-shot popup for a new loader version. Either action records the version
# in mod_config.cfg so the dialog stays quiet until another release ships.
func _show_modloader_update_dialog(latest: String) -> void:
	if not is_instance_valid(_ui_window):
		return
	var d := ConfirmationDialog.new()
	d.title = "Mod Loader update available"
	d.ok_button_text = "Open page"
	d.cancel_button_text = "Dismiss"
	d.dialog_autowrap = true
	d.min_size = Vector2(440, 120)
	d.dialog_text = "A newer version of the Mod Loader is available.\n\n" \
			+ "    Installed: v%s\n    Available: v%s\n\n" % [MODLOADER_VERSION, latest] \
			+ "Open the release page to download?"
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	_connect_dialog_exits(d,
		func():
			OS.shell_open(_modloader_release_page_url())
			_modloader_update_mark_seen(latest)
			d.queue_free(),
		func():
			_modloader_update_mark_seen(latest)
			d.queue_free()
	)
	d.popup_centered()
