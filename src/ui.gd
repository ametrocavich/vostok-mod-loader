## ----- ui.gd -----
## The launcher window: Mods, Browse, Modpacks and Updates tabs plus the Launch
## bar. Profiles live in UI_CONFIG_PATH under profile.<name>.*; the active one
## in [settings] active_profile. Closing the window is the same as Launch.

# -- Design tokens ------------------------------------------------------------
# Matches the VostokMods site palette: one accent green, one success green, one red.

# Base surfaces
const COL_BG         := Color("1b1d1d")  # window/panel floor -- VostokMods --ui-bg
const COL_SURFACE    := Color("2b2e2e")  # buttons, inputs, rows -- --ui-bg-muted
const COL_SURFACE_2  := Color("3b3e3e")  # hover, elevated rows
const COL_BORDER     := Color("434747")  # 1px structural borders -- --ui-border-accented
const COL_BORDER_DIM := Color("282929")  # disabled/unselected -- --ui-border

const COL_TEXT       := Color("d9d9d9")  # body -- --ui-text
const COL_TEXT_HI    := Color("f1f1f1")  # emphasis/hover -- --ui-text-highlighted
const COL_TEXT_DIM   := Color("a0a0a0")  # secondary/meta -- --ui-text-muted (70% over the ground)
const COL_TEXT_FAINT := Color("7a7b7b")  # disabled only -- --ui-text-dimmed (50%)

const COL_ACCENT     := Color("00b806")  # focus, selected, primary, progress, badges -- brand green 600
const COL_ACCENT_DIM := Color("008b07")  # accent borders/washes, banner edges -- brand green 700

const COL_OK         := Color("00e604")  # enabled, success -- brand green 500
const COL_OK_DIM     := Color("0b5c12")  # brand green 900
const COL_ERR        := Color("ef4444")  # errors, blocked, danger
const COL_ERR_DIM    := Color("7f1d1d")

# Type scale
const FS_META  := 11   # timestamps, counts, fine print
const FS_BODY  := 12   # default body, buttons, rows
const FS_EMPH  := 13   # emphasized row titles, dialog body
const FS_HEAD  := 14   # section headings, dialog titles
const FS_TITLE := 16   # the window header plate only

# Spacing scale
const SP_XS := 2   # hairline gaps (badge-to-label)
const SP_S  := 4   # intra-row gaps
const SP_M  := 8   # between controls in a group
const SP_L  := 12  # between groups; container padding
const SP_XL := 16  # dialog outer padding, tab content padding

# Control sizing
const CTRL_H := 26  # uniform min height for single-line inputs (LineEdit, SpinBox)

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
		if not _ui_cfg_refusal_notified and _ui_window != null and is_instance_valid(_ui_window):
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
# had at least one entry; false if it didn't exist or was empty.
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

# Save-as-modpack dialog: name, author and description inputs plus a warning
# list of enabled mods with no source. One ScrollContainer holds the body.
func _show_save_modpack_dialog(profile_to_save: String, orphans: Array, tabs: TabContainer) -> void:
	var has_orphans := not orphans.is_empty()
	var d := ConfirmationDialog.new()
	d.title = "Save partial modpack?" if has_orphans else "Save as modpack"
	# Sized so name, author and description fit; clamped to the launcher.
	d.min_size = _dialog_fit_size(Vector2i(600, 520 if has_orphans else 420))
	d.max_size = Vector2i(780, 600)

	var outer_scroll := ScrollContainer.new()
	outer_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(outer_scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", SP_M)
	outer_scroll.add_child(box)

	# A modpack is a shareable list of mods, not a bundle of the files.
	var intro := Label.new()
	intro.text = "A modpack is a shareable list of your enabled mods -- not the mod files themselves. Send the saved file to anyone: when they apply it they get this exact setup, and the mods download automatically from the site each one came from."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", COL_TEXT)
	intro.add_theme_font_size_override("font_size", FS_BODY)
	box.add_child(intro)
	box.add_child(HSeparator.new())

	var name_hdr := Label.new()
	name_hdr.text = "Modpack name:"
	name_hdr.add_theme_font_size_override("font_size", FS_BODY)
	name_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(name_hdr)

	var name_input := LineEdit.new()
	name_input.placeholder_text = "Name for this modpack"
	name_input.text = profile_to_save
	name_input.custom_minimum_size.y = CTRL_H
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
	author_input.custom_minimum_size.y = CTRL_H
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
		warn_hdr.text = "%d enabled mod(s) have no download source:" % orphans.size()
		warn_hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn_hdr.add_theme_color_override("font_color", COL_ACCENT)
		box.add_child(warn_hdr)

		var footer := Label.new()
		footer.text = "Without a download source, these mods can't auto-download when someone applies the modpack -- recipients install them manually."
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
	# Keep the dialog open until the save succeeds so a name collision does not destroy the form.
	d.dialog_hide_on_ok = false
	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.add_child(err_lbl)
	_attach_ui_dialog(d)
	if has_orphans:
		style_dialog_danger_button(d.get_ok_button())
	else:
		style_dialog_primary_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			var pack_name := name_input.text.strip_edges()
			var desc := desc_input.text
			var author := author_input.text.strip_edges()
			if pack_name == "":
				pack_name = profile_to_save
			_save_preferred_author(author)
			# Save before freeing the dialog: on failure the form survives.
			var result := save_profile_as_modpack(profile_to_save, pack_name, desc, author)
			if not bool(result.get("ok", false)):
				err_lbl.text = str(result.get("error", "unknown"))
				return
			d.queue_free()
			_rebuild_modpacks_tab(tabs)
			_show_modpack_saved_dialog(
				str(result.get("display_name", pack_name)),
				int(result.get("mod_count", 0)),
				str(result.get("path", ""))),
		func(): d.queue_free())
	d.popup_centered()

# Post-save confirmation for "Save as modpack": what was saved, where, and
# how to share it. OK opens the mods folder; Close dismisses.
func _show_modpack_saved_dialog(display_name: String, mod_count: int, path: String) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Modpack saved"
	var count_phrase := ""
	if mod_count == 1:
		count_phrase = " with 1 mod"
	elif mod_count > 1:
		count_phrase = " with %d mods" % mod_count
	var where := "\n\n" + path if path != "" else ""
	d.dialog_text = "Saved \"%s\"%s to your mods folder.%s\n\nTo share it, send that file to anyone. When they drop it in their mods folder and open the Modpacks tab, they apply it in one click -- the mods download automatically." \
			% [display_name, count_phrase, where]
	d.ok_button_text = "Open mods folder"
	d.get_cancel_button().text = "Close"
	_attach_ui_dialog(d)
	style_dialog_primary_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			if not _mods_dir.is_empty():
				OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
			d.queue_free(),
		func(): d.queue_free())
	d.popup_centered()

# Walk the source tree and write every file into the zip under zip_prefix.
# Hidden entries are skipped; DirAccess never follows symlinks in Godot 4.
func _add_dir_to_zip(packer: ZIPPacker, fs_path: String, zip_prefix: String) -> bool:
	var dir := DirAccess.open(fs_path)
	if dir == null:
		# Unopenable directory: fail rather than ship a silently incomplete snapshot.
		return false
	dir.list_dir_begin()
	var ok := true
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var src_full := fs_path.path_join(name)
		var zip_path := zip_prefix + "/" + name
		if dir.current_is_dir():
			if not _add_dir_to_zip(packer, src_full, zip_path):
				ok = false
		else:
			var f := FileAccess.open(src_full, FileAccess.READ)
			if f == null:
				ok = false
				continue
			var bytes := f.get_buffer(f.get_length())
			f.close()
			if packer.start_file(zip_path) == OK:
				if packer.write_file(bytes) != OK:
					ok = false
				packer.close_file()
			else:
				ok = false
	dir.list_dir_end()
	return ok

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
		mcm_ok = _add_dir_to_zip(packer, MCM_SOURCE_DIR, "MCM")

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

# Tear down and rebuild the Mods tab in place. Preserves the current tab so
# a Browse-row toggle does not yank the user onto the Mods tab.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_MODS)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	var saved_scroll := 0
	if is_instance_valid(_ui_mods_scroll):
		saved_scroll = _ui_mods_scroll.scroll_vertical
	var idx := old.get_index()
	# Capture the current tab by name: remove_child shifts sibling indices.
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = UI_TAB_MODS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	# Restore by name; if the previous tab was Mods, land on the rebuilt one.
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	# Profile/dev-mode changes bypass the per-row checkbox handler.
	refresh_launch_button_label()
	if saved_scroll > 0:
		_restore_mods_scroll(saved_scroll)

# One frame later: scroll_vertical set before layout clamps to zero.
func _restore_mods_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_mods_scroll):
		_ui_mods_scroll.scroll_vertical = saved_scroll

# Rebuild the Updates tab on show: it snapshots entries at build time, so a
# mod updated mid-session would leave rows whose Download targets a gone file.
func _rebuild_updates_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_UPDATES)
	if old == null:
		return
	var saved_scroll := 0
	if is_instance_valid(_ui_updates_scroll):
		saved_scroll = _ui_updates_scroll.scroll_vertical
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
	if saved_scroll > 0:
		_restore_updates_scroll(saved_scroll)

# Same one-frame-later restore as _restore_mods_scroll.
func _restore_updates_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_updates_scroll):
		_ui_updates_scroll.scroll_vertical = saved_scroll

# Modpack-apply failure summary: per-failure rows with an open-page button
# when the host has one, and "Retry failed" for the failed downloads.
func _show_modpack_failure_dialog(downloaded: int, failures: Array, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpack applied with issues"
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(540, 420))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	d.add_child(box)

	var hdr := Label.new()
	hdr.text = "Downloaded %d mod(s), %d failed." % [downloaded, failures.size()]
	box.add_child(hdr)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 140))
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

		var f_ref: Dictionary = f.get("ref", {}) if f.get("ref") is Dictionary else {}
		var page_url := host_mod_page_url(f_ref)
		if page_url != "":
			var open_btn := Button.new()
			open_btn.text = "Open " + host_display_name(str(f_ref["provider"])) + " page"
			open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(open_btn)
			open_btn.pressed.connect(func():
				OS.shell_open(page_url)
			)

	# Retry sits in the native button bar; omitted when nothing is downloadable.
	var retry_btn: Button = null
	var any_retryable := false
	for f_v in failures:
		if f_v is Dictionary and (f_v as Dictionary).get("ref") is Dictionary \
				and _modpack_ref_downloadable((f_v as Dictionary)["ref"]):
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


# Retry failed modpack downloads with a progress dialog, then re-show failures.
func _run_modpack_retry(failures: Array, tabs: TabContainer) -> void:
	# Reuses the apply progress dialog; Cancel sets _modpack_apply_cancelled.
	_modpack_apply_cancelled = false
	var progress_ui := _build_modpack_progress_dialog("", "Retrying failed downloads")
	var pd: AcceptDialog = progress_ui["dialog"]
	var pd_bar: ProgressBar = progress_ui["bar"]
	var status_lbl: Label = progress_ui["status"]
	var pd_cancel: Button = progress_ui["cancel"]
	pd_cancel.pressed.connect(func():
		if is_instance_valid(status_lbl):
			status_lbl.text = "Cancelling after current download..."
		if is_instance_valid(pd_cancel):
			pd_cancel.disabled = true
			pd_cancel.text = "Cancelling..."
		_modpack_apply_cancelled = true
	)
	pd.popup_centered()

	var progress_cb := func(p: Dictionary):
		if not is_instance_valid(status_lbl):
			return
		var cur := int(p.get("current", 0))
		var tot := int(p.get("total", 0))
		var nm := str(p.get("mod_name", ""))
		var act := str(p.get("action", ""))
		if is_instance_valid(pd_bar) and tot > 0:
			pd_bar.value = float(cur) / float(tot) * 100.0
		if act == "rate_wait":
			status_lbl.text = "Rate limited by %s -- resuming in %ds" % [str(p.get("host", "the mod site")), int(p.get("wait_s", 0))]
			return
		if nm != "":
			status_lbl.text = "Retrying %d of %d:\n%s" % [cur, tot, nm]
		else:
			status_lbl.text = "Retrying..."

	var result := await retry_failed_downloads(failures, progress_cb)

	if is_instance_valid(pd):
		pd.queue_free()

	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	var still_failed: Array = result.get("failures", [])
	var dl: int = int(result.get("downloaded", 0))
	if still_failed.is_empty():
		var ok_d := AcceptDialog.new()
		ok_d.title = "Retry complete"
		ok_d.dialog_text = "Downloaded %d mod(s) on retry." % dl
		ok_d.ok_button_text = "Close"
		_attach_ui_dialog(ok_d)
		_wire_accept_dismiss(ok_d)
		ok_d.popup_centered()
	else:
		_show_modpack_failure_dialog(dl, still_failed, tabs)


# Borderless accept dialog with one dismiss button; backs the two helpers below.
func _show_accept_dialog(title: String, message: String, ok_text := "OK", min_w := 360) -> void:
	var d := AcceptDialog.new()
	d.title = title
	d.dialog_text = message
	d.ok_button_text = ok_text
	d.min_size = Vector2i(min_w, 0)
	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Free an AcceptDialog on both confirmed and close_requested.
func _wire_accept_dismiss(d: AcceptDialog) -> void:
	d.confirmed.connect(func(): d.queue_free())
	d.close_requested.connect(func(): d.queue_free())

# Error dialog so user-facing failures surface in the UI, not just the log.
func _show_error_dialog(title: String, message: String) -> void:
	_show_accept_dialog(title, message, "Close", 400)


# Neutral info dialog for benign confirmations ("all mods up to date").
func _show_info_toast(message: String) -> void:
	_show_accept_dialog("Mod Loader", message, "Close")


# Clamp a dialog's min_size to the live launcher window: dialogs are embedded
# sub-windows, so a larger min_size gets clipped with no way to resize. Sizes
# are in content-scaled coordinates, hence the divide.
func _dialog_fit_size(desired: Vector2i) -> Vector2i:
	if _ui_window == null or not is_instance_valid(_ui_window):
		return desired
	var scale: float = maxf(_ui_window.content_scale_factor, 0.001)
	var avail := Vector2i(Vector2(_ui_window.size) / scale) - Vector2i(24, 24)
	return Vector2i(mini(desired.x, maxi(avail.x, 200)), mini(desired.y, maxi(avail.y, 150)))

# Every launcher dialog flows through this: borderless dark card, title and
# dialog_text moved into a header, caller children reparented into one VBox.
func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme
	d.transparent = false
	d.transparent_bg = false
	d.always_on_top = true
	d.transient = true
	d.exclusive = true
	d.borderless = true
	d.add_theme_stylebox_override("panel", _make_dialog_panel_stylebox())

	# AcceptDialog's dialog_text label is absolutely positioned, so sibling
	# Labels would overlap it; clear title and dialog_text and re-emit them.
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


# Set all four border widths of a StyleBoxFlat to `w`.
func _sb_border(s: StyleBoxFlat, w := 1) -> void:
	s.border_width_top = w
	s.border_width_bottom = w
	s.border_width_left = w
	s.border_width_right = w

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

# ConfirmationDialog fires `canceled` on Cancel and `close_requested` on
# ESC / window-X; callers want both to behave the same.
func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

# Swap the bottom-bar hint label to `text` while hovered (the launcher's tooltip).
func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	# mouse_entered/exited never fire on MOUSE_FILTER_IGNORE (the Label
	# default), so establish PASS here rather than at every caller.
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

## Whether the scanner could not read part of this mod. Distinct from a risk
## verdict; both otherwise render identically to the user.
func _entry_has_unscannable_code(entry: Dictionary) -> bool:
	var findings: Variant = entry.get("security_findings")
	if not (findings is Array):
		return false
	for f in (findings as Array):
		if f is Dictionary and str((f as Dictionary).get("rule", "")) == "compiled_script":
			return true
	return false


func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	# Calling compiled-only mods suspicious would accuse legitimate builds.
	var accusing := int(entry.get("risk_level", 0)) == 2
	d.title = ("Suspicious code in " if accusing else "Not fully scanned: ") + mod_name
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
	if accusing:
		intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
				+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
				+ "If you don't trust this mod, do not enable it."
	else:
		intro.text = "The scanner did not find anything dangerous, but it could not read part of " \
				+ "this mod -- compiled scripts are opaque to it. This is not an accusation: " \
				+ "plenty of legitimate mods ship compiled code. It only means the check below " \
				+ "is incomplete, so judge this mod by whether you trust its author."
	intro.add_theme_color_override("font_color", COL_ERR if accusing else COL_TEXT_DIM)
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

# Show an attached ConfirmationDialog and await the choice; true on confirm.
# The Array is the closure-shared state cell.
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

# Yes/no confirm when disabling a mod that registers game content; true =
# proceed. `count` > 1 switches to batch wording.
func _confirm_disable_content_mod(mod_name: String, count: int = 1) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Disable content mod?" if count <= 1 else "Disable content mods?"
	d.ok_button_text = "Disable anyway"
	d.cancel_button_text = "Keep enabled"
	d.dialog_autowrap = true
	d.min_size = Vector2(520, 120)
	if count > 1:
		d.dialog_text = "%d of these mods (including \"%s\") add game content (items, recipes, and similar). Saves that use their content may not load while the mods are disabled. Your saves are not deleted -- re-enable the mods to get them back.\n\nDisable anyway?" % [count, mod_name]
	else:
		d.dialog_text = "\"%s\" adds game content (items, recipes, and similar). A save that uses this content may not load while the mod is disabled. Your save is not deleted -- re-enable the mod to get it back.\n\nDisable anyway?" % mod_name
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	style_dialog_danger_button(d.get_ok_button())
	return await _await_dialog_choice(d)

