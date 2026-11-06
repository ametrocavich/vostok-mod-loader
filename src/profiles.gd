## Profile selection and mod_config.cfg persistence: stored profile keys mapped to mod entries.

const PROFILE_SUBSECTIONS := [".enabled", ".priority", ".settings", ".dep_ignore"]
const STATE_SUFFIXES := [".enabled", ".priority", ".dep_ignore"]

var _ui_cfg_refusal_notified := false

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	# Same .bak fallback as _load_ui_config, or a corrupt cfg strands every folder mod.
	if _ui_cfg_load(cfg) != OK and not _ui_cfg_load_bak(cfg):
		return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("[Config] Developer mode: ON")

func _load_ui_config() -> void:
	_active_profile = "Default"
	_complete_pending_mcm_switch()
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		cfg = ConfigFile.new()
		if not _ui_cfg_load_bak(cfg):
			if FileAccess.file_exists(UI_CONFIG_PATH):
				if DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt") == OK:
					# Or _load_ui_cfg_for_write refuses this save and every later one.
					DirAccess.remove_absolute(UI_CONFIG_PATH)
			_save_ui_config()
			return
		_log_warning("[Config] " + UI_CONFIG_PATH + " unreadable; recovered from .bak")
		if FileAccess.file_exists(UI_CONFIG_PATH):
			DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".corrupt")
		# A raw save, so the corrupt file is not rolled over the backup.
		var restore_err := cfg.save(UI_CONFIG_PATH)
		if restore_err != OK:
			_log_critical("[Config] Could not write recovered settings to %s (error %d); changes are not saved" \
					% [UI_CONFIG_PATH, restore_err])
		else:
			# The backup may carry a pending switch; the swap rewrites the file without it.
			_complete_pending_mcm_switch()
			var restored := ConfigFile.new()
			if _ui_cfg_load(restored) == OK:
				cfg = restored

	var has_any_profile := false
	for sec: String in cfg.get_sections():
		if sec.begins_with("profile."):
			has_any_profile = true
			break
	if not has_any_profile:
		var migrated := false
		for flat: String in ["enabled", "priority"]:
			if cfg.has_section(flat):
				for key: String in cfg.get_section_keys(flat):
					cfg.set_value("profile.Default." + flat, key, cfg.get_value(flat, key))
				migrated = true
		# _save_ui_config reloads from disk, so the migrated keys must be there first.
		if migrated:
			_persist_ui_cfg(cfg)

	# 3.4.2 kept the edge spaces _sanitize_profile_name now strips; its pack slots move once.
	var moved: Array[String] = []
	var listed := _list_profiles_in_cfg(cfg)
	for slot in listed:
		for prefix: String in [MODPACK_PROFILE_PREFIX, MODPACK_BACKUP_PREFIX]:
			var old_pack := slot.trim_prefix(prefix)
			var new_pack := old_pack.strip_edges()
			if not slot.begins_with(prefix) or new_pack == old_pack or new_pack == "" or (prefix + new_pack) in listed:
				continue
			_copy_profile_sections(cfg, slot, prefix + new_pack, PROFILE_SUBSECTIONS)
			_erase_profile_sections(cfg, slot)
			for key: String in ["active_profile", "modpack_backup_profile", "mcm_pending_from", "mcm_pending_to"]:
				if str(cfg.get_value("settings", key, "")) == slot:
					cfg.set_value("settings", key, prefix + new_pack)
			if str(cfg.get_value("settings", "active_modpack", "")) == old_pack:
				cfg.set_value("settings", "active_modpack", new_pack)
			var old_dir := MCM_SNAPSHOT_BASE.path_join(slot)
			var new_dir := MCM_SNAPSHOT_BASE.path_join(prefix + new_pack)
			# Windows drops a trailing space from paths, so there both names are one folder.
			if DirAccess.dir_exists_absolute(old_dir) and not DirAccess.dir_exists_absolute(new_dir):
				DirAccess.rename_absolute(old_dir, new_dir)
			moved.append("'%s'" % slot)
	if not moved.is_empty():
		_log_info("[Modpack] Renamed 3.4.2 pack slots without edge spaces: " + ", ".join(moved))
		_persist_ui_cfg(cfg)

	var stored := str(cfg.get_value("settings", "active_profile", "Default"))
	var pack := str(cfg.get_value("settings", "active_modpack", ""))
	var profiles := _list_profiles_in_cfg(cfg)
	var users := _list_user_profiles_in_cfg(cfg)
	if stored != VANILLA_PROFILE and stored in profiles:
		_active_profile = stored
	elif pack != "" and (MODPACK_PROFILE_PREFIX + pack) in profiles:
		_active_profile = MODPACK_PROFILE_PREFIX + pack
	else:
		_active_profile = users[0] if not users.is_empty() else "Default"

	# A managed slot is active only while active_modpack names it; else a crash stranded it.
	var stranded := _is_modpack_managed_profile(_active_profile) \
			and _active_profile != MODPACK_PROFILE_PREFIX + pack
	if stranded:
		_recover_stranded_slot(cfg, users)
	if stranded or (pack != "" and _active_profile != MODPACK_PROFILE_PREFIX + pack):
		cfg.set_value("settings", "active_modpack", "")
		cfg.set_value("settings", "modpack_backup_valid", false)
		_persist_ui_cfg(cfg)

	_apply_profile_to_entries(cfg, _active_profile)

	# An unstored Default is a placeholder that vanishes when a named profile is created.
	if _active_profile == "Default" and not has_any_profile:
		_save_ui_config()

