## Launcher UI harness: T1..T5, T7, T8 and T10..T36 assert helpers, seams, Browse kinds, the Modpacks tab, covers and the launch label; T9 dumps every surface for check_ui.sh.
## A dump records properties, not pixels; host requests fail as offline (the loader stays out of the tree).
extends "res://runner_base.gd"

const DUMP_PATH := "res://ui_dump.txt"
const MODS_DIR := "user://mods"
const PACK_ZIP := "user://mods/crafted_pack.zip"
const PACKS_DIR := "user://t14_mods"

## The loader with the mod and pack lists, manifest, import and covers served from fields; links asked are kept.
## With gated set, each list call waits until the test opens its gate.
class PackStub extends "res://stub_loader.gd":
	var pages: Array = []
	var asked: Array = []
	var manifest := {}
	var imports: Array = []
	var links: Array = []
	var hold := false
	var gated := false
	var gates: Array = []
	var mod_row := {}
	var mod_lists := 0

	func host_list_mods(_provider: String, _q: Dictionary) -> Dictionary:
		mod_lists += 1
		return host_ok(host_page([mod_row], false, "", 1))

	func host_list_categories(_provider: String) -> Dictionary:
		return host_err(HOST_ERR_OFFLINE, 0, "offline")

	func _vmp_list_modpacks(q: Dictionary) -> Dictionary:
		asked.append(q)
		var page: Dictionary = pages.pop_front() if not pages.is_empty() else host_err(HOST_ERR_OFFLINE, 0, "offline")
		if gated:
			var gate := {"open": false}
			gates.append(gate)
			while not gate["open"]:
				await Engine.get_main_loop().process_frame
		return page

	func _vmp_fetch_modpack_manifest(_url: String) -> Dictionary:
		return host_ok(manifest) if not manifest.is_empty() else host_err(HOST_ERR_OFFLINE, 0, "offline")

	func _vmp_modpack_detail(_slug: String) -> Dictionary:
		return host_err(HOST_ERR_OFFLINE, 0, "offline")

	func _hosted_pack_from_link(text: String) -> Dictionary:
		links.append(text)
		while hold:
			await Engine.get_main_loop().process_frame
		return imports.pop_front()

	var thumb_body := PackedByteArray()
	var thumb_urls: Array = []
	var thumb_hold := false

	func _fetch_thumb(url: String) -> PackedByteArray:
		thumb_urls.append(url)
		while thumb_hold:
			await Engine.get_main_loop().process_frame
		return thumb_body

## The loader with every force-unload call kept; the real one runs.
class ForceStub extends "res://stub_loader.gd":
	var forced: Array = []

	func force_unload_modpack(tabs: TabContainer) -> Dictionary:
		forced.append(tabs)
		return super(tabs)

## The loader with no tabs and no update check; host_get_mod answers "done" at
## once and holds every other ref while hold is set.
class MetaStub extends "res://stub_loader.gd":
	var hold := true

	func _check_modloader_update_async() -> void:
		pass

	func _ui_add_tabs(_tabs: TabContainer) -> void:
		pass

	func host_get_mod(ref: Dictionary) -> Dictionary:
		await Engine.get_main_loop().process_frame
		while hold and str(ref["id"]) != "done":
			await Engine.get_main_loop().process_frame
		var mod := host_empty_summary()
		mod["ref"] = ref
		return host_ok(mod)

## The loader with the content-mod confirm answered from a field and no cfg save.
class ToggleStub extends "res://stub_loader.gd":
	var answer := true
	var confirms: Array = []
	var install := {}

	func _confirm_disable_content_mod(mod_name: String, _count: int = 1) -> bool:
		confirms.append(mod_name)
		return answer

	func _browse_install_map() -> Dictionary:
		return install

	func _save_ui_config() -> void:
		pass

## The loader with every queued metadata fetch kept, not sent.
class FetchStub extends "res://stub_loader.gd":
	var fetched: Array = []

	func _fetch_meta_queued(ref: Dictionary) -> void:
		fetched.append(host_ref_key(ref))

var _out: PackedStringArray = []
var _user_abs := ""
var _version := ""

func _init() -> void:
	super("ui", "T1..T5, T7, T8 and T10..T36")
	max_frames = 600

func _run() -> void:
	var ml := boot_loader()
	if ml == null:
		_finish()
		return
	ml._compile_regex()
	# _has_loaded keeps _ready from booting the loader while it is in the tree.
	ml.set("_has_loaded", true)
	ml.set("_mods_dir", MODS_DIR)
	_version = str(ml.MODLOADER_VERSION)
	_user_abs = ProjectSettings.globalize_path("user://").trim_suffix("/")
	H.wipe_user()
	DirAccess.make_dir_recursive_absolute(MODS_DIR)

	var win := Window.new()
	win.size = Vector2i(1600, 1000)
	root.add_child(win)
	ml.set("_ui_window", win)
	_t1_browse_meta_and_gate(ml)
	_t2_browse_view_record(ml)
	_t3_confirm_and_active_state(ml)
	_t4_progress_callback(ml)
	_t5_progress_cancel_and_finish(ml)
	# The progress and error dialogs are exclusive; a second one would be refused.
	for c in win.get_children():
		win.remove_child(c)
		c.free()
	_t7_detail_sections(ml)
	_t8_failure_dialog_retry(ml)
	await _t12_pager_hooks(ml)
	_t13_row_frame_and_banner(ml)
	await _t14_to_t18_packs(win)
	await _t19_force_unload_confirm(win)
	await _t20_launch_saves_the_meta_sidecar()
	_t31_scale_setting_clamp(ml)
	await _t32_scale_fits_area()
	_t33_meta_refresh_window()
	await _t34_content_mod_confirm()
	_t35_menu_button_order(ml)
	ml.set("_ui_window", null)
	win.queue_free()
	await _settle()

	await _dump_all(ml)
	H.write_text(DUMP_PATH, "\n".join(_out) + "\n")
	ml.free()
	_report.scope = "T1..T5, T7, T8 and T10..T36, dump of %d line(s) written for T9" % _out.size()
	_finish()

func _t1_browse_meta_and_gate(ml: Object) -> void:
	begin("T1")
	var summary := {"author_name": "bob", "version": "1.0", "downloads": 0, "likes": 0, "views": 5,
		"category_name": "Guns", "updated_at": "", "default_file_id": "", "resolve_file": true}
	check_eq(ml._browse_meta_text(summary, PackedStringArray(["downloads", "likes", "views"])),
			"by bob - v1.0 - 0 downloads - 5 views - Guns", "meta line")
	for c in [
		[summary, true, false, true, "an unlisting host offers every file"],
		[summary, true, true, false, "no default file, no Download"],
		[{"default_file_id": "f1"}, true, true, true, "a default file offers Download"],
		[{"default_file_id": "f1"}, false, false, false, "no file resolving, no Download"],
	]:
		check_eq(bool(ml._browse_can_download(c[0], {"resolve_file": c[1], "lists_downloadable": c[2]})), c[3], c[4])
	check_eq(ml._rate_wait_text("Vostok Mods", 7), "Rate limited by Vostok Mods -- resuming in 7s", "rate-wait copy")

func _t2_browse_view_record(ml: Object) -> void:
	begin("T2")
	var v: Dictionary = ml._browse_make_view("vostokmods")
	_assert(v.has("sort_key") and v.has("sort_field") and v.has("sort_label") and not v.has("shown_count"),
			"view keys " + str(v.keys()))
	check_eq(v["sort_key"], (ml.host_sorts("vostokmods")[0] as Dictionary)["key"], "first sort")
	_assert(not bool(ml._browse_alive({"list": null})), "a null list is not alive")
	var n := Node.new()
	n.add_child(Node.new())
	_assert(bool(ml._browse_alive({"list": n})), "a live list is alive")
	ml._clear_children(n)
	_assert(n.get_child(0).is_queued_for_deletion(), "_clear_children queues every child")
	n.free()

func _t3_confirm_and_active_state(ml: Object) -> void:
	begin("T3")
	check_eq(ml._apply_confirm_text("P", 2, 3, 1, 1), "Apply \"P\"?\n\nActivates 2 of 3 mods and replaces your mod settings.\nWill download 1 mod(s).\n1 mod(s) cannot be downloaded and will be listed to install by hand.\n\nYour current state is backed up -- click Unload to restore.",
			"confirm text")
	for c in [["a", true, false, "the active pack"], ["b", false, true, "another pack is active"],
			["", false, false, "no pack is active"]]:
		var st: Dictionary = ml._modpack_active_state({"sanitized_name": "a"}, c[0])
		check_eq([st["is_active"], st["another_active"]], [c[1], c[2]], c[3])

func _t4_progress_callback(ml: Object) -> void:
	begin("T4")
	var lbl := Label.new()
	var bar := ProgressBar.new()
	var cb: Callable = ml._modpack_progress_callback(lbl, bar, false)
	var retry: Callable = ml._modpack_progress_callback(lbl, bar, true)
	cb.call({"current": 1, "total": 2, "mod_name": "X", "action": "downloading"})
	check_eq(bar.value, 50.0, "bar after 1 of 2")
	for c in [
		[cb, "X", "downloading", "Downloading 1 of 2:\nX"],
		[cb, "X", "skipped", "Skipping (install by hand) 1 of 2:\nX"],
		[cb, "", "applying", "Applying modpack..."],
		[cb, "", "rate_wait", "Rate limited by H -- resuming in 3s"],
		[retry, "X", "downloading", "Retrying 1 of 2:\nX"],
		[retry, "", "downloading", "Retrying..."],
	]:
		var current := 2 if c[2] == "applying" else 1
		(c[0] as Callable).call({"current": current, "total": 2, "mod_name": c[1], "action": c[2], "host": "H", "wait_s": 3})
		check_eq(lbl.text, c[3], "%s text for '%s'" % [c[2], c[1]])
	# No progress dialog (nothing downloads): the callback is a no-op.
	(ml._modpack_progress_callback(null, null, false) as Callable).call({"current": 1, "total": 2, "mod_name": "", "action": "downloading"})
	lbl.free()
	bar.free()

func _t5_progress_cancel_and_finish(ml: Object) -> void:
	begin("T5")
	ml.set("_modpack_apply_cancelled", false)
	var pui: Dictionary = ml._build_modpack_progress_dialog("Pack")
	var cancel: Button = pui["cancel"]
	cancel.pressed.emit()
	check_eq(ml.get("_modpack_apply_cancelled"), true, "Cancel sets the flag")
	check_eq((pui["status"] as Label).text, "Cancelling after current download...", "Cancel status line")
	_assert(cancel.disabled and cancel.text == "Cancelling...", "Cancel button disables itself")
	ml.set("_modpack_apply_cancelled", false)
	ml._apply_modpack_finish({"ok": true, "error": "", "downloaded": 2, "failed_downloads": 0, "failures": []}, pui, null)
	check_eq((pui["status"] as Label).text, "Modpack applied. Downloaded 2 mod(s).", "success text")
	_assert(not cancel.visible, "success hides Cancel")
	_assert((pui["dialog"] as AcceptDialog).confirmed.get_connections().size() >= 1, "success wires the dismiss")
	var pui2: Dictionary = ml._build_modpack_progress_dialog("Pack")
	ml._apply_modpack_finish({"ok": false, "error": "boom", "downloaded": 0, "failed_downloads": 0, "failures": []}, pui2, null)
	_assert((pui2["dialog"] as AcceptDialog).is_queued_for_deletion(), "a failed apply frees the dialog")
	# No progress dialog at all (nothing downloaded): no crash.
	ml._apply_modpack_finish({"ok": true, "error": "", "downloaded": 0, "failed_downloads": 0, "failures": []}, {}, null)

