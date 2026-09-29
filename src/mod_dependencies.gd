## Dependency declarations, dependency readiness and effective load order.
## Uses entry dictionaries from mod_discovery.gd and the active profile.

# Dependency ids satisfied by the mod loader itself; always count as present.
const LOADER_ID_ALIASES: Array[String] = [
	"metro_mod_loader", "metromodloader", "vostok_mod_loader",
	"mod_loader", "modloader", "mml", "rtvmodlib",
]

func _parse_dependency_list(cfg: ConfigFile, key: String) -> Array[String]:
	var deps: Array[String] = []
	if cfg == null or not cfg.has_section_key("dependencies", key):
		return deps
	var raw: Variant = cfg.get_value("dependencies", key)
	if raw is Array:
		for item in (raw as Array):
			_append_dependency_id(deps, str(item))
		return deps
	if typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in (raw as PackedStringArray):
			_append_dependency_id(deps, str(item))
		return deps

	# Whole-value strings like "foo, bar" for older author tools.
	var text := str(raw).strip_edges()
	if text.begins_with("[") and text.ends_with("]") and text.length() >= 2:
		text = text.substr(1, text.length() - 2)
	for part in text.split(","):
		_append_dependency_id(deps, part)
	return deps

func _append_dependency_id(deps: Array[String], raw_id: String) -> void:
	var dep_id := raw_id.strip_edges()
	if dep_id.length() >= 2:
		var quoted := (dep_id.begins_with("\"") and dep_id.ends_with("\"")) \
				or (dep_id.begins_with("'") and dep_id.ends_with("'"))
		if quoted:
			dep_id = dep_id.substr(1, dep_id.length() - 2).strip_edges()
	if dep_id == "":
		return
	var dep_key := dep_id.to_lower()
	for existing in deps:
		if existing.to_lower() == dep_key:
			return
	deps.append(dep_id)

# [mod] provides=["old_id", ...]: rename aliases. A requirement naming an
# alias is satisfied by this mod; a real installed mod with that id always
# wins. Junk shapes degrade to no aliases with a log line.
func _parse_provides_list(cfg: ConfigFile, mod_id: String, file_name: String) -> Array[String]:
	var ids: Array[String] = []
	if cfg == null or not cfg.has_section_key("mod", "provides"):
		return ids
	var raw: Variant = cfg.get_value("mod", "provides")
	if raw is Array:
		for item in (raw as Array):
			if item is String or item is StringName:
				_append_dependency_id(ids, str(item))
			else:
				_log_warning(file_name + ": ignoring non-string provides entry "
						+ str(item))
	elif typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in (raw as PackedStringArray):
			_append_dependency_id(ids, str(item))
	elif raw is String or raw is StringName:
		# Whole-value strings like "foo, bar" (mirrors _parse_dependency_list).
		var text := str(raw).strip_edges()
		if text.begins_with("[") and text.ends_with("]") and text.length() >= 2:
			text = text.substr(1, text.length() - 2)
		for part in text.split(","):
			_append_dependency_id(ids, part)
	else:
		_log_warning(file_name + ": ignoring provides= -- expected a string array, got "
				+ type_string(typeof(raw)))
		return ids
	# Drop self-aliases so the alias passes never see one.
	var self_key := mod_id.strip_edges().to_lower()
	var cleaned: Array[String] = []
	for alias in ids:
		if alias.to_lower() != self_key:
			cleaned.append(alias)
	return cleaned

func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

func _entry_mod_key(entry: Dictionary) -> String:
	return str(entry.get("mod_id", "")).strip_edges().to_lower()