func _recover_stranded_slot(cfg: ConfigFile, users: Array[String]) -> void:
	var pre_pack_restored := false
	if _active_profile.begins_with(MODPACK_PROFILE_PREFIX):
		var bslot := MODPACK_BACKUP_PREFIX + _active_profile.trim_prefix(MODPACK_PROFILE_PREFIX)
		if _has_mcm_snapshot(bslot):
			pre_pack_restored = _restore_mcm_from(bslot)
	var backup := str(cfg.get_value("settings", "modpack_backup_profile", ""))
	var to_backup := backup != "" and backup in users
	if to_backup:
		_active_profile = backup
	else:
		_active_profile = users[0] if not users.is_empty() else "Default"
	# Any landing but the backup gets its own MCM back, or the next switch saves over it.
	if not (pre_pack_restored and to_backup) and _has_mcm_snapshot(_active_profile):
		_restore_mcm_from(_active_profile)
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.set_value("settings", "modpack_backup_profile", "")
	_log_warning("[Modpack] Recovered from a stranded managed slot -> profile '%s'" % _active_profile)

func _resolve_stored_key(cfg: ConfigFile, profile: String, entry: Dictionary) -> String:
	var pk: String = entry["profile_key"]
	if cfg.has_section_key(_profile_sec(profile, ".enabled"), pk) \
			or cfg.has_section_key(_profile_sec(profile, ".priority"), pk):
		return pk
	var by_stem := pk.begins_with("zip:")
	var want: String = _normalized_mod_stem(entry["file_name"]) if by_stem else str(entry["mod_id"]).to_lower()
	if by_stem and want.is_empty():
		return ""
	var hit := ""
	for suffix: String in [".enabled", ".priority"]:
		var sec := _profile_sec(profile, suffix)
		if not cfg.has_section(sec):
			continue
		for key: String in cfg.get_section_keys(sec):
			if not by_stem:
				if _key_names_id(key, want):
					return key
			elif key.begins_with("zip:") and _normalized_mod_stem(key.trim_prefix("zip:")) == want:
				# Two stored keys with one stem: the mod is treated as new, not guessed.
				if hit != "" and hit != key:
					return ""
				hit = key
	return hit

