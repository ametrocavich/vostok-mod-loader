## Launch-time housekeeping from _run_pass_1: interrupted downloads, cache zips
## whose source mod is gone, and retired user:// state.

func _clean_stale_cache() -> void:
	# An interrupted download leaves <name>.download in mods/; the scan ignores
	# it and nothing else would remove it.
	var mods_names_ci: Dictionary = {}
	if not _mods_dir.is_empty():
		var mdir := DirAccess.open(_mods_dir)
		if mdir != null:
			mdir.list_dir_begin()
			while true:
				var mname := mdir.get_next()
				if mname == "":
					break
				if mdir.current_is_dir():
					continue
				if mname.get_extension().to_lower() == "download":
					DirAccess.remove_absolute(_mods_dir.path_join(mname))
					_log_debug("Removed interrupted download: " + mname)
					continue
				mods_names_ci[mname.to_lower()] = true
			mdir.list_dir_end()
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname.ends_with(".zip.src"):
			if not FileAccess.file_exists(cache_dir.path_join(fname.trim_suffix(".src"))):
				DirAccess.remove_absolute(cache_dir.path_join(fname))
				_log_debug("Removed orphan cache sidecar: " + fname)
			continue
		if fname.get_extension().to_lower() != "zip":
			continue
		var base := fname.get_basename()
		# Compared without case: a Linux player's X.VMZ is the same archive. A
		# vmz whose own stem ends in _dev matches here before the folder check.
		if mods_names_ci.has((base + ".vmz").to_lower()):
			continue
		var folder := _mods_dir.path_join(base.trim_suffix("_dev"))
		if base.ends_with("_dev") and DirAccess.dir_exists_absolute(folder):
			continue
		DirAccess.remove_absolute(cache_dir.path_join(fname))
		_static_remove_file(cache_dir.path_join(fname + ".src"))
		_log_debug("Removed stale cache: " + fname)
	dir.list_dir_end()

func _remove_retired_state() -> void:
	var backups := ProjectSettings.globalize_path("user://.modpack_backups")
	if DirAccess.dir_exists_absolute(backups):
		_remove_tree(backups, false)
		_log_info("Removed the unused directory user://.modpack_backups")
