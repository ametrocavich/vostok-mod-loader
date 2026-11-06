## LTSTestCore's output, runner and undo helpers and its network checks N0-N3;
## Main.gd extends it. Never ships to players.
extends Node

const TAG := "[LTSTEST]"
# The game log is buffered and lost when the game crashes on exit; this copy is flushed.
const PROGRESS := "user://ltstest_core_progress.txt"
# Fixed by install.sh and fixtures/pack/profile.json.
const TEST_PROFILE := "LTSTest"
const TEMP_PROFILE := "LTSTemp"
const PACK_FILE := "LTSTestPack.zip"
const PACK_NAME := "LTS Test Pack"

var _lib = null
var _pass := 0
var _fail := 0
var _cur_id := ""
var _cur_title := ""
var _cur_done := false
# label -> Callable undoing a change no check has undone yet; _drain runs them newest first.
var _undo: Dictionary = {}
var _tabs = null
var _pack_entry: Dictionary = {}
var _net_candidates: Array = []
var _net_ref: Dictionary = {}
var _net_detail: Dictionary = {}
var _net_skip_reason := ""

func _mark(step: String) -> void:
	var f := FileAccess.open(PROGRESS, FileAccess.READ_WRITE if FileAccess.file_exists(PROGRESS) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%s %s" % [Time.get_time_string_from_system(), step])
	f.flush()
	f.close()

func _line(text: String) -> void:
	print("%s %s" % [TAG, text])
	_mark(text)

func _emit(kind: String, id: String, title: String, detail: String) -> void:
	_line("%s %s %s: %s" % [kind, id, title, detail])

func _report(ok: bool, detail: String) -> void:
	_pass += int(ok)
	_fail += int(not ok)
	_emit("PASS" if ok else "FAIL", _cur_id, _cur_title, detail)
	_cur_done = true

func _summary(phase: String) -> void:
	_line("SUMMARY %s %d pass %d fail" % [phase, _pass, _fail])
	_pass = 0
	_fail = 0

func _begin(id: String, title: String) -> void:
	_mark("step " + id)
	_cur_id = id
	_cur_title = title
	_cur_done = false

# Runs [id, title, Callable] checks in order; a check stopped by a script error reports nothing itself.
func _run_all(checks: Array) -> void:
	for c in checks:
		_begin(c[0], c[1])
		await c[2].call()
		if not _cur_done:
			_report(false, "the check stopped before reporting (see SCRIPT ERROR in the game log)")

func _track(verb: String, section: String, id: String, pending: bool) -> void:
	var key := "%s %s/%s" % [verb, section, id]
	if pending:
		_undo[key] = Callable(_lib, verb).bind(section, id)
	else:
		_undo.erase(key)

# A registry verb; a change queues its undo, a successful undo drops it.
func _verb(verb: String, section: String, id: String, data = null) -> bool:
	var ok: bool = _lib.call(verb, section, id) if data == null else _lib.call(verb, section, id, data)
	if ok:
		var undo := "remove" if verb in ["register", "remove"] else "revert"
		_track(undo, section, id, verb in ["register", "patch", "override"])
	return ok

func _drain(what: String) -> void:
	var done := PackedStringArray()
	var keys := _undo.keys()
	keys.reverse()
	for key in keys:
		var result := str(_undo[key].call())
		if result != "":
			done.append("%s -> %s" % [key, result])
	_undo.clear()
	if not done.is_empty():
		_emit("INFO", "CLEANUP", what, "; ".join(done))

func _cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(_lib.UI_CONFIG_PATH)
	return cfg

func _cfg_has_profile(cfg: ConfigFile, profile: String) -> bool:
	for sec in cfg.get_sections():
		if sec.begins_with("profile." + profile + "."):
			return true
	return false

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _ui_window():
	var win = _lib._ui_window
	return win if is_instance_valid(win) else null

# U2-U4 work in U1's window; false, with a FAIL, once it is gone.
func _need_ui(why: String) -> bool:
	if _ui_window() != null and is_instance_valid(_tabs):
		return true
	_report(false, "no launcher window (%s)" % why)
	return false

func _newest_confirmation(win) -> Variant:
	var dialogs: Array = win.get_children().filter(func(c): return c is ConfirmationDialog)
	return null if dialogs.is_empty() else dialogs.back()

# Never leave LTSTemp behind or the booted profile switched away.
func _restore_profiles() -> String:
	var did := PackedStringArray()
	if _cfg_has_profile(_cfg(), TEMP_PROFILE):
		_lib._switch_profile(TEMP_PROFILE)
		if str(_lib._active_profile) == TEMP_PROFILE:
			_lib._delete_active_profile()
			did.append("deleted " + TEMP_PROFILE)
	if str(_lib._active_profile) != TEST_PROFILE:
		_lib._switch_profile(TEST_PROFILE)
		did.append("switched back to " + TEST_PROFILE)
	return "" if did.is_empty() else "%s; pending MCM swap %s" % [", ".join(did), str(_lib._mcm_switch_pending())]

func _restore_pack() -> String:
	var active := str(_lib.get_active_modpack())
	var did := PackedStringArray()
	if active != "" and active == str(_pack_entry.get("sanitized_name", PACK_NAME)):
		did.append("unloaded %s: %s" % [active, str(_lib.unload_modpack(null))])
	did.append(_restore_profiles())
	return "; ".join(did).trim_suffix("; ")

func _network_phase() -> void:
	await _run_all([["N0", "network", _check_network_list]])
	if _net_skip_reason == "":
		await _run_all([["N1", "detail", _check_network_detail], ["N2", "download end to end", _check_network_download],
				["N3", "cover image", _check_network_cover]])
	_drain("download")

func _check_network_list() -> void:
	var res = await _lib.host_list_mods(_lib.HOST_VOSTOKMODS, {"cursor": "", "limit": 20})
	if not (res is Dictionary):
		res = {"code": "", "message": "host_list_mods returned %s" % str(res)}
	if not bool(res.get("ok", false)):
		var code := str(res.get("code", ""))
		_net_skip_reason = "%s (%s)" % [code, str(res.get("message", ""))]
		if code == _lib.HOST_ERR_OFFLINE or code == _lib.HOST_ERR_RATE_LIMITED:
			_emit("INFO", "N0", "offline", _net_skip_reason)
			_cur_done = true
			return
		_report(false, "host_list_mods failed: " + _net_skip_reason)
		# N1-N3 fail too when N0 failed for a reason other than being offline.
		for id in ["N1", "N2", "N3"]:
			_emit("FAIL", id, "not run", "N0 failed: " + _net_skip_reason)
			_fail += 1
		return
	var rows: Array = res["data"].get("rows", [])
	for row in rows:
		if row is Dictionary and str(row.get("default_file_id", "")) != "" \
				and _lib._mod_ids_installed_from(row["ref"]).is_empty():
			_net_candidates.append(row)
	# Rows with a cover image first; N1 picks the smallest file among the first three.
	_net_candidates.sort_custom(func(a, b) -> bool:
		return str(a["thumbnail"].get("url", "")) != "" and str(b["thumbnail"].get("url", "")) == "")
	_net_candidates = _net_candidates.slice(0, 3)
	_report(not rows.is_empty(), "%d row(s) on the first page" % rows.size())

func _check_network_detail() -> void:
	if _net_candidates.is_empty():
		_report(false, "no downloadable row that is not already installed on the first page")
		return
	var best = _net_candidates[0]
	var best_size := -1
	var sizes := PackedStringArray()
	for row in _net_candidates:
		var file = await _lib.host_resolve_file(row["ref"], "")
		var size: int = int(file["data"].get("size", -1)) if file is Dictionary and bool(file.get("ok", false)) else -1
		sizes.append("%s=%d" % [str(_lib.host_ref_key(row["ref"])), size])
		if size > 0 and (best_size < 0 or size < best_size):
			best = row
			best_size = size
	var ref: Dictionary = best["ref"]
	var res = await _lib.host_get_mod(ref)
	var ok: bool = res is Dictionary and bool(res.get("ok", false)) and str(res["data"].get("name", "")) != ""
	if ok:
		_net_ref = ref
		_net_detail = res["data"]
	_report(ok, "%s: name \"%s\", file sizes %s" % [str(_lib.host_ref_key(ref)),
			str(res["data"].get("name", "")) if ok else str(res), ", ".join(sizes)])

func _check_network_download() -> void:
	if _net_ref.is_empty():
		_report(false, "no mod picked (N1 failed)")
		return
	var res = await _lib.download_mod_from_ref(_net_ref, "", true, "")
	if not (res is Dictionary) or not bool(res.get("ok", false)):
		_report(false, "download failed: %s" % str(res))
		return
	var file := str(res.get("file_name", ""))
	var path := str(_lib._mods_dir_path()).path_join(file)
	# Named before the delete, so a crash here leaves the file findable.
	_mark("N2 downloaded " + path)
	_undo["download " + file] = _remove_download.bind(path)
	var landed := FileAccess.file_exists(path)
	var deleted := _delete_downloaded(path)
	var listed := false
	for e in _lib.collect_mod_metadata():
		listed = listed or str(e.get("file_name", "")) == file
	var gone := not FileAccess.file_exists(path) and not listed
	if gone:
		_undo.erase("download " + file)
	_report(landed and deleted and gone, "%s landed %s; deleted through the loader %s; gone and unlisted %s" \
			% [path, str(landed), str(deleted), str(gone)])

# The Mods tab's Remove path: delete the file, strip its profile keys, rescan.
func _delete_downloaded(path: String) -> bool:
	_lib._reload_entries_for_active_profile()
	var entry = null
	for e in _lib._ui_mod_entries:
		if str(e.get("full_path", "")) == path:
			entry = e
	if entry == null:
		for e in _lib.collect_mod_metadata():
			if str(e.get("full_path", "")) == path:
				entry = e
	var ok: bool = _lib._delete_mod_file_and_cleanup(entry if entry != null else {"full_path": path, "profile_key": ""})
	_lib._reload_entries_for_active_profile()
	return ok

func _remove_download(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	if not _delete_downloaded(path):
		DirAccess.remove_absolute(path)
	return "%s removed %s" % [path, str(not FileAccess.file_exists(path))]

func _check_network_cover() -> void:
	if _net_detail.is_empty():
		_report(false, "no mod detail (N1 failed)")
		return
	var image: Dictionary = _net_detail.get("thumbnail", {})
	if str(image.get("url", "")) == "":
		image = _net_detail.get("banner", {})
	if str(image.get("url", "")) == "":
		_emit("INFO", "N3", "cover image", "the picked mod has no cover image; nothing to load")
		_cur_done = true
		return
	var key := str(image.get("cache_key", ""))
	var cached_before := key != "" and FileAccess.file_exists(str(_lib.UI_CACHE_DIR).path_join("thumbs").path_join(key))
	var rect := TextureRect.new()
	Callable(_lib, "_browse_load_thumbnail_async").call_deferred(rect, image)
	var waited := 0.0
	while rect.texture == null and waited < 10.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	var got := rect.texture != null
	# The loader paints the texture last, so once it is set nothing holds the
	# rect; on a timeout the request may still finish, so the rect is kept.
	if got:
		rect.free()
	_report(got, "texture %s after %.2f s (cached before %s) from %s" \
			% [str(got), waited, str(cached_before), str(image.get("url", ""))])