func _apply_profile_to_entries(cfg: ConfigFile, profile: String) -> void:
	_mods_hide_disabled = bool(cfg.get_value(_profile_sec(profile, ".settings"), "hide_disabled", false))
	var en_sec := _profile_sec(profile, ".enabled")
	var pr_sec := _profile_sec(profile, ".priority")
	var ig_sec := _profile_sec(profile, ".dep_ignore")
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		entry.erase("profile_version_mismatch")
		var resolved_key := _resolve_stored_key(cfg, profile, entry)
		var stored_version := resolved_key.substr(str(entry["mod_id"]).length() + 1)
		if resolved_key != "" and resolved_key != pk and not pk.begins_with("zip:") \
				and stored_version != str(entry["version"]):
			entry["profile_version_mismatch"] = {
				"stored":  stored_version,
				"current": entry["version"],
			}
		if resolved_key != "" and cfg.has_section_key(en_sec, resolved_key):
			entry["enabled"] = bool(cfg.get_value(en_sec, resolved_key))
		else:
			entry["enabled"] = profile == "Default"
		if resolved_key != "" and cfg.has_section_key(pr_sec, resolved_key):
			entry["priority"] = int(str(cfg.get_value(pr_sec, resolved_key)))
		else:
			entry["priority"] = entry["priority_default"]
		var ig_key := pk if cfg.has_section_key(ig_sec, pk) else resolved_key
		entry["dependency_ignored"] = ig_key != "" \
				and bool(cfg.get_value(ig_sec, ig_key, false))
	_refresh_dependency_status()

# Kept out of .enabled/.priority, so _save_ui_config's erase-and-rewrite leaves it alone.
func _save_per_profile_setting(key: String, value: Variant) -> void:
	_set_ui_cfg_value(_profile_sec(_active_profile, ".settings"), key, value)

func _mods_entry_visible(entry: Dictionary) -> bool:
	if _mods_hide_disabled and not entry["enabled"]:
		return false
	return _mods_filter_text == "" or entry["mod_name"].to_lower().contains(_mods_filter_text.to_lower())

# The version never holds "@", the id may, so both splitters cut at the last one.
func _profile_key_id(key: String) -> String:
	if key.begins_with("zip:"):
		return ""
	var at := key.rfind("@")
	return key.substr(0, at).to_lower() if at > 0 else ""

# A key is id + "@" + version and an id can hold "@", so the whole id is the prefix.
func _key_names_id(key: String, id_l: String) -> bool:
	return key.to_lower().begins_with(id_l + "@")

func _version_from_profile_key(key: String) -> String:
	var at := key.rfind("@")
	if at < 0:
		return ""
	return key.substr(at + 1)

# ConfigFile drops an emptied section, so a profile with no mods survives via .settings.
func _list_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	var prefix := "profile."
	for sec: String in cfg.get_sections():
		if not sec.begins_with(prefix):
			continue
		for suffix: String in PROFILE_SUBSECTIONS:
			if not sec.ends_with(suffix):
				continue
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - suffix.length())
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
			break
	names.sort()
	return names

# A pack's backup slot is erased key by key at unload, so it gets no marker.
func _keep_profile_listed(cfg: ConfigFile, name: String) -> void:
	if name == "" or name == VANILLA_PROFILE or name.begins_with(MODPACK_BACKUP_PREFIX):
		return
	var sec := _profile_sec(name, ".settings")
	if not cfg.has_section_key(sec, "listed"):
		cfg.set_value(sec, "listed", true)

func _list_profiles() -> Array[String]:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return []
	return _list_profiles_in_cfg(cfg)

func _active_profile_label() -> String:
	if _active_profile.begins_with(MODPACK_PROFILE_PREFIX):
		return "[Modpack: %s]" % _active_profile.trim_prefix(MODPACK_PROFILE_PREFIX)
	return _active_profile

# Anything that picks a profile to land on uses this: a switch into a pack slot corrupts it.
func _list_user_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	return _list_profiles_in_cfg(cfg).filter(
			func(n: String): return not _is_modpack_managed_profile(n))

func _schedule_priority_save() -> void:
	if _priority_save_pending:
		return
	_priority_save_pending = true
	await get_tree().create_timer(0.4).timeout
	if not _priority_save_pending:
		return
	_priority_save_pending = false
	_save_ui_config()

func _flush_priority_save() -> void:
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()

func _collect_live_profile_key_maps() -> Dictionary:
	var live_keys: Dictionary = {}
	var installed_ids: Dictionary = {}
	var installed_stems: Dictionary = {}
	var hidden_keys: Dictionary = {}
	for entry in _ui_mod_entries:
		var lk: String = entry["profile_key"]
		live_keys[lk] = true
		if lk.begins_with("zip:"):
			installed_stems[_normalized_mod_stem(entry["file_name"])] = true
			continue
		var id_l := str(entry["mod_id"]).to_lower()
		installed_ids[id_l] = true
		for dup in entry.get("duplicates_hidden", []):
			hidden_keys[id_l + "@" + str(dup["version"])] = true
	return {"live": live_keys, "ids": installed_ids, "stems": installed_stems, "hidden": hidden_keys}

