## Copy, restore, rename and delete per-profile MCM snapshots.
## Called by profile switching and modpack apply/unload.

# --- MCM snapshot mechanic ------------------------------------------------
# Each user profile owns a snapshot of user://MCM/ at
# user://.profile_snapshots/<profile>/MCM/. Switching snapshots the outgoing
# profile's MCM, then restores (or seeds) the incoming one; switching to
# Vanilla leaves user://MCM/ untouched.

func _mcm_snapshot_dir(profile_name: String) -> String:
	return MCM_SNAPSHOT_BASE.path_join(profile_name).path_join("MCM")

func _has_mcm_snapshot(profile_name: String) -> bool:
	return DirAccess.dir_exists_absolute(_mcm_snapshot_dir(profile_name))

# Copy src/ into dst/, overwriting matching files. Callers remove stale trees.
# Returns true after processing an entry, not proof that every copy succeeded.
# Dot-prefixed entries are skipped; profile and MCM swaps rely on that.
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

func _snapshot_mcm_to(profile_name: String) -> bool:
	var dst := _mcm_snapshot_dir(profile_name)
	# Wipe stale snapshot first so deleted-from-MCM files don't survive.
	_remove_tree(dst, false)
	return _copy_dir_recursive(MCM_SOURCE_DIR, dst)

# Replace user://MCM/ with a profile's snapshot. False when the profile has no
# snapshot, and the live folder is then left alone. An empty snapshot is a
# valid one: it restores to no MCM settings.
func _restore_mcm_from(profile_name: String) -> bool:
	var src := _mcm_snapshot_dir(profile_name)
	if not DirAccess.dir_exists_absolute(src):
		return false
	# Wholesale; a partial overlay would leak old files.
	_remove_tree(MCM_SOURCE_DIR, false)
	_copy_dir_recursive(src, MCM_SOURCE_DIR)
	return true

# Remove a profile's whole snapshot slot. A slot can hold files beside the
# MCM/ tree, so the directory goes as a tree.
func _delete_mcm_snapshot(profile_name: String) -> void:
	_remove_tree(MCM_SNAPSHOT_BASE.path_join(profile_name), false)

func _rename_mcm_snapshot(old_name: String, new_name: String) -> void:
	var old_parent := MCM_SNAPSHOT_BASE.path_join(old_name)
	var new_parent := MCM_SNAPSHOT_BASE.path_join(new_name)
	if not DirAccess.dir_exists_absolute(old_parent):
		return
	DirAccess.make_dir_recursive_absolute(MCM_SNAPSHOT_BASE)
	var da := DirAccess.open(MCM_SNAPSHOT_BASE)
	if da != null:
		da.rename(old_name, new_name)

# Write an MCM data map (relative_path -> bytes) into a profile's snapshot
# slot. Creates the dir even when mcm_data is empty, or _has_mcm_snapshot
# would be false and _switch_profile would seed from the previous profile.
func _write_mcm_snapshot_from_data(profile_name: String, mcm_data: Dictionary) -> void:
	var dst_base := _mcm_snapshot_dir(profile_name)
	_remove_tree(dst_base, false)
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