# Validate a candidate profile name (New and Rename). Returns the user-facing
# error, or "" when acceptable. `current` lets Rename accept its own name.
func _validate_profile_name(name: String, existing: Array, current := "") -> String:
	if name == "":
		return "Name cannot be empty or all invalid characters."
	if name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return "That name is reserved."
	if name == current:
		return ""
	# Case-insensitive: MCM snapshot dirs are keyed by profile name on a
	# case-insensitive filesystem, so case-only twins would share a dir.
	var lowered := name.to_lower()
	for other_v in existing:
		# A case-only rename (Main -> MAIN) is not a duplicate of itself.
		if current != "" and str(other_v) == current:
			continue
		if str(other_v).to_lower() == lowered:
			return "Profile \"" + str(other_v) + "\" already exists."
	return ""

# New Profile dialog: name plus initial state. Initial state defaults to
# Empty; a fresh profile starts blank.
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
	name_edit.custom_minimum_size.y = CTRL_H
	form.add_child(name_edit)

	var state_lbl := Label.new()
	state_lbl.text = "Initial state:"
	form.add_child(state_lbl)

	# CheckBox + ButtonGroup = radio buttons; set button_group before button_pressed.
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
			# Mutate in-memory entries to the chosen initial state, then _create_profile
			# snapshots them. Priorities are left untouched.
			if state_all.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = true
			elif state_empty.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = false
			_create_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_create.call())
	_connect_dialog_exits(d, try_create, func(): d.queue_free())
	d.popup_centered()
	name_edit.grab_focus()

# Rename dialog. Same validation as New; renaming to the same name is a no-op.
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
	name_edit.custom_minimum_size.y = CTRL_H
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

# The standard 8/8/6/6 outer margin shared by all top-level tab builders.
func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m

# Restore-point picker: lists the pre-apply snapshots newest first and
# restores the chosen one (mod_config.cfg, MCM and saved override files).
func _show_restore_snapshot_dialog(tabs: TabContainer) -> void:
	# Snapshots are captured with no pack active; restoring over an active pack
	# would leave its override files live and untracked. Unload first.
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
			var rcfg := ConfigFile.new()
			rcfg.load(UI_CONFIG_PATH)
			_active_profile = str(rcfg.get_value("settings", "active_profile", _active_profile))
			_reload_entries_for_active_profile()
			_rebuild_mods_tab(tabs)
			_rebuild_modpacks_tab(tabs)
			# The restore rewrote cfg and MCM on disk; a post-boot session restarts into it.
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

	# Export the current profile as a modpack zip; disabled while a pack is active.
	var save_modpack_btn := Button.new()
	save_modpack_btn.text = "Save current profile as modpack"
	save_modpack_btn.tooltip_text = "Save your currently-enabled mods as one shareable modpack file. Anyone you send it to gets this exact setup in one click."
	var save_disabled_reason := ""
	if active_modpack != "":
		save_disabled_reason = "Unload the active modpack first"
	save_modpack_btn.disabled = save_disabled_reason != ""
	if save_disabled_reason != "":
		save_modpack_btn.tooltip_text = save_disabled_reason
	hdr_row.add_child(save_modpack_btn)
	save_modpack_btn.pressed.connect(func():
		var profile_to_save := _active_profile
		var orphans := _enabled_mods_without_source()
		_show_save_modpack_dialog(profile_to_save, orphans, tabs)
	)

	var hosted_btn := Button.new()
	hosted_btn.text = "Get from VostokMods"
	hosted_btn.tooltip_text = "Browse the modpacks published on vostokmods.net, or paste a pack link."
	hdr_row.add_child(hosted_btn)
	hosted_btn.pressed.connect(func():
		_show_hosted_packs_dialog(tabs)
	)

	var open_folder_btn := Button.new()
	open_folder_btn.text = "Open mods folder"
	open_folder_btn.tooltip_text = "Drop modpack zips into this folder -- they appear in the list next time you open this tab."
	hdr_row.add_child(open_folder_btn)
	open_folder_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)

	# Restore from an automatic pre-apply snapshot; disabled until one exists.
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
	# Kept on self so _rebuild_modpacks_tab can carry the scroll position.
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
		empty.text = "No modpacks yet.\n\nA modpack is a shareable list of mods -- one small file that gives someone your exact setup in one click (the mods download automatically when they apply it).\n\nGet one from VostokMods above, save your current profile as a modpack, or drop someone else's modpack zip into your mods folder."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		list.add_child(empty)
		return margin

	for entry in _modpack_entries:
		list.add_child(_modpacks_render_row(entry, active_modpack, tabs))
		list.add_child(HSeparator.new())

	return margin


# Unload the active modpack, with an error dialog on failure; always rebuilds the tab.
func _unload_modpack_with_feedback(tabs: TabContainer) -> void:
	var result := unload_modpack(tabs)
	if not bool(result.get("ok", false)):
		_show_error_dialog("Could not unload modpack", str(result.get("error", "unknown")))
	_rebuild_modpacks_tab(tabs)

# One modpack row: name, meta, Apply or Active+Unload. Apply is disabled while another pack is active.
func _modpacks_render_row(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", SP_M)
	info_col.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = str(entry.get("raw_name", "?"))
	name_lbl.add_theme_font_size_override("font_size", FS_HEAD)
	name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
	# raw_name comes from the zip; clip it so it cannot push the buttons out of view.
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = name_lbl.text
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_lbl)

	var author: String = str(entry.get("author", "")).strip_edges()
	if not author.is_empty():
		var author_lbl := Label.new()
		author_lbl.text = "by " + author
		author_lbl.add_theme_font_size_override("font_size", FS_BODY)
		author_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		author_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
		name_row.add_child(author_lbl)

	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(desc_lbl)

	# Surface dedupe results so the user knows same-name zips exist but are hidden.
	var dups: Array = entry.get("duplicates_hidden", [])
	if not dups.is_empty():
		var dup_names := PackedStringArray()
		for d_v in dups:
			if d_v is Dictionary:
				dup_names.append(str((d_v as Dictionary).get("file_name", "?")))
		var dup_lbl := Label.new()
		dup_lbl.text = "Duplicate file(s) hidden: " + ", ".join(dup_names)
		dup_lbl.add_theme_color_override("font_color", COL_ACCENT)
		dup_lbl.add_theme_font_size_override("font_size", FS_BODY)
		dup_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(dup_lbl)

	var enabled_count: int = int(entry.get("enabled_count", 0))
	var total_count: int = int(entry.get("total_count", 0))
	var hosted: Dictionary = entry.get("hosted", {}) if entry.get("hosted") is Dictionary else {}
	var is_hosted := str(hosted.get("slug", "")) != ""
	var meta_lbl := Label.new()
	if total_count > 0:
		meta_lbl.text = "%d of %d mods enabled - %s" % [enabled_count, total_count, str(entry.get("file_name", ""))]
	else:
		meta_lbl.text = str(entry.get("file_name", ""))
	if is_hosted:
		meta_lbl.text = "from VostokMods - " + meta_lbl.text
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

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

	if is_hosted:
		var refresh_btn := Button.new()
		refresh_btn.text = "Refresh"
		refresh_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		refresh_btn.disabled = is_active
		row.add_child(refresh_btn)
		_wire_hint(refresh_btn, "Unload this pack before refreshing it from VostokMods." if is_active \
				else "Fetch the pack's current mod list from VostokMods.")
		var captured_hosted_entry := entry
		refresh_btn.pressed.connect(func():
			if not is_instance_valid(refresh_btn):
				return
			refresh_btn.disabled = true
			refresh_btn.text = "Refreshing..."
			var r: Dictionary = await _hosted_refresh_pack(captured_hosted_entry)
			if is_instance_valid(refresh_btn):
				refresh_btn.disabled = false
				refresh_btn.text = "Refresh"
			if not is_instance_valid(_ui_window):
				return
			if not bool(r.get("ok", false)):
				_show_error_dialog("Could not refresh modpack", str(r.get("error", "unknown")))
			elif bool(r.get("changed", false)):
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				_show_accept_dialog("Modpack updated", "\"" + str(r.get("name", "")) + "\" was updated from VostokMods. Apply it to get the changes.")
			else:
				_show_info_toast("\"" + str(r.get("name", "")) + "\" is up to date with VostokMods.")
		)

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
		# Primary styling is reserved for the detail dialog's Apply and the confirm OK.
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


# Full modpack-apply flow: validate, confirm, progress, apply, rebuild, failure dialog.
func _apply_modpack_with_ui_flow(entry: Dictionary, tabs: TabContainer) -> void:
	# Validate up front so the confirm shows a real preview and a bad zip bails early.
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		_show_error_dialog("Cannot apply modpack", str(validation.get("error", "unknown")))
		return
	var apply_enabled := int(validation.get("enabled_count", 0))
	var apply_total := int(validation.get("total_count", 0))
	var name_str := str(entry.get("raw_name", "?"))
	var missing_preview := _get_missing_mods_for_modpack(entry)
	var dl_count := missing_preview.size()
	var msg := "Apply \"%s\"?\n\nActivates %d of %d mods and replaces your mod settings (MCM)." % [name_str, apply_enabled, apply_total]
	if dl_count > 0:
		msg += "\nWill download %d mod(s)." % dl_count
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
			# No progress dialog when nothing downloads; a pop-and-vanish dialog looks broken.
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
				# Rate-limit pause: show the countdown so the dialog does not look hung.
				if act == "rate_wait":
					pd_status.text = "Rate limited by %s -- resuming in %ds" % [str(p.get("host", "the mod site")), int(p.get("wait_s", 0))]
					return
				var prefix := "Downloading"
				if act == "skipped": prefix = "Skipping (manual install)"
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

			# Cancelled before any state mutation; say so rather than "Applied with Issues".
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
			# Partial: tear down progress, route to the failure dialog.
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
			# Full success: leave the progress dialog in its completion state.
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


# Modpack-apply progress dialog: ProgressBar, status label and Cancel.
# Returns the dialog plus control references; title_override serves the retry pass.
func _build_modpack_progress_dialog(raw_name: String, title_override: String = "") -> Dictionary:
	var pd := AcceptDialog.new()
	pd.title = title_override if title_override != "" else "Applying modpack \"" + raw_name + "\""
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

	# Attach after content so _attach_ui_dialog reparents it. Non-dismissible
	# while running: a hidden dialog would lift the exclusive input block and
	# let the user Launch or switch profiles mid-apply. Cancel is the way out.
	_attach_ui_dialog(pd)
	pd.dialog_close_on_escape = false
	var pd_ok := pd.get_ok_button()
	if pd_ok != null:
		pd_ok.visible = false

	return {"dialog": pd, "bar": bar, "status": status, "cancel": cancel_btn}


# Read the modpack zip's profile.json into a Dictionary; {} on any failure.
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


# Detail modal for a Modpacks-tab row: size, counts, mod list with installed/missing marks.
func _show_modpack_detail_dialog(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = str(entry.get("raw_name", "?"))
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
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
	# Hand-edited packs carry null/String values; _count_truthy type-checks each.
	var enabled_count := _count_truthy(enabled_map)
	var installed_count := 0
	var missing_count := 0

	var index := _modpack_installed_index()
	var installed_keys: Dictionary = index["keys"]
	var installed_refs: Dictionary = index["refs"]
	var unavailable_map: Dictionary = parsed.get("unavailable", {}) if parsed.get("unavailable") is Dictionary else {}
	var key_installed := func(k: String) -> bool:
		return installed_keys.has(k) or _modpack_source_installed(sources_map.get(k), installed_refs)

	for k_v in enabled_map.keys():
		if key_installed.call(str(k_v)):
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
			var en: bool = _json_truthy(enabled_map[k_v])
			var installed: bool = key_installed.call(k)
			var src_rec := _normalize_source_record(sources_map.get(k_v))
			var has_source: bool = str(src_rec["provider"]) != ""
			var unavailable_reason: String = str(unavailable_map.get(k_v, ""))

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
			# A hosted pack keys mods by slug; show the slug, not the prefix.
			key_lbl.text = k.trim_prefix(HOSTED_KEY_PREFIX)
			key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			key_lbl.clip_text = true
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
				status_lbl.add_theme_color_override("font_color", COL_ACCENT)
			elif unavailable_reason != "":
				status_lbl.text = "Not available"
				status_lbl.tooltip_text = _hosted_unavailable_copy(unavailable_reason)
				status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
				status_lbl.add_theme_color_override("font_color", COL_ERR)
			else:
				status_lbl.text = "Manual install"
				status_lbl.add_theme_color_override("font_color", COL_ERR)
			status_lbl.add_theme_font_size_override("font_size", FS_BODY)
			status_lbl.custom_minimum_size.x = 110
			mod_row.add_child(status_lbl)

	var hosted_d: Dictionary = entry.get("hosted", {}) if entry.get("hosted") is Dictionary else {}
	var page_url := str(hosted_d.get("url", ""))
	if page_url.begins_with("https://vostokmods.net/"):
		var page_btn := d.add_button("Open page on VostokMods", false, "")
		page_btn.pressed.connect(func():
			OS.shell_open(page_url)
		)
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


# Modpacks published on VostokMods: paste a pack link or search the list.
# "Get" writes the pack into mods/ as a local modpack zip.
func _show_hosted_packs_dialog(tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpacks on VostokMods"
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(680, 560))

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_M)
	d.add_child(outer)

	var paste_row := HBoxContainer.new()
	paste_row.add_theme_constant_override("separation", SP_M)
	outer.add_child(paste_row)
	var paste := LineEdit.new()
	paste.placeholder_text = "Paste a modpack link from vostokmods.net"
	paste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste.custom_minimum_size.y = CTRL_H
	paste_row.add_child(paste)
	var add_btn := Button.new()
	add_btn.text = "Add"
	paste_row.add_child(add_btn)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", FS_BODY)
	status.add_theme_color_override("font_color", COL_TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Loading packs..."
	outer.add_child(status)

	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", SP_M)
	outer.add_child(search_row)
	var search := LineEdit.new()
	search.placeholder_text = "Search packs..."
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.custom_minimum_size.y = CTRL_H
	search_row.add_child(search)
	var sort_dropdown := OptionButton.new()
	for opt in [["updated", "Recently updated"], ["newest", "Newest"], ["name", "Name"]]:
		sort_dropdown.add_item(str(opt[1]))
		sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, str(opt[0]))
	var sort_popup := sort_dropdown.get_popup()
	sort_popup.always_on_top = true
	sort_popup.transient = true
	search_row.add_child(sort_dropdown)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	outer.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var load_more := Button.new()
	load_more.text = "Load more"
	load_more.visible = false
	outer.add_child(load_more)

	# Local hosted packs by slug, so a row can read "Added" instead of "Get".
	var local_by_slug := func() -> Dictionary:
		var out := {}
		for e in _modpack_entries:
			var h: Dictionary = e.get("hosted", {}) if e.get("hosted") is Dictionary else {}
			if str(h.get("slug", "")) != "":
				out[str(h.get("slug", ""))] = e
		return out

	var state := {"cursor": "", "seq": 0, "busy": false}

	var after_import := func(r: Dictionary, get_btn: Button):
		if not is_instance_valid(d):
			return
		if not bool(r.get("ok", false)):
			status.text = str(r.get("error", "unknown"))
			status.add_theme_color_override("font_color", COL_ERR)
			if is_instance_valid(get_btn):
				get_btn.disabled = false
				get_btn.text = "Get"
			return
		_modpack_entries = collect_modpack_metadata()
		if is_instance_valid(tabs):
			_rebuild_modpacks_tab(tabs)
		status.text = "Added \"" + str(r.get("name", "")) + "\" to your modpacks. Close this window and click Apply on it."
		status.add_theme_color_override("font_color", COL_OK)
		if is_instance_valid(get_btn):
			get_btn.text = "Added"
			get_btn.disabled = true

	var render := func(rows: Array, append: bool):
		if not append:
			for c in list.get_children():
				c.queue_free()
		var local: Dictionary = local_by_slug.call()
		for row_v in rows:
			var row: Dictionary = row_v
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", SP_L)
			list.add_child(line)
			var col := VBoxContainer.new()
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(col)
			var name_lbl := Label.new()
			name_lbl.text = str(row["name"])
			name_lbl.add_theme_font_size_override("font_size", FS_EMPH)
			name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
			name_lbl.clip_text = true
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			col.add_child(name_lbl)
			var parts := PackedStringArray()
			if str(row["author"]) != "":
				parts.append("by " + str(row["author"]))
			if int(row["mod_count"]) >= 0:
				parts.append("%d mods" % int(row["mod_count"]))
			var when := _format_iso_datetime(str(row["updated_at"]))
			if when != "":
				parts.append("updated " + when)
			col.add_child(_make_sub_label(" - ".join(parts), COL_TEXT_DIM, ""))
			if str(row["summary"]) != "":
				var sum_lbl := _make_sub_label(str(row["summary"]), COL_TEXT, "")
				sum_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				col.add_child(sum_lbl)
			var page_btn := Button.new()
			page_btn.text = "Page"
			page_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var captured_page := str(row["page_url"])
			page_btn.pressed.connect(func():
				if captured_page.begins_with("https://vostokmods.net/"):
					OS.shell_open(captured_page)
			)
			line.add_child(page_btn)
			var get_btn := Button.new()
			get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var slug := str(row["slug"])
			if local.has(slug):
				get_btn.text = "Added"
				get_btn.disabled = true
			else:
				get_btn.text = "Get"
			line.add_child(get_btn)
			var captured_manifest := str(row["manifest_url"])
			get_btn.pressed.connect(func():
				if not is_instance_valid(get_btn):
					return
				get_btn.disabled = true
				get_btn.text = "Getting..."
				status.text = "Fetching \"" + str(row["name"]) + "\"..."
				status.add_theme_color_override("font_color", COL_TEXT_DIM)
				var r: Dictionary = await _hosted_pack_from_link(captured_manifest)
				after_import.call(r, get_btn)
			)
			list.add_child(HSeparator.new())

	var fetch := func(append: bool):
		state["seq"] = int(state["seq"]) + 1
		var my_seq := int(state["seq"])
		if not append:
			state["cursor"] = ""
		load_more.disabled = true
		status.text = "Loading packs..." if not append else "Loading more..."
		status.add_theme_color_override("font_color", COL_TEXT_DIM)
		var md: Variant = sort_dropdown.get_item_metadata(sort_dropdown.selected)
		var res: Dictionary = await _vmp_list_modpacks({
			"query": search.text, "sort": str(md) if md != null else "", "cursor": str(state["cursor"]),
		})
		if not is_instance_valid(d) or int(state["seq"]) != my_seq:
			return
		if not res["ok"]:
			status.text = host_error_message(HOST_VOSTOKMODS, res)
			status.add_theme_color_override("font_color", COL_ERR)
			load_more.disabled = false
			return
		var page: Dictionary = res["data"]
		render.call(page["rows"], append)
		state["cursor"] = str(page["next_cursor"])
		load_more.visible = bool(page["has_more"])
		load_more.disabled = not bool(page["has_more"])
		var total := int(page["total"])
		if (page["rows"] as Array).is_empty() and not append:
			status.text = "No packs match." if search.text.strip_edges() != "" else "No modpacks on VostokMods yet."
		elif total >= 0:
			status.text = "%d pack(s) on VostokMods" % total
		else:
			status.text = ""

	var debounce := Timer.new()
	debounce.one_shot = true
	debounce.wait_time = 0.3
	d.add_child(debounce)
	debounce.timeout.connect(func(): fetch.call(false))
	search.text_changed.connect(func(_t: String):
		debounce.stop()
		debounce.start()
	)
	search.text_submitted.connect(func(_t: String):
		debounce.stop()
		fetch.call(false)
	)
	sort_dropdown.item_selected.connect(func(_i: int): fetch.call(false))
	load_more.pressed.connect(func(): fetch.call(true))

	var add_from_paste := func():
		if bool(state["busy"]):
			return
		var text := paste.text.strip_edges()
		if text.is_empty():
			return
		state["busy"] = true
		add_btn.disabled = true
		status.text = "Fetching the pack..."
		status.add_theme_color_override("font_color", COL_TEXT_DIM)
		var r: Dictionary = await _hosted_pack_from_link(text)
		state["busy"] = false
		if is_instance_valid(add_btn):
			add_btn.disabled = false
		after_import.call(r, null)
		if bool(r.get("ok", false)) and is_instance_valid(paste):
			paste.text = ""
			fetch.call(false)
	add_btn.pressed.connect(add_from_paste)
	paste.text_submitted.connect(func(_t: String): add_from_paste.call())

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()
	fetch.call(false)


