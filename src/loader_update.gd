## Loader release checks and their launcher notification.
## Mod updates are a separate flow in the Mods tab.

# GitHub repository that publishes loader releases, for the self-update
# check; "" disables it. Release tags are "v<MODLOADER_VERSION>" and the
# latest-release endpoint already excludes drafts and prereleases.
const MODLOADER_GITHUB_REPO := "ametrocavich/vostok-mod-loader"
const MODLOADER_RELEASES_API_URL := "https://api.github.com/repos/%s/releases/latest"
const MODLOADER_RELEASES_PAGE_URL := "https://github.com/%s/releases/latest"

# Self-update check state, kept for the session.
var _modloader_latest_version: String = ""
# Page of the release the self-update check found; "" until it runs, in
# which case the alert falls back to the repository's latest-release page.
var _modloader_release_url: String = ""
var _ui_update_alert_btn: LinkButton = null

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
	# compare_versions follows semver on prereleases: a stable release
	# supersedes a prerelease of the same version, and between two prereleases
	# only a strictly higher one is an update.
	if compare_versions(latest, MODLOADER_VERSION) <= 0:
		return

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