func _preserve_stored_profile_key(key: String, key_maps: Dictionary) -> bool:
	if key_maps["live"].has(key):
		return false
	if _hidden_folder_profile_keys.has(key) or key_maps["hidden"].has(key.to_lower()):
		return true
	return not _stored_key_migrated(key, key_maps["ids"], key_maps["stems"])

func _stored_key_migrated(key: String, installed_ids: Dictionary, installed_stems: Dictionary) -> bool:
	if key.begins_with("zip:"):
		return installed_stems.has(_normalized_mod_stem(key.trim_prefix("zip:")))
	var k := key.to_lower()
	var at := k.find("@")
	while at > 0:
		if installed_ids.has(k.substr(0, at)):
			return true
		at = k.find("@", at + 1)
	return false

func _save_ui_config() -> void:
	# Only the active profile is rebuilt from memory, so an unreadable cfg is never written.
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	for flat in ["enabled", "priority"]:
		if cfg.has_section(flat):
			cfg.erase_section(flat)
	if cfg.has_section_key("settings", "preferred_author"):
		cfg.erase_section_key("settings", "preferred_author")

	var key_maps := _collect_live_profile_key_maps()
	var live_enabled: Dictionary = {}
	var live_priority: Dictionary = {}
	var live_ignored: Dictionary = {}
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		live_enabled[pk] = entry["enabled"]
		live_priority[pk] = entry["priority"]
		if entry["dependency_ignored"]:
			live_ignored[pk] = true
	_rewrite_profile_section(cfg, _profile_sec(_active_profile, ".enabled"), live_enabled, key_maps)
	_rewrite_profile_section(cfg, _profile_sec(_active_profile, ".priority"), live_priority, key_maps)
	_rewrite_profile_section(cfg, _profile_sec(_active_profile, ".dep_ignore"), live_ignored, key_maps)
	_keep_profile_listed(cfg, _active_profile)

	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.set_value("settings", "active_profile", _active_profile)
	_persist_ui_cfg(cfg)

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

# ConfigFile.save truncates then writes and Windows has no atomic rename: copy .bak first.
func _persist_ui_cfg(cfg: ConfigFile) -> int:
	# A blank or unparseable live file is a save cut short; never roll it over the backup.
	if FileAccess.file_exists(UI_CONFIG_PATH) and not _ui_cfg_blank(UI_CONFIG_PATH):
		DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")
	return cfg.save(UI_CONFIG_PATH)

# Godot loads an empty file as OK; beside a backup that is a save cut short (corrupt).
func _ui_cfg_load(cfg: ConfigFile) -> int:
	var err := cfg.load(UI_CONFIG_PATH)
	if err == OK and cfg.get_sections().is_empty() and not _ui_cfg_blank(UI_CONFIG_PATH + ".bak"):
		return ERR_FILE_CORRUPT
	return err

func _ui_cfg_load_bak(cfg: ConfigFile) -> bool:
	var bak := UI_CONFIG_PATH + ".bak"
	return FileAccess.file_exists(bak) and cfg.load(bak) == OK

func _ui_cfg_blank(path: String) -> bool:
	var probe := ConfigFile.new()
	return probe.load(path) != OK or probe.get_sections().is_empty()

func _profile_sec(name: String, suffix: String) -> String:
	return "profile." + name + suffix

func _erase_profile_sections(cfg: ConfigFile, name: String) -> bool:
	var erased := false
	for suffix: String in PROFILE_SUBSECTIONS:
		var sec := _profile_sec(name, suffix)
		if cfg.has_section(sec):
			cfg.erase_section(sec)
			erased = true
	return erased

func _copy_profile_sections(cfg: ConfigFile, from: String, to: String, suffixes: Array) -> void:
	for suffix: String in suffixes:
		var src := _profile_sec(from, suffix)
		var dst := _profile_sec(to, suffix)
		if cfg.has_section(dst):
			cfg.erase_section(dst)
		if cfg.has_section(src):
			for key: String in cfg.get_section_keys(src):
				cfg.set_value(dst, key, cfg.get_value(src, key))