# Mirror of _rebuild_mods_tab. _rebuilding_modpacks_tab guards against
# recursion: remove_child and the current_tab restore both fire tab_changed.
func _rebuild_modpacks_tab(tabs: TabContainer) -> void:
	if _rebuilding_modpacks_tab:
		return
	_rebuilding_modpacks_tab = true
	var old := tabs.get_node_or_null(UI_TAB_MODPACKS)
	if old == null:
		_rebuilding_modpacks_tab = false
		return
	_rebuilding_tab_in_place = true
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

# Same one-frame-later restore as _restore_mods_scroll.
func _restore_modpacks_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_modpacks_scroll):
		_ui_modpacks_scroll.scroll_vertical = saved_scroll

# Delete-profile confirmation; the trash button is disabled when deletion is impossible.
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


# Per-row Remove confirmation, then delete, strip profile state, re-scan and rebuild.
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
				_rebuild_mods_tab(tabs)
			else:
				_show_error_dialog("Could not delete mod", "Could not remove %s. If this mod is enabled, its archive is mounted and the file stays locked while the game is open -- disable it, relaunch the game, then delete." % str(entry.get("file_name", "the mod"))),
		func(): d.queue_free())
	d.popup_centered()



func show_mod_ui() -> void:
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

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

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

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# _wire_hint needs _ui_hint_label, which the bottom bar set above.
	_wire_hint(close_btn, "Close the launcher and launch the game (same as Launch).")

	# Fire-and-forget self-update check; guards on is_instance_valid after the await.
	_check_modloader_update_async()

	# --- Tab contract ---
	# Each tab is built by a build_*_tab(tabs) -> Control function and added
	# under a stable node name (UI_TAB_*). TabContainer shows the name as the
	# tab title, the in-place rebuild helpers find the tab through
	# get_node_or_null(name), and the tab_changed listener below matches on
	# it. To add a tab: build_x_tab(tabs) + a UI_TAB_X const (constants.gd),
	# add and name it below, and add a rebuild or on-show refresh if other
	# surfaces can change its state. A name mismatch fails silently: the
	# rebuild helpers skip and the tab goes stale.

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

# -- Sub-label / row-action factories -----------------------------------------
# Ellipsis trim and working tooltips (Labels default to MOUSE_FILTER_IGNORE).
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

# Flat inline action button for row sub-lines (Enable dependency, Load anyway, Re-check).
func _make_row_action(text: String, color: Color, tip := "") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", color)
	# Flat buttons draw no hover stylebox; the brightened font is the hover cue.
	btn.add_theme_color_override("font_hover_color", color.lerp(COL_TEXT_HI, 0.35))
	btn.add_theme_color_override("font_pressed_color", color)
	btn.add_theme_font_size_override("font_size", FS_BODY)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	if tip != "":
		btn.tooltip_text = tip
	return btn

# Shared tail for dependency quick actions: recompute, persist, refresh.
# Rebuild is deferred so the mid-signal control isn't torn down.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

# Runtime-generated 16x16 pencil icon, monochrome to match the UI.
func _make_pencil_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	for x in range(1, 13):
		img.set_pixel(x, 5, line)
		img.set_pixel(x, 9, line)
	for y in range(5, 10):
		img.set_pixel(1, y, line)
		img.set_pixel(12, y, line)
	for y in range(5, 10):
		img.set_pixel(4, y, line)
	img.set_pixel(13, 6, line)
	img.set_pixel(13, 7, line)
	img.set_pixel(13, 8, line)
	img.set_pixel(14, 7, line)
	return ImageTexture.create_from_image(img)

# Runtime-generated 16x16 trashcan icon.
func _make_trashcan_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	for x in range(6, 10):
		img.set_pixel(x, 2, line)
	for x in range(3, 13):
		img.set_pixel(x, 4, line)
	for y in range(5, 14):
		img.set_pixel(4, y, line)
		img.set_pixel(11, y, line)
	for x in range(5, 11):
		img.set_pixel(x, 13, line)
	for y in range(6, 12):
		img.set_pixel(6, y, line)
		img.set_pixel(8, y, line)
		img.set_pixel(10, y, line)
	return ImageTexture.create_from_image(img)

func make_dark_theme() -> Theme:
	var t := Theme.new()
	# Pin the default font size; the engine's 16px default would flatten the type scale.
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
	var cb_checked := _make_checkbox_icon(true, COL_BORDER, COL_ACCENT)
	var cb_unchecked := _make_checkbox_icon(false, COL_BORDER, COL_ACCENT)
	t.set_icon("checked",   "CheckBox", cb_checked)
	t.set_icon("unchecked", "CheckBox", cb_unchecked)
	t.set_icon("checked_disabled",   "CheckBox", _make_checkbox_icon(true, COL_BORDER_DIM, COL_TEXT_FAINT))
	t.set_icon("unchecked_disabled", "CheckBox", _make_checkbox_icon(false, COL_BORDER_DIM, COL_TEXT_FAINT))
	# Radio variants: CheckBox + ButtonGroup switches to the radio_* icons.
	var rb_checked := _make_radio_icon(true, COL_BORDER, COL_ACCENT)
	var rb_unchecked := _make_radio_icon(false, COL_BORDER, COL_ACCENT)
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

	# -- TabContainer: the selected tab carries a 2px accent roofline; StyleBoxFlat
	# has one border color, so side borders go to 0.
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = COL_BG
	ts.border_color = COL_ACCENT
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
	le_focus.border_color = COL_ACCENT
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", COL_TEXT)

	# -- TextEdit (multi-line) -- mirror LineEdit so it matches the system.
	t.set_stylebox("normal", "TextEdit", le)
	t.set_stylebox("focus",  "TextEdit", le_focus)
	t.set_color("font_color", "TextEdit", COL_TEXT)

	# -- SpinBox arrows (stock glyph is light-theme) -----------------------------
	t.set_icon("updown", "SpinBox", _make_updown_icon(COL_TEXT_DIM))

	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# -- ScrollBars: width comes from stylebox minimum sizes (track 2+2, grabber
	# 6+6 = 16px); along-axis margins keep the grabber a usable length.
	var track_v := StyleBoxFlat.new()
	track_v.bg_color = COL_BG
	track_v.border_color = COL_BORDER_DIM
	track_v.border_width_left = 1
	track_v.content_margin_left = 2
	track_v.content_margin_right = 2
	var grab_v := StyleBoxFlat.new()
	grab_v.bg_color = COL_BORDER
	grab_v.content_margin_left = 6
	grab_v.content_margin_right = 6
	grab_v.content_margin_top = 12
	grab_v.content_margin_bottom = 12
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
	track_h.content_margin_top = 2
	track_h.content_margin_bottom = 2
	var grab_h := StyleBoxFlat.new()
	grab_h.bg_color = COL_BORDER
	grab_h.content_margin_top = 6
	grab_h.content_margin_bottom = 6
	grab_h.content_margin_left = 12
	grab_h.content_margin_right = 12
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
	pb_fill.bg_color = COL_ACCENT_DIM
	pb_fill.border_color = COL_ACCENT
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

	# -- OptionButton (separate theme type from Button, so re-set styles) ------
	t.set_stylebox("normal",   "OptionButton", bn.duplicate())
	t.set_stylebox("hover",    "OptionButton", bh.duplicate())
	t.set_stylebox("pressed",  "OptionButton", bp.duplicate())
	t.set_stylebox("disabled", "OptionButton", bd.duplicate())
	t.set_stylebox("focus",    "OptionButton", _make_focus_stylebox())
	t.set_color("font_color",         "OptionButton", COL_TEXT)
	t.set_color("font_hover_color",   "OptionButton", COL_TEXT_HI)
	t.set_color("font_pressed_color", "OptionButton", COL_TEXT)

	# -- Tooltip -- without these, tooltips render in the default light theme.
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
	var dlg_panel := StyleBoxFlat.new()
	dlg_panel.bg_color = COL_SURFACE
	dlg_panel.border_color = COL_BORDER
	_sb_border(dlg_panel)
	# Same padding tokens as _make_dialog_panel_stylebox.
	dlg_panel.content_margin_left = SP_XL
	dlg_panel.content_margin_right = SP_XL
	dlg_panel.content_margin_top = SP_L
	dlg_panel.content_margin_bottom = SP_L
	t.set_stylebox("panel", "AcceptDialog", dlg_panel)
	t.set_stylebox("panel", "ConfirmationDialog", dlg_panel.duplicate())
	t.set_stylebox("embedded_border",           "Window", dlg_panel.duplicate())
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel.duplicate())
	t.set_color("title_color", "Window", COL_TEXT_HI)

	return t

# -- Theme building blocks + component voices ---------------------------------
# Call sites opt into a voice via the style_* helpers; default buttons take the theme.

# Uniform 1px-border box with the theme's 10/4 button margins.
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

# Keyboard-focus ring: 1px accent border, no fill.
func _make_focus_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = COL_ACCENT
	_sb_border(s)
	return s

# Primary button voice: accent text and hover border. At most one per surface.
func style_primary_button(b: Button) -> void:
	_style_accent_button(b, COL_ACCENT)

# Danger button voice (Delete, Unload): red text + red hover border.
func style_danger_button(b: Button) -> void:
	_style_accent_button(b, COL_ERR)

# Accent voices for dialog action buttons. Kept on modulate: a theme
# font-color override on a dialog OK button does not take effect.
func style_dialog_primary_button(b: Button) -> void:
	b.modulate = COL_ACCENT

func style_dialog_danger_button(b: Button) -> void:
	b.modulate = COL_ERR

# Shared body of the two accent voices; everything else stays on the theme.
func _style_accent_button(b: Button, accent: Color) -> void:
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", accent)
	b.add_theme_color_override("font_pressed_color", accent)
	# Keep the accent while keyboard-focused.
	b.add_theme_color_override("font_focus_color", accent)
	b.add_theme_font_size_override("font_size", FS_BODY)
	b.add_theme_stylebox_override("hover", _make_button_stylebox(COL_SURFACE_2, accent))

# Badge chip stylebox (update counts, dependency state). Defaults to the
# accent notice look; pass COL_ERR/COL_ERR_DIM for error badges.
func _make_badge_stylebox(border: Color = COL_ACCENT, bg: Color = COL_ACCENT_DIM) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	_sb_border(s)
	s.content_margin_left = SP_S
	s.content_margin_right = SP_S
	s.content_margin_top = SP_XS
	s.content_margin_bottom = SP_XS
	return s

# Banner: a COL_SURFACE strip with a 3px colored left edge. Returns
# {"panel", "row", "label"} so callers can append action buttons.
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

# Runtime-generated 14x14 checkbox glyph; checked adds a 2px check stroke.
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
		var pts := [
			Vector2i(3, 7), Vector2i(4, 8), Vector2i(5, 9),
			Vector2i(6, 8), Vector2i(7, 7), Vector2i(8, 6),
			Vector2i(9, 5), Vector2i(10, 4),
		]
		for p in pts:
			img.set_pixel(p.x, p.y, mark_color)
			img.set_pixel(p.x, p.y + 1, mark_color)
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 radio glyph; distance-field ring, checked adds a dot.
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

# Runtime-generated 9x14 SpinBox arrows (the stock glyph is light-theme gray).
func _make_updown_icon(line: Color) -> ImageTexture:
	var img := Image.create(9, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for row in range(3):
		for x in range(4 - row, 5 + row):
			img.set_pixel(x, 2 + row, line)   # up triangle, apex on top
			img.set_pixel(x, 11 - row, line)  # down triangle, apex on bottom
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 close glyph, two diagonals (keeps the source ASCII).
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

# Cached summary for a mod from its host's Browse landing snapshot: an
# instant thumbnail and author with no network. {} when not cached.
func _mods_cached_summary(ref: Dictionary) -> Dictionary:
	var key := host_ref_key(ref)
	if key == "":
		return {}
	var snap := _browse_landing_snapshot(str(ref["provider"]))
	if snap.is_empty():
		return {}
	for sec_v in (snap["sections"] as Array):
		if not (sec_v is Dictionary):
			continue
		var rows_v: Variant = (sec_v as Dictionary).get("rows")
		if not (rows_v is Array):
			continue
		for row_v in (rows_v as Array):
			if not (row_v is Dictionary):
				continue
			var row: Dictionary = row_v
			if row.get("ref") is Dictionary and host_ref_key(row["ref"]) == key:
				return row
	return {}

# Persisted per-mod meta sidecar so relaunches do not re-fetch every mod's
# detail: {"<ref_key>": {"mod": <ModDetail>, "saved_at": unix}} under
# user://mws_cache/ (deny-listed for modpack overrides). Stale entries soft-refresh.
const _MODS_META_SIDECAR_PATH := "user://mws_cache/mods_meta_v2.json"
const _MODS_META_REFRESH_SEC := 86400

# True when a record has every field the detail dialog indexes directly.
func _mods_meta_record_complete(mod: Dictionary) -> bool:
	for k in host_empty_summary():
		if not mod.has(k):
			return false
	return mod["ref"] is Dictionary and mod["thumbnail"] is Dictionary and host_ref_valid(mod["ref"])

# Lazy one-time seed of the meta memo from the sidecar. Every field is
# shape-checked so a hand-edited file skips entries rather than crash.
func _mods_meta_sidecar_load() -> void:
	if _mods_meta_sidecar_loaded:
		return
	_mods_meta_sidecar_loaded = true
	if not FileAccess.file_exists(_MODS_META_SIDECAR_PATH):
		return
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	for key_v in (parsed as Dictionary):
		var key := str(key_v)
		if host_ref_from_key(key).is_empty():
			continue
		var entry_v: Variant = (parsed as Dictionary)[key_v]
		if not (entry_v is Dictionary):
			continue
		var mod_v: Variant = (entry_v as Dictionary).get("mod")
		if not (mod_v is Dictionary) or not _mods_meta_record_complete(mod_v):
			continue
		# saved_at arrives as a float after the JSON round-trip; int() it.
		var saved_v: Variant = (entry_v as Dictionary).get("saved_at", 0)
		if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
			continue
		# Never clobber fresher data a fetch already memoized this session.
		if not _mods_meta_by_key.has(key):
			_mods_meta_by_key[key] = mod_v
			_mods_meta_saved_at[key] = int(saved_v)

# Stamp `key` as freshly fetched and rewrite the sidecar from the memo. Only
# keys with a saved_at stamp persist; snapshot-sourced entries stay session-only.
func _mods_meta_sidecar_store(key: String) -> void:
	_mods_meta_saved_at[key] = int(Time.get_unix_time_from_system())
	var out := {}
	for k in _mods_meta_saved_at:
		var d: Variant = _mods_meta_by_key.get(k, {})
		if d is Dictionary and not (d as Dictionary).is_empty():
			out[str(k)] = {
				"mod": d,
				"saved_at": int(_mods_meta_saved_at[k]),
			}
	DirAccess.make_dir_recursive_absolute(_MODS_META_SIDECAR_PATH.get_base_dir())
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out))
	f.close()