func _t7_detail_sections(ml: Object) -> void:
	begin("T7")
	var box := VBoxContainer.new()
	var rt: RichTextLabel = ml._browse_detail_description(box)
	_assert(box.get_child_count() == 3 and box.get_child(2) == rt, "description is separator, heading, text")
	box.free()
	var stats: Dictionary = ml._modpack_detail_stats({"file_path": ""})
	_assert(int(stats["zip_size"]) == 0 and int(stats["installed_count"]) == 0 and (stats["installed"] as Dictionary).is_empty(),
			"a pack with no file has empty stats")

func _t8_failure_dialog_retry(ml: Object) -> void:
	begin("T8")
	var win: Window = ml.get("_ui_window")
	for c in [["foo", "vostokmods", true, "a downloadable failure offers Retry"], ["", "", false, "no Retry without a source"]]:
		ml._show_modpack_failure_dialog(1, [{"profile_key": "a", "error": "e", "ref": ml.host_ref(c[1], c[0])}], null)
		check_eq(_dialog_button_texts(_last_child(win)).has("Retry failed"), c[2], c[3])
		_free_last_child(win)
	(ml.get("_pack_mod_names") as Dictionary)["vostokmods:foo"] = "Foo Mod"
	ml._show_modpack_failure_dialog(1, [{"profile_key": "vostokmods:foo", "error": "e", "ref": ml.host_ref("vostokmods", "foo")},
		{"profile_key": "vostokmods:bar", "error": "e", "ref": ml.host_ref("vostokmods", "bar")}], null)
	var texts := _label_texts(_last_child(win))
	_assert(texts.has("Foo Mod") and texts.has("vostokmods:bar"), "rows name the mod, else the key")
	_assert(_find_button(_last_child(win), "Open page on Vostok Mods") != null, "the page button names the site")
	_free_last_child(win)
	(ml.get("_pack_mod_names") as Dictionary).clear()

# The shared pager driven by stub hooks, the way the pack list drives it; no host is asked.
func _t12_pager_hooks(ml: Object) -> void:
	begin("T12")
	var rows := [_summary(ml, "a", "A", "f"), _summary(ml, "b", "B", "f"), _summary(ml, "c", "C", "f")]
	var ctl := {"mode": "", "asked": []}
	var list_fn := func(q: Dictionary) -> Dictionary:
		(ctl["asked"] as Array).append(str(q["cursor"]))
		if ctl["mode"] == "slow":
			await process_frame
		match str(ctl["mode"]):
			"fail": return ml.host_err(ml.HOST_ERR_OFFLINE, 0, "offline")
			"empty": return ml.host_ok(ml.host_page([], false, "", 0))
		var page: Dictionary = ml.host_page([rows[0], rows[1]], true, "p2", 3) if str(q["cursor"]) == "" 				else ml.host_page([rows[1], rows[2]], false, "", 3)
		if ctl["mode"] == "cached":
			page["cached_at"] = int(Time.get_unix_time_from_system()) - 3600
		return ml.host_ok(page)
	var row_fn := func(s: Dictionary, _install: Dictionary) -> Control:
		var l := Label.new()
		l.text = "row " + str(s["name"])
		return l
	var empty_fn := func() -> String:
		return "none here"
	var cont := VBoxContainer.new()
	var sort_dropdown := OptionButton.new()
	cont.add_child(sort_dropdown)
	var state := {"provider": "vostokmods", "views": {"vostokmods": ml._browse_make_view("vostokmods")},
		"fetch_seq": 0, "sort_dropdown": sort_dropdown, "list_fn": list_fn, "row_fn": row_fn,
		"empty_fn": empty_fn, "noun": "packs", "retry": func(): pass}
	state.merge(ml._browse_build_list_area(cont))
	var offline := "Could not reach Vostok Mods. Check your connection."
	# Load more restores the scroll a frame later, on the loader's tree.
	root.add_child(ml)
	for c in [
		["fail", false, offline, [], true, false, "first page fails"],
		["", false, "2 of 3 packs", ["A", "B"], false, true, "page one"],
		["fail", true, offline, ["A", "B"], false, true, "failed append keeps pages"],
		["", true, "3 of 3 packs", ["A", "B", "C"], false, false, "append dedupes by ref"],
		["cached", false, "2 of 3 packs", ["A", "B"], true, true, "snapshot page"],
		["empty", false, "none here", [], false, false, "empty page"],
	]:
		ctl["mode"] = c[0]
		await ml._fetch_listing(state, c[1])
		var more: Button = state["load_more_btn"]
		var loaded := ((ml._browse_view(state) as Dictionary)["loaded_rows"] as Array).map(func(r): return r["name"])
		check_eq((ctl["asked"] as Array).back(), "p2" if c[1] else "", "%s: cursor asked" % c[6])
		check_eq((state["status_lbl"] as Label).text, c[2], "%s: status" % c[6])
		check_eq(_row_names(state["list"]), c[3], "%s: rows shown" % c[6])
		check_eq(loaded, c[3], "%s: rows kept" % c[6])
		check_eq((state["banner_slot"] as Control).visible, c[4], "%s: banner" % c[6])
		check_eq(more.visible and not more.disabled, c[5], "%s: Load more" % c[6])
		if c[0] == "cached":
			var texts := _label_texts(state["banner_slot"])
			_assert(texts.size() == 2 and texts[0].begins_with("Showing cached results.")
					and texts[1].begins_with("Last refreshed "), "cached banner texts " + str(texts))
	root.remove_child(ml)
	ctl["mode"] = "slow"
	ml._fetch_listing(state, false)
	state["fetch_seq"] = int(state["fetch_seq"]) + 1
	await _settle()
	check_eq((state["status_lbl"] as Label).text, "Loading...", "a stale fetch does not render")
	ml._fetch_listing(state, false)
	(state["list"] as Node).free()
	await _settle()
	check_eq((state["status_lbl"] as Label).text, "Loading...", "a freed list stops the fetch")
	cont.free()

# Live row labels from the stub row_fn, skipping freed-at-frame-end rows.
func _row_names(list: Node) -> Array:
	var out := []
	for c in list.get_children():
		if c is Label and not c.is_queued_for_deletion() and (c as Label).text.begins_with("row "):
			out.append((c as Label).text.trim_prefix("row "))
	return out