func _get_ui_cfg_value(section: String, key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return default
	return cfg.get_value(section, key, default)

# Saving a cfg that failed to load would replace every profile, so only "missing" passes.
func _load_ui_cfg_for_write() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := _ui_cfg_load(cfg)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		_log_warning("[Config] mod_config.cfg unreadable (error %d); change not saved" % err)
		if not _ui_cfg_refusal_notified and is_instance_valid(_ui_window):
			_ui_cfg_refusal_notified = true
			_show_error_dialog("Settings cannot be saved",
					"Your settings file (mod_config.cfg) cannot be read right now, so changes made in this session will not be saved. Your existing profiles are untouched. Restart the game to recover.")
		return null
	if err == ERR_FILE_NOT_FOUND and _ui_cfg_load_bak(cfg):
		_log_warning("[Config] " + UI_CONFIG_PATH + " is missing; continuing from the .bak contents")
	return cfg

func _set_ui_cfg_value(section: String, key: String, value: Variant) -> void:
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	cfg.set_value(section, key, value)
	_persist_ui_cfg(cfg)

# _ui_mod_entries is replaced on every rescan, so a captured full_path goes stale.
func _live_full_path(profile_key: String, fallback: String) -> String:
	if profile_key == "":
		return fallback
	var live := _live_entry_for_profile_key(profile_key, {})
	if live.is_empty():
		return fallback
	return live["full_path"]

func _live_entry_for_profile_key(profile_key: String, fallback: Dictionary) -> Dictionary:
	if profile_key == "":
		return fallback
	for cur in _ui_mod_entries:
		if cur["profile_key"] == profile_key:
			return cur
	var want_id := _profile_key_id(profile_key)
	if want_id != "":
		for cur in _ui_mod_entries:
			if _profile_key_id(cur["profile_key"]) == want_id:
				return cur
	return fallback

func _rescan_entries() -> void:
	_ui_mod_entries = collect_mod_metadata()
	var cfg := ConfigFile.new()
	_ui_cfg_load(cfg)
	_apply_profile_to_entries(cfg, _active_profile)

func _reload_entries_for_active_profile() -> void:
	_flush_priority_save()
	_rescan_entries()
	# A pack mod that just arrived moves to its own key, or it sits disabled beside a stub row.
	_modpack_reconcile_active()

func _loaded_set_signature() -> String:
	var parts := PackedStringArray()
	# The modified time catches an update that replaced a file under its own name.
	for c in _loadable_enabled_entries()["loadable"]:
		parts.append("%s|%s|%s|%d" % [c["full_path"], c["profile_key"], c["priority"],
				FileAccess.get_modified_time(c["full_path"])])
	parts.append("dev=" + str(_developer_mode))
	parts.append("pack=" + get_active_modpack())
	return "\n".join(parts)

func _post_boot_restart_needed() -> bool:
	return _loaded_set_signature() != _booted_set_signature or _mcm_switch_pending()

func _create_profile(name: String) -> void:
	_flush_priority_save()
	# After boot with a switch pending, the live MCM is another profile's.
	var old := _active_profile
	if old != name and not (_boot_complete and _mcm_switch_pending()):
		_snapshot_mcm_to(old)
	_active_profile = name
	_mods_hide_disabled = false
	_save_ui_config()
	_capture_mcm_into(name, old)
	if _boot_complete:
		var cfg := _load_ui_cfg_for_write()
		if cfg != null:
			_record_pending_mcm_switch(cfg, old, name)
			_persist_ui_cfg(cfg)

func _delete_active_profile() -> void:
	# The late timer would save the deleted profile's state under its successor.
	_priority_save_pending = false
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	var target := _active_profile
	_erase_profile_sections(cfg, target)
	_delete_mcm_snapshot(target)
	var remaining := _list_user_profiles_in_cfg(cfg)
	_active_profile = "Default" if remaining.is_empty() else remaining[0]
	cfg.set_value("settings", "active_profile", _active_profile)
	if _boot_complete:
		_record_pending_mcm_switch(cfg, target, _active_profile, true)
	_persist_ui_cfg(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	if not _boot_complete and _has_mcm_snapshot(_active_profile):
		_restore_mcm_from(_active_profile)

# Same name returns early: snapshot-then-restore would clobber unsaved MCM edits.
func _switch_profile(name: String) -> void:
	var old := _active_profile
	if old == name:
		return
	_flush_priority_save()
	# After boot the mods still write their MCM files (some on exit): the restart swaps.
	if not _boot_complete:
		_snapshot_mcm_to(old)
	_active_profile = name
	var cfg := _load_ui_cfg_for_write()
	if cfg != null:
		cfg.set_value("settings", "active_profile", _active_profile)
		if _boot_complete:
			_record_pending_mcm_switch(cfg, old, name)
		_persist_ui_cfg(cfg)
	else:
		cfg = ConfigFile.new()
		_ui_cfg_load(cfg)
	_apply_profile_to_entries(cfg, _active_profile)
	if not _boot_complete:
		if _has_mcm_snapshot(name):
			_restore_mcm_from(name)
		else:
			_snapshot_mcm_to(name)

# mcm_pending_from owns the live MCM; a second switch keeps `from`, a switch back cancels.
func _record_pending_mcm_switch(cfg: ConfigFile, old: String, name: String, deleted := false) -> void:
	var from := old
	if str(cfg.get_value("settings", "mcm_pending_to", "")) != "":
		from = str(cfg.get_value("settings", "mcm_pending_from", ""))
	if deleted and from == old:
		from = ""
	if name == from:
		cfg.erase_section_key("settings", "mcm_pending_from")
		cfg.erase_section_key("settings", "mcm_pending_to")
		return
	if from != "":
		cfg.set_value("settings", "mcm_pending_from", from)
	else:
		cfg.erase_section_key("settings", "mcm_pending_from")
	cfg.set_value("settings", "mcm_pending_to", name)

func _mcm_switch_pending() -> bool:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return false
	return str(cfg.get_value("settings", "mcm_pending_to", "")) != ""

# Runs before any mod; `from` is erased after its snapshot, before the restore.
func _complete_pending_mcm_switch() -> void:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return
	var to := str(cfg.get_value("settings", "mcm_pending_to", ""))
	if to == "":
		return
	var from := str(cfg.get_value("settings", "mcm_pending_from", ""))
	# Raw saves: the Pass 1 recovery may still need the .bak a rolling save overwrites.
	if from != "":
		_snapshot_mcm_to(from)
		cfg.erase_section_key("settings", "mcm_pending_from")
		if cfg.save(UI_CONFIG_PATH) != OK:
			_log_warning("[Config] Could not save %s; the profile switch to %s is retried next launch" % [UI_CONFIG_PATH, to])
			return
	if _has_mcm_snapshot(to):
		_restore_mcm_from(to)
	else:
		_snapshot_mcm_to(to)
	cfg.erase_section_key("settings", "mcm_pending_to")
	if cfg.save(UI_CONFIG_PATH) != OK:
		_log_warning("[Config] Could not save %s; the profile switch to %s is retried next launch" % [UI_CONFIG_PATH, to])
		return
	_mcm_switch_completed = true
	_log_info("[Config] Completed the recorded profile switch to " + to)

func _rename_profile(new_name: String) -> void:
	var old := _active_profile
	if old == new_name:
		return
	_active_profile = new_name
	_save_ui_config()
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	_copy_profile_sections(cfg, old, new_name, [".settings"])
	_keep_profile_listed(cfg, new_name)
	var key_maps := _collect_live_profile_key_maps()
	for suffix: String in STATE_SUFFIXES:
		var old_sec := _profile_sec(old, suffix)
		if not cfg.has_section(old_sec):
			continue
		var new_sec := _profile_sec(new_name, suffix)
		for key: String in cfg.get_section_keys(old_sec):
			if not cfg.has_section_key(new_sec, key) and _preserve_stored_profile_key(key, key_maps):
				cfg.set_value(new_sec, key, cfg.get_value(old_sec, key))
	_erase_profile_sections(cfg, old)
	for pk: String in ["mcm_pending_from", "mcm_pending_to"]:
		if str(cfg.get_value("settings", pk, "")) == old:
			cfg.set_value("settings", pk, new_name)
	_persist_ui_cfg(cfg)
	var old_slot := MCM_SNAPSHOT_BASE.path_join(old)
	if DirAccess.dir_exists_absolute(old_slot):
		DirAccess.rename_absolute(old_slot, MCM_SNAPSHOT_BASE.path_join(new_name))

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
	for key in _hidden_folder_profile_keys:
		present[key] = true
	for mid in _hidden_folder_ids:
		ids_installed[str(mid).to_lower()] = true
	var missing: Array[String] = []
	for key: String in cfg.get_section_keys(en_sec):
		if not present.has(key) and not _stored_key_migrated(key, ids_installed, key_maps["stems"]):
			missing.append(key)
	missing.sort()
	return missing

func _remove_missing_entries_from_profile(keys: Array) -> void:
	if keys.is_empty():
		return
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	for suffix: String in STATE_SUFFIXES:
		var sec := _profile_sec(_active_profile, suffix)
		for key: String in keys:
			if cfg.has_section_key(sec, key):
				cfg.erase_section_key(sec, key)
	_persist_ui_cfg(cfg)

# Dots would collide with the `profile.<name>.enabled` section path.
func _sanitize_profile_name(raw: String) -> String:
	var trimmed := raw.strip_edges()
	var out := ""
	for i in trimmed.length():
		var c := trimmed.substr(i, 1)
		var u := trimmed.unicode_at(i)
		# A cased letter in any script changes under case folding (admits Cyrillic and Greek).
		var is_letter := c.to_lower() != c.to_upper()
		var is_digit := u >= 48 and u <= 57
		if is_letter or is_digit or c == " " or c == "-" or c == "_":
			out += c
	return out.strip_edges()

func _delete_mod_file_and_cleanup(entry: Dictionary) -> bool:
	var path: String = entry["full_path"]
	if FileAccess.file_exists(path):
		if DirAccess.remove_absolute(path) != OK:
			return false
	var profile_key: String = entry["profile_key"]
	# Profiles not active since a version change key the mod by its old version.
	var mod_id := _profile_key_id(profile_key)
	var still_installed: Dictionary = {}
	for other in _ui_mod_entries:
		if other["profile_key"] != profile_key:
			still_installed[other["profile_key"].to_lower()] = true
	if mod_id != "":
		for dup in entry.get("duplicates_hidden", []):
			still_installed[(mod_id + "@" + str(dup["version"])).to_lower()] = true
	for hk in _hidden_folder_profile_keys:
		still_installed[str(hk).to_lower()] = true
	var cfg := _load_ui_cfg_for_write()
	if cfg != null:
		var profiles := _list_profiles_in_cfg(cfg)
		for section in cfg.get_sections():
			if not section.begins_with("profile."):
				continue
			var sec_suffix := ""
			for suffix: String in STATE_SUFFIXES:
				if section.ends_with(suffix):
					sec_suffix = suffix
			if sec_suffix == "":
				continue
			# A pack slot keeps declaring the mod; its backup slot is the player's own.
			if section.substr(8, section.length() - 8 - sec_suffix.length()).begins_with(MODPACK_PROFILE_PREFIX):
				continue
			for key: String in cfg.get_section_keys(section):
				if key == profile_key \
						or (mod_id != "" and _profile_key_id(key) == mod_id and not still_installed.has(key.to_lower())):
					cfg.erase_section_key(section, key)
		for name in profiles:
			_keep_profile_listed(cfg, name)
		_persist_ui_cfg(cfg)
	return true

func _move_profile_key(old_key: String, new_key: String) -> void:
	if old_key == "" or new_key == "" or old_key == new_key:
		return
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	var changed := false
	for section in cfg.get_sections():
		var movable := section == "mod_sources"
		if section.begins_with("profile."):
			for suffix: String in STATE_SUFFIXES:
				movable = movable or section.ends_with(suffix)
		if not movable or not cfg.has_section_key(section, old_key):
			continue
		if not cfg.has_section_key(section, new_key):
			cfg.set_value(section, new_key, cfg.get_value(section, old_key))
		cfg.erase_section_key(section, old_key)
		changed = true
	if changed:
		_persist_ui_cfg(cfg)