func _entries_by_mod_id(entries: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for entry in entries:
		var key := _entry_mod_key(entry)
		if key == "":
			continue
		if not by_id.has(key):
			by_id[key] = entry
	# Second pass: aliases resolve to their providing mod, after the real-id
	# pass so an alias never shadows a real id; ties go to the first entry.
	for entry in entries:
		for raw_alias in (entry as Dictionary).get("provides", []):
			var alias_key := str(raw_alias).strip_edges().to_lower()
			if alias_key == "" or by_id.has(alias_key):
				continue
			by_id[alias_key] = entry
	return by_id

func _dependency_display(entry: Dictionary) -> String:
	var name := str(entry.get("mod_name", "")).strip_edges()
	var mod_id := str(entry.get("mod_id", "")).strip_edges()
	if name != "" and mod_id != "" and name != mod_id:
		return name + " (" + mod_id + ")"
	if mod_id != "":
		return mod_id
	return name

func _filter_dependency_ready_candidates(candidates: Array,
		log_skips: bool = false) -> Array[Dictionary]:
	var active_by_id := _entries_by_mod_id(candidates)
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var blocked: Dictionary = {}
	var changed := true
	while changed:
		changed = false
		for entry in candidates:
			var entry_key := _entry_mod_key(entry)
			if entry_key == "" or blocked.has(entry_key):
				continue
			# "Load anyway": loads regardless and stays active for dependents.
			if bool(entry.get("dependency_ignored", false)):
				continue
			for raw_dep in entry.get("required_dependencies", []):
				var dep_id := str(raw_dep).strip_edges()
				if dep_id == "":
					continue
				var dep_key := dep_id.to_lower()
				# Self-dependency is a typo; warned elsewhere, never blocked.
				if dep_key == entry_key:
					continue
				# "Requires Metro Mod Loader": the loader itself satisfies it.
				if LOADER_ID_ALIASES.has(dep_key):
					continue
				# Canonicalize an alias to the provider's real id: `blocked` is keyed by
				# real ids, so a raw alias would read a blocked provider as satisfied.
				if active_by_id.has(dep_key):
					dep_key = _entry_mod_key(active_by_id[dep_key])
				elif installed_by_id.has(dep_key):
					dep_key = _entry_mod_key(installed_by_id[dep_key])
				if active_by_id.has(dep_key) and not blocked.has(dep_key):
					continue
				var status := "not_installed"
				if active_by_id.has(dep_key) and blocked.has(dep_key):
					status = "not_loaded"
				elif installed_by_id.has(dep_key):
					var installed: Dictionary = installed_by_id[dep_key]
					status = "disabled" if not bool(installed.get("enabled", false)) else "not_loaded"
				elif _dep_is_hidden_folder(dep_key):
					status = "hidden_folder"
				blocked[entry_key] = {"dependency": dep_id, "status": status}
				changed = true
				break

	var ready: Array[Dictionary] = []
	for entry in candidates:
		var entry_key := _entry_mod_key(entry)
		if entry_key != "" and blocked.has(entry_key):
			if log_skips:
				var info: Dictionary = blocked[entry_key]
				_log_critical("Skipping %s -- required dependency %s is %s" \
						% [_dependency_display(entry), info["dependency"],
						   _dependency_status_label(str(info["status"]))])
			continue
		ready.append(entry)
	return ready

func _dependency_status_label(status: String) -> String:
	match status:
		"disabled":
			return "installed but disabled"
		"not_loaded":
			return "blocked by its own missing dependency"
		"hidden_folder":
			return "a dev folder hidden while Developer Mode is off"
		_:
			return "not installed"

# A required dep that exists only as a dev folder while Developer Mode is
# off gets its own status so the row can name the fix.
func _dep_is_hidden_folder(dep_key: String) -> bool:
	for hid in _hidden_folder_ids.keys():
		if str(hid).strip_edges().to_lower() == dep_key:
			return true
	return false

# Stable topological pass over priority-sorted candidates: a required dep is
# hoisted above its dependent only when priority order violates the edge
# (Kahn walk, lowest original index first). Cycles are reported, not force-ordered.
func _apply_dependency_ordering(candidates: Array) -> Dictionary:
	var n := candidates.size()
	var key_to_index: Dictionary = {}
	for i in n:
		var k := _entry_mod_key(candidates[i])
		if k != "" and not key_to_index.has(k):
			key_to_index[k] = i
	# Alias edges point at the providing mod; second pass so an alias never steals a real id.
	for i in n:
		for raw_alias in (candidates[i] as Dictionary).get("provides", []):
			var ak := str(raw_alias).strip_edges().to_lower()
			if ak != "" and not key_to_index.has(ak):
				key_to_index[ak] = i
	var indegree := PackedInt32Array()
	indegree.resize(n)
	var dependents: Dictionary = {}
	var has_edges := false
	for i in n:
		var entry: Dictionary = candidates[i]
		var entry_key := _entry_mod_key(entry)
		# Required deps are hard edges; optional deps are soft edges applied only
		# when the dep is present. Optional deps never block, they only order.
		var dep_lists := [entry.get("required_dependencies", []), entry.get("optional_dependencies", [])]
		for dep_list in dep_lists:
			for raw_dep in dep_list:
				var dep_key := str(raw_dep).strip_edges().to_lower()
				if dep_key == "" or dep_key == entry_key or not key_to_index.has(dep_key):
					continue
				var di: int = key_to_index[dep_key]
				if di == i:
					continue
				if (dependents.get(di, []) as Array).has(i):
					continue  # required+optional both name it -- one edge only
				if not dependents.has(di):
					dependents[di] = []
				(dependents[di] as Array).append(i)
				indegree[i] += 1
				has_edges = true
	var ordered: Array[Dictionary] = []
	if not has_edges:
		for c in candidates:
			ordered.append(c)
		return {"ordered": ordered, "adjusted": false, "cycle_keys": []}
	var emitted: Dictionary = {}
	var remaining := n
	var progress := true
	while remaining > 0 and progress:
		progress = false
		for i in n:
			if emitted.has(i) or indegree[i] > 0:
				continue
			emitted[i] = true
			ordered.append(candidates[i])
			remaining -= 1
			for j in dependents.get(i, []):
				indegree[j] -= 1
			progress = true
			break
	# Leftovers are in a cycle or downstream of one. Emit them at the end in
	# original order, but report only nodes that are in a cycle.
	var cycle_keys: Array[String] = []
	if remaining > 0:
		var leftover: Array[int] = []
		for i in n:
			if not emitted.has(i):
				leftover.append(i)
				ordered.append(candidates[i])
		for i in leftover:
			if _node_reaches_self(i, dependents, emitted):
				var ck := _entry_mod_key(candidates[i])
				if ck != "":
					cycle_keys.append(ck)
	var adjusted := false
	for i in n:
		if ordered[i] != candidates[i]:
			adjusted = true
			break
	return {"ordered": ordered, "adjusted": adjusted, "cycle_keys": cycle_keys}

# True iff `start` can reach itself within the still-unemitted subgraph.
# `dependents[x]` lists nodes that depend on x.
func _node_reaches_self(start: int, dependents: Dictionary, emitted: Dictionary) -> bool:
	var seen: Dictionary = {}
	# Plain Array: an untyped Array cannot be assigned to an Array[int] var.
	var stack: Array = (dependents.get(start, []) as Array).duplicate()
	while not stack.is_empty():
		var x: int = stack.pop_back()
		if emitted.has(x):
			continue
		if x == start:
			return true
		if seen.has(x):
			continue
		seen[x] = true
		for y in dependents.get(x, []):
			if not emitted.has(y):
				stack.append(y)
	return false

# The one definition of what loads, in what order: load_all_mods, boot's
# archive collection, the order panel and the launch button all read this.
# duplicate_entries=true hands back copies; the UI passes false to observe live dicts.
func _loadable_enabled_entries(log_skips := false, duplicate_entries := false) -> Dictionary:
	var enabled: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if bool(entry.get("enabled", false)):
			enabled.append(entry.duplicate() if duplicate_entries else entry)
	enabled.sort_custom(_compare_load_order)
	var ordering := _apply_dependency_ordering(enabled)
	var loadable := _filter_dependency_ready_candidates(ordering["ordered"], log_skips)
	return {
		"loadable": loadable,
		"enabled_count": enabled.size(),
		"adjusted": ordering["adjusted"],
		"cycle_keys": ordering["cycle_keys"],
	}

# Enable every required dependency (transitively) that is installed but off.
func _enable_required_deps(entry: Dictionary) -> Dictionary:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var enabled_names: Array[String] = []
	var unfixed: Array[String] = []
	var queue: Array[String] = []
	var seen: Dictionary = {}
	for raw_dep in entry.get("required_dependencies", []):
		queue.append(str(raw_dep).strip_edges().to_lower())
	while not queue.is_empty():
		var dep_key: String = queue.pop_front()
		if dep_key == "" or seen.has(dep_key) or LOADER_ID_ALIASES.has(dep_key):
			continue
		seen[dep_key] = true
		if not installed_by_id.has(dep_key):
			unfixed.append(dep_key)
			continue
		var dep_entry: Dictionary = installed_by_id[dep_key]
		if not bool(dep_entry.get("enabled", false)):
			dep_entry["enabled"] = true
			enabled_names.append(str(dep_entry.get("mod_name", dep_key)))
		for raw in dep_entry.get("required_dependencies", []):
			queue.append(str(raw).strip_edges().to_lower())
	return {"enabled_names": enabled_names, "unfixed": unfixed}

# Display name for a dependency id; loop callers should pass a prebuilt map.
func _dependency_display_for_id(dep_id: String, installed_by_id: Variant = null) -> String:
	var dep_key := dep_id.strip_edges().to_lower()
	var by_id: Dictionary = installed_by_id if installed_by_id is Dictionary \
			else _entries_by_mod_id(_ui_mod_entries)
	if by_id.has(dep_key):
		return str((by_id[dep_key] as Dictionary).get("mod_name", dep_id))
	return dep_id

# Returns the _loadable_enabled_entries pick computed mid-pass so hot callers reuse it.
func _refresh_dependency_status() -> Dictionary:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var enabled_by_id := _entries_by_mod_id(_ui_mod_entries.filter(
			func(e): return bool((e as Dictionary).get("enabled", false))))
	for entry in _ui_mod_entries:
		entry["dependency_warnings"] = []
		entry["dependency_blockers"] = []
		entry["dependency_blockers_info"] = []
		entry["dependencies_satisfied"] = true

	var pick := _loadable_enabled_entries()
	var loadable_by_id := _entries_by_mod_id(pick["loadable"])
	var cycle_keys: Array = pick["cycle_keys"]

	for entry in _ui_mod_entries:
		if not bool(entry.get("enabled", false)):
			continue
		var warnings: Array[String] = []
		var blockers: Array[String] = []
		var info: Array[Dictionary] = []
		var entry_key := _entry_mod_key(entry)
		if cycle_keys.has(entry_key):
			warnings.append("load order could not be fully resolved (dependency cycle in chain)")
		for raw_dep in entry.get("required_dependencies", []):
			var dep_id := str(raw_dep).strip_edges()
			if dep_id == "":
				continue
			var dep_key := dep_id.to_lower()
			if dep_key == entry_key:
				warnings.append("lists itself as a dependency (ignored)")
				continue
			if LOADER_ID_ALIASES.has(dep_key):
				continue
			# Resolve the dep the way the load filter does: bind the id to whichever
			# enabled mod owns it (real id beats alias), else installed, then satisfied
			# only if that owner is loadable. A raw-id test would let a blocked id escape to an alias.
			var owner_key := dep_key
			if enabled_by_id.has(dep_key):
				owner_key = _entry_mod_key(enabled_by_id[dep_key])
			elif installed_by_id.has(dep_key):
				owner_key = _entry_mod_key(installed_by_id[dep_key])
			if loadable_by_id.has(owner_key) and _entry_mod_key(loadable_by_id[owner_key]) == owner_key:
				continue
			var status := "not_installed"
			var display := dep_id
			var fixable := false
			if installed_by_id.has(dep_key):
				var dep_entry: Dictionary = installed_by_id[dep_key]
				display = _dependency_display(dep_entry)
				if not bool(dep_entry.get("enabled", false)):
					status = "disabled"
					fixable = true
				else:
					status = "not_loaded"
			elif _dep_is_hidden_folder(dep_key):
				status = "hidden_folder"
			blockers.append(dep_id)
			info.append({"id": dep_id, "status": status, "display": display, "fixable": fixable})
		entry["dependency_warnings"] = warnings
		entry["dependency_blockers_info"] = info
		if bool(entry.get("dependency_ignored", false)):
			# "Load anyway": nothing blocks the mod, but keep the info for the row.
			entry["dependency_blockers"] = []
			entry["dependencies_satisfied"] = true
		else:
			entry["dependency_blockers"] = blockers
			entry["dependencies_satisfied"] = blockers.is_empty()
	return pick