func _label_texts(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for c in node.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is Label:
			out.append((c as Label).text)
		out.append_array(_label_texts(c))
	return out

func _t13_row_frame_and_banner(ml: Object) -> void:
	begin("T13")
	var s := _summary(ml, "pack", "Pack", "")
	s["author_name"] = "A"
	s["version"] = ""
	s["downloads"] = 5
	s["views"] = 7
	s["category_name"] = "Cat"
	var metrics := PackedStringArray(["downloads", "views"])
	for c in [["3 mods", "by A - 3 mods - 5 downloads - 7 views - Cat - updated 2026-01-02 03:04"],
			["", "by A - 5 downloads - 7 views - Cat - updated 2026-01-02 03:04"]]:
		check_eq(ml._browse_meta_text(s, metrics, c[0]), c[1], "meta with count '%s'" % c[0])
	var opened := [0]
	var row: HBoxContainer = ml._row_frame(s, "3 mods", func(): opened[0] += 1)
	check_eq(row.get_child_count(), 2, "frame is thumb and info")
	var name_btn: Button = row.get_child(1).get_child(0)
	name_btn.pressed.emit()
	check_eq([name_btn.text, opened[0]], ["Pack", 1], "name link opens")
	check_eq(_label_texts(row.get_child(1)), PackedStringArray([ml._browse_meta_text(s, metrics, "3 mods")]),
			"frame meta has the count")
	row.free()
	var cont := VBoxContainer.new()
	var retried := [0]
	var state: Dictionary = ml._browse_build_list_area(cont)
	state["provider"] = "vostokmods"
	state["retry"] = func(): retried[0] += 1
	ml._show_banner(state, "down", 0, Color.RED)
	_press(cont, "Retry")
	check_eq(retried[0], 1, "Retry calls the state's retry")
	cont.free()
	var key := "vostokmods_packs"
	ml._store_landing(key, [{"title": "", "rows": [s]}])
	(ml.get("_browse_landing_snapshots") as Dictionary).erase(key)
	var snap: Dictionary = ml._browse_landing_snapshot(key)
	check_eq((snap["sections"][0]["rows"] as Array).size(), 1, "pack snapshot reads back")
	(ml.get("_browse_landing_snapshots") as Dictionary).erase(key)
	DirAccess.remove_absolute(ml._browse_landing_snapshot_path(key))

# T14..T18 and T21, T22 drive Browse's Modpacks kind and the Modpacks tab on a stub
# loader: list, manifest and import come from fields.
func _t14_to_t18_packs(win: Window) -> void:
	DirAccess.make_dir_recursive_absolute(PACKS_DIR)
	_write_pack("have", "Have Pack")
	var pk: Object = PackStub.new()
	pk._compile_regex()
	pk.set("_has_loaded", true)
	pk.set("_mods_dir", PACKS_DIR)
	pk.set("_ui_window", win)
	pk.mod_row = _summary(pk, "m1", "M One", "f1")
	var tabs := TabContainer.new()
	_t14_pack_rows(pk, tabs)
	_t15_pack_detail(pk, win, tabs)
	_t16_pack_status(pk, tabs)
	await _t17_pack_import(pk, tabs)
	await _t18_pack_rebuilds(pk, tabs)
	_t21_browse_kinds(pk, tabs)
	_t22_your_packs(pk, tabs)
	_t24_check_icon(pk)
	await _t25_browse_reselect(pk, tabs)
	await _t26_paste_kept(pk, tabs)
	_t27_spin_label(pk, tabs)
	await _t28_cover_cache(pk)
	await _t29_freed_cover(pk)
	await _t36_thumb_retry(pk)
	await _t30_get_after_failure(pk, tabs)
	# A live first page wrote the snapshots; the dump's launcher_empty pins the state without them.
	for key in ["vostokmods_packs", "vostokmods"]:
		DirAccess.remove_absolute(pk._browse_landing_snapshot_path(key))
	pk._set_ui_cfg_value("settings", "browse_kind", "mods")
	for c in win.get_children():
		win.remove_child(c)
		c.free()
	tabs.free()
	pk.free()

func _write_pack(slug: String, pack_name: String) -> void:
	H.write_zip(PACKS_DIR + "/vostokmods-" + slug + ".zip", {"profile.json": JSON.stringify({"metroprofile": 1,
		"name": pack_name, "enabled": {"vostokmods:a": true},
		"hosted": {"provider": "vostokmods", "slug": slug, "url": "https://vostokmods.net/modpack/" + slug}})}, _report)

func _pack_summary(pk: Object, slug: String, pack_name: String, count: int) -> Dictionary:
	return pk._vmp_modpack_summary({"slug": slug, "name": pack_name, "ownerDisplayName": "joni", "modCount": count,
		"downloadsCount": 9, "viewsCount": 4, "updatedAt": "2026-01-02T03:04:05Z"})

# With more, the page says five more packs wait behind Load more.
func _pack_page(pk: Object, rows: Array, more := false) -> Dictionary:
	return pk.host_ok(pk.host_page(rows, more, "2" if more else "", rows.size() + (5 if more else 0)))

# A fresh Browse tab on the stub, opened on Mods and switched to Modpacks; the record is dropped first.
func _pack_tab(pk: Object, tabs: TabContainer, pages: Array) -> Dictionary:
	pk.set("_packs_state", {})
	pk._set_ui_cfg_value("settings", "browse_kind", "mods")
	pk.pages = pages
	var tab: Control = pk.build_browse_tab(tabs)
	tabs.add_child(tab)
	_find_button(tab, "Modpacks").button_pressed = true
	return pk.get("_packs_state")

# A Browse rebuild: the old tab is freed, the record is kept, and the remembered kind is Modpacks.
func _rebuild_pane(pk: Object, tabs: TabContainer, old: Control) -> Control:
	tabs.remove_child(old)
	old.free()
	var tab: Control = pk.build_browse_tab(tabs)
	tabs.add_child(tab)
	return tab

# Every label on a fresh Modpacks tab.
func _your_packs(pk: Object, tabs: TabContainer) -> PackedStringArray:
	var tab: Control = pk.build_modpacks_tab(tabs)
	var texts := _label_texts(tab)
	tab.free()
	return texts

func _open_gates(pk: Object) -> void:
	for g: Dictionary in pk.gates:
		g["open"] = true
	pk.gates.clear()

func _t14_pack_rows(pk: Object, tabs: TabContainer) -> void:
	begin("T14")
	var have := _pack_summary(pk, "Have", "Have Pack", 3)
	var fresh := _pack_summary(pk, "fresh", "Fresh Pack", -1)
	var state := _pack_tab(pk, tabs, [_pack_page(pk, [have, fresh])])
	check_eq([pk.asked[0]["query"], pk.asked[0]["sort"], pk.asked[0]["cursor"]], ["", "updated", ""], "first page asked")
	check_eq((state["status_lbl"] as Label).text, "2 of 2 packs", "status counts packs")
	var btns: Dictionary = state["get_btns"]
	var metrics := PackedStringArray(["downloads", "views"])
	for c in [["Have", "Added", true, "3 mods", "a local pack reads Added, any case"],
			["fresh", "Get", false, "", "a new pack offers Get"]]:
		var btn: Button = btns[c[0]]
		check_eq([btn.text, btn.disabled], [c[1], c[2]], c[4])
		var row: Node = btn.get_parent()
		var meta: Label = row.get_child(1).get_child(1)
		check_eq(meta.text, pk._browse_meta_text(have if c[0] == "Have" else fresh, metrics, c[3]), c[0] + " meta line")
		_assert(_find_button(row, "Page") == null, c[0] + " row has no Page button")
	_assert((btns["fresh"] as Button).has_theme_color_override("font_color"), "Get is primary")
	state["busy"] = true
	state["busy_slug"] = "fresh"
	pk._paint_import(state)
	check_eq([(btns["fresh"] as Button).text, (btns["fresh"] as Button).disabled], ["Getting...", true], "busy row reads Getting...")
	state["busy"] = false
	state["busy_slug"] = ""
	pk._paint_import(state)
	check_eq([(btns["fresh"] as Button).text, (btns["fresh"] as Button).disabled], ["Get", false], "idle row re-arms Get")
	var mp: Control = pk.build_modpacks_tab(tabs)
	var local_row: Node = (pk.get("_ui_modpacks_scroll") as Node).get_child(0).get_child(0).get_child(0)
	check_eq(local_row.get_child(0).get_class(), "PanelContainer", "a coverless local row keeps the cover cell")
	_assert(_label_texts(local_row).has("from Vostok Mods - 1 mods - 0 installed"), "local row counts mods and installed")
	mp.free()
	var slot: String = (pk.get("_modpack_entries") as Array)[0]["sanitized_name"]
	check_eq(pk._another_active_text(slot), "Unload \"Have Pack\" before applying another modpack.", "the hint names the pack")
	var win: Window = pk.get("_ui_window")
	var before := win.get_child_count()
	((btns["Have"] as Button).get_parent().get_child(1).get_child(0) as Button).pressed.emit()
	check_eq(win.get_child_count(), before + 1, "the name link opens the detail")
	_assert(_dialog_button_texts(_last_child(win)).has("Added"), "detail of a local pack reads Added")
	_free_last_child(win)

# Mod rows as [name, marker] pairs.
func _detail_rows(view: Dictionary) -> Array:
	var rows := []
	for r in (view["mods"] as Node).get_children():
		if r is HBoxContainer:
			rows.append([(r.get_child(1) as Label).text, (r.get_child(2) as Label).text])
	return rows

func _t15_pack_detail(pk: Object, win: Window, tabs: TabContainer) -> void:
	begin("T15")
	var ents: Array[Dictionary] = [{"profile_key": "zip:inst.vmz", "mod_id": "inst", "version": "1",
		"full_path": "user://nope/inst.vmz"}]
	pk.set("_ui_mod_entries", ents)
	pk.manifest = {"format": 2, "slug": "fresh", "name": "Fresh Pack", "mods": [
		{"slug": "inst", "name": "Inst Mod", "version": "1", "available": true},
		{"slug": "dl", "name": "DL Mod", "version": "2", "available": true},
		{"slug": "scan", "name": "Scan Mod", "available": false, "reason": "scanning"},
		{"slug": "gone", "name": "Gone Mod", "available": false, "reason": "removed"}]}
	var view: Dictionary = pk._listing_pack_dialog(_pack_summary(pk, "fresh", "Fresh Pack", 4))
	check_eq(_sorted_buttons(win), ["Close", "Get", "Open page on Vostok Mods"], "listing detail buttons")
	_assert(not (view["mods_status"] as Label).visible, "the manifest replaces the loading line")
	check_eq((view["counts"] as Label).text, "4 mods - 1 installed", "counts line")
	check_eq(_detail_rows(view), [["DL Mod", "Will download"], ["Gone Mod", "Not available"], ["Inst Mod", "Installed"],
			["Scan Mod", "Not available"]], "mod names and markers")
	_free_last_child(win)
	pk.manifest = {}
	view = pk._listing_pack_dialog(_pack_summary(pk, "fresh", "Fresh Pack", 4))
	check_eq((view["mods_status"] as Label).text, "Could not reach Vostok Mods. Check your connection.",
			"an unreachable manifest is one line")
	check_eq((view["mods"] as Node).get_child_count(), 0, "no mod rows without a manifest")
	_free_last_child(win)
	var entry: Dictionary = pk.collect_modpack_metadata()[0]
	view = pk._local_pack_dialog(entry, tabs)
	check_eq(_sorted_buttons(win), ["Apply", "Close", "Open page on Vostok Mods"], "local detail buttons")
	check_eq((view["counts"] as Label).text.get_slice(" - ", 0), "1 mods", "local counts from the zip")
	check_eq([_detail_rows(view), (view["mods_status"] as Label).visible], [[["a", "Install by hand"]], false],
			"offline a local pack shows its keys")
	_free_last_child(win)
	pk.manifest = {"format": 2, "slug": "have", "name": "Have Pack", "mods": [{"slug": "a", "name": "A Mod"}]}
	view = pk._local_pack_dialog(entry, tabs)
	check_eq([_detail_rows(view), (view["counts"] as Label).text.get_slice(" - ", 0)], [[["A Mod", "Install by hand"]], "1 mods"],
			"a site pack takes the manifest's names")
	_free_last_child(win)
	pk.manifest = {}
	for c in [["https://vostokmods.net/modpack/x", true, "a site link opens"],
			["https://vostokmods.net.evil/x", false, "a look-alike host does not open"],
			["https://www.vostokmods.net/modpack/x", true, "a www link opens"],
			["http://vostokmods.net/modpack/x", false, "an http link does not open"]]:
		check_eq(bool(pk._hosted_page_url_ok(c[0])), c[1], c[2])
	for c in [["HTTPS://x/c.png", "HTTPS://x/c.png"], ["http://x/c.png", ""]]:
		check_eq(pk._pack_cover({"thumbnail_url": c[0]})["url"], c[1], "local cover " + c[0])
	var none: Array[Dictionary] = []
	pk.set("_ui_mod_entries", none)

func _t16_pack_status(pk: Object, tabs: TabContainer) -> void:
	begin("T16")
	var rows := [_pack_summary(pk, "have", "Have Pack", 3), _pack_summary(pk, "fresh", "Fresh Pack", 2)]
	var snap_path: String = pk._browse_landing_snapshot_path("vostokmods_packs")
	var state := _pack_tab(pk, tabs, [_pack_page(pk, [])])
	for c in [
		["", [_pack_page(pk, [])], "No packs on Vostok Mods yet.", [], "no packs published"],
		["zzz", [_pack_page(pk, [])], "No pack matches that search.", [], "no match"],
		["", [_pack_page(pk, rows)], "2 of 2 packs", [], "a live page"],
		["", [], "2 of 2 packs", ["Showing cached results. Vostok Mods is unreachable."], "offline with a snapshot"],
		["zzz", [], "Could not load packs.", ["Vostok Mods is unreachable."], "a search has no snapshot"],
	]:
		(pk._browse_view(state) as Dictionary)["query"] = c[0]
		pk.pages = c[1]
		pk._fetch_listing(state, false)
		check_eq((state["status_lbl"] as Label).text, c[2], c[4] + ": status")
		var banner := _label_texts(state["banner_slot"])
		check_eq(Array(banner).slice(0, 1), c[3], c[4] + ": banner")
		check_eq((state["banner_slot"] as Control).visible, not (c[3] as Array).is_empty(), c[4] + ": banner shown")
	_assert(FileAccess.file_exists(snap_path), "a live first page writes the snapshot")
	# A rebuild keeps the loaded rows and the search text without asking again.
	(pk._browse_view(state) as Dictionary)["query"] = ""
	pk.pages = [_pack_page(pk, rows)]
	pk._fetch_listing(state, false)
	(pk._browse_view(state) as Dictionary)["query"] = "abc"
	var asked: int = pk.asked.size()
	tabs.add_child(pk.build_browse_tab(tabs))
	state = pk.get("_packs_state")
	check_eq([(state["search_input"] as LineEdit).text, pk.asked.size()], ["abc", asked], "rebuild keeps search, no fetch")
	check_eq([(state["status_lbl"] as Label).text, (state["get_btns"] as Dictionary).size()], ["2 of 2 packs", 2],
			"rebuild re-renders the pages")
	(state["sort_dropdown"] as OptionButton).item_selected.emit(3)
	check_eq(pk.asked.back()["sort"], "views", "the sort menu reaches the query")

func _t17_pack_import(pk: Object, tabs: TabContainer) -> void:
	begin("T17")
	var state := _pack_tab(pk, tabs, [_pack_page(pk, [_pack_summary(pk, "fresh", "Fresh Pack", 2),
		_pack_summary(pk, "other", "Other Pack", 1)])])
	var paste: LineEdit = state["paste"]
	var add_btn: Button = state["add_btn"]
	var status: Label = state["status_lbl"]
	check_eq(add_btn.text, "Get", "the paste button says Get")
	paste.text = "  "
	add_btn.pressed.emit()
	check_eq(pk.links.size(), 0, "an empty paste asks nothing")
	pk.hold = true
	pk.imports = [{"ok": true, "error": "", "name": "Fresh Pack", "file_path": ""}]
	paste.text = "https://vostokmods.net/modpack/fresh"
	add_btn.pressed.emit()
	check_eq([status.text, add_btn.disabled], ["Getting the pack...", true], "paste Get is busy")
	var other_btn: Button = (state["get_btns"] as Dictionary)["other"]
	check_eq([other_btn.text, other_btn.disabled], ["Get", true], "other Gets are disabled meanwhile")
	other_btn.pressed.emit()
	check_eq(pk.links, ["https://vostokmods.net/modpack/fresh"], "Get waits for the paste")
	pk._listing_pack_dialog(_pack_summary(pk, "fresh", "Fresh Pack", 2))
	var dialog_get: Button = (state["detail_gets"] as Array).back()[0]
	check_eq([dialog_get.text, dialog_get.disabled], ["Get", true], "a detail Get waits too")
	_write_pack("fresh", "Fresh Pack")
	pk.hold = false
	await _settle()
	var fresh_btn: Button = (state["get_btns"] as Dictionary)["fresh"]
	check_eq(status.text, "Added \"Fresh Pack\" to Your packs; Apply it on the Modpacks tab.", "paste success text")
	check_eq([paste.text, state["paste_text"], add_btn.disabled, fresh_btn.text, fresh_btn.disabled],
			["", "", false, "Added", true], "field cleared, row flipped")
	check_eq([dialog_get.text, dialog_get.disabled], ["Added", true], "the detail Get flips too")
	_free_last_child(pk.get("_ui_window"))
	_assert(_your_packs(pk, tabs).has("Fresh Pack"), "Your packs lists the new pack")
	pk.imports = [{"ok": false, "error": "nope", "name": ""}]
	paste.text = "bad"
	add_btn.pressed.emit()
	check_eq([status.text, paste.text, add_btn.disabled], ["nope", "bad", false], "paste error keeps the field")
	var other: Button = (state["get_btns"] as Dictionary)["other"]
	pk.imports = [{"ok": false, "error": "boom", "name": ""}]
	other.pressed.emit()
	check_eq([status.text, other.text, other.disabled], ["boom", "Get", false], "row Get error re-arms Get")
	check_eq(pk.links.slice(1), ["bad", "https://vostokmods.net/api/modpacks/other/manifest"], "links asked")

# A Browse rebuild mid-fetch, a stale answer, a failed sort and a new window leave the pane right.
func _t18_pack_rebuilds(pk: Object, tabs: TabContainer) -> void:
	begin("T18")
	var rows := [_pack_summary(pk, "p1", "P1", 1), _pack_summary(pk, "p2", "P2", 1)]
	pk.set("_packs_state", {})
	pk._set_ui_cfg_value("settings", "browse_kind", "modpacks")
	pk.gated = true
	pk.pages = [_pack_page(pk, rows, true)]
	var tab: Control = pk.build_browse_tab(tabs)
	tabs.add_child(tab)
	var asked: int = pk.asked.size()
	tab = _rebuild_pane(pk, tabs, tab)
	var state: Dictionary = pk.get("_packs_state")
	check_eq([pk.asked.size(), (state["status_lbl"] as Label).text], [asked, "Loading..."], "a first page in flight is reused")
	_open_gates(pk)
	await _settle()
	var more: Button = state["load_more_btn"]
	check_eq([(state["status_lbl"] as Label).text, more.visible and not more.disabled], ["2 of 7 packs", true],
			"the first page lands in the rebuilt pane")

	# Load more restores the scroll a frame later, on the loader's tree.
	root.add_child(pk)
	pk.pages = [pk.host_ok(pk.host_page([_pack_summary(pk, "p3", "P3", 1)], false, "", 3))]
	more.pressed.emit()
	tab = _rebuild_pane(pk, tabs, tab)
	_open_gates(pk)
	await _settle()
	more = state["load_more_btn"]
	check_eq([(state["status_lbl"] as Label).text, (state["get_btns"] as Dictionary).size(), more.visible], ["3 of 3 packs", 3, false],
			"Load more lands in the rebuilt pane")
	root.remove_child(pk)
	var snap: Dictionary = pk._browse_landing_snapshot("vostokmods_packs")
	check_eq((snap["sections"][0]["rows"] as Array).size(), 2, "Load more leaves the snapshot alone")

	rows = [_pack_summary(pk, "p1", "P1", 1), _pack_summary(pk, "p2", "P2", 1)]
	pk.pages = [_pack_page(pk, rows.duplicate()), pk.host_ok(pk.host_page(rows.duplicate(), false, "", 9))]
	pk._fetch_listing(state, false)
	pk._fetch_listing(state, false)
	(pk.gates[1] as Dictionary)["open"] = true
	await _settle()
	_open_gates(pk)
	await _settle()
	check_eq([(pk._browse_view(state) as Dictionary)["total"], (state["status_lbl"] as Label).text], [9, "2 of 9 packs"],
			"a stale answer keeps the newer total")
	pk.gated = false

	(state["sort_dropdown"] as OptionButton).item_selected.emit(3)
	check_eq([(state["status_lbl"] as Label).text, ((pk._browse_view(state) as Dictionary)["loaded_rows"] as Array).size()],
			["Could not load packs.", 0], "a failed sort keeps no rows")
	check_eq(Array(_label_texts(state["banner_slot"])), ["Vostok Mods is unreachable."], "another sort's snapshot is not shown")
	asked = pk.asked.size()
	tab = _rebuild_pane(pk, tabs, tab)
	check_eq(pk.asked.size(), asked + 1, "the rebuild after a failed sort asks again")
	(state["sort_dropdown"] as OptionButton).item_selected.emit(0)
	check_eq([(state["status_lbl"] as Label).text, Array(_label_texts(state["banner_slot"])).slice(0, 1)],
			["2 of 2 packs", ["Showing cached results. Vostok Mods is unreachable."]], "its own sort shows the snapshot")

	(state["paste"] as LineEdit).text_changed.emit("https://vostokmods.net/modpack/x")
	tab = _rebuild_pane(pk, tabs, tab)
	check_eq((state["paste"] as LineEdit).text, "https://vostokmods.net/modpack/x", "the paste text survives a rebuild")

	var win: Variant = pk.get("_ui_window")
	pk.set("_ui_window", null)
	pk._packs_record()
	pk.set("_ui_window", win)
	_assert(not state.has("list_fn") and not state.has("row_fn") and not state.has("retry"),
			"a replaced record drops its callables")
	pk.set("_packs_state", {})
	tabs.remove_child(tab)
	tab.free()


# The Browse tab's shown parts: [mods group, mods area, packs group, packs area].
func _kind_shown(tab: Control) -> Array:
	var box: Node = tab.get_child(0)
	var toolbar: Node = box.get_child(0)
	return [toolbar.get_child(1).visible, box.get_child(2).visible, toolbar.get_child(2).visible, box.get_child(3).visible]

# The switch shows one kind, remembers it, reads a garbage kind as Mods, and
# neither kind refetches or touches the other's rows.
func _t21_browse_kinds(pk: Object, tabs: TabContainer) -> void:
	begin("T21")
	pk.set("_packs_state", {})
	pk.pages = [_pack_page(pk, [_pack_summary(pk, "k1", "K1", 1)])]
	pk._set_ui_cfg_value("settings", "browse_kind", "garbage")
	var asked: int = pk.asked.size()
	var tab: Control = pk.build_browse_tab(tabs)
	tabs.add_child(tab)
	check_eq(_kind_shown(tab), [true, true, false, false], "a garbage kind opens on Mods")
	check_eq(pk.asked.size(), asked, "Mods asks for no packs")
	var mods_area: Node = tab.get_child(0).get_child(2)
	var mods_status: Label = mods_area.get_child(1)
	var mods_list: Node = mods_area.get_child(2).get_child(0).get_child(0)
	var mods_before := [mods_status.text, mods_list.get_child_count()]
	_assert(mods_list.get_child_count() > 0, "the mod landing rendered")
	var mod_lists: int = pk.mod_lists
	_find_button(tab, "Modpacks").button_pressed = true
	check_eq(_kind_shown(tab), [false, false, true, true], "Modpacks shows only packs")
	check_eq(pk._get_ui_cfg_value("settings", "browse_kind", ""), "modpacks", "Modpacks is remembered")
	check_eq(((pk.get("_packs_state") as Dictionary)["status_lbl"] as Label).text, "1 of 1 packs", "first show fetches packs")
	check_eq([mods_status.text, mods_list.get_child_count()], mods_before, "a pack fetch leaves mods alone")
	asked = pk.asked.size()
	_find_button(tab, "Mods").button_pressed = true
	check_eq(_kind_shown(tab), [true, true, false, false], "Mods shows only mods")
	check_eq(pk._get_ui_cfg_value("settings", "browse_kind", ""), "mods", "Mods is remembered")
	_find_button(tab, "Modpacks").button_pressed = true
	check_eq([pk.asked.size(), pk.mod_lists], [asked, mod_lists], "switching back refetches nothing")
	var state: Dictionary = pk.get("_packs_state")
	(state["sort_dropdown"] as OptionButton).item_selected.emit(1)
	check_eq((state["status_lbl"] as Label).text, "Could not load packs.", "a failed sort shows the failure")
	pk.pages = [_pack_page(pk, [_pack_summary(pk, "k1", "K1", 1)])]
	asked = pk.asked.size()
	_find_button(tab, "Mods").button_pressed = true
	_find_button(tab, "Modpacks").button_pressed = true
	check_eq([pk.asked.size(), (state["status_lbl"] as Label).text], [asked + 1, "1 of 1 packs"], "an empty list asks again on show")
	_find_button(tab, "Mods").button_pressed = true
	_find_button(tab, "Modpacks").button_pressed = true
	check_eq(pk.asked.size(), asked + 1, "a filled list does not")
	tab = _rebuild_pane(pk, tabs, tab)
	check_eq(_kind_shown(tab), [false, false, true, true], "the next build opens on Modpacks")
	_assert(_find_button(tab, "Modpacks").button_pressed, "the Modpacks switch is pressed")
	pk.set("_packs_state", {})
	tabs.remove_child(tab)
	tab.free()

# Your packs: the empty hint alone with no pack, the list alone with one.
func _t22_your_packs(pk: Object, tabs: TabContainer) -> void:
	begin("T22")
	var hint := "No packs yet. Get one under Browse > Modpacks and it shows up here, ready to Apply."
	DirAccess.make_dir_recursive_absolute("user://t22_empty")
	for c in [[PACKS_DIR, "ScrollContainer", "with packs"], ["user://t22_empty", "Label", "no packs"]]:
		pk.set("_mods_dir", c[0])
		var tab: Control = pk.build_modpacks_tab(tabs)
		var kids: Array = tab.get_child(0).get_children().map(func(n: Node): return n.get_class())
		check_eq(kids, [c[1]], c[2] + ": one child")
		check_eq(_label_texts(tab).has(hint), c[1] == "Label", c[2] + ": hint")
		check_eq(pk.get("_ui_modpacks_scroll") != null, c[1] != "Label", c[2] + ": scroll recorded")
		tab.free()
	pk.set("_mods_dir", PACKS_DIR)

# The pressed kind's check mark: two diagonal strokes, not a filled box.
func _t24_check_icon(pk: Object) -> void:
	begin("T24")
	var img: Image = (pk._make_check_icon(Color.WHITE) as Texture2D).get_image()
	check_eq(img.get_size(), Vector2i(12, 12), "the icon is 12x12")
	check_eq(img.get_pixel(5, 9), Color.WHITE, "the stroke takes the color")
	for c in [[2, 5, true, "short stroke start"], [10, 3, true, "long stroke end"],
			[0, 0, false, "top left corner empty"], [11, 11, false, "bottom right corner empty"],
			[0, 11, false, "bottom left corner empty"], [11, 0, false, "top right corner empty"],
			[3, 9, false, "below the short stroke empty"], [8, 8, false, "not a filled box"]]:
		check_eq(img.get_pixel(c[0], c[1]).a > 0.5, c[2], c[3])

# Selecting Browse on a failed pack list asks again, as the kind switch does.
func _t25_browse_reselect(pk: Object, tabs: TabContainer) -> void:
	begin("T25")
	DirAccess.remove_absolute(pk._browse_landing_snapshot_path("vostokmods_packs"))
	(pk.get("_browse_landing_snapshots") as Dictionary).erase("vostokmods_packs")
	pk.set("_packs_state", {})
	pk._set_ui_cfg_value("settings", "browse_kind", "modpacks")
	pk.pages = []
	var tab: Control = pk.build_browse_tab(tabs)
	tabs.add_child(tab)
	var state: Dictionary = pk.get("_packs_state")
	check_eq((state["status_lbl"] as Label).text, "Could not load packs.", "an offline first page fails")
	pk.pages = [_pack_page(pk, [_pack_summary(pk, "r1", "R1", 1)])]
	var asked: int = pk.asked.size()
	pk._on_browse_selected(tab)
	check_eq([pk.asked.size(), (state["status_lbl"] as Label).text], [asked + 1, "1 of 1 packs"],
			"reselecting Browse asks again")
	pk._on_browse_selected(tab)
	check_eq(pk.asked.size(), asked + 1, "a filled list is not refetched")
	pk.set("_packs_state", {})
	pk._set_ui_cfg_value("settings", "browse_kind", "mods")
	tabs.remove_child(tab)
	tab.free()

# A link typed while a pasted Get runs is kept when that Get lands.
func _t26_paste_kept(pk: Object, tabs: TabContainer) -> void:
	begin("T26")
	var state := _pack_tab(pk, tabs, [_pack_page(pk, [])])
	var paste: LineEdit = state["paste"]
	var second := "https://vostokmods.net/modpack/second"
	pk.hold = true
	pk.imports = [{"ok": true, "error": "", "name": "First", "file_path": ""}]
	paste.text = "https://vostokmods.net/modpack/first"
	(state["add_btn"] as Button).pressed.emit()
	paste.text = second
	paste.text_changed.emit(second)
	pk.hold = false
	await _settle()
	check_eq([paste.text, state["paste_text"]], [second, second], "the new link stays")
	pk.set("_packs_state", {})

# After boot a load-order edit flips the launch button to a restart.
func _t27_spin_label(pk: Object, tabs: TabContainer) -> void:
	begin("T27")
	var ents: Array[Dictionary] = [{"mod_name": "Spin", "mod_id": "spin", "enabled": true, "priority": 1, "ext": "vmz",
		"profile_key": "zip:spin.vmz", "file_name": "spin.vmz", "full_path": "user://nope/spin.vmz", "has_registry": false,
		"required_dependencies": [], "optional_dependencies": [], "dependency_blockers": [],
		"dependency_blockers_info": [], "dependency_warnings": [], "warnings": [], "author_notes": [],
		"dependency_ignored": false}]
	pk.set("_ui_mod_entries", ents)
	var btn := Button.new()
	pk.set("_ui_launch_btn", btn)
	pk.set("_boot_complete", true)
	pk.set("_booted_set_signature", pk._loaded_set_signature())
	pk.refresh_launch_button_label()
	check_eq(btn.text, "Back to game", "an unchanged set reads Back to game")
	# A pending save returns at once, so no timer needs the tree.
	pk.set("_priority_save_pending", true)
	var tab: Control = pk.build_mods_tab(tabs)
	# A Range out of the tree does not emit value_changed.
	(pk.get("_ui_window") as Window).add_child(tab)
	var spin: SpinBox = tab.find_children("*", "SpinBox", true, false)[0]
	spin.value = spin.value + 1
	check_eq(btn.text, "Apply and restart", "a load-order edit asks for restart")
	tab.free()
	btn.free()
	pk.set("_ui_launch_btn", null)
	pk.set("_boot_complete", false)
	pk.set("_priority_save_pending", false)
	var none: Array[Dictionary] = []
	pk.set("_ui_mod_entries", none)

func _cover_png() -> PackedByteArray:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	return img.save_png_to_buffer()

# Pack covers, listing and local alike, land on disk under one key; a failed cover is asked once.
func _t28_cover_cache(pk: Object) -> void:
	begin("T28")
	var url := "https://files.vostokmods.net/packs/9/cover.png"
	var cover: Dictionary = pk._pack_cover({"thumbnail_url": url})
	var key: String = cover["cache_key"]
	_assert(key != "", "a pack cover has a disk key")
	check_eq(pk._vmp_modpack_summary({"slug": "c", "thumbnailUrl": url})["thumbnail"]["cache_key"], key,
			"listing and local covers share it")
	var holder := Control.new()
	pk.thumb_body = _cover_png()
	pk.thumb_urls.clear()
	await pk._browse_load_thumbnail_async(pk._make_thumb_cell(holder, Vector2(96, 54)), cover)
	var path: String = str(pk.UI_CACHE_DIR).path_join("thumbs").path_join(key)
	_assert(FileAccess.file_exists(path), "the cover is written to disk")
	(pk.get("_thumb_texture_cache") as Dictionary).clear()
	var again: TextureRect = pk._make_thumb_cell(holder, Vector2(96, 54))
	await pk._browse_load_thumbnail_async(again, cover)
	check_eq([pk.thumb_urls.size(), again.texture != null], [1, true], "the next launch reads the disk")
	DirAccess.remove_absolute(path)
	pk.thumb_body = PackedByteArray()
	var dead := {"url": "https://files.vostokmods.net/packs/9/dead.png", "cache_key": ""}
	var last: TextureRect
	for i in 2:
		last = pk._make_thumb_cell(holder, Vector2(96, 54))
		await pk._browse_load_thumbnail_async(last, dead)
	check_eq(pk.thumb_urls.count(dead["url"]), 1, "a failed cover is asked once")
	check_eq((last.get_parent().get_node("ThumbStateLabel") as Label).text, "load failed", "it still reads load failed")
	holder.free()

# A cell freed while its cover downloads raises no error and the texture is kept.
func _t29_freed_cover(pk: Object) -> void:
	begin("T29")
	pk.thumb_body = _cover_png()
	pk.thumb_hold = true
	var holder := Control.new()
	var image := {"url": "https://files.vostokmods.net/packs/9/freed.png", "cache_key": ""}
	pk._browse_load_thumbnail_async(pk._make_thumb_cell(holder, Vector2(96, 54)), image)
	holder.free()
	pk.thumb_hold = false
	await _settle()
	_assert((pk.get("_thumb_texture_cache") as Dictionary).has(image["url"]), "the memo keeps the texture")
	pk.thumb_body = PackedByteArray()

# A failed mod thumbnail is asked again on a later render.
func _t36_thumb_retry(pk: Object) -> void:
	begin("T36")
	var holder := Control.new()
	var image := {"url": "https://files.vostokmods.net/mods/7/thumb.png", "cache_key": ""}
	pk.thumb_body = PackedByteArray()
	pk.thumb_urls.clear()
	await pk._browse_load_thumbnail_async(pk._make_thumb_cell(holder, Vector2(96, 54)), image)
	var failed: Dictionary = pk.get("_thumb_failed")
	failed[image["url"]] = Time.get_ticks_msec() - 1
	pk.thumb_body = _cover_png()
	var later: TextureRect = pk._make_thumb_cell(holder, Vector2(96, 54))
	await pk._browse_load_thumbnail_async(later, image)
	check_eq([pk.thumb_urls.size(), later.texture != null], [2, true], "a later render asks again")
	pk.thumb_body = PackedByteArray()
	holder.free()

# A Get that fails after its detail dialog closed leaves the next Get free to run.
func _t30_get_after_failure(pk: Object, tabs: TabContainer) -> void:
	begin("T30")
	var state := _pack_tab(pk, tabs, [_pack_page(pk, [_pack_summary(pk, "g1", "G One", 1),
		_pack_summary(pk, "g2", "G Two", 1)])])
	var win: Window = pk.get("_ui_window")
	var links: int = pk.links.size()
	pk.hold = true
	pk.imports = [{"ok": false, "error": "", "name": ""}, {"ok": true, "error": "", "name": "G Two", "file_path": ""}]
	pk._listing_pack_dialog(_pack_summary(pk, "g1", "G One", 1))
	((state["detail_gets"] as Array).back()[0] as Button).pressed.emit()
	_free_last_child(win)
	pk.hold = false
	await _settle()
	check_eq([state["busy"], state["busy_slug"]], [false, ""], "a failed Get clears busy")
	var btn: Button = (state["get_btns"] as Dictionary)["g2"]
	check_eq([btn.text, btn.disabled], ["Get", false], "the other Get is armed")
	btn.pressed.emit()
	await _settle()
	check_eq(pk.links.size(), links + 2, "a second Get asks")
	check_eq((state["status_lbl"] as Label).text, "Added \"G Two\" to Your packs; Apply it on the Modpacks tab.",
			"the second Get lands")
	pk.set("_packs_state", {})

# A pack with no backup: Unload asks to keep the pack as a profile; Cancel keeps it active.
func _t19_force_unload_confirm(win: Window) -> void:
	begin("T19")
	var fs: Object = ForceStub.new()
	fs._compile_regex()
	fs.set("_has_loaded", true)
	fs.set("_mods_dir", PACKS_DIR)
	fs.set("_ui_window", win)
	fs.set("_active_profile", "modpack__Kept")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "active_profile", "modpack__Kept")
	cfg.set_value("settings", "active_modpack", "Kept")
	cfg.set_value("profile.modpack__Kept.enabled", "vostokmods:a", true)
	cfg.save(str(fs.UI_CONFIG_PATH))
	var tabs := TabContainer.new()
	var mods_tab: Control = fs.build_mods_tab(tabs)
	mods_tab.name = str(fs.UI_TAB_MODS)
	tabs.add_child(mods_tab)
	var banner := "Modpack \"Kept\" is active. Changes here save to the modpack, not your profiles."
	_assert(_label_texts(tabs.get_node(str(fs.UI_TAB_MODS))).has(banner), "the Mods tab shows the pack banner")
	for confirm in [false, true]:
		fs._unload_modpack_with_feedback(tabs)
		var d := _last_child(win) as ConfirmationDialog
		check_eq(Array(_label_texts(d)).filter(func(t: String): return t != ""), ["Could not unload modpack",
				"The backup for this pack is missing, so your previous profile cannot be restored.\n\n"
				+ "Keep the pack's mods as a profile named \"Kept\" and leave the pack?"], "confirm title and text")
		check_eq([d.ok_button_text, d.cancel_button_text], ["Keep as profile", "Cancel"], "confirm buttons")
		if confirm:
			d.confirmed.emit()
		else:
			d.canceled.emit()
		await _settle()
		check_eq(fs.forced.size(), 1 if confirm else 0, "force calls after %s" % ("Keep" if confirm else "Cancel"))
	check_eq(fs.get_active_modpack(), "", "no pack is active after the force")
	_assert(not _label_texts(tabs.get_node(str(fs.UI_TAB_MODS))).has(banner), "the Mods tab banner is gone")
	H.pack_cleanup(fs)
	tabs.free()
	fs.free()