# Paint host meta onto the current Mods-tab rows for `key`, resolved through
# _mods_meta_nodes at paint time. No entry = memoize only. Idempotent per row.
func _mods_apply_host_meta(key: String, data: Dictionary) -> void:
	# One host mod can back several rows (.vmz copy plus dev-folder copy).
	var rows_v: Variant = _mods_meta_nodes.get(key)
	if not (rows_v is Array):
		return
	for nodes_v in (rows_v as Array):
		if not (nodes_v is Dictionary):
			continue
		var nodes: Dictionary = nodes_v
		var holder_v: Variant = nodes.get("holder")
		if holder_v is Dictionary:
			(holder_v as Dictionary)["data"] = data
		var thumb_v: Variant = nodes.get("thumb")
		if is_instance_valid(thumb_v) and thumb_v is TextureRect:
			var thumb_rect: TextureRect = thumb_v
			var image_v: Variant = data.get("thumbnail")
			if image_v is Dictionary and str((image_v as Dictionary).get("url", "")) != "":
				# The caption stays until _set_thumb_ready clears it.
				_browse_load_thumbnail_async(thumb_rect, image_v)
			else:
				_set_thumb_failed(thumb_rect, false)
		var col_v: Variant = nodes.get("name_col")
		if is_instance_valid(col_v) and col_v is VBoxContainer:
			var name_col: VBoxContainer = col_v
			if not name_col.has_node("HostAuthorLabel"):
				var author := str(data.get("author_name", ""))
				if author != "":
					var author_lbl := _make_sub_label("by " + author, COL_TEXT_DIM, "")
					author_lbl.name = "HostAuthorLabel"
					name_col.add_child(author_lbl)
					name_col.move_child(author_lbl, 1)  # right under the name

# Paint the "load failed" overlay for a mod whose meta fetch failed. Only
# for keys with no memoized data; a failed soft refresh keeps its texture.
func _mods_paint_meta_failed(key: String) -> void:
	var rows_v: Variant = _mods_meta_nodes.get(key)
	if not (rows_v is Array):
		return
	for nodes_v in (rows_v as Array):
		if not (nodes_v is Dictionary):
			continue
		var thumb_v: Variant = (nodes_v as Dictionary).get("thumb")
		if is_instance_valid(thumb_v) and thumb_v is TextureRect:
			_set_thumb_failed(thumb_v as TextureRect, true)

# Serialized background meta fetches: parallel per-row detail calls could
# drain a host's rate budget. One drain loop; a host in cooldown is skipped.
var _mods_meta_fetch_queue: Array[Dictionary] = []
var _mods_meta_fetch_active := false

func _mods_meta_fetch_enqueue(ref: Dictionary) -> void:
	# No dedupe needed: the retry window is armed before the enqueue.
	_mods_meta_fetch_queue.append(ref)
	if _mods_meta_fetch_active:
		return
	_mods_meta_fetch_active = true
	while not _mods_meta_fetch_queue.is_empty():
		var next: Dictionary = _mods_meta_fetch_queue.pop_front()
		var provider := str(next["provider"])
		if host_rate_cooldown_seconds(provider) > 0:
			continue
		var key := host_ref_key(next)
		var res := await host_get_mod(next)
		var fetch_ok := false
		if res["ok"] and res["data"] is Dictionary and _mods_meta_record_complete(res["data"]):
			fetch_ok = true
			_mods_meta_by_key[key] = res["data"]
			_mods_meta_sidecar_store(key)
			_mods_apply_host_meta(key, res["data"])
		if not fetch_ok:
			# Cold-path failure: caption "load failed"; a failed soft refresh keeps its texture.
			var memo_v: Variant = _mods_meta_by_key.get(key)
			if not (memo_v is Dictionary) or (memo_v as Dictionary).is_empty():
				_mods_paint_meta_failed(key)
	_mods_meta_fetch_active = false

# Populate an installed row's host thumbnail and author and stash the record
# for the detail dialog: memo first, then the Browse snapshot, then a queued fetch.
func _mods_load_host_meta(ref: Dictionary) -> void:
	var key := host_ref_key(ref)
	if key == "":
		return
	_mods_meta_sidecar_load()
	var data: Dictionary = _mods_meta_by_key.get(key, {})
	if not data.is_empty():
		# Memoized: paint synchronously so the row does not sit gray.
		_mods_apply_host_meta(key, data)
		# Soft refresh: a sidecar entry older than a day re-fetches in the
		# background; saved_at == 0 means snapshot-sourced, never refreshed.
		var saved_at := int(_mods_meta_saved_at.get(key, 0))
		if saved_at <= 0 \
				or int(Time.get_unix_time_from_system()) - saved_at < _MODS_META_REFRESH_SEC:
			return
		if Time.get_ticks_msec() < int(_mods_meta_retry_at.get(key, 0)):
			return
		_mods_meta_retry_at[key] = Time.get_ticks_msec() + 60000
		_mods_meta_fetch_enqueue(ref)
		return
	# Skip if a recent attempt failed or is still queued; racing rebuilds share one request.
	if Time.get_ticks_msec() < int(_mods_meta_retry_at.get(key, 0)):
		return
	_mods_meta_retry_at[key] = Time.get_ticks_msec() + 60000
	data = _mods_cached_summary(ref)
	if data.is_empty():
		# Cold path: queue the network fetch.
		_mods_meta_fetch_enqueue(ref)
		return
	# Snapshot hit: memo for the session only.
	_mods_meta_by_key[key] = data
	_mods_apply_host_meta(key, data)

# Click handler for a Mods-row name link: opens the detail dialog once the
# async load has filled `holder`; until then it says so.
func _open_mods_host_detail(holder: Dictionary, ref: Dictionary) -> void:
	var data_v: Variant = holder.get("data")
	if data_v is Dictionary and _mods_meta_record_complete(data_v):
		_show_browse_mod_detail_dialog(data_v, func(_d, _b): pass)
	else:
		var host := host_display_name(str(ref.get("provider", "")))
		_show_accept_dialog(host + " details",
				"Still loading this mod's " + host + " page (or it's unavailable offline). Try again in a moment.",
				"Close", 380)

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	# Drop last build's row-node mapping; the row loop re-registers each row.
	_mods_meta_nodes.clear()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Hook health from the previous session: generation runs after this window
	# closes, so this is where a player learns a game update broke the rewriter.
	var hook_problem := _hook_status_problem()
	if not hook_problem.is_empty():
		var is_error := str(hook_problem.get("severity", "")) == "error"
		var hook_banner := _make_banner(str(hook_problem.get("text", "")), COL_ERR if is_error else COL_ACCENT)
		var update_btn := Button.new()
		update_btn.text = "Check for loader update"
		var hook_banner_row: HBoxContainer = hook_banner["row"]
		hook_banner_row.add_child(update_btn)
		update_btn.pressed.connect(func():
			OS.shell_open(_modloader_release_page_url())
		)
		_wire_hint(update_btn, "Open the loader's release page in your browser.")
		outer.add_child(hook_banner["panel"])

	# Active-modpack banner with a one-click Unload.
	var active_modpack := get_active_modpack()
	if active_modpack != "":
		var banner := _make_banner(
				"Modpack \"" + active_modpack + "\" is active. Changes here save to the modpack, not your profiles.",
				COL_ACCENT)
		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		var banner_row: HBoxContainer = banner["row"]
		banner_row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
		outer.add_child(banner["panel"])

	# -- Toolbar: mods folder, profile controls, UI scale, Developer Mode --

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

	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = SP_L
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window: always_on_top and transient so it is
	# not stranded behind the launcher; theme lookup does not cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Fresh install: Default is a placeholder, materialized on first save.
	# Modpack-managed profiles are filtered out of the dropdown.
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

	# With a modpack active the active profile is a hidden managed slot:
	# disable the dropdown and label it with the pack.
	if active_modpack != "":
		profile_opt.clear()
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true

	# All profile mutations are disabled while a modpack is active.
	var modpack_locked := active_modpack != ""
	# On Vanilla or a modpack-locked slot the per-row dependency actions would
	# mutate state _save_ui_config will not persist, so they are hidden.
	var profile_editable := _active_profile != VANILLA_PROFILE and not modpack_locked

	var new_profile_btn := Button.new()
	new_profile_btn.text = "+"
	new_profile_btn.tooltip_text = "Create a new profile" if not modpack_locked else "Unload the active modpack first"
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

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# Launcher zoom, user-owned; never DPI-derived (see show_mod_ui).
	var scale_lbl := Label.new()
	scale_lbl.text = "UI scale"
	scale_lbl.add_theme_font_size_override("font_size", FS_BODY)
	scale_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	toolbar.add_child(scale_lbl)

	var scale_values := [1.0, 1.25, 1.5, 1.75, 2.0]
	var scale_opt := OptionButton.new()
	for sv: float in scale_values:
		scale_opt.add_item("%d%%" % int(round(sv * 100.0)))
	var cur_scale_idx := scale_values.find(_ui_scale_setting())
	scale_opt.select(cur_scale_idx if cur_scale_idx >= 0 else 0)
	scale_opt.custom_minimum_size.y = CTRL_H
	scale_opt.add_theme_font_size_override("font_size", FS_BODY)
	toolbar.add_child(scale_opt)
	_wire_hint(scale_opt, "Scale the launcher window. Applies immediately.")

	scale_opt.item_selected.connect(func(idx: int):
		var sv: float = scale_values[idx] if idx >= 0 and idx < scale_values.size() else 1.0
		# Written straight through: a display preference must not rewrite profile state.
		var scfg := _load_ui_cfg_for_write()
		if scfg != null:
			scfg.set_value("settings", "ui_scale", sv)
			_persist_ui_cfg(scfg)
		# Apply even if the save was refused.
		_apply_ui_scale(_ui_window, sv)
	)

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
		# Persist now: the post-boot reopen path has no closing save.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: sticky filter bar + mod list -----------------------------------
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)

	# Filter bar. All/None respect the active filter, toggling only the visible subset.
	var filter_bar := HBoxContainer.new()
	filter_bar.add_theme_constant_override("separation", SP_M)
	left_col.add_child(filter_bar)

	var filter_edit := LineEdit.new()
	filter_edit.placeholder_text = "Filter mods..."
	filter_edit.text = _mods_filter_text
	filter_edit.custom_minimum_size.y = CTRL_H
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

	# Check Updates populates _mod_updates_state so rows show update badges.
	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	if _mod_updates_check_in_progress:
		check_btn.disabled = true
		check_btn.text = "Checking..."
	filter_bar.add_child(check_btn)
	_wire_hint(check_btn, "Check each mod's site for a newer version. Mods that don't say where they came from are skipped.")
	check_btn.pressed.connect(func():
		if _mod_updates_check_in_progress:
			return
		check_btn.disabled = true
		check_btn.text = "Checking..."
		var summary := await _run_updates_check_for_mods()
		# A mid-check rebuild frees the original button: skip only the button
		# touches; the rebuild and toast must still run.
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		# Errored checks are reported, not counted as up to date.
		var n := int(summary.get("with_updates", 0))
		var ck := int(summary.get("checked", 0))
		var er := int(summary.get("errors", 0))
		var msg := ""
		if ck == 0:
			msg = "No installed mods say where they came from, so there is nothing to check."
		elif er >= ck:
			msg = "Could not check any mods. Check your connection and try again."
		elif n == 0:
			msg = "Everything is up to date. Checked %d mod(s)." % (ck - er)
			if er > 0:
				msg += " %d could not be checked." % er
		else:
			msg = "%d update(s) available." % n
			if er > 0:
				msg += " %d could not be checked." % er
		# Only toast while the launcher exists: with _ui_window null the dialog
		# would parent to the game's root and steal input mid-game.
		if is_instance_valid(_ui_window):
			_show_info_toast(msg)
	)

	# Debounce the filter rebuild: each _rebuild_mods_tab is a full tear-down
	# with disk work, so keystrokes only store text and restart the timer.
	var filter_debounce := Timer.new()
	filter_debounce.one_shot = true
	filter_debounce.wait_time = 0.25
	filter_bar.add_child(filter_debounce)
	filter_debounce.timeout.connect(func():
		# Restore focus after the rebuild so the user can keep typing.
		_mods_filter_focus_pending = true
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		filter_debounce.stop()
		filter_debounce.start()
	)
	all_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		# Bulk None disables content mods too; confirm once for the batch.
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

	# Right padding keeps the load-order SpinBox arrows off the scrollbar.
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
	# Scrollbar always visible so it cannot flip and re-trigger the autowrap oscillation bug.
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	var refresh_order := func():
		# _refresh_dependency_status returns the loader's own pick. Reuse it: this
		# fires per step while a spin arrow is held.
		var pick: Dictionary = _refresh_dependency_status()
		for child in order_list.get_children():
			child.queue_free()
		var loadable: Array = pick["loadable"]
		var enabled_count := int(pick["enabled_count"])
		if enabled_count == 0:
			var lbl := Label.new()
			lbl.text = "No mods enabled"
			lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			order_list.add_child(lbl)
			return
		if loadable.is_empty():
			# Manual line break; never autowrap here (see below).
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_ACCENT,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", FS_EMPH)
			lbl.add_theme_color_override("font_color", COL_TEXT)
			# No autowrap: an autowrap label in a fixed-width ScrollContainer hits a
			# Godot 4.6 layout-oscillation bug (scrollbar appears, width shrinks, re-wrap,
			# repeat) that floods the message queue and crashes.
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Full name shows in the bottom status-line hint.
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			order_list.add_child(lbl)
			_wire_hint(lbl, str(e["mod_name"]))
		if bool(pick["adjusted"]):
			var reorder_lbl := _make_sub_label("reordered for dependencies", COL_TEXT_DIM)
			order_list.add_child(reorder_lbl)
			_wire_hint(reorder_lbl, "A required mod was moved up so it loads before the mod that needs it. Your load-order numbers are unchanged.")
		var blocked_count := enabled_count - loadable.size()
		if blocked_count > 0:
			var blocked_lbl := _make_sub_label("%d blocked by dependencies" % blocked_count, COL_ACCENT)
			order_list.add_child(blocked_lbl)
			_wire_hint(blocked_lbl, "Blocked mods stay checked but don't load. See the orange row warnings for fixes.")

	# -- Updates available: mods with newer versions, from _mod_updates_state --
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
		u_hdr.add_theme_color_override("font_color", COL_ACCENT)
		u_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		u_hdr_row.add_child(u_hdr)
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
			u_name.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_name)

			var u_ver := Label.new()
			u_ver.text = "v%s  ->  v%s" % [str(upd.get("current_version", "?")), str(upd.get("latest_version", "?"))]
			u_ver.add_theme_color_override("font_color", COL_TEXT)
			u_ver.add_theme_font_size_override("font_size", FS_BODY)
			u_ver.custom_minimum_size.x = 160
			# A long prerelease string must not widen the column.
			u_ver.clip_text = true
			u_ver.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_ver.tooltip_text = u_ver.text
			u_ver.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_ver)

			var u_btn := Button.new()
			u_btn.text = "Update"
			upd_row.add_child(u_btn)
			_wire_hint(u_btn, "Download the latest version and replace the installed one.")
			var captured_pk := pk
			var captured_upd := upd
			# Row rebuilt mid-download: render the button inert.
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
				var upd_ref: Dictionary = captured_upd.get("ref", {}) if captured_upd.get("ref") is Dictionary else {}
				# Re-resolve the path live: another surface may have renamed the file.
				var full_path: String = _live_full_path(captured_pk, str(captured_upd.get("full_path", "")))
				var result: Dictionary = await replace_mod_from_ref(full_path, upd_ref)
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
					elif is_instance_valid(tabs):
						# A mid-download rebuild left a replacement button stuck; rebuild now the flag is clear.
						_rebuild_mods_tab(tabs)
					var err_name := str(captured_upd.get("mod_name", "this mod"))
					var err_msg := "Could not download %s. Check your connection and try again." % err_name
					var err_detail := str(result.get("error", ""))
					if err_detail != "" and err_detail != "unknown":
						err_msg += "\n\nDetails: " + err_detail
					if is_instance_valid(_ui_window):
						_show_error_dialog("Update failed", err_msg)
			)
			list.add_child(HSeparator.new())

	# -- Missing from this profile: rows with Remove, and Download when a
	# source is known --
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
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
		remove_all_btn.tooltip_text = "Remove all missing mods from this profile"
		missing_hdr_row.add_child(remove_all_btn)
		_wire_hint(remove_all_btn, "Remove every missing mod from the active profile.")
		remove_all_btn.pressed.connect(func():
			var n := missing_files.size()
			var d := ConfirmationDialog.new()
			d.title = "Remove missing-mod entries"
			d.dialog_text = "Remove %d missing-mod entr%s from \"%s\"?\n\nOnly the active profile is affected -- other profiles still list these mods." % [
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
		# Compute sources once per build, not per row.
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

			# Download button when source info is known; otherwise Remove only.
			var src_v: Variant = missing_sources.get(fn)
			var src_ref: Dictionary = {}
			var src_version: String = ""
			if src_v is Dictionary:
				# Already canonical; _normalize_source_record handled the untrusted JSON.
				# This runs on the pass-1 path, where a crash would block the main menu.
				var src: Dictionary = src_v
				src_ref = _source_host_ref(src)
				src_version = str(src.get("version", ""))
			if _modpack_ref_downloadable(src_ref):
				var src_host := host_display_name(str(src_ref["provider"]))
				var dl_btn := Button.new()
				dl_btn.text = "Download"
				dl_btn.tooltip_text = "Download this mod from " + src_host
				miss_row.add_child(dl_btn)
				_wire_hint(dl_btn, "Download this mod from " + src_host + ".")
				var captured_ref := src_ref
				var captured_version := src_version
				# Reuse _mod_update_in_flight keyed by the stored profile key, or a
				# mid-download rebuild re-enables the button and a second click duplicates.
				var captured_fn := fn
				if _mod_update_in_flight.has(fn):
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
				dl_btn.pressed.connect(func():
					if not is_instance_valid(dl_btn):
						return
					if _mod_update_in_flight.has(captured_fn):
						return
					_mod_update_in_flight[captured_fn] = true
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
					# allow_rename_on_collision: dedup happens at scan time.
					var r: Dictionary = await download_mod_from_ref(captured_ref, captured_version, true)
					_mod_update_in_flight.erase(captured_fn)
					if bool(r.get("ok", false)):
						_reload_entries_for_active_profile()
						if is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
					else:
						if is_instance_valid(dl_btn):
							dl_btn.disabled = false
							dl_btn.text = "Download"
						elif is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
						if is_instance_valid(_ui_window):
							_show_error_dialog("Download failed", str(r.get("error", "Could not download this mod. Check your connection and try again.")))
				)
			else:
				# No source info: name what is unavailable. STOP so the label gets hover signals.
				var no_src_lbl := Label.new()
				no_src_lbl.text = "Download unavailable"
				no_src_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
				no_src_lbl.add_theme_font_size_override("font_size", FS_BODY)
				no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
				miss_row.add_child(no_src_lbl)
				_wire_hint(no_src_lbl,
					"This mod does not say which site it came from, so it can't be downloaded automatically. Reinstall it manually.")

			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Remove this missing mod from this profile"
			miss_row.add_child(remove_btn)
			_wire_hint(remove_btn, "Remove this mod from the active profile.")
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

	# Spacer over the thumbnail column so "Mod" sits above the name text.
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

	# Spacer matching the per-row trash button so the header aligns.
	var h_tail := Control.new()
	h_tail.custom_minimum_size.x = 28
	header_row.add_child(h_tail)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		# No autowrap inside the ScrollContainer (oscillation bug); newlines still break.
		empty.clip_text = true
		empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		empty.tooltip_text = empty.text
		empty.mouse_filter = Control.MOUSE_FILTER_PASS
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(empty)

	var rendered_any := false
	# Hoisted once per build; the fallback rebuilds this map per call.
	var dep_names_by_id := _entries_by_mod_id(_ui_mod_entries)
	var persisted_sources := _get_persisted_mod_sources()
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

		# Host info column: async thumbnail, author line and name click-through to
		# the detail dialog. A link-out host opens the mod page instead. Mods with
		# no host keep the same-width cell so the name column stays aligned.
		var row_ref := _entry_host_ref(entry, persisted_sources)
		var row_key := host_ref_key(row_ref)
		var row_browsable := row_key != "" and bool(host_caps(str(row_ref["provider"]))["browse"])
		var row_page_url := host_mod_page_url(row_ref) if row_key != "" else ""
		var meta_holder: Dictionary = {}
		var thumb_ref: TextureRect = null
		# Every row gets a thumbnail cell captioned "no thumbnail"; a texture clears it.
		var thumb_rect := _make_thumb_cell(row, Vector2(96, 54), true, true)
		if row_browsable:
			thumb_ref = thumb_rect

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_col)

		# name_ctrl: clickable for hosted mods, plain Label otherwise.
		var name_ctrl: Control
		if row_browsable or row_page_url != "":
			# Flat Button, not LinkButton, so clip_text keeps a long name from widening the row.
			var name_lnk := Button.new()
			name_lnk.flat = true
			name_lnk.text = entry["mod_name"]
			name_lnk.clip_text = true
			name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
			name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var row_host := host_display_name(str(row_ref["provider"]))
			name_lnk.tooltip_text = str(entry["mod_name"]) + ("  --  click for " + row_host + " details" if row_browsable \
					else "  --  click to open the " + row_host + " page in your browser")
			name_lnk.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
			name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
			name_col.add_child(name_lnk)
			if row_browsable:
				name_lnk.pressed.connect(_open_mods_host_detail.bind(meta_holder, row_ref))
				# Register the row's live nodes before the meta load so paints resolve to
				# current nodes. Appended: several rows can share one host mod.
				var meta_rows: Array = _mods_meta_nodes.get(row_key, [])
				meta_rows.append({
					"thumb": thumb_ref,
					"name_col": name_col,
					"holder": meta_holder,
				})
				_mods_meta_nodes[row_key] = meta_rows
				_mods_load_host_meta(row_ref)
			else:
				var captured_page := row_page_url
				name_lnk.pressed.connect(func():
					OS.shell_open(captured_page)
				)
			name_ctrl = name_lnk
		else:
			var name_lbl := Label.new()
			name_lbl.text = entry["mod_name"]
			name_lbl.clip_text = true
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lbl.tooltip_text = str(entry["mod_name"])
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
		# Dependencies: one clipped line; the actionable blocked row renders below.
		var required_deps: Array = entry.get("required_dependencies", [])
		var optional_deps: Array = entry.get("optional_dependencies", [])
		var blockers_info: Array = entry.get("dependency_blockers_info", [])
		var dep_ignored := bool(entry.get("dependency_ignored", false))
		var dep_blocked: bool = entry["enabled"] \
				and not (entry.get("dependency_blockers", []) as Array).is_empty()
		if dep_blocked:
			# The green "enabled" tint would lie. This mod won't load.
			name_ctrl.add_theme_color_override("font_color", COL_ACCENT)
		if required_deps.size() > 0 or optional_deps.size() > 0:
			var named := PackedStringArray()
			for d in required_deps:
				named.append(_dependency_display_for_id(str(d), dep_names_by_id))
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
				tip.append("requires %s (%s)" % [_dependency_display_for_id(str(d), dep_names_by_id), str(d)])
			for d in optional_deps:
				tip.append("optional: %s (%s)" % [_dependency_display_for_id(str(d), dep_names_by_id), str(d)])
			name_col.add_child(_make_sub_label(dep_line, COL_TEXT_DIM, "\n".join(tip)))
		for warn_text: String in entry.get("warnings", []):
			name_col.add_child(_make_sub_label(warn_text, COL_ACCENT, warn_text))
		for warn_text: String in entry.get("dependency_warnings", []):
			name_col.add_child(_make_sub_label(warn_text, COL_ACCENT, warn_text))

		# Blocked: one orange line naming the cause plus buttons that fix it.
		if dep_blocked and not blockers_info.is_empty():
			var block_row := HBoxContainer.new()
			block_row.add_theme_constant_override("separation", SP_M)
			name_col.add_child(block_row)
			var first: Dictionary = blockers_info[0]
			# display already reads "Name (id)"; a dash avoids a second paren.
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
			var bl := _make_sub_label("won't load -- needs " + why, COL_ACCENT, "\n".join(btip))
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
			# Override active while requirements are unmet: show what is ignored and the way back.
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

		# Older same-id archives the dedup pass hid; name the file to delete.
		for dup: Dictionary in entry.get("duplicates_hidden", []):
			var dup_v_raw: String = str(dup.get("version", ""))
			var dup_v: String = ("v" + dup_v_raw) if dup_v_raw != "" else "(unversioned)"
			var hide_text := "older version hidden: " + str(dup["file_name"]) + " (" + dup_v + ")"
			name_col.add_child(_make_sub_label(hide_text, COL_ACCENT, hide_text))

		# The profile was saved with another version of this mod; show that the
		# enabled/priority state was carried over rather than re-defaulted.
		var vm: Dictionary = entry.get("profile_version_mismatch", {})
		if not vm.is_empty():
			var stored_v: String = str(vm.get("stored", ""))
			var current_v: String = str(vm.get("current", ""))
			var stored_disp := stored_v if stored_v != "" else "(unset)"
			var current_disp := current_v if current_v != "" else "(unset)"
			var vm_text := "version changed: " + stored_disp + " -> " + current_disp
			name_col.add_child(_make_sub_label(vm_text, COL_ACCENT, vm_text))

		# Scanner indicator, red risk only: pattern combinations that are close
		# to diagnostic of malware. Elevated-API findings are logged but not
		# shown; most legitimate mods have one. Loading is never blocked.
		var risk: int = int(entry.get("risk_level", 0))
		if risk == 2:
			var sec_btn := Button.new()
			sec_btn.text = "suspicious code"
			sec_btn.flat = true
			sec_btn.tooltip_text = "Show what the scanner flagged in this mod"
			sec_btn.add_theme_color_override("font_color", COL_ERR)
			# Flat buttons have no hover stylebox; the font shift is the hover cue.
			sec_btn.add_theme_color_override("font_hover_color", COL_ERR.lerp(COL_TEXT_HI, 0.35))
			sec_btn.add_theme_font_size_override("font_size", FS_BODY)
			sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(sec_btn)
			var captured_entry := entry
			sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))
		elif _entry_has_unscannable_code(entry):
			# Not a risk verdict: the scanner could not read this mod's compiled
			# bytecode, and no badge would read as "checked, nothing found". Dim, not
			# red: shipping compiled code is not an accusation.
			var unscanned_btn := Button.new()
			unscanned_btn.text = "not scanned"
			unscanned_btn.flat = true
			unscanned_btn.tooltip_text = "This mod ships compiled code the scanner cannot read. Nothing was checked."
			unscanned_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
			unscanned_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)
			unscanned_btn.add_theme_font_size_override("font_size", FS_BODY)
			unscanned_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			unscanned_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(unscanned_btn)
			var captured_unscanned := entry
			unscanned_btn.pressed.connect(func(): _show_security_findings_dialog(captured_unscanned))

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		spin.custom_minimum_size.y = CTRL_H
		row.add_child(spin)

		# Per-row Remove. Folder mods skip the file delete: recursive deletion of a
		# working directory is too risky to do casually.
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
			# Disabling a mod that registers game content can stop an existing save
			# from loading; confirm first, and revert the checkbox on cancel.
			if not on and bool(e.get("has_registry", false)):
				var ok: bool = await _confirm_disable_content_mod(str(e.get("mod_name", "this mod")))
				if not ok:
					# An async rebuild may have freed this checkbox while the dialog was open.
					if is_instance_valid(check):
						check.set_pressed_no_signal(true)
					return
			# Write to the live entry: a mid-dialog rescan replaces _ui_mod_entries
			# with fresh dicts, and a confirmed disable must not be dropped.
			var live := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
			live["enabled"] = on
			# Full rebuild: dependency state on other rows changes with the enabled set.
			_after_dep_action(tabs)
		)
		spin.value_changed.connect(func(val: float):
			# Write through the live entry: a mid-drag rescan orphans the captured `e`.
			var live_spin := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
			live_spin["priority"] = int(val)
			# No rebuild here: value_changed fires per step while the arrows are held
			# and a rebuild would destroy the SpinBox under the cursor.
			refresh_order.call()
			# Debounce the disk save: a held arrow fires value_changed per step and
			# each _save_ui_config is a full ConfigFile load and rewrite.
			_schedule_priority_save()
		)

	# The filter narrowed every row out; say so, distinct from no mods installed.
	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match. Try a shorter search or turn off Hide disabled."
		no_match.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_match.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(no_match)

	# Restore focus to the search input after a filter-driven rebuild, deferred
	# so the new tab is in the tree. Cleared on consume so other rebuilds do not steal focus.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text resets the caret to column 0 and FOCUS_ENTER does
		# not move it; restore the caret to end-of-text after focus lands.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	# Wrap in the shared tab margin so the view does not shift between tabs.
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin

