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
	# 220px). Clamped to the live launcher size -- the fixed 600x520 was
	# taller than the launcher's 640x420 minimum and got clipped.
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

	# Plain-language explanation of what saving a modpack actually does, so the
	# feature is self-explanatory without docs: it is a shareable LIST of the
	# enabled mods, not a bundle of the mod files; applying it elsewhere
	# re-downloads them from ModWorkshop. Shown on both the clean and the
	# orphan paths.
	var intro := Label.new()
	intro.text = "A modpack is a shareable list of your enabled mods -- not the mod files themselves. Send the saved file to anyone: when they apply it they get this exact setup, and the mods download from ModWorkshop automatically."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", COL_TEXT)
	intro.add_theme_font_size_override("font_size", FS_BODY)
	box.add_child(intro)
	box.add_child(HSeparator.new())

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
		warn_hdr.text = "%d enabled mod(s) have no ModWorkshop ID:" % orphans.size()
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
	# Keep the dialog open until the save actually succeeds: freeing the
	# form BEFORE validating meant a name collision (or invalid name)
	# destroyed the typed name/author/description and the user had to
	# retype everything. Same inline-error pattern as New/Rename profile.
	d.dialog_hide_on_ok = false
	# Error label OUTSIDE the scroll (sibling of it) so it is always
	# visible above the button bar regardless of scroll position.
	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.add_child(err_lbl)
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
			if pack_name == "":
				pack_name = profile_to_save
			# Remember author across saves -- avoids forcing the user to
			# retype their handle every modpack. Cleared if they explicitly
			# blank it out.
			_save_preferred_author(author)
			# Validate/save BEFORE freeing the dialog (dialog_hide_on_ok is
			# false): on any failure -- name collision, invalid name, export
			# error -- the form survives with everything typed and the error
			# shows inline instead of in a dialog over a destroyed form.
			var result := save_profile_as_modpack(profile_to_save, pack_name, desc, author)
			if not bool(result.get("ok", false)):
				err_lbl.text = str(result.get("error", "unknown"))
				return
			d.queue_free()
			_rebuild_modpacks_tab(tabs)
			# Confirm what happened, where the file is, and how to share it --
			# the save is otherwise silent, leaving the user unsure it worked.
			_show_modpack_saved_dialog(
				str(result.get("display_name", pack_name)),
				int(result.get("mod_count", 0)),
				str(result.get("path", ""))),
		func(): d.queue_free())
	d.popup_centered()

# Post-save confirmation for "Save as modpack". States plainly that it worked,
# how many mods went in, the exact file path, and the one-step way to share it,
# so the whole create-and-share loop is understandable without documentation.
# OK opens the mods folder (so the user can grab the file); Close dismisses.
func _show_modpack_saved_dialog(display_name: String, mod_count: int, path: String) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Modpack saved"
	var count_phrase := ""
	if mod_count == 1:
		count_phrase = " with 1 mod"
	elif mod_count > 1:
		count_phrase = " with %d mods" % mod_count
	var where := "\n\n" + path if path != "" else ""
	d.dialog_text = "Saved \"%s\"%s to your mods folder.%s\n\nTo share it, send that file to anyone. When they drop it in their mods folder and open the Modpacks tab, they apply it in one click -- the mods download from ModWorkshop automatically." \
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
# MCM/ snapshot of user://MCM/. Returns {"ok": true, "mod_count": int} or
# {"error": "..."}. mod_count is how many enabled mods the pack contains, so
# the caller's success message can be specific. Cleans up partial output on
# any failure path so a corrupt half-zip doesn't survive to confuse the user
# (or block a retry).
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
	# Count the enabled mods from the payload we just wrote so the caller can
	# say "saved with N mods" without re-deriving it. Parse failure is
	# non-fatal -- the save succeeded, we just report an unknown count.
	var mod_count := 0
	var parsed_v: Variant = JSON.parse_string(json_str)
	if parsed_v is Dictionary and (parsed_v as Dictionary).get("enabled") is Dictionary:
		mod_count = ((parsed_v as Dictionary)["enabled"] as Dictionary).size()
	return {"ok": true, "mod_count": mod_count}

# Write an MCM data map (relative_path -> bytes) into a profile's snapshot
# slot. Replaces any existing snapshot. Used by the modpack apply path
# (_materialize_modpack_profile) before the profile swap restores from this
# slot. Always creates the destination
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
		# Same unchecked-write hazard as _copy_dir_recursive: store_buffer
		# returns bool since 4.3, and a full disk truncates silently.
		if not f.store_buffer(bytes):
			_log_warning("[MCM] Failed writing " + dst + " (disk full?) -- snapshot incomplete")
		f.close()

# Metroprofile v1 schema is LOCKED at 3.0.1. Full spec (wrapper format, JSON
# shape, profile key format, forward-compat rules, round-trip guarantees) is
# in the wiki: docs/wiki/Profile-Format.md. Changes to the export/import
# shape require bumping the schema version so old parsers reject cleanly.

# Serialize the named profile to a JSON string. Used as the inner layer of
# _export_profile_to_zip (modpack save); exposed separately in case we need
# it for debugging or tests. Empty string if the profile has no stored sections.
# CONTRACT: this is the ONE writer of the metroprofile v1 payload, but the
# payload is parsed independently in several places. Profile-STATE fields
# (the enabled/priority/dep_ignore family, materialized into config
# sections) must be read by the single state consumer,
# _materialize_modpack_profile (modpacks.gd, modpack apply), or the field
# silently drops. Metadata fields may instead need their own readers
# ("sources", for example, is read only by _missing_mod_sources_combined,
# _get_missing_mods_for_modpack and the modpack detail dialog, not by the
# state consumer above), and _validate_modpack (modpacks.gd) pre-checks
# schema/name/enabled. Keep new fields optional
# (docs/wiki/Profile-Format.md forward-compat rules) and document them there.
func _profile_to_json_string(profile_name: String, description: String = "", author: String = "", display_name: String = "") -> String:
	# display_name is the modpack's own name (the payload "name" field). When
	# empty it falls back to the profile name -- so a caller that doesn't name
	# the pack keeps the old behavior. profile_name still selects which
	# profile's config sections we read.
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