# A Launch that cuts the Mods-row meta queue short still saves the mods that answered.
func _t20_launch_saves_the_meta_sidecar() -> void:
	begin("T20")
	var ms: Object = MetaStub.new()
	ms.set("_has_loaded", true)
	root.add_child(ms)
	var sidecar: String = ms._MODS_META_SIDECAR_PATH
	H.remove_user_file(sidecar)
	var keys := []
	for id in ["done", "slow"]:
		ms._fetch_meta_queued(ms.host_ref("vostokmods", id))
		keys.append(ms.host_ref_key(ms.host_ref("vostokmods", id)))
	await _settle()
	_assert(not FileAccess.file_exists(sidecar), "nothing saved mid-queue")
	ms.show_mod_ui()
	await _settle()
	(ms.get("_ui_launch_btn") as Button).pressed.emit()
	await _settle()
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar))
	check_eq((saved as Dictionary).keys() if saved is Dictionary else saved, keys.slice(0, 1), "Launch saved the answered mod")
	ms.hold = false
	await _settle()
	saved = JSON.parse_string(FileAccess.get_file_as_string(sidecar))
	check_eq((saved as Dictionary).keys() if saved is Dictionary else saved, keys, "the drain saves the rest")
	root.remove_child(ms)
	H.remove_user_file(sidecar)
	ms.free()

