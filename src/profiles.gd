## Profile selection and mod_config.cfg persistence.
## Owns the mapping between stored profile keys and current mod entries.
## Profile snapshots live in profile_snapshots.gd; profile dialogs in ui_dialogs.gd.

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		# Read from the same .bak _load_ui_config recovers from; otherwise a
		# recoverable corrupt config strands every folder mod for the session.
		var bak := UI_CONFIG_PATH + ".bak"
		if not (FileAccess.file_exists(bak) and cfg.load(bak) == OK):
			return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	_active_profile = "Default"
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
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
			var restore_err := cfg.save(UI_CONFIG_PATH)
			if restore_err != OK:
				# Writers keep refusing the unreadable live file, so the backup
				# stays the good copy and the next launch recovers again.
				_log_critical("[Config] Could not write the recovered settings back to %s (error %d) -- this session runs on the backup, and changes made now are not saved." \
						% [UI_CONFIG_PATH, restore_err])
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
	else:
		# The stored name is gone. An active pack's own slot keeps the pack and
		# its MCM settings consistent; otherwise land on a profile the player
		# made, never on another modpack-managed slot.
		var pack := str(cfg.get_value("settings", "active_modpack", ""))
		var users := _list_user_profiles_in_cfg(cfg)
		if pack != "" and (MODPACK_PROFILE_PREFIX + pack) in profiles:
			_active_profile = MODPACK_PROFILE_PREFIX + pack
		else:
			_active_profile = users[0] if not users.is_empty() else "Default"

	# Reconcile modpack state. A managed slot (modpack__X) is a legitimate
	# active profile only while active_modpack names it; a mismatch means a
	# crash mid-apply/unload. Recover to a user profile and clear stale flags.
	var active_mp := str(cfg.get_value("settings", "active_modpack", ""))
	var mp_dirty := false
	if _is_modpack_managed_profile(_active_profile) \
			and _active_profile != MODPACK_PROFILE_PREFIX + active_mp:
		# Roll live MCM back to the pre-apply snapshot, keyed off the slot name
		# since active_mp may be blank; without the rollback the next profile
		# switch would capture the pack's MCM.
		if _active_profile.begins_with(MODPACK_PROFILE_PREFIX):
			var bslot := MODPACK_BACKUP_PREFIX + _active_profile.trim_prefix(MODPACK_PROFILE_PREFIX)
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
		# _switch_profile): clear the flag.
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

# The stored profile key an entry's state lives under: its own key when the
# profile has it; else the id-prefix match ("<mod_id>@*") so a version bump
# carries the stored state; else, for a mod with no declared id, the filename
# stem match so a re-package does not orphan the settings. "" when the
# profile holds nothing for the mod.
func _resolve_stored_key(cfg: ConfigFile, profile: String, entry: Dictionary) -> String:
	var pk: String = entry["profile_key"]
	if cfg.has_section_key(_profile_sec(profile, ".enabled"), pk) \
			or cfg.has_section_key(_profile_sec(profile, ".priority"), pk):
		return pk
	if not pk.begins_with("zip:"):
		return _find_stored_key_for_mod_id(cfg, profile, entry["mod_id"])
	return _find_stored_key_for_zip_stem(cfg, profile, entry["file_name"])

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
		var resolved_key := _resolve_stored_key(cfg, profile, entry)
		# The state came from another version of the same id; the row says so.
		if resolved_key != "" and resolved_key != pk and not pk.begins_with("zip:"):
			entry["profile_version_mismatch"] = {
				"stored":  _version_from_profile_key(resolved_key),
				"current": entry["version"],
			}
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
		else:
			# This profile stores none: the mod's own default, not the value the
			# previously applied profile left on the entry.
			entry["priority"] = int(entry.get("priority_default", entry.get("priority", 0)))
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
	if _ui_cfg_load(cfg) != OK:
		return []
	return _list_profiles_in_cfg(cfg)

# The active profile as player-facing text. A modpack-managed slot reads the
# way the Profile dropdown shows it, never as its internal "modpack__" key.
func _active_profile_label() -> String:
	if _active_profile.begins_with(MODPACK_PROFILE_PREFIX):
		return "[Modpack: %s]" % _active_profile.trim_prefix(MODPACK_PROFILE_PREFIX)
	return _active_profile

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

# Maps for the stored-key preservation pass: "live" holds the live
# profile_keys, "ids" the mod_ids of installed id-keyed entries (to drop stale
# versioned keys) and "stems" the normalized filename stems of installed
# filename-keyed entries (to drop the key a re-packaged mod left behind).
func _collect_live_profile_key_maps() -> Dictionary:
	var live_keys: Dictionary = {}
	var installed_ids: Dictionary = {}
	var installed_stems: Dictionary = {}
	for entry in _ui_mod_entries:
		var lk: String = str(entry["profile_key"])
		live_keys[lk] = true
		if lk.begins_with("zip:"):
			installed_stems[_normalized_mod_stem(str(entry["file_name"]))] = true
		else:
			installed_ids[str(entry["mod_id"])] = true
	return {"live": live_keys, "ids": installed_ids, "stems": installed_stems}

