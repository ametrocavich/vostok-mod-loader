## The neutered loader with its network leaves replaced by fixtures. Setting fixture_dir also
## stubs download_mod_from_ref: ids "fail-*" fail, "have-*" are on disk, "cancel-*" press Cancel.
extends "res://modloader_neutered.gd"

var stub_details := {}
var stub_archive := ""
var stub_headers := PackedStringArray()
var stub_requests: Array = []
var fixture_dir := ""
var calls: Array = []

func _vmp_detail(id: String, ttl_ms: int = _VM_TTL_DETAIL_MS) -> Dictionary:
	if not stub_details.has(id):
		return host_err(HOST_ERR_NOT_FOUND, 404, "no fixture for " + id)
	return host_ok(stub_details[id])

func _http_download_to_temp(provider: String, url: String, headers: PackedStringArray,
		temp_path: String, expected_sha256: String = "") -> Dictionary:
	stub_requests.append({"provider": provider, "url": url, "headers": headers,
			"temp_path": temp_path, "sha256": expected_sha256})
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	if stub_archive == "" or DirAccess.copy_absolute(stub_archive, temp_path) != OK:
		return {"ok": false, "error": "stub transfer failed", "headers": PackedStringArray()}
	return {"ok": true, "error": "", "headers": stub_headers}

## Without fixture_dir the shipped download runs, through the two stubs above.
func download_mod_from_ref(ref: Dictionary, version: String = "", allow_rename: bool = false,
		expected_sha256: String = "") -> Dictionary:
	if fixture_dir == "":
		return await super(ref, version, allow_rename, expected_sha256)
	var id := str(ref.get("id", ""))
	calls.append(id)
	if id.begins_with("fail-"):
		return {"ok": false, "file_name": "", "error": "Download failed (HTTP 500)"}
	if id.begins_with("have-"):
		return {"ok": false, "file_name": "", "code": DOWNLOAD_ALREADY_INSTALLED, "error": "Already have a file named " + id + ".zip in the mods folder"}
	if DirAccess.copy_absolute(fixture_dir.path_join(id + ".zip"), _mods_dir.path_join(id + ".zip")) != OK:
		return {"ok": false, "file_name": "", "error": "stub: no fixture for " + id}
	if id.begins_with("cancel-"):
		_modpack_apply_cancelled = true
	return {"ok": true, "file_name": id + ".zip", "error": ""}