func _t31_scale_setting_clamp(ml: Object) -> void:
	begin("T31")
	var path := str(ml.UI_CONFIG_PATH)
	for c in [[5.0, 2.0], [0.2, 1.0], [1.5, 1.5]]:
		var cfg := ConfigFile.new()
		cfg.set_value("settings", "ui_scale", c[0])
		cfg.save(path)
		check_num(ml._ui_scale_setting(), c[1], "ui_scale %s clamped" % c[0])
	H.remove_user_file(path)
	H.remove_user_file(path + ".bak")

# _window_area reads the tree, so the loader joins it; headless, the root is 64x64.
func _t32_scale_fits_area() -> void:
	begin("T32")
	var sl: Object = load("res://stub_loader.gd").new()
	sl.set("_has_loaded", true)
	root.add_child(sl)
	var root_size := root.size
	root.size = Vector2i(1280, 720)
	var win := Window.new()
	sl._apply_ui_scale(win, 2.0)
	check_eq([Vector2i(root.get_visible_rect().size), win.size], [Vector2i(1280, 720), Vector2i(1240, 680)],
			"scale 2 fits the area")
	root.size = root_size
	win.free()
	root.remove_child(sl)
	sl.free()
	# Headless Linux segfaults when an embedded window is freed in the frame the root was resized.
	await _settle()