# ----- Browse: source-neutral helpers ---------------------------------------

# Installed mods keyed by host_ref_key. Last wins on duplicates.
func _browse_install_map() -> Dictionary:
	var out: Dictionary = {}
	var persisted: Dictionary = _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var key := host_ref_key(_entry_host_ref(entry, persisted))
		if key != "":
			out[key] = entry
	return out


# Counter off a ModSummary that may have been through a JSON round trip (ints come back as floats).
func _browse_metric(row: Dictionary, key: String) -> int:
	var v: Variant = row.get(key, -1)
	if v is int:
		return v
	if v is float:
		return int(v)
	return -1


# Offline grace for the Browse landing, per host: the last fully populated
# landing, in memory and on disk, so a first launch offline still shows
# something. Lives under user://mws_cache/, deny-listed for pack overrides.
var _browse_landing_snapshots: Dictionary = {}
const _BROWSE_LANDING_CACHE_DIR := "user://mws_cache"

func _browse_landing_snapshot_path(provider: String) -> String:
	return _BROWSE_LANDING_CACHE_DIR.path_join("landing_" + provider.validate_filename() + ".json")

func _browse_landing_snapshot_store(provider: String, sections: Array) -> void:
	# A landing served from the list cache is not a refresh; do not restamp it.
	var prev_v: Variant = _browse_landing_snapshots.get(provider)
	if prev_v is Dictionary and JSON.stringify((prev_v as Dictionary).get("sections")) == JSON.stringify(sections):
		return
	var snap := {"sections": sections, "saved_at_unix": int(Time.get_unix_time_from_system())}
	_browse_landing_snapshots[provider] = snap
	DirAccess.make_dir_recursive_absolute(_BROWSE_LANDING_CACHE_DIR)
	var path := _browse_landing_snapshot_path(provider)
	# Write-then-rename so a crash mid-write cannot truncate the live copy.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var wrote := f.store_string(JSON.stringify(snap))
	var werr := f.get_error()
	f.close()
	if not wrote or werr != OK:
		DirAccess.remove_absolute(tmp)
		return
	DirAccess.rename_absolute(tmp, path)

func _browse_landing_snapshot(provider: String) -> Dictionary:
	if _browse_landing_snapshots.has(provider):
		return _browse_landing_snapshots[provider]
	var path := _browse_landing_snapshot_path(provider)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var snap: Dictionary = parsed
	if not (snap.get("sections") is Array):
		return {}
	var saved_v: Variant = snap.get("saved_at_unix", 0)
	if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
		return {}
	# A row from an older build that lacks a field is dropped, not crashed on.
	var sections: Array = []
	for sec_v in (snap["sections"] as Array):
		if not (sec_v is Dictionary):
			continue
		var sec: Dictionary = sec_v
		var rows_v: Variant = sec.get("rows")
		if not (rows_v is Array):
			continue
		var rows: Array = []
		for row_v in (rows_v as Array):
			if row_v is Dictionary and _mods_meta_record_complete(row_v):
				rows.append(row_v)
		sections.append({"title": str(sec.get("title", "")), "rows": rows})
	snap["sections"] = sections
	_browse_landing_snapshots[provider] = snap
	return snap


