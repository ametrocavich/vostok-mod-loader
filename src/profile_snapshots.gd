## Per-profile MCM snapshots: user://.profile_snapshots/<profile>/MCM/.
## After boot user://MCM belongs to the running mods; edits copy slots and the restart swaps.

func _mcm_snapshot_dir(profile_name: String) -> String:
	return MCM_SNAPSHOT_BASE.path_join(profile_name).path_join("MCM")

func _has_mcm_snapshot(profile_name: String) -> bool:
	return DirAccess.dir_exists_absolute(_mcm_snapshot_dir(profile_name))

# Dot-prefixed entries are skipped; profile and MCM swaps rely on that.
func _copy_dir_recursive(src: String, dst: String) -> void:
	if not DirAccess.dir_exists_absolute(src):
		return
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return
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
			continue
		var src_f := FileAccess.open(src_full, FileAccess.READ)
		if src_f == null:
			continue
		var bytes := src_f.get_buffer(src_f.get_length())
		src_f.close()
		var dst_f := FileAccess.open(dst_full, FileAccess.WRITE)
		if dst_f == null:
			_log_warning("[MCM] Cannot open " + dst_full + " for write -- copy incomplete")
			continue
		if not dst_f.store_buffer(bytes):
			_log_warning("[MCM] Failed writing " + dst_full + " (disk full?) -- copy incomplete")
		dst_f.close()
	dir.list_dir_end()

# Fill a profile's slot from `src` (the live MCM, or another slot). A missing
# source still leaves an empty slot, or the profile would later seed from another's MCM.
func _snapshot_mcm_to(profile_name: String, src := MCM_SOURCE_DIR) -> void:
	var dst := _mcm_snapshot_dir(profile_name)
	_remove_tree(dst, false)
	DirAccess.make_dir_recursive_absolute(dst)
	_copy_dir_recursive(src, dst)

# False when the profile has no snapshot; the live folder is then left alone.
# The restore is wholesale: a partial overlay would leak old files.
func _restore_mcm_from(profile_name: String) -> bool:
	var src := _mcm_snapshot_dir(profile_name)
	if not DirAccess.dir_exists_absolute(src):
		return false
	_remove_tree(MCM_SOURCE_DIR, false)
	_copy_dir_recursive(src, MCM_SOURCE_DIR)
	return true

# Fill `dst_profile`'s slot with `owner_profile`'s MCM: after boot with a switch
# pending the live folder belongs to another profile, so the owner's slot is the truth.
func _capture_mcm_into(dst_profile: String, owner_profile: String) -> void:
	if _boot_complete and _mcm_switch_pending():
		# An owner with no slot is seeded from the live folder at the restart, so seed it now.
		if not _has_mcm_snapshot(owner_profile):
			_snapshot_mcm_to(owner_profile)
		_snapshot_mcm_to(dst_profile, _mcm_snapshot_dir(owner_profile))
	else:
		_snapshot_mcm_to(dst_profile)

# A slot can hold files beside its MCM/ tree, so the whole directory goes.
func _delete_mcm_snapshot(profile_name: String) -> void:
	_remove_tree(MCM_SNAPSHOT_BASE.path_join(profile_name), false)

# Write {relative_path: bytes} into a profile's slot. The directory exists even for
# empty data, or the switch would seed the slot from the previous profile.
func _write_mcm_snapshot_from_data(profile_name: String, mcm_data: Dictionary) -> void:
	var dst_base := _mcm_snapshot_dir(profile_name)
	_remove_tree(dst_base, false)
	DirAccess.make_dir_recursive_absolute(dst_base)
	for rel_v in mcm_data:
		var dst := dst_base.path_join(str(rel_v))
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			continue
		if not f.store_buffer(mcm_data[rel_v]):
			_log_warning("[MCM] Failed writing " + dst + " (disk full?) -- snapshot incomplete")
		f.close()