# A record under a day old is kept; an older one refetches.
func _t33_meta_refresh_window() -> void:
	begin("T33")
	var fs: Object = FetchStub.new()
	fs.set("_mods_meta_sidecar_loaded", true)
	var now := int(Time.get_unix_time_from_system())
	for c in [["fresh", 10, 0], ["stale", 2 * 86400, 1]]:
		var ref: Dictionary = fs.host_ref("vostokmods", c[0])
		var key: String = fs.host_ref_key(ref)
		fs._mods_meta_by_key[key] = {}
		fs._mods_meta_saved_at[key] = now - c[1]
		fs.fetched.clear()
		fs._load_host_meta(ref)
		check_eq(fs.fetched.size(), c[2], "%s record fetches" % c[0])
	check_eq([fs._arm_meta_retry("k"), fs._arm_meta_retry("k")], [true, false], "a second arm waits")
	fs.free()

# Only disabling a content mod asks; Keep enabled leaves it on.
func _t34_content_mod_confirm() -> void:
	begin("T34")
	var ts: Object = ToggleStub.new()
	var check := CheckBox.new()
	var state := {"tabs": null, "list": null}
	# [enabled, has_registry, answer, confirms, enabled after]
	for c in [[false, true, false, 1, true], [false, true, true, 1, false],
			[true, true, false, 0, true], [false, false, false, 0, false]]:
		var entry := H.mod_entry("zip:c.zip", "c", "1", {"enabled": not c[0], "has_registry": c[1]})
		var ents: Array[Dictionary] = [entry]
		ts.set("_ui_mod_entries", ents)
		ts.install = {"k": entry}
		ts.answer = c[2]
		ts.confirms.clear()
		check.set_pressed_no_signal(c[0])
		await ts._on_toggle("k", c[0], check, state)
		check_eq([ts.confirms.size(), entry["enabled"], check.button_pressed], [c[3], c[4], c[4]],
				"toggle %s registry %s answer %s" % c.slice(0, 3))
	check.free()
	ts.free()

func _t35_menu_button_order(ml: Object) -> void:
	begin("T35")
	for c in [[["Start", "Quit"], ["Start", "MetroMods", "Quit"]], [["Start"], ["Start", "MetroMods"]]]:
		var menu := Node.new()
		var main := Node.new()
		main.name = "Main"
		menu.add_child(main)
		var buttons := VBoxContainer.new()
		buttons.name = "Buttons"
		main.add_child(buttons)
		for n: String in c[0]:
			var b := Button.new()
			b.name = n
			buttons.add_child(b)
		ml._inject_mods_button(menu)
		ml._inject_mods_button(menu)
		check_eq(buttons.get_children().map(func(n: Node): return str(n.name)), c[1], "Mods sits before Quit")
		menu.free()

func _sorted_buttons(win: Window) -> Array:
	var texts := Array(_dialog_button_texts(_last_child(win)))
	texts.sort()
	return texts

# queue_free lands at the end of a frame, after process_frame resumes us.
func _settle() -> void:
	await process_frame
	await process_frame