# True when a stored profile key must survive _save_ui_config's erase and
# rewrite: keys with a live entry are rewritten from memory; everything else
# (dev-hidden folder mods, missing mods) is kept, except a key whose state
# already migrated to a live entry (see _stored_key_migrated). key_maps is
# _collect_live_profile_key_maps().
func _preserve_stored_profile_key(key: String, key_maps: Dictionary) -> bool:
	if (key_maps["live"] as Dictionary).has(key):
		return false
	if _hidden_folder_profile_keys.has(key):
		return true
	return not _stored_key_migrated(key, key_maps["ids"], key_maps["stems"])

# True when a stored key with no live entry belongs to a mod that is
# installed under another key, the two carry-overs _resolve_stored_key makes:
# "<id>@<old version>" for an installed id, and "zip:<old file name>" whose
# normalized stem matches an installed filename-keyed mod.
func _stored_key_migrated(key: String, installed_ids: Dictionary, installed_stems: Dictionary) -> bool:
	if key.begins_with("zip:"):
		return installed_stems.has(_normalized_mod_stem(key.trim_prefix("zip:")))
	var at := key.find("@")
	return at > 0 and installed_ids.has(key.substr(0, at))

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
	# No reader for this key.
	if cfg.has_section_key("settings", "preferred_author"):
		cfg.erase_section_key("settings", "preferred_author")

	# The Vanilla sentinel must never materialize stored sections.
	if _active_profile != VANILLA_PROFILE:
		var en_sec := _profile_sec(_active_profile, ".enabled")
		var pr_sec := _profile_sec(_active_profile, ".priority")
		var ig_sec := _profile_sec(_active_profile, ".dep_ignore")
		var key_maps := _collect_live_profile_key_maps()
		var live_enabled: Dictionary = {}
		var live_priority: Dictionary = {}
		var live_ignored: Dictionary = {}
		for entry in _ui_mod_entries:
			var pk: String = entry["profile_key"]
			live_enabled[pk] = entry["enabled"]
			live_priority[pk] = entry["priority"]
			if bool(entry.get("dependency_ignored", false)):
				live_ignored[pk] = true
		_rewrite_profile_section(cfg, en_sec, live_enabled, key_maps)
		_rewrite_profile_section(cfg, pr_sec, live_priority, key_maps)
		_rewrite_profile_section(cfg, ig_sec, live_ignored, key_maps)

	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)
	if _boot_complete:
		_dirty_since_boot = true

# Rebuild one per-profile section: erase it, write the live entries' values,
# and put back the stored keys that have no live entry (see
# _preserve_stored_profile_key). key_maps is _collect_live_profile_key_maps().
func _rewrite_profile_section(cfg: ConfigFile, section: String, live: Dictionary, key_maps: Dictionary) -> void:
	var preserved: Dictionary = {}
	if cfg.has_section(section):
		for key: String in cfg.get_section_keys(section):
			if _preserve_stored_profile_key(key, key_maps):
				preserved[key] = cfg.get_value(section, key)
		cfg.erase_section(section)
	for k in live:
		cfg.set_value(section, k, live[k])
	for k in preserved:
		cfg.set_value(section, k, preserved[k])

# Persist the UI config with a rolling backup: ConfigFile.save truncates
# then writes and there is no Windows-safe atomic rename, so copy the good
# file to .bak first. Best-effort; returns the ConfigFile.save error.
func _persist_ui_cfg(cfg: ConfigFile) -> int:
	# A live file that is blank or does not parse is what a save cut short
	# leaves behind; rolling it over the backup would lose the last good copy
	# of every profile.
	if FileAccess.file_exists(UI_CONFIG_PATH) and not _ui_cfg_blank(UI_CONFIG_PATH):
		DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")
	return cfg.save(UI_CONFIG_PATH)

# Load mod_config.cfg into `cfg`. Godot reads an empty file as a successful
# load with no sections, but an empty live file beside a backup is a save
# cut short (the game killed or the disk full mid-write), not a fresh
# install, so it reports ERR_FILE_CORRUPT: the backup recovery in
# _load_ui_config runs and writers stand down instead of saving over it.
func _ui_cfg_load(cfg: ConfigFile) -> int:
	var err := cfg.load(UI_CONFIG_PATH)
	if err == OK and cfg.get_sections().is_empty() and not _ui_cfg_blank(UI_CONFIG_PATH + ".bak"):
		return ERR_FILE_CORRUPT
	return err

# True for a config file that is missing, does not parse, or holds no section.
func _ui_cfg_blank(path: String) -> bool:
	var probe := ConfigFile.new()
	return probe.load(path) != OK or probe.get_sections().is_empty()

