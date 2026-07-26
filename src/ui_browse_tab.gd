func build_browse_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Shared mutable state. Lambdas capture primitives by VALUE in GDScript;
	# routing through a Dictionary lets all the closures (search/sort/category
	# handlers, load-more, do_get) read and mutate the same fields. "discover"
	# mode hits popular-and-latest; any user input flips to "filter" mode which
	# uses the paginated list_mods endpoint.
	var state := {
		"mode": "discover",
		"query": "",
		"sort": "bumped_at",
		# featured: true while the sort dropdown sits on item 0 ("Featured",
		# the curated landing). The empty-input handlers key on THIS flag --
		# not on sort == "bumped_at" -- so "Recently updated" is a real sort
		# that routes through the filter fetch like every other sort.
		"featured": true,
		"category_id": 0,
		"next_page": 1,
		"has_more": false,
		# fetch_seq: monotonic counter incremented at the START of every list
		# fetch (discover or filter). Each fetch captures its own seq, then
		# checks it after await; if state["fetch_seq"] has advanced, a newer
		# fetch is in flight and this one's result must NOT render. Without
		# this guard, rapid sort/category clicks let the slowest response win
		# whichever finishes last -- so the UI shows results that don't match
		# the dropdown's current value.
		"fetch_seq": 0,
		# downloading_id: mws_id currently being downloaded. -1 = idle.
		# Singletons (not concurrent) because the temp-file + collect rebuild
		# would race; additional Get clicks land in download_queue and run
		# sequentially after the current one finishes.
		"downloading_id": -1,
		# download_queue: Array of {mod_data, get_btn} dicts awaiting their
		# turn. on_get drains this FIFO once the current download completes.
		"download_queue": [],
		# queue_failures / queue_done_total: per-batch failure report. A failed
		# item's status line is synchronously overwritten while the queue
		# drains (next item's "Downloading...", then the success re-fetch), so
		# failures accumulate here and are summarized once the queue empties.
		"queue_failures": [],
		"queue_done_total": 0,
		# categories_loaded / categories_loading: the category dropdown is
		# populated by a one-shot fetch at tab build. These gate the retry
		# paths (banner Retry, next successful list fetch) so the dropdown can
		# recover from a failed first fetch without ever double-populating.
		"categories_loaded": false,
		"categories_loading": false,
	}

	# -- Toolbar: search + sort + category --
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	var search_input := LineEdit.new()
	search_input.placeholder_text = "Search mods..."
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size.x = 200
	search_input.custom_minimum_size.y = CTRL_H
	# The API 422s on a query over 150 chars, which our non-2xx handling would
	# report as a connection problem no retry could fix. Stop it at the input.
	search_input.max_length = MWS_QUERY_MAX_LEN
	toolbar.add_child(search_input)

	var sort_dropdown := OptionButton.new()
	# Index -> API sort enum. Item 0 "Featured" is NOT a sort: it represents
	# the curated Popular+Latest discover landing. It still maps to bumped_at
	# in sort_keys so a search typed while Featured is selected has a sane
	# sort. The real sorts follow; search honors the chosen sort (no
	# best_match override).
	sort_dropdown.add_item("Featured")
	sort_dropdown.add_item("Recently updated")
	sort_dropdown.add_item("Most downloaded")
	sort_dropdown.add_item("Most liked")
	sort_dropdown.add_item("Most viewed")
	sort_dropdown.add_item("Newest")
	var sort_keys := ["bumped_at", "bumped_at", "downloads", "likes", "views", "published_at"]
	# Explicit, not incidental: the resting label is the Featured landing.
	sort_dropdown.select(0)
	toolbar.add_child(sort_dropdown)

	var category_dropdown := OptionButton.new()
	category_dropdown.add_item("All categories")
	category_dropdown.set_item_metadata(0, 0)  # category_id 0 = no filter
	toolbar.add_child(category_dropdown)

	# OptionButton popups are sub-Windows; the launcher's always_on_top leaves
	# them stranded behind the main window unless we explicitly raise them.
	# Theme assignment is also explicit because theme inheritance does not
	# always cross Window boundaries in Godot 4. Same fix the profile_opt
	# dropdown applies in build_mods_tab. Unfolded rather than looped because
	# iterating over an Array literal makes the loop variable untyped Variant
	# and `var popup := dd.get_popup()` then fails type inference at parse time.
	var sort_popup := sort_dropdown.get_popup()
	sort_popup.always_on_top = true
	sort_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		sort_popup.theme = _ui_window.theme

	var cat_popup := category_dropdown.get_popup()
	cat_popup.always_on_top = true
	cat_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		cat_popup.theme = _ui_window.theme

	container.add_child(HSeparator.new())

	# Offline-grace banner slot. show_browse_banner (below) fills it when a
	# list fetch fails (cached results / unreachable / rate limit) and the
	# success paths clear it. Hidden when empty so it costs no height on the
	# happy path; it sits above the list as a sibling, never over it, so it
	# cannot block interaction with rendered rows.
	var banner_slot := VBoxContainer.new()
	banner_slot.visible = false
	container.add_child(banner_slot)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", FS_BODY)
	status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(status_lbl)

	# One status-text pattern (spec section 6): every Browse state change
	# routes through here so the color always matches the message --
	# COL_AMBER in-progress, COL_OK success, COL_ERR failure, COL_TEXT_DIM
	# neutral/meta. font_color override, never modulate (modulate would
	# also tint child icons; spec jank class 5). Assigned BEFORE every
	# closure that calls it, so by-value capture picks up a real Callable
	# (handoff bug class 1).
	var set_status := func(text: String, color: Color):
		if not is_instance_valid(status_lbl):
			return
		status_lbl.text = text
		status_lbl.add_theme_color_override("font_color", color)

	# Mirror of set_status for downloads started from the detail dialog. The
	# dialog is exclusive and covers the tab's status label, so failures and
	# already-downloading/queued notices were invisible behind it -- the
	# dialog's button just flipped back to "Download" with no explanation.
	# _show_browse_mod_detail_dialog tags its Download button with an
	# in-dialog status Label (meta "browse_dialog_status"); when the button
	# that initiated the download carries that tag, render the message there
	# too. No-op for list-row buttons and freed dialogs.
	var set_dl_status := func(get_btn: Variant, text: String, color: Color):
		if not is_instance_valid(get_btn):
			return
		var btn := get_btn as Button
		if btn == null or not btn.has_meta("browse_dialog_status"):
			return
		var lbl_v: Variant = btn.get_meta("browse_dialog_status")
		if is_instance_valid(lbl_v) and lbl_v is Label:
			var lbl := lbl_v as Label
			lbl.visible = true
			lbl.text = text
			lbl.tooltip_text = text
			lbl.add_theme_color_override("font_color", color)

	# Failure reason for the offline banner. The 429 cooldown owns the copy
	# while it is armed (rate-limited is actionable-by-waiting, unreachable
	# is not); otherwise the generic unreachable line.
	var browse_fail_reason := func() -> String:
		# Single source for the rate-limit sentence: mws_error_status() returns
		# the "rate limit reached, try again in Ns" copy when a cooldown is armed
		# and the unreachable line otherwise -- identical to the old inline
		# duplicate, but now the wording can't drift from the status label's.
		return mws_error_status("ModWorkshop is unreachable.")

	var clear_browse_banner := func():
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		banner_slot.visible = false

	# Banner with a Retry action (spec section 6: banner via the one
	# builder; edge_color COL_AMBER = notice such as showing-cached-results,
	# COL_ERR = error such as no-cached-data, matching the adjacent status
	# label's color). saved_at_unix > 0 adds a
	# "Last refreshed Xm ago" note in FS_META COL_TEXT_DIM (spec section 7:
	# meta info never parenthetical in the body label). Retry re-runs the
	# CURRENT view's fetch through `state`: this lambda is created before
	# do_discover_fetch / do_filter_fetch are assigned, and lambdas capture
	# locals by value at creation (handoff bug class 1), so the state
	# dictionary is the only route to their real bodies.
	var show_browse_banner := func(text: String, saved_at_unix: int, edge_color: Color):
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		var banner := _make_banner(text, edge_color)
		var banner_row: HBoxContainer = banner["row"]
		if saved_at_unix > 0:
			var age_lbl := Label.new()
			age_lbl.text = "Last refreshed " + _format_age(saved_at_unix)
			age_lbl.add_theme_font_size_override("font_size", FS_META)
			age_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			banner_row.add_child(age_lbl)
		var retry_btn := Button.new()
		retry_btn.text = "Retry"
		banner_row.add_child(retry_btn)
		retry_btn.pressed.connect(func():
			# The category dropdown's one-shot fetch may have failed in the
			# same outage that raised this banner; Retry is the tab's recovery
			# affordance, so repopulate it too (guarded no-op once loaded).
			(state["fn_populate_categories"] as Callable).call()
			if str(state["mode"]) == "discover":
				(state["fn_discover_fetch"] as Callable).call()
			else:
				(state["fn_filter_fetch"] as Callable).call(false)
		)
		banner_slot.add_child(banner["panel"])
		banner_slot.visible = true

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	# Right margin clears the vertical scrollbar so the Get button on each row
	# doesn't sit underneath it. ScrollContainer in Godot 4 lays content out
	# at full width and OVERLAYS the scrollbar -- without this margin the
	# rightmost pixels of every row hide behind it.
	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_wrap.add_child(list)

	var load_more_btn := Button.new()
	load_more_btn.text = "Load more"
	load_more_btn.visible = false
	container.add_child(load_more_btn)

	# Map mws_id -> entry (or absent if not installed). Recomputed every
	# render because re-discovery after a successful Get rewrites
	# _ui_mod_entries; rows flip from Get -> enable-toggle next render
	# without a UI close/reopen.
	var compute_install_map := func() -> Dictionary:
		var out: Dictionary = {}
		for entry in _ui_mod_entries:
			var cfg: ConfigFile = entry.get("cfg")
			if cfg == null:
				continue
			if not cfg.has_section_key("updates", "modworkshop"):
				continue
			var mws_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
			if mws_id > 0:
				out[mws_id] = entry
		return out

	# Forward declarations: on_get's success branch + queue processor re-
	# render the current view to flip duplicate Get buttons, so the fetch
	# callables must be in scope. Bodies are assigned below.
	var do_discover_fetch: Callable
	var do_filter_fetch: Callable

	# Enable/disable toggle from the Browse row. Mutates the entry in
	# _ui_mod_entries (Dictionary references), saves via _save_ui_config,
	# rebuilds the Mods tab so its row reflects the change.
	var on_toggle := func(mws_id: int, enabled: bool, check: CheckBox):
		for entry in _ui_mod_entries:
			var cfg: ConfigFile = entry.get("cfg")
			if cfg == null:
				continue
			if not cfg.has_section_key("updates", "modworkshop"):
				continue
			var entry_mws := int(str(cfg.get_value("updates", "modworkshop", "0")))
			if entry_mws != mws_id:
				continue
			# Same content-mod guard as the Mods-tab checkbox: disabling a
			# mod that registers game content can stop an existing save that
			# uses it from loading. Confirm first; if the user backs out,
			# revert the checkbox without re-firing toggled.
			var live_entry: Dictionary = entry
			if not enabled and bool(entry.get("has_registry", false)):
				var ok: bool = await _confirm_disable_content_mod(str(entry.get("mod_name", "this mod")))
				if not ok:
					if is_instance_valid(check):
						check.set_pressed_no_signal(true)
					return
				# The launcher window can close while the dialog is open;
				# the controls may be freed. A rescan while the dialog was
				# open (e.g. a queued download landing) replaces
				# _ui_mod_entries with fresh dicts, so write the confirmed
				# state to the LIVE entry, not the orphaned capture.
				live_entry = _live_entry_for_profile_key(str(entry.get("profile_key", "")), entry)
			live_entry["enabled"] = enabled
			_save_ui_config()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)
			set_status.call(("Enabled " if enabled else "Disabled ") + str(live_entry.get("mod_name", "?")) + " in profile " + _active_profile, COL_TEXT_DIM)
			return

	# Forward decl so on_get + queue processor can reference each other.
	var perform_download_for_item: Callable

	perform_download_for_item = func(item: Dictionary):
		var mod_data: Dictionary = item["mod_data"]
		var get_btn = item.get("get_btn")
		var mws_id := int(mod_data.get("id", 0))
		state["downloading_id"] = mws_id
		if is_instance_valid(get_btn):
			get_btn.disabled = true
			get_btn.text = "Downloading..."
		var queue: Array = state["download_queue"]
		var qsuffix := (" (" + str(queue.size()) + " queued)") if not queue.is_empty() else ""
		set_status.call("Downloading " + str(mod_data.get("name", "?")) + qsuffix + "...", COL_AMBER)
		set_dl_status.call(get_btn, "Downloading " + str(mod_data.get("name", "?")) + "...", COL_AMBER)

		# Rate-limit pause, same as the modpack apply loop: once a 429 arms
		# the cooldown, every remaining queued item's metadata lookup would
		# fail fast in milliseconds and the whole batch would mass-fail.
		# Wait it out with a visible countdown instead; the Browse tab stays
		# interactive (no modal here). Bail if the launcher closes mid-wait.
		var rate_waited := false
		while mws_rate_cooldown_seconds() > 0:
			rate_waited = true
			if not is_instance_valid(status_lbl) or get_tree() == null:
				state["downloading_id"] = -1
				return
			var wait_s := mws_rate_cooldown_seconds()
			set_status.call("Rate limited by ModWorkshop -- resuming in %ds" % wait_s, COL_AMBER)
			set_dl_status.call(get_btn, "Rate limited by ModWorkshop -- resuming in %ds" % wait_s, COL_AMBER)
			await get_tree().create_timer(1.0).timeout
		if rate_waited and is_instance_valid(status_lbl):
			set_status.call("Downloading " + str(mod_data.get("name", "?")) + "...", COL_AMBER)
			set_dl_status.call(get_btn, "Downloading " + str(mod_data.get("name", "?")) + "...", COL_AMBER)

		var result: Dictionary = await download_new_mod(mws_id)
		state["downloading_id"] = -1

		# The launcher window can be closed (Launch / X) during the multi-second
		# download -- Browse downloads pop no modal. Everything below touches
		# freed nodes (status_lbl, the Browse list, the tab). The file already
		# landed on disk inside download_new_mod, so just stop cleanly.
		if not is_instance_valid(status_lbl):
			return

		# Count every completed item (success or failure) so the drain summary
		# below can say "N of M downloads failed".
		state["queue_done_total"] = int(state.get("queue_done_total", 0)) + 1

		if bool(result.get("ok", false)):
			# Remember that this batch installed at least one mod; the drain
			# below keys the one-shot rescan and row sync on it. The full
			# mods-dir rescan + Mods-tab rebuild happen at drain, NOT here:
			# per-item they re-opened every installed archive and rebuilt the
			# hidden Mods tab once per queued download.
			state["queue_any_success"] = true
			if is_instance_valid(get_btn):
				get_btn.text = "Installed"
				get_btn.disabled = true
			set_status.call("Installed " + str(result.get("file_name", "")), COL_OK)
			set_dl_status.call(get_btn, "Installed " + str(result.get("file_name", "")), COL_OK)
		else:
			if is_instance_valid(get_btn):
				get_btn.disabled = false
				get_btn.text = "Download"
			# Error copy pattern (spec section 7): what happened + what to do
			# next; fall back to the connection hint when the downloader gave
			# no detail rather than saying "unknown".
			var err_detail := str(result.get("error", "")).strip_edges()
			if err_detail.is_empty():
				err_detail = "Check your connection and try again."
			var fail_line := "Could not download " + str(mod_data.get("name", "mod")) + ". " + err_detail
			set_status.call(fail_line, COL_ERR)
			set_dl_status.call(get_btn, fail_line, COL_ERR)
			# Remember the failure: while a queued batch drains, the status
			# line above is synchronously overwritten by the next item's
			# "Downloading...", so the drain summary below is the only report
			# of mid-batch casualties that survives.
			(state["queue_failures"] as Array).append(str(mod_data.get("name", "mod")) + " (" + err_detail + ")")

		# Drain queue or settle the batch. Re-rendering frees button refs in
		# the queue, so we only re-render once the queue is empty -- otherwise
		# subsequent items lose their "Queued" button state mid-flight.
		#
		# Call through `state`, NOT the captured locals. GDScript lambdas
		# capture locals BY VALUE at creation time; this lambda was created
		# before perform_download_for_item / do_discover_fetch /
		# do_filter_fetch were assigned, so the captured copies are empty
		# Callables. `state` is a Dictionary (reference type), so the bindings
		# stored on it at the end of build_browse_tab are visible here.
		var remaining: Array = state["download_queue"]
		if not remaining.is_empty():
			var next_item: Dictionary = remaining.pop_front()
			(state["fn_perform_download"] as Callable).call(next_item)
			return

		# Queue drained -- settle the whole batch at once.
		var any_success := bool(state.get("queue_any_success", false))
		var failures: Array = state["queue_failures"]
		var batch_total := int(state.get("queue_done_total", 0))
		state["queue_any_success"] = false
		state["queue_failures"] = []
		state["queue_done_total"] = 0

		# ONE mods-dir rescan + hidden Mods-tab rebuild for the whole batch
		# (previously per successful item -- a main-thread stall proportional
		# to installed-mod count, multiplied by the queue length).
		if any_success:
			_reload_entries_for_active_profile()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)

		if failures.is_empty():
			if any_success:
				# Re-render only after an all-success batch. The re-fetch
				# exists to flip duplicate Get buttons to Installed; after a
				# failure it would synchronously overwrite the failure report
				# with "Loading..." before it ever rendered a frame.
				#
				# Carry the scroll position across the re-render: the full
				# re-render resets the ScrollContainer to the top. The fetch
				# lambdas consume restore_scroll and re-apply it one frame
				# after rendering.
				if is_instance_valid(scroll):
					state["restore_scroll"] = int(scroll.scroll_vertical)
				if str(state["mode"]) == "discover":
					(state["fn_discover_fetch"] as Callable).call()
				else:
					(state["fn_filter_fetch"] as Callable).call(false)
			return

		# At least one item failed. Skip the re-fetch (its completion would
		# wipe the failure report with "N popular, M latest"); sync duplicate
		# rows of installed mods in place instead -- same mod can appear in
		# popular AND latest -- so the failure text stays visible.
		if any_success and is_instance_valid(scroll):
			_refresh_browse_installed_rows(scroll)
		# Persistent batch summary: for a lone download the full error set
		# above is already on screen and stays; for a real batch it names
		# every failed mod, since only the LAST item's outcome survived the
		# drain before.
		if batch_total > 1:
			var fail_strs := PackedStringArray()
			for f_v in failures:
				fail_strs.append(str(f_v))
			set_status.call("%d of %d downloads failed: %s" % [failures.size(), batch_total, ", ".join(fail_strs)], COL_ERR)

	var on_get: Callable
	on_get = func(mod_data: Dictionary, get_btn: Button):
		var mws_id := int(mod_data.get("id", 0))
		if int(state["downloading_id"]) != -1:
			# Another download is in flight. Queue this one (unless it's the
			# same mod already in-flight or already queued -- silent dedup).
			if int(state["downloading_id"]) == mws_id:
				set_status.call("Already downloading this mod", COL_TEXT_DIM)
				set_dl_status.call(get_btn, "Already downloading this mod", COL_TEXT_DIM)
				return
			var queue: Array = state["download_queue"]
			for q_v in queue:
				if int((q_v as Dictionary).get("mod_data", {}).get("id", 0)) == mws_id:
					set_status.call("Already queued", COL_TEXT_DIM)
					set_dl_status.call(get_btn, "Already queued", COL_TEXT_DIM)
					return
			queue.append({"mod_data": mod_data, "get_btn": get_btn})
			if is_instance_valid(get_btn):
				get_btn.disabled = true
				get_btn.text = "Queued"
			var queued_line := "Queued " + str(mod_data.get("name", "?")) + " (" + str(queue.size()) + " in queue)"
			set_status.call(queued_line, COL_TEXT_DIM)
			set_dl_status.call(get_btn, queued_line, COL_TEXT_DIM)
			return
		perform_download_for_item.call({"mod_data": mod_data, "get_btn": get_btn})

	var render_mod_rows := func(mods: Array, append: bool):
		if not append:
			for child in list.get_children():
				child.queue_free()
			# Give this view the same heading treatment the landing's sections
			# get. Sits above the empty state too, so "no results" still says
			# what was searched for.
			var cat_name := ""
			if is_instance_valid(category_dropdown) and int(state["category_id"]) > 0:
				cat_name = category_dropdown.get_item_text(category_dropdown.selected)
			var hdr := Label.new()
			hdr.text = _browse_results_header_text(
				str(state["query"]), str(state["sort"]), cat_name)
			hdr.add_theme_font_size_override("font_size", FS_HEAD)
			hdr.add_theme_color_override("font_color", COL_TEXT)
			# A long search string must not widen the list and force a
			# horizontal scrollbar.
			hdr.clip_text = true
			hdr.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			hdr.tooltip_text = hdr.text
			hdr.mouse_filter = Control.MOUSE_FILTER_PASS
			list.add_child(hdr)
			list.add_child(HSeparator.new())
		var install_map: Dictionary = compute_install_map.call()
		for mod_data in mods:
			if not (mod_data is Dictionary):
				continue
			var mws_id := int((mod_data as Dictionary).get("id", 0))
			var entry_or_null: Variant = install_map.get(mws_id)
			list.add_child(_browse_render_mod_row(mod_data, entry_or_null, on_get, on_toggle))
			list.add_child(HSeparator.new())

	do_discover_fetch = func():
		# Stamp this fetch with a fresh seq so any earlier in-flight fetch's
		# completion handler sees the mismatch and bails. Snapshot into a
		# local `my_seq` because state["fetch_seq"] will keep advancing if
		# the user clicks again before our await returns.
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		# Consume any pending scroll carry (set by the post-download
		# re-render) up front so a failed or superseded fetch cannot leak it
		# into a later user-initiated fetch.
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		state["mode"] = "discover"
		# Rendering the landing means "Featured" is the truthful dropdown
		# label; sync state + selection so clearing a search/category (or the
		# initial fetch) never leaves a sort name over the curated view.
		# OptionButton.select() does not emit item_selected, so no recursion.
		state["featured"] = true
		state["sort"] = "bumped_at"
		if is_instance_valid(sort_dropdown) and sort_dropdown.selected != 0:
			sort_dropdown.select(0)
		state["next_page"] = 1
		state["has_more"] = false
		state.erase("loaded_rows")
		load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading...", COL_TEXT_DIM)
		var data: Variant = await mws_get_popular_and_latest()
		# Stale completion: another fetch was started while we awaited.
		# Newer fetch's render owns the UI; drop ours.
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		# Offline grace: a failed live fetch falls back to the last-good
		# snapshot (this session's or a previous launch's, via disk) and
		# renders it behind a cached-results banner instead of leaving the
		# tab empty. No snapshot -> the old failure status, plus the
		# banner's Retry affordance so recovery doesn't need a tab switch.
		var cached_at := 0
		if not (data is Dictionary):
			var snap: Dictionary = mws_discover_snapshot()
			if snap.is_empty():
				set_status.call(mws_error_status("Could not load mods. Check your connection and try again."), COL_ERR)
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
				return
			data = snap["data"]
			cached_at = int(snap["saved_at_unix"])
		var popular: Array = (data as Dictionary).get("popular", [])
		var latest: Array = (data as Dictionary).get("latest", [])
		for child in list.get_children():
			child.queue_free()
		var install_map: Dictionary = compute_install_map.call()
		if not popular.is_empty():
			var pop_hdr := Label.new()
			# "this week" because the backing sort is ModWorkshop's
			# weekly_score -- the label must match the parameter.
			pop_hdr.text = "Popular this week"
			pop_hdr.add_theme_font_size_override("font_size", FS_HEAD)
			pop_hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(pop_hdr)
			list.add_child(HSeparator.new())
			for mod_data in popular:
				if not (mod_data is Dictionary):
					continue
				var mws_id := int((mod_data as Dictionary).get("id", 0))
				list.add_child(_browse_render_mod_row(mod_data, install_map.get(mws_id), on_get, on_toggle))
				list.add_child(HSeparator.new())
		if not latest.is_empty():
			var spacer := Control.new()
			spacer.custom_minimum_size.y = SP_M
			list.add_child(spacer)
			var lat_hdr := Label.new()
			lat_hdr.text = "Latest"
			lat_hdr.add_theme_font_size_override("font_size", FS_HEAD)
			lat_hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(lat_hdr)
			list.add_child(HSeparator.new())
			for mod_data in latest:
				if not (mod_data is Dictionary):
					continue
				var mws_id := int((mod_data as Dictionary).get("id", 0))
				list.add_child(_browse_render_mod_row(mod_data, install_map.get(mws_id), on_get, on_toggle))
				list.add_child(HSeparator.new())
		if cached_at > 0:
			show_browse_banner.call("Showing cached results. " + str(browse_fail_reason.call()), cached_at, COL_AMBER)
		else:
			clear_browse_banner.call()
			# A live fetch landing proves connectivity is back: recover a
			# category dropdown whose one-shot populate failed earlier
			# (guarded no-op once loaded). Snapshot fallback proves nothing,
			# hence the live-only branch. Through `state`: this lambda was
			# created before populate_categories was assigned.
			(state["fn_populate_categories"] as Callable).call()
		set_status.call("%d popular, %d latest" % [popular.size(), latest.size()], COL_TEXT_DIM)
		# Restore the pre-refetch scroll position one frame later: the fresh
		# rows have no layout yet on this frame, so setting scroll_vertical
		# now would clamp against a zero-height list (handoff bug class 6).
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	do_filter_fetch = func(append: bool):
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		# Same pending-scroll-carry consumption as do_discover_fetch.
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		state["mode"] = "filter"
		var page: int = int(state["next_page"]) if append else 1
		if not append:
			state["next_page"] = 1
			state["has_more"] = false
			load_more_btn.visible = false
		# Disable Load more for the duration of the fetch so a rapid second
		# click can't enqueue a redundant page request. The completion path
		# re-derives visible/disabled from has_more.
		load_more_btn.disabled = true
		set_status.call("Loading..." if not append else "Loading more...", COL_TEXT_DIM)
		# Search honors the chosen sort (default "Recently bumped" = bumped_at)
		# instead of silently switching to best_match relevance. best_match pinned
		# an exact-name match (e.g. an outdated "Ryhon Item Spawner") to the top
		# regardless of upload date; a user searching wants most-recent first.
		var sort: String = str(state["sort"])
		var data: Variant = await mws_list_mods(str(state["query"]), sort, int(state["category_id"]), page)
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		if not (data is Dictionary):
			set_status.call(mws_error_status("Could not search. Check your connection and try again."), COL_ERR)
			# Only the discover landing has an offline snapshot (filter/search
			# results are never cached), so a failed search gets the Retry
			# banner but no cached rows. Append failures skip the banner: the
			# already-rendered pages stay on screen and the re-enabled Load
			# more button below IS the retry affordance.
			if not append:
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
			load_more_btn.disabled = not bool(state["has_more"])
			return
		var rows: Array = _mws_data_rows(data)
		# Accumulate every page fetched for this query/filter so the sort and
		# render below operate on the FULL loaded set; a fresh (non-append)
		# fetch resets the accumulator. Dedup by id: a mod bumped between page
		# fetches shifts server pages and can arrive twice.
		if append:
			var acc: Array = state.get("loaded_rows", [])
			var seen := {}
			for r in acc:
				if r is Dictionary:
					seen[int((r as Dictionary).get("id", 0))] = true
			for r in rows:
				if not (r is Dictionary) or not seen.has(int((r as Dictionary).get("id", 0))):
					acc.append(r)
			rows = acc
		state["loaded_rows"] = rows
		# MWS ignores the sort param when a text query is present -- it always
		# returns relevance order, so an outdated exact-name match pins to the
		# top no matter the dropdown. Re-sort client-side by the selected field.
		# Sorting the accumulated set keeps multi-page results globally sorted
		# (each page sorted in isolation used to per-page sawtooth on Load more).
		# ISO date strings compare chronologically.
		if str(state["query"]) != "":
			var sort_key := str(state["sort"])
			var numeric := sort_key == "downloads" or sort_key == "likes" or sort_key == "views"
			rows.sort_custom(func(a, b):
				if not (a is Dictionary):
					return false
				if not (b is Dictionary):
					return true
				if numeric:
					# .get() default only covers ABSENT keys; a present-but-null
					# counter would make int(null) a runtime error. JSON numbers
					# parse as float, so accept int/float and coerce junk to 0.
					var av: Variant = (a as Dictionary).get(sort_key)
					var bv: Variant = (b as Dictionary).get(sort_key)
					var ai: int = int(av) if (av is int or av is float) else 0
					var bi: int = int(bv) if (bv is int or bv is float) else 0
					return ai > bi
				return str((a as Dictionary).get(sort_key, "")) > str((b as Dictionary).get(sort_key, ""))
			)
		# .get()'s default only covers an ABSENT key; a present-but-null (or
		# non-dict) meta would crash the typed assignment. Same guard shape
		# as _mws_data_rows applies to the sibling data field.
		var meta_v: Variant = (data as Dictionary).get("meta")
		var meta: Dictionary = meta_v if meta_v is Dictionary else {}
		var current_page: int = int(meta.get("current_page", page))
		var last_page: int = int(meta.get("last_page", current_page))
		var total: int = int(meta.get("total", rows.size()))
		state["next_page"] = current_page + 1
		state["has_more"] = current_page < last_page
		clear_browse_banner.call()
		# Successful live fetch: recover the category dropdown if its one-shot
		# populate failed earlier (guarded no-op once loaded).
		(state["fn_populate_categories"] as Callable).call()
		# Full re-render of the accumulated set. On Load more this replaces
		# the old per-page append -- required for the global re-sort above to
		# actually show -- so carry the current scroll position across the
		# rebuild (restored one frame later below, same as the pending-carry
		# path). A pending carry, if any, wins: it predates this fetch.
		if append and my_restore < 0 and is_instance_valid(scroll):
			my_restore = int(scroll.scroll_vertical)
		render_mod_rows.call(rows, false)
		# Count from the data, not the scene tree. render_mod_rows clears a
		# non-append view with queue_free(), which Godot defers to end-of-frame,
		# so list.get_child_count() in this same synchronous block still counts
		# the just-freed old rows -- inflating "N of M mods" and (worse) keeping
		# shown_so_far > 0 so the new "No results" empty state never appears.
		# `rows` is the full accumulated set here, so no append arithmetic.
		state["shown_count"] = rows.size()
		var shown_so_far: int = int(state["shown_count"])
		# Empty state as an invitation (spec section 7), not a bare zero.
		if shown_so_far == 0:
			set_status.call("No results. Try a different search or category.", COL_TEXT_DIM)
		else:
			set_status.call("%d of %d mods" % [shown_so_far, total], COL_TEXT_DIM)
		load_more_btn.visible = bool(state["has_more"])
		load_more_btn.disabled = not bool(state["has_more"])
		# Restore the pre-refetch scroll position one frame later: the fresh
		# rows have no layout yet on this frame, so setting scroll_vertical
		# now would clamp against a zero-height list (handoff bug class 6).
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	# Debounce: Godot 4 LineEdit's text_changed fires per keystroke. A timer
	# armed on each keystroke and only the timeout actually queries the API
	# means a 300ms typing pause before the network kicks in -- well within
	# the 90 req/min/IP rate budget even when the user types fast.
	var search_debounce := Timer.new()
	search_debounce.one_shot = true
	search_debounce.wait_time = 0.3
	container.add_child(search_debounce)
	search_debounce.timeout.connect(func():
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and bool(state["featured"]):
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	search_input.text_changed.connect(func(new_text: String):
		state["query"] = new_text.strip_edges()
		search_debounce.stop()
		search_debounce.start()
	)
	search_input.text_submitted.connect(func(_t: String):
		search_debounce.stop()
		# Same routing as the debounce timeout: Enter in an EMPTY box while
		# Featured is selected must (re)render the curated landing -- an
		# unconditional filter fetch here would show a flat sorted list under
		# a "Featured" dropdown label.
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and bool(state["featured"]):
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	sort_dropdown.item_selected.connect(func(idx: int):
		state["sort"] = sort_keys[idx] if idx >= 0 and idx < sort_keys.size() else "bumped_at"
		# Item 0 = "Featured" (the curated landing); any real sort -- including
		# "Recently updated" (bumped_at) -- routes through list_mods with the
		# chosen sort, even with an empty query.
		state["featured"] = idx == 0
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and bool(state["featured"]):
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	category_dropdown.item_selected.connect(func(idx: int):
		var cid_var = category_dropdown.get_item_metadata(idx)
		state["category_id"] = int(cid_var) if cid_var != null else 0
		if str(state["query"]) == "" and int(state["category_id"]) == 0 and bool(state["featured"]):
			do_discover_fetch.call()
		else:
			do_filter_fetch.call(false)
	)

	load_more_btn.pressed.connect(func():
		do_filter_fetch.call(true)
	)

	# Populate categories asynchronously after the tab is visible. Each entry's
	# metadata holds the API category_id; the visible label is just the name.
	# Skip child categories for the first pass -- a flat list of 40 items in a
	# dropdown is already a stretch UX-wise, so we surface only top-level
	# (parent_id == null) and rely on search to find sub-category mods.
	var populate_categories := func():
		# Retry-able, not one-shot: the banner Retry and every successful list
		# fetch re-invoke this until it lands, so a failed first fetch
		# (offline launch, rate-limit cooldown) no longer leaves an
		# "All categories"-only dropdown for the whole session. The two flags
		# make re-invocation safe: loaded = success is permanent for the
		# session, loading = don't stack a second in-flight fetch (which
		# would double-populate the items on a race).
		if bool(state.get("categories_loaded", false)) or bool(state.get("categories_loading", false)):
			return
		state["categories_loading"] = true
		var data: Variant = await mws_get_categories()
		# Bookkeeping BEFORE the validity guard so a freed dropdown can't
		# leave the loading flag stuck true forever.
		state["categories_loading"] = false
		if not is_instance_valid(category_dropdown):
			return
		if not (data is Dictionary):
			# Leave categories_loaded false so the next Retry / successful
			# list fetch attempts again.
			return
		var rows: Array = _mws_data_rows(data)
		for cat in rows:
			if not (cat is Dictionary):
				continue
			var cd: Dictionary = cat
			# Only top-level for now.
			if cd.get("parent_id") != null:
				continue
			var cat_name := str(cd.get("name", ""))
			var cat_id := int(cd.get("id", 0))
			if cat_name.is_empty() or cat_id == 0:
				continue
			category_dropdown.add_item(cat_name)
			var idx := category_dropdown.item_count - 1
			category_dropdown.set_item_metadata(idx, cat_id)
		state["categories_loaded"] = true
	populate_categories.call()

	# Bind the forward-referenced lambdas onto `state` so the
	# perform_download lambda (created before these were assigned) can reach
	# their real values by reference at call time. See the capture note in
	# perform_download_for_item's queue-drain block.
	state["fn_perform_download"] = perform_download_for_item
	state["fn_discover_fetch"] = do_discover_fetch
	state["fn_filter_fetch"] = do_filter_fetch
	state["fn_populate_categories"] = populate_categories

	# Initial fetch is the curated landing page.
	do_discover_fetch.call()

	return margin


# Refresh the baked-at-render-time state of Browse rows in place. The
# "Enabled in <profile>" checkboxes bake the profile name and enabled state
# when rendered, and profile switches, modpack apply/unload, and Mods-tab
# edits all change that state behind the Browse tab's back (the tab has no
# rebuild path by design -- its content is network-fetched). Called from the
# tab_changed listener when Browse is shown. In-place (no re-fetch, no
# re-render) so search text, caret, scroll position, and loaded pages all
# survive. Rows are found via the browse_mws_id meta tag set at render time.
func _refresh_browse_installed_rows(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	# mws_id -> entry for every installed mod that declares one. Last-wins,
	# matching compute_install_map in build_browse_tab.
	var by_id: Dictionary = {}
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		if not cfg.has_section_key("updates", "modworkshop"):
			continue
		var mws_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
		if mws_id > 0:
			by_id[mws_id] = entry
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not node.has_meta("browse_mws_id"):
			continue
		var entry_v: Variant = by_id.get(int(node.get_meta("browse_mws_id")))
		if node is CheckBox:
			var cb := node as CheckBox
			if entry_v is Dictionary:
				cb.disabled = false
				cb.text = "Enabled in " + _active_profile
				cb.tooltip_text = "Toggle this mod in profile: " + _active_profile + "."
				# set_pressed_no_signal: this is a display sync, not a user
				# toggle -- firing toggled here would re-save the profile.
				cb.set_pressed_no_signal(bool((entry_v as Dictionary).get("enabled", false)))
			else:
				# The mod was uninstalled behind the tab's back (Mods-tab Remove).
				# Leave the row but make it inert: an enabled checkbox here toggles
				# nothing (on_toggle finds no matching entry and falls through) yet
				# still flips visually, falsely claiming a now-uninstalled mod was
				# enabled/disabled in the profile.
				cb.set_pressed_no_signal(false)
				cb.disabled = true
				cb.text = "Removed"
				cb.tooltip_text = "This mod is no longer installed. Click its name and use Download to install it again."
		elif node is Button and entry_v is Dictionary:
			# A Download button whose mod is now installed (modpack apply or
			# retry landed it). Skip in-flight buttons (Downloading/Queued,
			# both disabled); the download path re-renders on its own.
			var btn := node as Button
			if not btn.disabled:
				btn.text = "Installed"
				btn.disabled = true


# Guarded int() for API JSON fields. Dictionary.get()'s default only covers
# an ABSENT key -- a present-but-null value flows through and int(null) is a
# runtime error (the search sort comparator and the snapshot loader already
# guard this way). JSON numbers parse as float, so accept int/float and
# coerce anything else (null, string junk) to the fallback.