func _dialog_button_texts(d: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var ok := (d as AcceptDialog).get_ok_button()
	for b in ok.get_parent().get_children():
		if b is Button:
			out.append((b as Button).text)
	return out

func _dump_all(ml: Object) -> void:
	begin("T9")
	_section("theme")
	var th: Theme = ml.make_dark_theme()
	_w("default_font_size=" + str(th.default_font_size))
	var types := Array(th.get_type_list())
	types.sort()
	for type in types:
		for kind in [["color", "color"], ["const", "constant"], ["fsize", "font_size"], ["icon", "icon"], ["sbox", "stylebox"]]:
			var names := Array(th.call("get_%s_list" % kind[1], type))
			names.sort()
			for n in names:
				var v: Variant = th.call("get_" + kind[1], n, type)
				if kind[0] == "icon":
					v = _tex_dump(v)
				elif kind[0] == "sbox":
					v = _sb_dump(v)
				_w("%s %s/%s=%s" % [kind[0], type, n, str(v)])

	# The launcher window, built in show_mod_ui's order (without the await).
	root.add_child(ml)
	var win: Window = ml._ui_create_window()
	root.remove_child(ml)
	_dump_factories(ml, win)

	var lroot: VBoxContainer = ml._ui_window_root(win)
	ml._ui_build_header(lroot, win)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lroot.add_child(tabs)
	lroot.add_child(HSeparator.new())
	ml._ui_build_bottom_bar(lroot, win)
	ml._ui_add_tabs(tabs)
	ml.refresh_launch_button_label()
	await _settle()
	_section("launcher_empty")
	_dump_root_layers()
	_node_dump(win, 0)

	_section("tab_switch")
	for i in [1, 2, 0]:
		tabs.current_tab = i
		_w("tab %d hint=%s" % [i, _norm(str(ml.get("_ui_hint_default")))])
	_section("modpacks_tab_after_switch")
	_node_dump(tabs.get_node(str(ml.UI_TAB_MODPACKS)), 0)

	var cfg := ConfigFile.new()
	cfg.set_value("profile.Default.enabled", "zip:a.vmz", true)
	cfg.set_value("profile.Default.enabled", "zip:gone.vmz", true)
	cfg.set_value("profile.Default.enabled", "zip:gone2.vmz", true)
	cfg.set_value("profile.Default.priority", "zip:a.vmz", 3)
	cfg.set_value("profile.Second.enabled", "zip:a.vmz", false)
	cfg.set_value("mod_sources", "zip:a.vmz", JSON.stringify({"provider": "vostokmods", "id": "alpha", "version": "1"}))
	cfg.set_value("mod_sources", "zip:gone2.vmz", JSON.stringify({"provider": "vostokmods", "id": "gone-two", "version": "2"}))
	cfg.save("user://mod_config.cfg")
	ml.set("_active_profile", "Default")
	var ents: Array[Dictionary] = [
		{"mod_name": "Alpha", "mod_id": "alpha", "enabled": true, "priority": 3, "ext": "vmz", "profile_key": "zip:a.vmz",
			"file_name": "a.vmz", "full_path": "user://nope/a.vmz", "has_registry": true,
			"required_dependencies": ["beta"], "optional_dependencies": ["gamma"],
			"dependency_blockers": ["beta"], "dependency_blockers_info": [{"display": "Beta (beta)", "status": "missing", "fixable": true}],
			"warnings": ["warn1"], "dependency_warnings": ["dw"], "author_notes": ["note"],
			"duplicates_hidden": [{"file_name": "old.vmz", "version": "1"}],
			"profile_version_mismatch": {"stored": "1", "current": "2"}, "dependency_ignored": false},
		{"mod_name": "Folder", "mod_id": "folder", "enabled": false, "priority": 1, "ext": "folder", "profile_key": "folder:f",
			"file_name": "f", "full_path": "user://nope/f", "dependency_ignored": true, "has_registry": false,
			"required_dependencies": [], "optional_dependencies": [], "dependency_blockers": [],
			"dependency_warnings": [], "warnings": [], "author_notes": [],
			"dependency_blockers_info": [{"display": "Zed (zed)", "status": "hidden_folder"}]},
	]
	ml.set("_ui_mod_entries", ents)
	ml.set("_developer_mode", true)
	ml.set("_mod_updates_state", {"zip:a.vmz": {"mod_name": "Alpha", "current_version": "1", "latest_version": "2",
		"full_path": "user://nope/a.vmz", "ref": {"provider": "vostokmods", "id": "alpha"}}})
	H.write_zip(PACK_ZIP, {"profile.json": JSON.stringify({"metroprofile": 1, "name": "Crafted Pack", "author": "tester",
		"description": "A pack for the harness.",
		"enabled": {"zip:a.vmz": true, "zip:gone.vmz": true, "zip:off.vmz": false},
		"sources": {"zip:gone.vmz": {"provider": "vostokmods", "id": "gone", "version": "1"}}})}, _report)

	ml._rebuild_mods_tab(tabs)
	ml._rebuild_modpacks_tab(tabs)
	await _settle()
	_section("launcher_entries")
	_node_dump(win, 0)

	await _t10_rebuild_keeps_scroll(ml, tabs)
	_t23_browse_repaints_gets(ml, tabs)
	begin("T9")
	await _dump_browse(ml, win, tabs)
	await _dump_packs(ml, win, tabs)
	await _dump_dialogs(ml, win, tabs)
	await _t11_missing_rows_remove(ml, win)

	# The window frees its click shield on the way out.
	ml.set("_ui_window", null)
	win.queue_free()
	await _settle()
	_section("teardown")
	_dump_root_layers()
	_w("root children=%d" % root.get_child_count())

# Each factory output sits under the launcher window so theme lookups resolve.
func _dump_factories(ml: Object, win: Window) -> void:
	var holder := VBoxContainer.new()
	win.add_child(holder)
	_section("factories")
	holder.add_child(ml._make_sub_label("abc", Color.RED, "tip"))
	holder.add_child(ml._make_sub_label("abc", Color.RED))
	holder.add_child(ml._make_sub_label("abc", Color.RED, "", 13))
	holder.add_child(ml._make_head_label("Head"))
	holder.add_child(ml._make_head_label("Head", Color.GREEN))
	holder.add_child(ml._make_row_action("Act", Color.BLUE, "tip"))
	var b: Dictionary = ml._make_banner("hello", Color.BLUE)
	holder.add_child(b["panel"])
	_w("banner keys=" + str(b.keys()))
	var plate_root := VBoxContainer.new()
	holder.add_child(plate_root)
	ml._make_header_plate(plate_root, "Plate", 14)
	var btn := Button.new()
	btn.text = "primary"
	ml.style_primary_button(btn)
	holder.add_child(btn)
	var dbtn := Button.new()
	dbtn.text = "danger"
	ml.style_danger_button(dbtn)
	holder.add_child(dbtn)
	var mbtn := Button.new()
	ml.style_dialog_primary_button(mbtn)
	holder.add_child(mbtn)
	var opt := OptionButton.new()
	ml._style_option_popup(opt)
	holder.add_child(opt)
	_node_dump(holder, 0)
	_w("box " + _sb_dump(ml._make_box(Color.RED)))
	_w("box " + _sb_dump(ml._make_box(Color.RED, Color.BLUE, 3, 4, 2)))
	_w("box dialog " + _sb_dump(ml._make_dialog_panel_stylebox()))
	_w("box badge " + _sb_dump(ml._make_badge_stylebox()))
	_w("box badge_ok " + _sb_dump(ml._make_badge_stylebox(Color.GREEN, Color.BLACK)))
	_w("box button " + _sb_dump(ml._make_button_stylebox(Color.GRAY, Color.WHITE)))
	_w("box focus " + _sb_dump(ml._make_focus_stylebox()))
	_w("fit " + str(ml._dialog_fit_size(Vector2i(660, 540))) + " " + str(ml._dialog_fit_size(Vector2i(4000, 4000))))
	win.remove_child(holder)
	holder.free()

func _t11_missing_rows_remove(ml: Object, win: Window) -> void:
	begin("T11")
	_press(win, "Remove this missing mod from this profile")
	await _settle()
	var cfg := ConfigFile.new()
	cfg.load("user://mod_config.cfg")
	var keys := cfg.get_section_keys("profile.Default.enabled")
	_assert(keys.has("zip:a.vmz") and keys.has("zip:gone2.vmz") and not keys.has("zip:gone.vmz"),
			"Remove drops its own key (left %s)" % str(keys))
	_press(win, "Remove all missing mods from this profile")
	(_last_child(win) as ConfirmationDialog).confirmed.emit()
	await _settle()
	cfg = ConfigFile.new()
	cfg.load("user://mod_config.cfg")
	keys = cfg.get_section_keys("profile.Default.enabled")
	_assert(keys.has("zip:a.vmz") and not keys.has("zip:gone2.vmz"), "Remove all drops missing keys (left %s)" % str(keys))
	_assert(_find_button(win, "Remove all missing mods from this profile") == null, "the missing section is gone")

# The rebuilt tab is re-added, so the tab on screen is kept by name.
# Selecting Browse repaints pack Get buttons from mods/, so a pack deleted elsewhere offers Get again.
func _t23_browse_repaints_gets(ml: Object, tabs: TabContainer) -> void:
	begin("T23")
	var dir := "user://t23_packs"
	DirAccess.make_dir_recursive_absolute(dir)
	H.write_zip(dir + "/vostokmods-gone.zip", {"profile.json": JSON.stringify({"metroprofile": 1, "name": "Gone",
		"enabled": {}, "hosted": {"provider": "vostokmods", "slug": "gone", "url": "https://vostokmods.net/modpack/gone"}})}, _report)
	ml.set("_mods_dir", dir)
	var state: Dictionary = ml.get("_packs_state")
	var btn := Button.new()
	state["get_btns"] = {"gone": btn}
	for c in [[true, "Added", "a pack in mods/ reads Added"], [false, "Get", "a deleted pack offers Get"]]:
		if not c[0]:
			DirAccess.remove_absolute(dir + "/vostokmods-gone.zip")
		tabs.current_tab = 0
		tabs.current_tab = 1
		check_eq(btn.text, c[1], c[2])
	state["get_btns"] = {}
	btn.free()
	tabs.current_tab = 0
	ml.set("_mods_dir", MODS_DIR)
	ml.set("_modpack_entries", ml.collect_modpack_metadata())

func _t10_rebuild_keeps_scroll(ml: Object, tabs: TabContainer) -> void:
	begin("T10")
	# The scroll restore waits a frame on get_tree(). A cooldown on every
	# host keeps the in-tree loader from sending anything meanwhile.
	for p in ml.host_providers():
		ml.host_arm_cooldown(p, 600000)
	root.add_child(ml)
	var scrolls := [["_ui_mods_scroll", "_rebuild_mods_tab", func(): return ml.get("_ui_mods_scroll")],
			["_ui_modpacks_scroll", "_rebuild_modpacks_tab", func(): return ml.get("_ui_modpacks_scroll")]]
	for c in scrolls:
		# A list built on a hidden tab has no layout to scroll; showing the Modpacks tab rebuilds it.
		for i in tabs.get_tab_count():
			if tabs.get_tab_control(i).is_ancestor_of(c[2].call()):
				tabs.current_tab = i
		await _settle()
		var old_scroll: ScrollContainer = c[2].call()
		old_scroll.custom_minimum_size.y = 0
		var list: Control = old_scroll.get_child(0)
		list.custom_minimum_size.y = 4000
		await _settle()
		old_scroll.scroll_vertical = 37
		var saved := old_scroll.scroll_vertical
		check_eq(saved, 37, "%s scrolls in the harness" % c[0])
		tabs.current_tab = 1
		ml.call(c[1], tabs)
		_assert(tabs.current_tab == 1 and str(tabs.get_tab_control(1).name) == str(ml.UI_TAB_BROWSE),
				"%s keeps Browse on screen" % c[1])
		var new_scroll: ScrollContainer = c[2].call()
		_assert(new_scroll != old_scroll, "%s is a new list" % c[0])
		new_scroll.get_child(0).custom_minimum_size.y = 4000
		await _settle()
		check_eq(new_scroll.scroll_vertical, saved, "%s keeps its scroll" % c[0])
	tabs.current_tab = 0
	ml.call("_rebuild_mods_tab", tabs)
	check_eq(tabs.current_tab, 0, "rebuilding the shown tab shows it")
	await _settle()
	# Out of the tree a later rebuild must find nothing to restore.
	for c in scrolls:
		(c[2].call() as ScrollContainer).scroll_vertical = 0
	root.remove_child(ml)
	(ml.get("_host_cooldown_until_ms") as Dictionary).clear()

# The offline landing from a saved snapshot, the other host, and a results listing.
func _dump_browse(ml: Object, win: Window, tabs: TabContainer) -> void:
	var rows := [
		_summary(ml, "alpha", "Alpha", "f1"),
		_summary(ml, "beta-mod", "Beta Mod", "f2"),
		_summary(ml, "no-file", "No File", ""),
	]
	var snap := {"sections": [{"title": "Popular", "rows": rows}], "saved_at_unix": int(Time.get_unix_time_from_system())}
	H.write_text(ml._browse_landing_snapshot_path("vostokmods"), JSON.stringify(snap))

	_section("browse_tab_cached")
	var bt: Control = ml.build_browse_tab(tabs)
	win.add_child(bt)
	await _settle()
	_node_dump(bt, 0)

	_section("browse_tab_other_host")
	var src_opt := _find_option(bt, "Vostok Mods")
	if _assert(src_opt != null, "the Browse tab has a source menu"):
		src_opt.select(1)
		src_opt.item_selected.emit(1)
	await _settle()
	_node_dump(bt, 0)
	win.remove_child(bt)
	bt.free()

	_section("browse_results")
	var state := {"provider": "vostokmods", "providers": PackedStringArray(["vostokmods"]), "views": {},
		"tabs": tabs, "noun": "mods", "on_get": func(_d, _b): pass, "on_toggle": func(_k, _e, _c): pass}
	var cont := VBoxContainer.new()
	win.add_child(cont)
	state.merge(ml._browse_build_toolbar(state, cont))
	state.merge(ml._browse_build_list_area(cont))
	ml._browse_apply_provider_controls(state, "vostokmods")
	(ml._browse_view(state) as Dictionary)["query"] = "alp"
	ml._browse_render_rows(state, rows)
	await _settle()
	_node_dump(cont, 0)
	win.remove_child(cont)
	cont.free()

# Browse on Modpacks, the pack list offline from a saved snapshot; launcher_empty pins Mods.
func _dump_packs(ml: Object, win: Window, tabs: TabContainer) -> void:
	var rows := [_pack_summary(ml, "joni-pack", "Joni Pack", 31), _pack_summary(ml, "big-jay", "Big Jay", -1)]
	var snap := {"sections": [{"title": "updated", "rows": rows}], "saved_at_unix": int(Time.get_unix_time_from_system())}
	var snap_path: String = ml._browse_landing_snapshot_path("vostokmods_packs")
	H.write_text(snap_path, JSON.stringify(snap))
	_section("packs_pane_cached")
	ml.set("_packs_state", {})
	ml._set_ui_cfg_value("settings", "browse_kind", "modpacks")
	var pt: Control = ml.build_browse_tab(tabs)
	win.add_child(pt)
	await _settle()
	_node_dump(pt, 0)
	win.remove_child(pt)
	pt.free()
	ml._set_ui_cfg_value("settings", "browse_kind", "mods")
	(ml.get("_browse_landing_snapshots") as Dictionary).erase("vostokmods_packs")
	DirAccess.remove_absolute(snap_path)

func _summary(ml: Object, id: String, mod_name: String, file_id: String) -> Dictionary:
	var s: Dictionary = ml.host_empty_summary()
	s["ref"] = ml.host_ref("vostokmods", id)
	s["name"] = mod_name
	s["author_name"] = "someone"
	s["version"] = "1.0"
	s["downloads"] = 3
	s["category_name"] = "Weapons"
	s["updated_at"] = "2026-01-02T03:04:05Z"
	s["default_file_id"] = file_id
	return s

func _find_option(node: Node, first_item: String) -> OptionButton:
	for c in node.get_children():
		if c is OptionButton and (c as OptionButton).item_count > 0 and (c as OptionButton).get_item_text(0) == first_item:
			return c
		var found := _find_option(c, first_item)
		if found != null:
			return found
	return null

func _dump_dialogs(ml: Object, win: Window, tabs: TabContainer) -> void:
	_section("dialog new_profile")
	ml._show_new_profile_dialog(tabs)
	_dump_last(win)

	_section("dialog rename_profile")
	ml._show_rename_profile_dialog(tabs)
	_dump_last(win)

	for c in [["delete_profile", "Delete the active profile"], ["remove_mod", "Permanently delete this mod"],
			["remove_all_missing", "Remove all missing mods from this profile"],
			["host_detail_loading", "Alpha  --  click for Vostok Mods details"]]:
		_section("dialog " + c[0])
		_press(win, c[1])
		_dump_last(win)

	for count in [1, 2]:
		_section("dialog content_confirm %d" % count)
		root.add_child(ml)
		ml._confirm_disable_content_mod("X", count)
		var cd: Node = _last_child(win)
		_node_dump(cd, 0)
		(cd as ConfirmationDialog).canceled.emit()
		await process_frame
		await process_frame
		root.remove_child(ml)
		_w("freed=%s" % str(not is_instance_valid(cd) or cd.is_queued_for_deletion()))
		await process_frame

	_section("dialog accept")
	ml._show_accept_dialog("T", "M")
	_dump_last(win)
	_section("dialog error")
	ml._show_error_dialog("Err", "Something failed")
	_dump_last(win)
	_section("dialog info")
	ml._show_info_toast("All good")
	_dump_last(win)
	_section("dialog loader_update")
	ml._show_modloader_update_dialog("9.9.9")
	_dump_last(win)

	_section("dialog browse_detail")
	var summary: Dictionary = ml.host_empty_summary()
	summary["ref"] = ml.host_ref("vostokmods", "alpha-two")
	summary["name"] = "Alpha Two"
	summary["author_name"] = "someone"
	summary["version"] = "1.2"
	summary["downloads"] = 10
	summary["short_description"] = "Short **text**."
	summary["default_file_id"] = "f1"
	ml._show_browse_mod_detail_dialog(summary, func(_d, _b): pass)
	_dump_last(win)

	_section("dialog browse_detail_installed")
	var inst: Dictionary = summary.duplicate(true)
	inst["ref"] = ml.host_ref("vostokmods", "alpha")
	ml._show_browse_mod_detail_dialog(inst, func(_d, _b): pass)
	_dump_last(win)

	_section("dialog modpack_detail")
	_press(win, "Details")
	_dump_last(win)

	# Offline, so the mod list shows the error line T15 asserts.
	_section("dialog pack_detail_remote")
	ml._listing_pack_dialog(_pack_summary(ml, "joni-pack", "Joni Pack", 31))
	_dump_last(win)

	_section("dialog apply_confirm")
	var packs: Array = ml.get("_modpack_entries")
	ml._apply_modpack_with_ui_flow(packs[0], tabs)
	_dump_last(win)

	_section("dialog progress")
	var pui: Dictionary = ml._build_modpack_progress_dialog("Crafted Pack")
	(pui["dialog"] as AcceptDialog).popup_centered()
	_dump_last(win)
	_section("dialog progress_retry")
	ml._build_modpack_progress_dialog("", "Retrying failed downloads")
	_dump_last(win)

	_section("dialog failure")
	ml._show_modpack_failure_dialog(2, [
		{"profile_key": "zip:gone.vmz", "error": "not found", "ref": ml.host_ref("vostokmods", "gone")},
		{"profile_key": "zip:manual.vmz", "error": "no source", "ref": ml.host_ref("", "")},
	], tabs)
	_dump_last(win)

	# A pack active with no backup; the refusal writes nothing, so the cfg goes back as it was.
	_section("dialog force_unload")
	var cfg_bytes := FileAccess.get_file_as_bytes("user://mod_config.cfg")
	var cfg := ConfigFile.new()
	cfg.load("user://mod_config.cfg")
	cfg.set_value("settings", "active_modpack", "Crafted Pack")
	cfg.save("user://mod_config.cfg")
	ml._unload_modpack_with_feedback(tabs)
	_dump_last(win)
	H.write_bytes("user://mod_config.cfg", cfg_bytes)

func _press(node: Node, label: String) -> void:
	var b := _find_button(node, label)
	if _assert(b != null, "a button '%s' to press" % label):
		b.pressed.emit()

func _find_button(node: Node, label: String) -> Button:
	for c in node.get_children():
		if c is Button and ((c as Button).text == label or (c as Button).tooltip_text == label):
			return c
		var found := _find_button(c, label)
		if found != null:
			return found
	return null

func _last_child(win: Window) -> Node:
	return win.get_child(win.get_child_count() - 1)

func _free_last_child(win: Window) -> void:
	var last := _last_child(win)
	win.remove_child(last)
	last.free()

func _dump_last(win: Window) -> void:
	_node_dump(_last_child(win), 0)
	_free_last_child(win)

# The click shield the launcher puts on the game's root.
func _dump_root_layers() -> void:
	for c in root.get_children():
		if c is CanvasLayer:
			_node_dump(c, 0)

func _w(s: String) -> void:
	_out.append(s)

func _section(title: String) -> void:
	_w("=== " + title)

# Machine-specific text out: the user:// root and the loader version.
func _norm(s: String) -> String:
	return s.replace(_user_abs + "/", "user://").replace(_user_abs, "user:/").replace(_version, "<version>")

func _sb_dump(sb: StyleBox) -> String:
	if sb == null:
		return "null"
	var parts := PackedStringArray([sb.get_class()])
	for p in sb.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var n: String = p["name"]
		if n.begins_with("resource_") or n == "script":
			continue
		parts.append("%s=%s" % [n, str(sb.get(n))])
	return " ".join(parts)

func _tex_dump(t: Texture2D) -> String:
	if t == null:
		return "null"
	var img := t.get_image()
	return "%s %dx%d %s" % [t.get_class(), img.get_width(), img.get_height(), str(hash(img.get_data()))]

const _PROPS := ["text", "tooltip_text", "placeholder_text", "mouse_filter", "clip_text", "text_overrun_behavior",
	"autowrap_mode", "size_flags_horizontal", "size_flags_vertical", "custom_minimum_size",
	"disabled", "flat", "horizontal_alignment", "vertical_alignment", "alignment", "button_pressed",
	"min_value", "max_value", "value", "underline", "modulate", "max_length",
	"expand_mode", "stretch_mode", "selected", "item_count", "dialog_hide_on_ok", "dialog_close_on_escape",
	"ok_button_text", "cancel_button_text", "title", "dialog_text", "min_size", "size", "borderless", "exclusive",
	"always_on_top", "transient", "transparent", "transparent_bg", "dialog_autowrap", "wrap_controls",
	"gui_embed_subwindows", "content_scale_factor", "split_offset", "vertical_scroll_mode", "horizontal_scroll_mode",
	"one_shot", "wait_time", "layer", "visible", "icon", "button_group", "bbcode_enabled", "fit_content",
	"selection_enabled", "meta_underlined", "anchor_right", "anchor_bottom"]

func _node_dump(n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var nm := str(n.name)
	if nm.begins_with("@"):
		nm = "@"
	var line := "%s%s [%s]" % [pad, n.get_class(), nm]
	for p in _PROPS:
		if p in n:
			var v: Variant = n.get(p)
			if v is Texture2D:
				v = _tex_dump(v)
			elif v is ButtonGroup:
				v = "group"
			line += " %s=%s" % [p, str(v)]
	if n is OptionButton:
		var o := n as OptionButton
		for i in o.item_count:
			line += " item%d=%s/%s" % [i, o.get_item_text(i), str(o.get_item_metadata(i))]
		var pop := o.get_popup()
		line += " popup(top=%s transient=%s theme=%s)" % [pop.always_on_top, pop.transient, pop.theme != null]
	if n is Control:
		var c := n as Control
		for cname in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color", "default_color"]:
			if c.has_theme_color_override(cname):
				line += " ov_%s=%s" % [cname, str(c.get_theme_color(cname))]
			elif c.is_inside_tree():
				line += " %s=%s" % [cname, str(c.get_theme_color(cname))]
		if c.has_theme_font_size_override("font_size"):
			line += " ov_fs=%d" % c.get_theme_font_size("font_size")
		elif c.is_inside_tree():
			line += " fs=%d" % c.get_theme_font_size("font_size")
		for cn in ["separation", "margin_left", "margin_right", "margin_top", "margin_bottom"]:
			if c.has_theme_constant_override(cn):
				line += " ov_%s=%d" % [cn, c.get_theme_constant(cn)]
		for sbn in ["panel", "normal", "hover", "pressed", "disabled", "focus"]:
			if c.has_theme_stylebox_override(sbn):
				line += " ov_sb_%s={%s}" % [sbn, _sb_dump(c.get_theme_stylebox(sbn))]
		line += " has_theme=%s" % (c.theme != null)
	if n is Window:
		var w := n as Window
		for sbn in ["panel", "embedded_border", "embedded_unfocused_border"]:
			if w.has_theme_stylebox_override(sbn):
				line += " ov_sb_%s={%s}" % [sbn, _sb_dump(w.get_theme_stylebox(sbn))]
		line += " has_theme=%s" % (w.theme != null)
	if n.has_meta("browse_ref_key"):
		line += " meta_ref_key=%s" % str(n.get_meta("browse_ref_key"))
	var conns := 0
	for s in n.get_signal_list():
		conns += n.get_signal_connection_list(s["name"]).size()
	line += " conns=%d" % conns
	_w(_norm(line))
	for ch in n.get_children(true):
		_node_dump(ch, depth + 1)