func build_browse_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Shared mutable state: lambdas capture locals by value, so the closures
	# below read and write through this Dictionary. Per-host view records live
	# under "views", so a sort or category chosen on one host cannot leak.
	var providers: PackedStringArray = host_browse_providers()
	# Open on the source used last time; the first browsable host otherwise.
	var initial_provider := providers[0] if providers.size() > 0 else HOST_MODWORKSHOP
	var remembered := str(_get_ui_cfg_value("settings", "browse_source", ""))
	if providers.has(remembered):
		initial_provider = remembered
	var state := {
		"provider": initial_provider,
		"views": {},
		# Monotonic per fetch; a completion whose seq is stale must not render.
		"fetch_seq": 0,
		# host_ref_key of the download in flight; downloads run one at a time.
		"downloading_key": "",
		"download_queue": [],
		"queue_failures": [],
		"queue_done_total": 0,
		"queue_any_success": false,
	}

	var make_view := func(provider: String) -> Dictionary:
		var sorts: Array = host_sorts(provider)
		var first: Dictionary = sorts[0] if not sorts.is_empty() else {}
		var has_sections := not host_sections(provider).is_empty()
		return {
			"mode": "discover" if has_sections else "filter",
			"query": "",
			"sort_key": str(first.get("key", "")),
			"sort_field": str(first.get("row_field", "")),
			"sort_label": str(first.get("label", "")),
			# true while the sort menu rests on the curated landing item.
			"featured": has_sections,
			"category_ref": "",
			"category_name": "",
			"cursor": "",
			"has_more": false,
			"loaded_rows": [],
			"shown_count": 0,
			"categories_loaded": false,
			"categories_loading": false,
		}
	var view := func() -> Dictionary:
		var p := str(state["provider"])
		var views: Dictionary = state["views"]
		if not views.has(p):
			views[p] = make_view.call(p)
		return views[p]

	# -- Toolbar: source, search, sort, category --
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	# The source switcher scopes everything to its right. Built from
	# host_browse_providers(): a link-out host must not appear in a listing control.
	var provider_dropdown := OptionButton.new()
	for p in providers:
		provider_dropdown.add_item(host_display_name(p))
		provider_dropdown.set_item_metadata(provider_dropdown.item_count - 1, p)
		if p == initial_provider:
			provider_dropdown.select(provider_dropdown.item_count - 1)
	provider_dropdown.visible = providers.size() > 1
	provider_dropdown.custom_minimum_size.y = CTRL_H
	toolbar.add_child(provider_dropdown)
	_wire_hint(provider_dropdown, "Which mod site to browse.")

	var search_input := LineEdit.new()
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size.x = 200
	search_input.custom_minimum_size.y = CTRL_H
	toolbar.add_child(search_input)

	var sort_dropdown := OptionButton.new()
	toolbar.add_child(sort_dropdown)

	var category_dropdown := OptionButton.new()
	category_dropdown.add_item("All categories")
	category_dropdown.set_item_metadata(0, "")
	toolbar.add_child(category_dropdown)

	# OptionButton popups are sub-Windows: raise them above the always_on_top
	# launcher and set the theme explicitly. Unfolded because iterating an Array
	# literal makes the loop variable untyped and get_popup() fails inference.
	var provider_popup := provider_dropdown.get_popup()
	provider_popup.always_on_top = true
	provider_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		provider_popup.theme = _ui_window.theme

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

	# Controls are built once; switching hosts toggles visibility and repopulates
	# items. Capabilities that are off hide their control rather than disable it.
	var apply_provider_controls := func(provider: String):
		var caps: Dictionary = host_caps(provider)
		var v: Dictionary = view.call()
		search_input.visible = bool(caps["search"])
		search_input.max_length = host_limit(provider, "query_max_len", 150)
		search_input.placeholder_text = "Search " + host_display_name(provider) + "..."
		search_input.text = str(v["query"])
		sort_dropdown.clear()
		var has_sections := not host_sections(provider).is_empty()
		if has_sections:
			# Item 0 is the curated landing, not a sort; its metadata key is "".
			sort_dropdown.add_item("Featured")
			sort_dropdown.set_item_metadata(0, {"key": "", "row_field": "", "label": ""})
		for opt_v in host_sorts(provider):
			var opt: Dictionary = opt_v
			sort_dropdown.add_item(str(opt.get("label", "")))
			sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, opt)
		sort_dropdown.visible = sort_dropdown.item_count > 0
		var sel := 0
		if not bool(v["featured"]):
			for i in sort_dropdown.item_count:
				var md: Variant = sort_dropdown.get_item_metadata(i)
				if md is Dictionary and str((md as Dictionary).get("key", "")) != "" \
						and str((md as Dictionary).get("key", "")) == str(v["sort_key"]):
					sel = i
					break
		if sort_dropdown.item_count > 0:
			sort_dropdown.select(sel)
		category_dropdown.clear()
		category_dropdown.add_item("All categories")
		category_dropdown.set_item_metadata(0, "")
		category_dropdown.visible = bool(caps["categories"])

	container.add_child(HSeparator.new())

	# Offline-grace banner slot, a sibling above the list so it never covers rows.
	var banner_slot := VBoxContainer.new()
	banner_slot.visible = false
	container.add_child(banner_slot)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", FS_BODY)
	status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(status_lbl)

	# Every Browse state change routes through here so color matches message.
	var set_status := func(text: String, color: Color):
		if not is_instance_valid(status_lbl):
			return
		status_lbl.text = text
		status_lbl.add_theme_color_override("font_color", color)

	# Mirror of set_status for downloads started from the detail dialog, which
	# covers the tab's status label (meta "browse_dialog_status" on the button).
	var set_dl_status := func(get_btn: Variant, text: String, color: Color):
		if not is_instance_valid(get_btn):
			return
		var btn := get_btn as Button
		if btn == null or not btn.has_meta("browse_dialog_status"):
			return
		var lbl_v: Variant = btn.get_meta("browse_dialog_status")
		if is_instance_valid(lbl_v) and lbl_v is Label:
			var lbl := lbl_v as Label
			lbl.visible = true
			lbl.text = text
			lbl.tooltip_text = text
			lbl.add_theme_color_override("font_color", color)

	var cooldown_seconds := func(provider: String) -> int:
		return host_rate_cooldown_seconds(provider)

	# Failure reason for the banner: the cooldown owns the copy while armed.
	var browse_fail_reason := func() -> String:
		var p := str(state["provider"])
		var secs: int = cooldown_seconds.call(p)
		if secs > 0:
			return "%s rate limit reached. Try again in %ds." % [host_display_name(p), secs]
		return host_display_name(p) + " is unreachable."

	var clear_browse_banner := func():
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		banner_slot.visible = false

	# Banner with a Retry action. Retry goes through `state` because this lambda
	# is created before the fetch lambdas are assigned.
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
			(state["fn_populate_categories"] as Callable).call()
			(state["fn_route"] as Callable).call()
		)
		banner_slot.add_child(banner["panel"])
		banner_slot.visible = true

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	# Right margin clears the overlay scrollbar, which would hide each row's right edge.
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

	# Empty the list the moment the view changes, or the previous host's rows
	# sit under a toolbar that says otherwise until the fetch renders. Search
	# text is the exception: results stay while typing.
	var clear_list_now := func(label: String):
		if not is_instance_valid(list):
			return
		for child in list.get_children():
			child.queue_free()
		load_more_btn.visible = false
		set_status.call(label, COL_TEXT_DIM)

	# Enable/disable toggle from a Browse row; mutates the live entry, saves, rebuilds Mods.
	var on_toggle := func(ref_key: String, enabled: bool, check: CheckBox):
		var entry_v: Variant = _browse_install_map().get(ref_key)
		if not (entry_v is Dictionary):
			return
		var entry: Dictionary = entry_v
		# Content mods need the save-compatibility confirm; revert the box on cancel.
		var live_entry: Dictionary = entry
		if not enabled and bool(entry.get("has_registry", false)):
			var ok: bool = await _confirm_disable_content_mod(str(entry.get("mod_name", "this mod")))
			if not ok:
				if is_instance_valid(check):
					check.set_pressed_no_signal(true)
				return
			# A rescan during the dialog replaces _ui_mod_entries; write to the live entry.
			live_entry = _live_entry_for_profile_key(str(entry.get("profile_key", "")), entry)
		live_entry["enabled"] = enabled
		_save_ui_config()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		set_status.call(("Enabled " if enabled else "Disabled ") + str(live_entry.get("mod_name", "?")) + " in profile " + _active_profile, COL_TEXT_DIM)

	var perform_download_for_item: Callable
	perform_download_for_item = func(item: Dictionary):
		var mod_data: Dictionary = item["mod_data"]
		var get_btn = item.get("get_btn")
		var ref: Dictionary = mod_data["ref"]
		var provider := str(ref["provider"])
		var host := host_display_name(provider)
		var key := host_ref_key(ref)
		state["downloading_key"] = key
		if is_instance_valid(get_btn):
			get_btn.disabled = true
			get_btn.text = "Downloading..."
		var queue: Array = state["download_queue"]
		var qsuffix := (" (" + str(queue.size()) + " queued)") if not queue.is_empty() else ""
		set_status.call("Downloading " + str(mod_data["name"]) + qsuffix + "...", COL_ACCENT)
		set_dl_status.call(get_btn, "Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)

		# Rate-limit pause: once a 429 arms the cooldown every queued item would
		# fail fast. Wait it out with a countdown; bail if the launcher closes.
		var rate_waited := false
		while int(cooldown_seconds.call(provider)) > 0:
			rate_waited = true
			if not is_instance_valid(status_lbl) or get_tree() == null:
				state["downloading_key"] = ""
				return
			var wait_s: int = cooldown_seconds.call(provider)
			set_status.call("Rate limited by %s -- resuming in %ds" % [host, wait_s], COL_ACCENT)
			set_dl_status.call(get_btn, "Rate limited by %s -- resuming in %ds" % [host, wait_s], COL_ACCENT)
			await get_tree().create_timer(1.0).timeout
		if rate_waited and is_instance_valid(status_lbl):
			set_status.call("Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)
			set_dl_status.call(get_btn, "Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)

		var result: Dictionary = await download_mod_from_ref(ref)
		state["downloading_key"] = ""

		# The launcher can close during a download; the file is on disk, so stop touching nodes.
		if not is_instance_valid(status_lbl):
			return

		state["queue_done_total"] = int(state.get("queue_done_total", 0)) + 1

		if bool(result.get("ok", false)):
			state["queue_any_success"] = true
			if is_instance_valid(get_btn):
				get_btn.text = "Installed"
				get_btn.disabled = true
			set_status.call("Installed " + str(result.get("file_name", "")), COL_OK)
			set_dl_status.call(get_btn, "Installed " + str(result.get("file_name", "")), COL_OK)
		else:
			if is_instance_valid(get_btn):
				get_btn.disabled = false
				get_btn.text = "Download"
			var err_detail := str(result.get("error", "")).strip_edges()
			if err_detail.is_empty():
				err_detail = "Check your connection and try again."
			var fail_line := "Could not download " + str(mod_data["name"]) + ". " + err_detail
			set_status.call(fail_line, COL_ERR)
			set_dl_status.call(get_btn, fail_line, COL_ERR)
			# The status line is overwritten as the queue drains; the batch summary is the report.
			(state["queue_failures"] as Array).append(str(mod_data["name"]) + " (" + err_detail + ")")

		# Drain the queue before re-rendering, which frees the queued button refs.
		var remaining: Array = state["download_queue"]
		if not remaining.is_empty():
			var next_item: Dictionary = remaining.pop_front()
			(state["fn_perform_download"] as Callable).call(next_item)
			return

		var any_success := bool(state.get("queue_any_success", false))
		var failures: Array = state["queue_failures"]
		var batch_total := int(state.get("queue_done_total", 0))
		state["queue_any_success"] = false
		state["queue_failures"] = []
		state["queue_done_total"] = 0

		# One rescan + Mods-tab rebuild for the whole batch.
		if any_success:
			_reload_entries_for_active_profile()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)

		if failures.is_empty():
			if any_success:
				# Re-render so duplicate rows flip to Installed, keeping the scroll position.
				if is_instance_valid(scroll):
					state["restore_scroll"] = int(scroll.scroll_vertical)
				(state["fn_route"] as Callable).call()
			return

		# At least one failure: keep the report on screen, sync rows in place.
		if any_success and is_instance_valid(scroll):
			_refresh_browse_installed_rows(scroll)
		if batch_total > 1:
			var fail_strs := PackedStringArray()
			for f_v in failures:
				fail_strs.append(str(f_v))
			set_status.call("%d of %d downloads failed: %s" % [failures.size(), batch_total, ", ".join(fail_strs)], COL_ERR)

	var on_get: Callable
	on_get = func(mod_data: Dictionary, get_btn: Button):
		var key := host_ref_key(mod_data["ref"])
		if str(state["downloading_key"]) != "":
			if str(state["downloading_key"]) == key:
				set_status.call("Already downloading this mod", COL_TEXT_DIM)
				set_dl_status.call(get_btn, "Already downloading this mod", COL_TEXT_DIM)
				return
			var queue: Array = state["download_queue"]
			for q_v in queue:
				var q_data: Dictionary = (q_v as Dictionary).get("mod_data", {})
				if q_data.has("ref") and host_ref_key(q_data["ref"]) == key:
					set_status.call("Already queued", COL_TEXT_DIM)
					set_dl_status.call(get_btn, "Already queued", COL_TEXT_DIM)
					return
			queue.append({"mod_data": mod_data, "get_btn": get_btn})
			if is_instance_valid(get_btn):
				get_btn.disabled = true
				get_btn.text = "Queued"
			var queued_line := "Queued " + str(mod_data["name"]) + " (" + str(queue.size()) + " in queue)"
			set_status.call(queued_line, COL_TEXT_DIM)
			set_dl_status.call(get_btn, queued_line, COL_TEXT_DIM)
			return
		perform_download_for_item.call({"mod_data": mod_data, "get_btn": get_btn})

	# Empty-state copy points at the other source so a thin catalog does not read as broken.
	var empty_copy := func() -> String:
		var v: Dictionary = view.call()
		if str(v["query"]) != "" or str(v["category_ref"]) != "":
			return "No results. Try a different search or category."
		var p := str(state["provider"])
		if providers.size() > 1:
			var other := ""
			for q in providers:
				if q != p:
					other = host_display_name(q)
					break
			return "No mods on %s yet. Pick %s in the source menu to browse there." % [host_display_name(p), other]
		return "No mods on " + host_display_name(p) + " yet."

	var render_mod_rows := func(rows: Array, append: bool):
		var v: Dictionary = view.call()
		if not append:
			for child in list.get_children():
				child.queue_free()
			var hdr := Label.new()
			# Every filtered list is sorted by sort_key; the header names that sort.
			var sort_label := str(v["sort_label"]) if sort_dropdown.visible else ""
			hdr.text = _browse_results_header_text(str(v["query"]), sort_label, str(v["category_name"]))
			hdr.add_theme_font_size_override("font_size", FS_HEAD)
			hdr.add_theme_color_override("font_color", COL_TEXT)
			hdr.clip_text = true
			hdr.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			hdr.tooltip_text = hdr.text
			hdr.mouse_filter = Control.MOUSE_FILTER_PASS
			list.add_child(hdr)
			list.add_child(HSeparator.new())
		var install_map: Dictionary = _browse_install_map()
		for row_v in rows:
			if not (row_v is Dictionary):
				continue
			var row: Dictionary = row_v
			list.add_child(_browse_render_mod_row(row, install_map.get(host_ref_key(row["ref"])), on_get, on_toggle))
			list.add_child(HSeparator.new())

	var do_discover_fetch: Callable
	var do_filter_fetch: Callable

	# The curated landing: one list query per section the host declares.
	# Hosts without sections never come here.
	do_discover_fetch = func():
		var provider := str(state["provider"])
		var v: Dictionary = view.call()
		var sections: Array = host_sections(provider)
		if sections.is_empty():
			(state["fn_filter_fetch"] as Callable).call(false)
			return
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		v["mode"] = "discover"
		v["featured"] = true
		if sort_dropdown.visible and sort_dropdown.selected != 0:
			sort_dropdown.select(0)
		v["cursor"] = ""
		v["has_more"] = false
		v["loaded_rows"] = []
		load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading...", COL_TEXT_DIM)

		var results: Array = []
		var ok_count := 0
		for sec_v in sections:
			var sec: Dictionary = sec_v
			var limit := int(sec.get("limit", 10))
			var res := await host_list_mods(provider, {"sort_key": str(sec.get("sort_key", "")), "cursor": "", "limit": limit})
			if int(state["fetch_seq"]) != my_seq:
				return
			if not res["ok"]:
				continue
			ok_count += 1
			var rows: Array = (res["data"] as Dictionary)["rows"]
			if limit > 0 and rows.size() > limit:
				rows = rows.slice(0, limit)
			results.append({"title": str(sec.get("title", "")), "rows": rows})
		if not is_instance_valid(status_lbl):
			return

		var cached_at := 0
		if ok_count == 0:
			var snap := _browse_landing_snapshot(provider)
			if snap.is_empty():
				set_status.call(host_display_name(provider) + ": could not load mods. Check your connection and try again.", COL_ERR)
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
				return
			results = snap["sections"]
			cached_at = int(snap["saved_at_unix"])
		elif ok_count == sections.size():
			# Only a complete landing is worth remembering.
			_browse_landing_snapshot_store(provider, results)

		for child in list.get_children():
			child.queue_free()
		var install_map: Dictionary = _browse_install_map()
		var total := 0
		var first_section := true
		for sec_v in results:
			var sec: Dictionary = sec_v
			var rows: Array = sec.get("rows", [])
			if rows.is_empty():
				continue
			if not first_section:
				var spacer := Control.new()
				spacer.custom_minimum_size.y = SP_M
				list.add_child(spacer)
			first_section = false
			var hdr := Label.new()
			hdr.text = str(sec.get("title", ""))
			hdr.add_theme_font_size_override("font_size", FS_HEAD)
			hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(hdr)
			list.add_child(HSeparator.new())
			for row_v in rows:
				if not (row_v is Dictionary):
					continue
				var row: Dictionary = row_v
				list.add_child(_browse_render_mod_row(row, install_map.get(host_ref_key(row["ref"])), on_get, on_toggle))
				list.add_child(HSeparator.new())
				total += 1
		if cached_at > 0:
			show_browse_banner.call("Showing cached results. " + str(browse_fail_reason.call()), cached_at, COL_ACCENT)
		else:
			clear_browse_banner.call()
			# A live fetch proves connectivity: recover a category menu that failed to populate.
			(state["fn_populate_categories"] as Callable).call()
		if total == 0:
			set_status.call(empty_copy.call(), COL_TEXT_DIM)
		else:
			set_status.call("%d mods" % total, COL_TEXT_DIM)
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	do_filter_fetch = func(append: bool):
		var provider := str(state["provider"])
		var caps: Dictionary = host_caps(provider)
		var v: Dictionary = view.call()
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		v["mode"] = "filter"
		var cursor := str(v["cursor"]) if append else ""
		if not append:
			v["cursor"] = ""
			v["has_more"] = false
			load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading..." if not append else "Loading more...", COL_TEXT_DIM)

		var res := await host_list_mods(provider, {
			"query": str(v["query"]),
			"sort_key": str(v["sort_key"]),
			"category_ref": str(v["category_ref"]),
			"cursor": cursor,
		})
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		if not res["ok"]:
			set_status.call(host_error_message(provider, res), COL_ERR)
			# Only the landing has an offline snapshot; a failed search gets the Retry
			# banner. Append failures keep the rendered pages; Load more is the retry.
			if not append:
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
			load_more_btn.disabled = not bool(v["has_more"])
			return
		var page: Dictionary = res["data"]
		var rows: Array = page["rows"]
		# Accumulate every page so the sort runs on the full set; dedup by ref.
		if append:
			var acc: Array = v["loaded_rows"]
			var seen := {}
			for r in acc:
				seen[host_ref_key((r as Dictionary)["ref"])] = true
			for r in rows:
				if not seen.has(host_ref_key((r as Dictionary)["ref"])):
					acc.append(r)
			rows = acc
		v["loaded_rows"] = rows
		# Some hosts ignore `sort` with a query; re-sort client-side on the adapter's field.
		if bool(caps["sort_ignored_with_query"]) and str(v["query"]) != "" and str(v["sort_field"]) != "":
			var field := str(v["sort_field"])
			rows.sort_custom(func(a, b):
				var av: Variant = (a as Dictionary).get(field)
				var bv: Variant = (b as Dictionary).get(field)
				if (av is int or av is float) and (bv is int or bv is float):
					return int(av) > int(bv)
				return str(av) > str(bv)
			)
		v["cursor"] = str(page["next_cursor"])
		v["has_more"] = bool(page["has_more"])
		clear_browse_banner.call()
		(state["fn_populate_categories"] as Callable).call()
		if append and my_restore < 0 and is_instance_valid(scroll):
			my_restore = int(scroll.scroll_vertical)
		render_mod_rows.call(rows, false)
		# Count from the data: queue_free() is deferred, so freed rows still count this frame.
		v["shown_count"] = rows.size()
		var total := int(page["total"])
		if rows.is_empty():
			set_status.call(empty_copy.call(), COL_TEXT_DIM)
		elif bool(caps["total_count"]) and total >= 0:
			set_status.call("%d of %d mods" % [rows.size(), total], COL_TEXT_DIM)
		else:
			set_status.call("%d mods" % rows.size(), COL_TEXT_DIM)
		load_more_btn.visible = bool(v["has_more"])
		load_more_btn.disabled = not bool(v["has_more"])
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	# One definition of "show the landing or the listing?" for every handler.
	var wants_discover := func() -> bool:
		var v: Dictionary = view.call()
		return str(v["query"]) == "" and str(v["category_ref"]) == "" and bool(v["featured"]) \
				and not host_sections(str(state["provider"])).is_empty()
	var route := func():
		if wants_discover.call():
			(state["fn_discover_fetch"] as Callable).call()
		else:
			(state["fn_filter_fetch"] as Callable).call(false)

	# Debounce: text_changed fires per keystroke; only the timeout queries.
	var search_debounce := Timer.new()
	search_debounce.one_shot = true
	search_debounce.wait_time = 0.3
	container.add_child(search_debounce)
	search_debounce.timeout.connect(func():
		route.call()
	)
	search_input.text_changed.connect(func(new_text: String):
		var v: Dictionary = view.call()
		v["query"] = new_text.strip_edges()
		search_debounce.stop()
		search_debounce.start()
	)
	search_input.text_submitted.connect(func(_t: String):
		search_debounce.stop()
		route.call()
	)

	sort_dropdown.item_selected.connect(func(idx: int):
		var v: Dictionary = view.call()
		var md: Variant = sort_dropdown.get_item_metadata(idx)
		var opt: Dictionary = md if md is Dictionary else {}
		var key := str(opt.get("key", ""))
		v["featured"] = key == ""
		if key != "":
			v["sort_key"] = key
			v["sort_field"] = str(opt.get("row_field", ""))
			v["sort_label"] = str(opt.get("label", ""))
		else:
			# Back on Featured, a typed query sorts by the host's first sort.
			var sorts: Array = host_sorts(str(state["provider"]))
			var first: Dictionary = sorts[0] if not sorts.is_empty() else {}
			v["sort_key"] = str(first.get("key", ""))
			v["sort_field"] = str(first.get("row_field", ""))
			v["sort_label"] = str(first.get("label", ""))
		clear_list_now.call("Loading...")
		route.call()
	)

	category_dropdown.item_selected.connect(func(idx: int):
		var v: Dictionary = view.call()
		var md: Variant = category_dropdown.get_item_metadata(idx)
		v["category_ref"] = str(md) if md != null else ""
		v["category_name"] = category_dropdown.get_item_text(idx) if idx > 0 else ""
		clear_list_now.call("Loading...")
		route.call()
	)

	provider_dropdown.item_selected.connect(func(idx: int):
		var p := str(provider_dropdown.get_item_metadata(idx))
		if p == str(state["provider"]):
			return
		state["provider"] = p
		_set_ui_cfg_value("settings", "browse_source", p)
		var v: Dictionary = view.call()
		# Categories are per host and the menu was just cleared; refetch.
		v["categories_loaded"] = false
		apply_provider_controls.call(p)
		clear_browse_banner.call()
		clear_list_now.call("Loading " + host_display_name(p) + "...")
		(state["fn_populate_categories"] as Callable).call()
		route.call()
	)

	load_more_btn.pressed.connect(func():
		do_filter_fetch.call(true)
	)

	# Category menu, per host. Re-invoked by the banner Retry and every
	# successful list fetch until it lands; the two flags prevent stacking.
	var populate_categories := func():
		var provider := str(state["provider"])
		var v: Dictionary = view.call()
		if not bool(host_caps(provider)["categories"]):
			return
		if bool(v["categories_loaded"]) or bool(v["categories_loading"]):
			return
		v["categories_loading"] = true
		var res := await host_list_categories(provider)
		v["categories_loading"] = false
		if not is_instance_valid(category_dropdown):
			return
		# The user switched hosts mid-flight; these are not the menu's items.
		if str(state["provider"]) != provider:
			return
		if not res["ok"]:
			return
		var cats: Array = res["data"]
		var ids := {}
		for c in cats:
			ids[str((c as Dictionary)["id"])] = true
		category_dropdown.clear()
		category_dropdown.add_item("All categories")
		category_dropdown.set_item_metadata(0, "")
		for c in cats:
			var cd: Dictionary = c
			# A hierarchical host lists only its top level here; a flat host's group
			# names are not ids, so every entry shows.
			if str(cd["parent_id"]) != "" and ids.has(str(cd["parent_id"])):
				continue
			if str(cd["name"]) == "":
				continue
			category_dropdown.add_item(str(cd["name"]))
			var idx := category_dropdown.item_count - 1
			category_dropdown.set_item_metadata(idx, str(cd["id"]))
			if str(cd["id"]) == str(v["category_ref"]):
				category_dropdown.select(idx)
		v["categories_loaded"] = true

	# Bind the forward-referenced lambdas onto `state` for closures created earlier.
	state["fn_perform_download"] = perform_download_for_item
	state["fn_discover_fetch"] = do_discover_fetch
	state["fn_filter_fetch"] = do_filter_fetch
	state["fn_populate_categories"] = populate_categories
	state["fn_route"] = route

	apply_provider_controls.call(str(state["provider"]))
	populate_categories.call()
	route.call()

	return margin


# Refresh the baked-at-render-time state of Browse rows in place, so search
# text, caret, scroll and loaded pages survive. Rows are found through the
# browse_ref_key meta tag set at render time.
func _refresh_browse_installed_rows(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	var by_key: Dictionary = _browse_install_map()
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not node.has_meta("browse_ref_key"):
			continue
		var entry_v: Variant = by_key.get(str(node.get_meta("browse_ref_key")))
		if node is CheckBox:
			var cb := node as CheckBox
			if entry_v is Dictionary:
				cb.disabled = false
				cb.text = "Enabled in " + _active_profile
				cb.tooltip_text = "Toggle this mod in profile: " + _active_profile + "."
				# Display sync, not a user toggle: no signal, no profile save.
				cb.set_pressed_no_signal(bool((entry_v as Dictionary).get("enabled", false)))
			else:
				# Uninstalled behind the tab's back: keep the row, make it inert.
				cb.set_pressed_no_signal(false)
				cb.disabled = true
				cb.text = "Removed"
				cb.tooltip_text = "This mod is no longer installed. Click its name and use Download to install it again."
		elif node is Button and entry_v is Dictionary:
			# A Download button whose mod arrived some other way; skip in-flight buttons.
			var btn := node as Button
			if not btn.disabled:
				btn.text = "Installed"
				btn.disabled = true


# Guarded int() for API JSON fields: .get()'s default only covers an absent
# key, int(null) is a runtime error, and JSON numbers parse as float.
func _json_int(d: Dictionary, key: String, fallback: int = 0) -> int:
	var v: Variant = d.get(key)
	return int(v) if (v is int or v is float) else fallback


# Guarded truthiness for one untrusted JSON value (bool(null) is a runtime
# error). _count_truthy (modpacks.gd) is the same rule over a dictionary.
func _json_truthy(v: Variant) -> bool:
	return (v is bool and v) or ((v is int or v is float) and v != 0)


# Title for a filtered, searched or category view, so "no results" still says
# what was searched. sort_label "" means the standing "All mods" listing.
func _browse_results_header_text(query: String, sort_label: String, category_name: String) -> String:
	var q := query.strip_edges()
	var head: String = ("Results for \"" + q + "\"") if not q.is_empty() \
			else (sort_label.strip_edges() if not sort_label.strip_edges().is_empty() else "All mods")
	var cat := category_name.strip_edges()
	if not cat.is_empty():
		head += " in " + cat
	return head


# Render one Browse row from a ModSummary; every field is present by contract
# (host_types.gd). The thumbnail loads asynchronously.
func _browse_render_mod_row(summary: Dictionary, install_entry: Variant, on_get: Callable, on_toggle: Callable) -> Control:
	var ref: Dictionary = summary["ref"]
	var provider := str(ref["provider"])
	var caps: Dictionary = host_caps(provider)
	var ref_key := host_ref_key(ref)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	# Same cell the Mods tab builds, so a mod with no image reads "no thumbnail".
	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54))
	_browse_load_thumbnail_async(thumb_rect, summary["thumbnail"])

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Flat Button, not LinkButton: LinkButton cannot clip, and a long name pushed Download out of view.
	var name_lnk := Button.new()
	name_lnk.flat = true
	name_lnk.text = str(summary["name"])
	name_lnk.clip_text = true
	name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lnk.add_theme_font_size_override("font_size", FS_EMPH)
	name_lnk.add_theme_color_override("font_color", COL_TEXT)
	name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
	name_lnk.tooltip_text = name_lnk.text
	var captured_summary := summary
	name_lnk.pressed.connect(func():
		_show_browse_mod_detail_dialog(captured_summary, on_get)
	)
	info_col.add_child(name_lnk)

	# A metric chip renders only when reported: -1 means not reported, 0 is a real zero.
	var metrics: PackedStringArray = caps["metrics"]
	var meta_parts := PackedStringArray()
	if str(summary["author_name"]) != "":
		meta_parts.append("by " + str(summary["author_name"]))
	if str(summary["version"]) != "":
		meta_parts.append("v" + str(summary["version"]))
	var downloads := _browse_metric(summary, "downloads")
	if metrics.has("downloads") and downloads >= 0:
		meta_parts.append(str(downloads) + " downloads")
	var likes := _browse_metric(summary, "likes")
	if metrics.has("likes") and likes > 0:
		meta_parts.append(str(likes) + " likes")
	var views := _browse_metric(summary, "views")
	if metrics.has("views") and views > 0:
		meta_parts.append(str(views) + " views")
	if str(summary["category_name"]) != "":
		meta_parts.append(str(summary["category_name"]))
	var updated_short := _format_iso_datetime(str(summary["updated_at"]))
	if updated_short != "":
		meta_parts.append("updated " + updated_short)

	var meta_lbl := Label.new()
	meta_lbl.text = " - ".join(meta_parts)
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	# Installed mods get an enable toggle; others get Download when the host can
	# serve a file, and a quiet label when it cannot, since every other disabled
	# Download here means in flight or installed. default_file_id "" means no clean file yet.
	var can_download := bool(caps["resolve_file"]) \
			and (not bool(caps["lists_downloadable"]) or str(summary["default_file_id"]) != "")
	if install_entry is Dictionary:
		var entry: Dictionary = install_entry as Dictionary
		var enable_check := CheckBox.new()
		enable_check.text = "Enabled in " + _active_profile
		enable_check.button_pressed = bool(entry.get("enabled", false))
		enable_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		enable_check.set_meta("browse_ref_key", ref_key)
		var captured_key := ref_key
		var captured_check := enable_check
		enable_check.toggled.connect(func(on: bool):
			on_toggle.call(captured_key, on, captured_check)
		)
		row.add_child(enable_check)
		_wire_hint(enable_check, "Toggle this mod in profile: " + _active_profile + ".")
	elif can_download:
		var get_btn := Button.new()
		get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		get_btn.text = "Download"
		get_btn.set_meta("browse_ref_key", ref_key)
		var captured := summary
		var captured_btn := get_btn
		get_btn.pressed.connect(func():
			on_get.call(captured, captured_btn)
		)
		row.add_child(get_btn)
		_wire_hint(get_btn, "Download this mod from " + host_display_name(provider) + ".")
	else:
		var no_dl := Label.new()
		no_dl.text = "No file yet" if bool(caps["resolve_file"]) else "Browse only"
		no_dl.add_theme_font_size_override("font_size", FS_META)
		no_dl.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_dl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		no_dl.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(no_dl)
		if bool(caps["resolve_file"]):
			_wire_hint(no_dl, host_display_name(provider) + " has no downloadable file for this mod yet (it may still be scanning).")
		else:
			_wire_hint(no_dl, host_display_name(provider) + " does not provide downloads through the loader.")

	return row


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
	if wrap == null or not is_instance_valid(wrap):
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
	if wrap != null and is_instance_valid(wrap) and wrap.has_node("ThumbStateLabel"):
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

# Detail modal for a Browse row: opens on the ModSummary and async-loads the
# detail and file history. Get forwards to the rows' on_get callback.
func _show_browse_mod_detail_dialog(summary: Dictionary, on_get: Callable) -> void:
	var ref: Dictionary = summary["ref"]
	var provider := str(ref["provider"])
	var caps: Dictionary = host_caps(provider)
	var ref_key := host_ref_key(ref)

	var d := AcceptDialog.new()
	d.title = str(summary["name"])
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	# Scroll on top, a download status line pinned below so feedback stays visible.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_S)
	d.add_child(outer)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	# In-dialog download status: the modal covers the tab's status label;
	# set_dl_status finds this through the Download button's meta.
	var dl_status := Label.new()
	dl_status.visible = false
	dl_status.add_theme_font_size_override("font_size", FS_BODY)
	dl_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	dl_status.clip_text = true
	dl_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	dl_status.mouse_filter = Control.MOUSE_FILTER_PASS
	outer.add_child(dl_status)

	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_L)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Image band from the thumbnail now; the detail fetch repaints it with the
	# banner. Built only when there is an image.
	var banner_rect: TextureRect = null
	var thumb: Dictionary = summary["thumbnail"]
	if str(thumb["url"]) != "":
		banner_rect = _make_thumb_cell(box, Vector2(0, 220), false)
		_browse_load_thumbnail_async(banner_rect, thumb)

	var metrics: PackedStringArray = caps["metrics"]
	var meta := Label.new()
	var parts := PackedStringArray()
	if str(summary["author_name"]) != "":
		parts.append("by " + str(summary["author_name"]))
	if str(summary["version"]) != "":
		parts.append("v" + str(summary["version"]))
	var downloads := _browse_metric(summary, "downloads")
	if metrics.has("downloads") and downloads >= 0:
		parts.append(str(downloads) + " downloads")
	var likes := _browse_metric(summary, "likes")
	if metrics.has("likes") and likes >= 0:
		parts.append(str(likes) + " likes")
	var views := _browse_metric(summary, "views")
	if metrics.has("views") and views >= 0:
		parts.append(str(views) + " views")
	if str(summary["category_name"]) != "":
		parts.append(str(summary["category_name"]))
	var updated_short := _format_iso_datetime(str(summary["updated_at"]))
	if updated_short != "":
		parts.append("updated " + updated_short)
	meta.text = " - ".join(parts)
	meta.add_theme_font_size_override("font_size", FS_META)
	meta.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(meta)

	var can_download := bool(caps["resolve_file"]) \
			and (not bool(caps["lists_downloadable"]) or str(summary["default_file_id"]) != "")
	if not bool(caps["resolve_file"]):
		var note := Label.new()
		note.text = host_display_name(provider) + " does not provide downloads through the loader."
		note.add_theme_font_size_override("font_size", FS_META)
		note.add_theme_color_override("font_color", COL_TEXT_DIM)
		box.add_child(note)

	# Description: the short text now, the full one once the detail lands. Adapters deliver BBCode.
	var desc_hdr := Label.new()
	desc_hdr.text = "Description"
	desc_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	desc_hdr.add_theme_color_override("font_color", COL_TEXT)
	var desc_rt := RichTextLabel.new()
	desc_rt.bbcode_enabled = true
	desc_rt.fit_content = true
	desc_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_rt.selection_enabled = true
	desc_rt.meta_underlined = true
	desc_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_rt.add_theme_color_override("default_color", COL_TEXT)
	# Links open in the system browser, web schemes only: the URL comes from
	# an untrusted description, and OS.shell_open is ShellExecute on Windows.
	desc_rt.meta_clicked.connect(func(meta_v):
		var u := str(meta_v).strip_edges()
		if u.to_lower().begins_with("http://") or u.to_lower().begins_with("https://"):
			OS.shell_open(u)
	)
	var desc_sep := HSeparator.new()
	var show_description := func(bbcode: String):
		if not is_instance_valid(desc_rt):
			return
		if bbcode.strip_edges().is_empty():
			return
		if desc_rt.get_parent() == null:
			box.add_child(desc_sep)
			box.add_child(desc_hdr)
			box.add_child(desc_rt)
		desc_rt.text = bbcode
	show_description.call(_markdown_to_bbcode(str(summary["short_description"])))

	# Files section only for hosts that expose version history.
	var files_status: Label = null
	var files_list: VBoxContainer = null
	if bool(caps["file_history"]):
		box.add_child(HSeparator.new())
		var files_hdr := Label.new()
		files_hdr.text = "Files"
		files_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		files_hdr.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(files_hdr)
		files_status = Label.new()
		files_status.text = "Loading file list..."
		files_status.add_theme_font_size_override("font_size", FS_BODY)
		files_status.add_theme_color_override("font_color", COL_TEXT_DIM)
		box.add_child(files_status)
		files_list = VBoxContainer.new()
		files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(files_list)

	# Page and Download sit in the dialog's button bar so they stay visible.
	var page_url := host_mod_page_url(ref)
	if page_url != "":
		var page_btn := d.add_button("Open mod page in browser", false, "")
		page_btn.pressed.connect(func():
			OS.shell_open(page_url)
		)
	var already_installed := _browse_install_map().has(ref_key)
	# A Dictionary slot so the async detail can add the button late (lambdas capture by value).
	var action := {"get_btn": null}
	var add_download_button := func(record: Dictionary):
		var get_btn := d.add_button("Download", true, "")
		style_primary_button(get_btn)
		get_btn.set_meta("browse_dialog_status", dl_status)
		get_btn.pressed.connect(func():
			on_get.call(record, get_btn)
		)
		action["get_btn"] = get_btn
	if already_installed:
		var installed_btn := d.add_button("Installed", true, "")
		installed_btn.disabled = true
	elif can_download:
		add_download_button.call(summary)

	# Async detail: full description, banner, and a Download button when the
	# host now has a file. Any failure leaves the summary view standing.
	var load_detail := func():
		var res := await host_get_mod(ref)
		if not res["ok"]:
			return
		if not is_instance_valid(d):
			return
		var detail: Dictionary = res["data"]
		show_description.call(str(detail["description"]))
		var banner: Dictionary = detail["banner"]
		if str(banner["url"]) != "" and banner_rect != null and is_instance_valid(banner_rect):
			_browse_load_thumbnail_async(banner_rect, banner)
		if action["get_btn"] == null and not already_installed and bool(caps["resolve_file"]) \
				and str(detail["default_file_id"]) != "":
			add_download_button.call(detail)
	load_detail.call()

	var load_files := func():
		if files_status == null:
			return
		var res := await host_list_files(ref)
		if not is_instance_valid(files_status):
			return
		if not res["ok"]:
			files_status.text = host_error_message(provider, res)
			files_status.add_theme_color_override("font_color", COL_ERR)
			return
		var files: Array = res["data"]
		if files.is_empty():
			files_status.text = "No downloadable files yet."
			return
		files_status.queue_free()
		var primary_id := str(summary["default_file_id"])
		for file_v in files:
			var fd: Dictionary = file_v
			var f_row := HBoxContainer.new()
			f_row.add_theme_constant_override("separation", SP_L)
			files_list.add_child(f_row)

			var v_lbl := Label.new()
			var v_str: String = "v" + str(fd["version"])
			if primary_id != "" and str(fd["id"]) == primary_id:
				v_str += " (primary)"
			v_lbl.text = v_str
			v_lbl.custom_minimum_size.x = 140
			v_lbl.clip_text = true
			v_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			v_lbl.tooltip_text = v_lbl.text
			v_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			f_row.add_child(v_lbl)

			var size_lbl := Label.new()
			var size := _browse_metric(fd, "size")
			size_lbl.text = _format_size(size) if size >= 0 else ""
			size_lbl.custom_minimum_size.x = 80
			size_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(size_lbl)

			var date_str := str(fd["created_at"])
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


