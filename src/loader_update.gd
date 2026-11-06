## The loader's own release check and its launcher notice; mod updates live in the Mods tab.

# "" disables the check. Tags are "v<MODLOADER_VERSION>"; the latest-release
# endpoint already excludes drafts and prereleases.
const MODLOADER_GITHUB_REPO := "ametrocavich/vostok-mod-loader"
const MODLOADER_RELEASES_API_URL := "https://api.github.com/repos/%s/releases/latest"
const MODLOADER_RELEASES_PAGE_URL := "https://github.com/%s/releases/latest"

var _modloader_release_url: String = ""
var _ui_update_alert_btn: LinkButton = null

func _modloader_release_page_url() -> String:
	if _modloader_release_url != "":
		return _modloader_release_url
	return MODLOADER_RELEASES_PAGE_URL % MODLOADER_GITHUB_REPO

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
	# Semver on prereleases: a stable release supersedes a prerelease of the same
	# version, and between two prereleases only a strictly higher one is an update.
	if compare_versions(latest, MODLOADER_VERSION) <= 0:
		return

	if is_instance_valid(_ui_update_alert_btn):
		_ui_update_alert_btn.text = "v%s available -- click to open the release page" % latest
		_ui_update_alert_btn.add_theme_color_override("font_color", COL_ACCENT)
		_ui_update_alert_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)

	if str(_get_ui_cfg_value("modloader_update", "last_seen_version", "")) != latest:
		_show_modloader_update_dialog(latest)

# Either button records the version, so the dialog stays quiet until the next release.
func _show_modloader_update_dialog(latest: String) -> void:
	if not is_instance_valid(_ui_window):
		return
	var d := ConfirmationDialog.new()
	d.title = "Mod Loader update available"
	d.ok_button_text = "Open page"
	d.cancel_button_text = "Dismiss"
	d.min_size = Vector2(440, 120)
	d.dialog_text = "A newer version of the Mod Loader is available.\n\n" \
			+ "    Installed: v%s\n    Available: v%s\n\n" % [MODLOADER_VERSION, latest] \
			+ "Open the release page to download?"
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			OS.shell_open(_modloader_release_page_url())
			_set_ui_cfg_value("modloader_update", "last_seen_version", latest)
			d.queue_free(),
		func():
			_set_ui_cfg_value("modloader_update", "last_seen_version", latest)
			d.queue_free()
	)
	d.popup_centered()