func _profile_sec(name: String, suffix: String) -> String:
	return "profile." + name + suffix

# Every per-profile section suffix; use only when wiping or renaming a whole
# profile. The [".enabled", ".priority"] loops elsewhere are intentional.
const PROFILE_SUBSECTIONS := [".enabled", ".priority", ".settings", ".dep_ignore"]

# Read a single value from mod_config.cfg; `default` when missing/unparseable.
func _get_ui_cfg_value(section: String, key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return default
	return cfg.get_value(section, key, default)

# Load mod_config.cfg for a partial write. Persisting a cfg that failed to
# load would replace every profile with the caller's few keys, so any load
# error other than a missing file returns null and the change stays
# in-memory; the refusal is surfaced once in the launcher.
var _ui_cfg_refusal_notified := false

func _load_ui_cfg_for_write() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := _ui_cfg_load(cfg)
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
	_ui_cfg_load(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	_mark_mod_set_changed()

# The on-disk mod set changed after boot; a post-boot session restarts into
# it on close, the same convention as a profile switch.
func _mark_mod_set_changed() -> void:
	if _boot_complete:
		_dirty_since_boot = true

# Snapshot the in-memory state to a new profile and switch to it. Caller
# validates `name`. Seeds the new profile's MCM slot from user://MCM/.
# `same_selection` is true when the new profile copies the active one's
# selection: nothing that loads changes, so a running game need not restart.
# The dialog's other initial states (empty, all enabled) change what loads.
func _create_profile(name: String, same_selection: bool = false) -> void:
	# Refresh the outgoing profile's MCM snapshot first, as _switch_profile does.
	var old := _active_profile
	if old != VANILLA_PROFILE and old != name:
		_snapshot_mcm_to(old)
	_active_profile = name
	# The new profile has no stored view settings; start from the defaults.
	_mods_hide_disabled = false
	if same_selection:
		_save_profile_bookkeeping()
	else:
		_save_ui_config()
	_snapshot_mcm_to(name)

# _save_ui_config for a change that touches no mod state: a rename of the
# active profile, or a new profile copied from it, leaves the enabled set and
# the load order as they were, so it must not flag the restart a post-boot
# mod change needs.
func _save_profile_bookkeeping() -> void:
	var was_dirty := _dirty_since_boot
	_save_ui_config()
	_dirty_since_boot = was_dirty

# Delete the active profile's sections and its MCM snapshot, then switch to
# the first remaining profile. Caller ensures another profile exists.
func _delete_active_profile() -> void:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
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
		_ui_cfg_load(cfg)
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
	_save_profile_bookkeeping()
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
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
	for suffix: String in [".enabled", ".priority", ".dep_ignore"]:
		var old_sec := _profile_sec(old, suffix)
		if not cfg.has_section(old_sec):
			continue
		var new_sec := _profile_sec(new_name, suffix)
		for key: String in cfg.get_section_keys(old_sec):
			if cfg.has_section_key(new_sec, key):
				continue
			if _preserve_stored_profile_key(key, key_maps):
				cfg.set_value(new_sec, key, cfg.get_value(old_sec, key))
	for suffix: String in PROFILE_SUBSECTIONS:
		var sec := _profile_sec(old, suffix)
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	_persist_ui_cfg(cfg)
	_rename_mcm_snapshot(old, new_name)

# Profile keys the active profile references whose mod is not in
# _ui_mod_entries. Keys whose id prefix matches an installed mod at another
# version count as present (_apply_profile_to_entries flags those). Red stub rows.
func _missing_mods_in_active_profile() -> Array[String]:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return []
	var en_sec := _profile_sec(_active_profile, ".enabled")
	if not cfg.has_section(en_sec):
		return []
	var key_maps := _collect_live_profile_key_maps()
	var present: Dictionary = key_maps["live"]
	var ids_installed: Dictionary = key_maps["ids"]
	# Dev-hidden folder mods are still on disk; not missing.
	for key in _hidden_folder_profile_keys.keys():
		present[key] = true
	for mid in _hidden_folder_ids.keys():
		ids_installed[mid] = true
	var missing: Array[String] = []
	for key: String in cfg.get_section_keys(en_sec):
		if present.has(key):
			continue
		if _stored_key_migrated(key, ids_installed, key_maps["stems"]):
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
	if _ui_cfg_load(cfg) != OK:
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
	if _ui_cfg_load(cfg) != OK:
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

# Remove a mod file from disk and strip its entries from every profile,
# keyed by profile_key so a renamed archive still cleans up. True on delete.
func _delete_mod_file_and_cleanup(entry: Dictionary) -> bool:
	var path: String = str(entry["full_path"])
	if FileAccess.file_exists(path):
		if DirAccess.remove_absolute(path) != OK:
			return false
	var profile_key: String = str(entry["profile_key"])
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) == OK:
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