# -- Updates-tab session state -------------------------------------------------
# The Updates tab is torn down and rebuilt on every show, so the results of
# a completed check live at module scope, as _mod_updates_state does for the
# Mods-tab badges.
#   _updates_tab_status: profile_key -> {text, tooltip, color} for a row's
#     terminal Status text ("Up to date", "Check failed", ...). Rows with an
#     available update re-arm from _mod_updates_state instead, so a mod
#     updated from the Mods tab never shows a stale "Update: vX" here.
#   _updates_tab_log: timestamped Activity lines, re-rendered on build.
#   _updates_tab_dl_in_flight: this tab's row downloads still awaiting;
#     "Check for updates" re-enables only when it reaches zero.
var _updates_tab_status: Dictionary = {}
var _updates_tab_log: Array[String] = []
# Oldest lines drop off past this many; see add_log in build_updates_tab.
const _UPDATES_LOG_MAX := 200
var _updates_tab_dl_in_flight: int = 0
# Live references to the current build's list scroller and check button, so
# a rebuild carries scroll position and completions re-enable the current button.
var _ui_updates_scroll: ScrollContainer = null
var _ui_updates_check_btn: Button = null

# Arm an Updates-tab row for an available update: status, Download button
# and handler. Shared by the check and the on-show rebuild. State writes are
# unconditional; UI touches are guarded per node.
func _updates_arm_row_update(info: Dictionary, latest_v: String, add_log: Callable) -> void:
	var pre_entry: Dictionary = info.get("entry", {})
	var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
	# Surface state through _mod_updates_state so the Mods tab badge and the rebuild see it.
	if pk != "":
		_mod_updates_state[pk] = {
			"latest_version": latest_v,
			"current_version": str(info["version"]),
			"ref": info["ref"],
			"full_path": str(info["full_path"]),
			"mod_name": str(info["mod_name"]),
		}
		# An available update supersedes any stored terminal status.
		_updates_tab_status.erase(pk)
	var lbl: Label = info["label"]
	var dl_btn: Button = info["dl_btn"]
	if is_instance_valid(lbl):
		# Accent = the update signal; the tooltip carries the full text.
		lbl.text = "Update: v" + latest_v
		lbl.tooltip_text = lbl.text
		lbl.add_theme_color_override("font_color", COL_ACCENT)
	if not is_instance_valid(dl_btn):
		return
	dl_btn.modulate.a = 1.0
	dl_btn.disabled = false
	dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var full_path: String = str(info["full_path"])
	var ref: Dictionary = info["ref"]
	var mod_name: String = str(info["mod_name"])
	var new_ver: String = latest_v
	# Guard key for _mod_update_in_flight, shared with the Mods-tab badge path
	# because both surfaces target the same file and rollback paths.
	var guard_key: String = pk if pk != "" else full_path
	# Disconnect previous connections so repeated checks don't stack callbacks.
	for c in dl_btn.pressed.get_connections():
		dl_btn.pressed.disconnect(c["callable"])
	dl_btn.pressed.connect(func():
		# Refuse a second concurrent download of the same mod: two runs would
		# delete each other's temp and backup files and corrupt the rollback.
		if _mod_update_in_flight.has(guard_key):
			return
		_mod_update_in_flight[guard_key] = true
		_updates_tab_dl_in_flight += 1
		dl_btn.disabled = true
		dl_btn.text = "Downloading..."
		if is_instance_valid(lbl):
			lbl.text = "Downloading..."
			lbl.tooltip_text = lbl.text
			lbl.add_theme_color_override("font_color", COL_ACCENT)
		if is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = true
		# Re-resolve live: the Mods-tab badge may have renamed this file since the build.
		var live_path: String = _live_full_path(pk, full_path)
		var result: Dictionary = await replace_mod_from_ref(live_path, ref)
		# State bookkeeping first, unconditionally: the on-show rebuild can free
		# every node this closure captured while the download is in flight. UI
		# touches are guarded individually below.
		_mod_update_in_flight.erase(guard_key)
		_updates_tab_dl_in_flight = maxi(0, _updates_tab_dl_in_flight - 1)
		# Re-enable the current check button only when no downloads remain.
		if _updates_tab_dl_in_flight == 0 and is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = false
		if result.get("ok", false):
			# Update cached version so next Check won't re-flag this mod.
			info["version"] = new_ver
			# Reflect the on-disk rename in the live entry dict so the next discovery
			# pass and any rebuild point at the new archive.
			var new_path: String = str(result.get("new_path", full_path))
			var new_fn: String = str(result.get("new_file_name", full_path.get_file()))
			info["full_path"] = new_path
			var entry_ref: Dictionary = _live_entry_for_profile_key(pk, pre_entry)
			if not entry_ref.is_empty():
				entry_ref["full_path"] = new_path
				entry_ref["file_name"] = new_fn
			if pk != "":
				# Drop the shared badge state and persist the terminal status.
				_mod_updates_state.erase(pk)
				_updates_tab_status[pk] = {
					"text": "Updated -- restart to apply",
					"tooltip": "Updated -- restart to apply",
					"color": COL_OK,
				}
			# The badge state changed while the Mods tab may be off-screen.
			_mods_badges_dirty = true
			var rename_note: String = (" (renamed to " + new_fn + ")") if new_fn != full_path.get_file() else ""
			add_log.call(mod_name + " -- updated to v" + new_ver + rename_note + ". Restart game to apply.")
			if is_instance_valid(lbl):
				lbl.text = "Updated -- restart to apply"
				lbl.tooltip_text = lbl.text
				lbl.add_theme_color_override("font_color", COL_OK)
			if is_instance_valid(dl_btn):
				dl_btn.modulate.a = 0.0
				dl_btn.disabled = true
				dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
				dl_btn.text = "Update"
			var ver_lbl_v: Variant = info.get("ver_lbl")
			if ver_lbl_v is Label and is_instance_valid(ver_lbl_v):
				(ver_lbl_v as Label).text = "v" + new_ver
				(ver_lbl_v as Label).tooltip_text = "v" + new_ver
		else:
			# Surface the real failure cause (file collision, locked file, rate
			# limit) instead of blaming the connection.
			var err_detail := str(result.get("error", ""))
			var log_line := "Could not download " + mod_name + ". Check your connection and try again."
			if err_detail != "" and err_detail != "unknown":
				log_line = "Could not download " + mod_name + " -- " + err_detail
			if pk != "":
				_updates_tab_status[pk] = {"text": "Download failed", "tooltip": log_line, "color": COL_ERR}
			add_log.call(log_line)
			if is_instance_valid(lbl):
				lbl.text = "Download failed"
				lbl.tooltip_text = log_line
				lbl.add_theme_color_override("font_color", COL_ERR)
			if is_instance_valid(dl_btn):
				dl_btn.disabled = false
				dl_btn.text = "Retry"
	)

# Scroll the restored log to its newest line one frame later (no layout yet).
func _updates_scroll_log_to_bottom(sc: ScrollContainer) -> void:
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = 999999

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

	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	style_primary_button(check_btn)
	# A tab rebuilt mid-download must not offer a check that would reset the row.
	if _updates_tab_dl_in_flight > 0:
		check_btn.disabled = true
	toolbar.add_child(check_btn)
	_ui_updates_check_btn = check_btn

	container.add_child(HSeparator.new())

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
	_ui_updates_scroll = scroll

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, ref, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	var persisted_sources := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var ref := _entry_host_ref(entry, persisted_sources)
		# Checkable means a host that can hand back a file.
		var checkable := not ref.is_empty() and bool(host_caps(str(ref["provider"]))["resolve_file"])

		var row := HBoxContainer.new()
		list.add_child(row)

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
		# A long prerelease string must not push the columns out of alignment.
		ver_lbl.clip_text = true
		ver_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		ver_lbl.tooltip_text = ver_lbl.text
		ver_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		# Status text can outgrow the column; trim it.
		status_lbl.clip_text = true
		status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		# PASS so the ellipsized status text gets a full-text tooltip.
		status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		if entry["ext"] == "folder":
			# Dev folders cannot take a downloaded archive; say so instead of offering one.
			status_lbl.text = "Dev folder"
			status_lbl.tooltip_text = "Dev folders load straight from your mods folder, so there is nothing to download. Update downloads only apply to mods installed as archives."
		elif not ref.is_empty() and not checkable:
			status_lbl.text = "No update info"
			status_lbl.tooltip_text = host_display_name(str(ref["provider"])) + " does not provide downloads through the loader, so this mod cannot be checked."
		elif not checkable or version == "":
			# Say why this row cannot be checked.
			status_lbl.text = "No update info"
			status_lbl.tooltip_text = "This mod's mod.txt does not say where it came from ([updates] source= plus [mod] version=), so it cannot be checked. Add both fields to enable update checks."
		else:
			status_lbl.text = "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width; modulate.a hides it.
		var dl_btn := Button.new()
		dl_btn.text = "Update"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if checkable and version != "" and entry["ext"] != "folder":
			# Hold the underlying entry dict so the download callback can update
			# full_path and file_name in place when an update lands under a new name.
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "ref": ref,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"], "entry": entry,
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods to check yet.\nGet mods from the Browse tab, then check for updates here."
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

	var log_label := func(line: String) -> Label:
		var lbl := Label.new()
		lbl.text = line
		lbl.add_theme_font_size_override("font_size", FS_BODY)
		lbl.add_theme_color_override("font_color", COL_TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		return lbl

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var line := "[" + t + "] " + msg
		# Persist first: a download can finish after this tab was rebuilt. Capped,
		# since every rebuild re-renders one Label per stored line.
		_updates_tab_log.append(line)
		while _updates_tab_log.size() > _UPDATES_LOG_MAX:
			_updates_tab_log.remove_at(0)
		if not is_instance_valid(log_list):
			return
		log_list.add_child(log_label.call(line))
		# Defer a frame: the new label has no layout yet.
		_updates_scroll_log_to_bottom(log_scroll)

	# Restore Activity lines from earlier checks this session, then scroll to
	# the newest line one frame later (the restored labels have no layout yet).
	for line in _updates_tab_log:
		log_list.add_child(log_label.call(line))
	if not _updates_tab_log.is_empty():
		_updates_scroll_log_to_bottom(log_scroll)

	# Restore per-row results from earlier checks this session. Precedence: a
	# download in flight renders the row inert (a live Update button would
	# allow a second concurrent download); then an available update re-arms
	# from _mod_updates_state; then any stored terminal status.
	for fn in status_info:
		var info: Dictionary = status_info[fn]
		var entry_d: Dictionary = info.get("entry", {})
		var pk := str(entry_d.get("profile_key", ""))
		if pk == "":
			continue
		var row_lbl: Label = info["label"]
		if _mod_update_in_flight.has(pk):
			row_lbl.text = "Downloading..."
			row_lbl.tooltip_text = row_lbl.text
			row_lbl.add_theme_color_override("font_color", COL_ACCENT)
			var b: Button = info["dl_btn"]
			b.modulate.a = 1.0
			b.disabled = true
			b.text = "Downloading..."
			continue
		if _mod_updates_state.has(pk):
			var upd: Dictionary = _mod_updates_state[pk]
			var latest_known := str(upd.get("latest_version", ""))
			# Re-verify against the row's current version. The file may have
			# been updated through another surface since the check ran.
			if latest_known != "" and compare_versions(str(info["version"]), latest_known) < 0:
				_updates_arm_row_update(info, latest_known, add_log)
				continue
		if _updates_tab_status.has(pk):
			var st: Dictionary = _updates_tab_status[pk]
			row_lbl.text = str(st.get("text", ""))
			row_lbl.tooltip_text = str(st.get("tooltip", row_lbl.text))
			var col_v: Variant = st.get("color")
			row_lbl.add_theme_color_override("font_color", col_v if col_v is Color else COL_TEXT_DIM)

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
			btn.text = "Update"
		await check_updates_for_ui(status_info, add_log, check_btn)
		# The launcher can close while the check is in flight; the button dies with it.
		if not is_instance_valid(check_btn):
			return
		check_btn.disabled = false
		check_btn.text = "Check for updates"
	)

	return margin

# Update check for every installed mod with a downloadable host and a version.
# Populates _mod_updates_state. Returns {checked, with_updates, errors}.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0}
	_mod_updates_check_in_progress = true
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	var pending: Array = []
	var persisted_sources := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		# Dev folders cannot take a downloaded archive; never flag them.
		if str(entry.get("ext", "")) == "folder":
			continue
		var ref := _entry_host_ref(entry, persisted_sources)
		if ref.is_empty() or not bool(host_caps(str(ref["provider"]))["resolve_file"]):
			continue
		var version := str(cfg.get_value("mod", "version", "")).strip_edges()
		if version == "":
			continue
		pending.append({
			"profile_key": str(entry.get("profile_key", "")),
			"ref": ref,
			"version": version,
			"full_path": str(entry.get("full_path", "")),
			"mod_name": str(entry.get("mod_name", "?")),
		})
	if pending.is_empty():
		_mod_updates_check_in_progress = false
		return summary
	var refs: Array = []
	for p in pending:
		refs.append((p as Dictionary)["ref"])
	var latest := await fetch_latest_versions(refs)
	for p in pending:
		summary["checked"] += 1
		var info: Dictionary = p
		var raw = latest.get(host_ref_key(info["ref"]), null)
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
			"ref": info["ref"],
			"full_path": info["full_path"],
			"mod_name": info["mod_name"],
		}
	_mod_updates_check_in_progress = false
	return summary


func check_updates_for_ui(status_info: Dictionary, add_log: Callable, _check_btn: Button) -> void:
	var refs: Array = []
	for fn in status_info:
		refs.append(status_info[fn]["ref"])
	if refs.is_empty():
		# With only dev-folder or sourceless mods installed, say why nothing
		# happened (same copy as the Mods-tab toast).
		add_log.call("No installed mods say where they came from, so there is nothing to check.")
		return

	var latest := await fetch_latest_versions(refs)

	# The Mods tab is off-screen; flag it to rebuild its badges on the next show.
	_mods_badges_dirty = true

	# State bookkeeping must survive a mid-check tab rebuild (switching away
	# frees every node in status_info): persisted state is written
	# unconditionally, UI touches are guarded per node.
	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var pre_entry: Dictionary = info.get("entry", {})
		var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
		var latest_v = latest.get(host_ref_key(info["ref"]), null)
		if latest_v == null:
			# The rate-limit hint lives in the tooltip; the sentence would ellipsize here.
			var fail_tip := host_error_status(str((info["ref"] as Dictionary)["provider"]), "Check failed")
			if pk != "":
				_updates_tab_status[pk] = {"text": "Check failed", "tooltip": fail_tip, "color": COL_ERR}
			if is_instance_valid(lbl):
				lbl.text = "Check failed"
				lbl.tooltip_text = fail_tip
				lbl.add_theme_color_override("font_color", COL_ERR)
			continue

		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			if pk != "":
				_mod_updates_state.erase(pk)
				_updates_tab_status[pk] = {"text": "Up to date", "tooltip": "Up to date", "color": COL_TEXT_DIM}
			if is_instance_valid(lbl):
				lbl.text = "Up to date"
				lbl.tooltip_text = lbl.text
				lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		else:
			# Server has a newer version: arm the row through the shared helper.
			_updates_arm_row_update(info, str(latest_v), add_log)

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
