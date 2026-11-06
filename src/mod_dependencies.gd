## Dependency declarations, dependency readiness and the effective load order.

# Dependency ids the loader itself satisfies.
const LOADER_ID_ALIASES: Array[String] = [
	"metro_mod_loader", "metromodloader", "vostok_mod_loader",
	"mod_loader", "modloader", "mml", "rtvmodlib",
]

func _parse_dependency_list(cfg: ConfigFile, key: String) -> Array[String]:
	if cfg == null or not cfg.has_section_key("dependencies", key):
		return []
	return _parse_id_list(cfg.get_value("dependencies", key))

# An id list is an array or a "foo, bar" / "[foo, bar]" string. A non-empty strict_for
# (provides=, the mod's file name) drops values that are not strings, with a log line.
func _parse_id_list(raw: Variant, strict_for: String = "") -> Array[String]:
	var ids: Array[String] = []
	if raw is Array:
		for item in (raw as Array):
			if strict_for != "" and not (item is String or item is StringName):
				_log_warning(strict_for + ": ignoring non-string provides entry " + str(item))
				continue
			_append_dependency_id(ids, str(item))
		return ids
	if typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in (raw as PackedStringArray):
			_append_dependency_id(ids, item)
		return ids
	if strict_for != "" and not (raw is String or raw is StringName):
		_log_warning(strict_for + ": ignoring provides= -- expected a string array, got "
				+ type_string(typeof(raw)))
		return ids
	var text := str(raw).strip_edges()
	if text.begins_with("[") and text.ends_with("]") and text.length() >= 2:
		text = text.substr(1, text.length() - 2)
	for part in text.split(","):
		_append_dependency_id(ids, part)
	return ids

func _append_dependency_id(deps: Array[String], raw_id: String) -> void:
	var dep_id := raw_id.strip_edges()
	if dep_id.length() >= 2:
		var quoted := (dep_id.begins_with("\"") and dep_id.ends_with("\"")) \
				or (dep_id.begins_with("'") and dep_id.ends_with("'"))
		if quoted:
			dep_id = dep_id.substr(1, dep_id.length() - 2).strip_edges()
	if dep_id == "":
		return
	for existing in deps:
		if existing.to_lower() == dep_id.to_lower():
			return
	deps.append(dep_id)

# [mod] provides=: old ids this mod answers to, minus its own; a real installed
# mod with that id always wins over the alias.
func _parse_provides_list(cfg: ConfigFile, mod_id: String, file_name: String) -> Array[String]:
	if not cfg.has_section_key("mod", "provides"):
		return []
	var self_key := mod_id.strip_edges().to_lower()
	var cleaned: Array[String] = []
	for alias in _parse_id_list(cfg.get_value("mod", "provides"), file_name):
		if alias.to_lower() != self_key:
			cleaned.append(alias)
	return cleaned

func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := _load_order_name(a)
	var b_name := _load_order_name(b)
	if a_name != b_name:
		return a_name < b_name
	return a["file_name"].to_lower() < b["file_name"].to_lower()

# A mod with no name= sorts by its file name with the extension, as on 3.4.2,
# where that was its name; "Foo-Addon.zip" loads before "Foo.zip".
func _load_order_name(e: Dictionary) -> String:
	if e["mod_name"] == e["file_name"].get_basename():
		var cfg: ConfigFile = e["cfg"]
		if cfg == null or not cfg.has_section_key("mod", "name"):
			return e["file_name"].to_lower()
	return e["mod_name"].to_lower()

func _entry_mod_key(entry: Dictionary) -> String:
	return entry["mod_id"].strip_edges().to_lower()

# Id -> index of the first entry with that id; provides= aliases are added after
# every real id, so an alias never shadows a real one.
func _mod_id_index(entries: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for i in entries.size():
		var key := _entry_mod_key(entries[i])
		if key != "" and not by_id.has(key):
			by_id[key] = i
	for i in entries.size():
		for alias: String in entries[i].get("provides", []):
			var alias_key := alias.strip_edges().to_lower()
			if alias_key != "" and not by_id.has(alias_key):
				by_id[alias_key] = i
	return by_id

func _entries_by_mod_id(entries: Array) -> Dictionary:
	var index := _mod_id_index(entries)
	var by_id: Dictionary = {}
	for key in index:
		by_id[key] = entries[index[key]]
	return by_id

func _dependency_display(entry: Dictionary) -> String:
	var name: String = entry["mod_name"].strip_edges()
	var mod_id: String = entry["mod_id"].strip_edges()
	if name != "" and mod_id != "" and name != mod_id:
		return name + " (" + mod_id + ")"
	if mod_id != "":
		return mod_id
	return name

# The candidates whose required dependencies all load, repeated until none drop
# out, since a blocked mod blocks its dependents too.
func _drop_blocked(candidates: Array, log_skips: bool) -> Array[Dictionary]:
	var active_by_id := _entries_by_mod_id(candidates)
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var blocked: Dictionary = {}
	var changed := true
	while changed:
		changed = false
		for entry in candidates:
			var entry_key := _entry_mod_key(entry)
			# "Load anyway" loads the mod and keeps it active for its dependents.
			if entry_key == "" or blocked.has(entry_key) or entry.get("dependency_ignored", false):
				continue
			for raw: String in entry["required_dependencies"]:
				var dep_id := raw.strip_edges()
				var dep_key := dep_id.to_lower()
				# A self-dependency is a typo the row warns about; it never blocks.
				if dep_id == "" or dep_key == entry_key or LOADER_ID_ALIASES.has(dep_key):
					continue
				# `blocked` is keyed by real ids, so an alias resolves to its provider first.
				dep_key = _dep_owner_key(dep_key, active_by_id, installed_by_id)
				if active_by_id.has(dep_key) and not blocked.has(dep_key):
					continue
				var status := "not_loaded" if active_by_id.has(dep_key) else _dep_status(dep_key, installed_by_id)
				blocked[entry_key] = {"dependency": dep_id, "status": status}
				changed = true
				break
	var ready: Array[Dictionary] = []
	for entry in candidates:
		var entry_key := _entry_mod_key(entry)
		if not blocked.has(entry_key):
			ready.append(entry)
		elif log_skips:
			_log_critical("Skipping %s -- required dependency %s is %s" % [_dependency_display(entry),
					blocked[entry_key]["dependency"], _dependency_status_label(blocked[entry_key]["status"])])
	return ready

func _dep_status(dep_key: String, installed_by_id: Dictionary) -> String:
	if installed_by_id.has(dep_key):
		return "not_loaded" if installed_by_id[dep_key]["enabled"] else "disabled"
	for hidden_id: String in _hidden_folder_ids:
		if hidden_id.strip_edges().to_lower() == dep_key:
			return "hidden_folder"
	return "not_installed"

# The real id of the mod that answers to a dependency id: an enabled mod first,
# else an installed one, else the id itself. The load filter and the rows share it.
func _dep_owner_key(dep_key: String, enabled_by_id: Dictionary, installed_by_id: Dictionary) -> String:
	if enabled_by_id.has(dep_key):
		return _entry_mod_key(enabled_by_id[dep_key])
	if installed_by_id.has(dep_key):
		return _entry_mod_key(installed_by_id[dep_key])
	return dep_key

# "not_loaded" covers an enabled mod that did not load and an active one blocked down its chain.
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

# Stable topological pass over priority-sorted candidates: a dependency is hoisted
# only when priority order breaks an edge. Cycles are reported, not force-ordered.
func _apply_dependency_ordering(candidates: Array) -> Dictionary:
	var n := candidates.size()
	var edges := _build_dependency_edges(candidates)
	var dependents: Dictionary = edges["dependents"]
	var indegree: Array[int] = edges["indegree"]
	var ordered: Array[Dictionary] = []
	if dependents.is_empty():
		ordered.assign(candidates)
		return {"ordered": ordered, "adjusted": false, "cycle_keys": []}
	# Each round emits the first candidate with no unmet edge, else releases one optional edge.
	var emitted: Dictionary = {}
	while emitted.size() < n:
		var next := -1
		for i in n:
			if not emitted.has(i) and indegree[i] <= 0:
				next = i
				break
		if next >= 0:
			emitted[next] = true
			ordered.append(candidates[next])
			for j in dependents.get(next, []):
				indegree[j] -= 1
		elif not _release_optional_edge(edges, emitted):
			break
	# Leftovers load last in their original order; only those in a cycle are reported.
	var cycle_keys: Array[String] = []
	if emitted.size() < n:
		var leftover: Array[int] = []
		for i in n:
			if not emitted.has(i):
				leftover.append(i)
				ordered.append(candidates[i])
		for i in leftover:
			if _node_reaches(i, i, dependents, emitted):
				var ck := _entry_mod_key(candidates[i])
				if ck != "":
					cycle_keys.append(ck)
	var adjusted := false
	for i in n:
		if ordered[i] != candidates[i]:
			adjusted = true
			break
	return {"ordered": ordered, "adjusted": adjusted, "cycle_keys": cycle_keys}

# Edges by candidate index: dependents[dep] loads before each listed index, indegree[i]
# counts i's unmet edges, and optional holds the optional edges as {dep, dependent}.
func _build_dependency_edges(candidates: Array) -> Dictionary:
	var key_to_index := _mod_id_index(candidates)
	var indegree: Array[int] = []
	indegree.resize(candidates.size())
	indegree.fill(0)
	var dependents: Dictionary = {}
	var optional: Array[Dictionary] = []
	for i in candidates.size():
		var entry_key := _entry_mod_key(candidates[i])
		for is_optional in [false, true]:
			for raw: String in candidates[i]["optional_dependencies" if is_optional else "required_dependencies"]:
				var dep_key := raw.strip_edges().to_lower()
				if dep_key == "" or dep_key == entry_key or not key_to_index.has(dep_key):
					continue
				var dep: int = key_to_index[dep_key]
				# An id in both lists is one (required) edge.
				if dep == i or (dependents.get(dep, []) as Array).has(i):
					continue
				(dependents.get_or_add(dep, []) as Array).append(i)
				indegree[i] += 1
				if is_optional:
					optional.append({"dep": dep, "dependent": i})
	return {"dependents": dependents, "indegree": indegree, "optional": optional}

# Drops the first optional edge that closes a cycle, false when none does: two mods
# that optionally name each other are not a cycle, and a required chain wins.
func _release_optional_edge(edges: Dictionary, emitted: Dictionary) -> bool:
	var optional: Array[Dictionary] = edges["optional"]
	for k in optional.size():
		var edge := optional[k]
		if emitted.has(edge["dependent"]) or emitted.has(edge["dep"]) \
				or not _node_reaches(edge["dependent"], edge["dep"], edges["dependents"], emitted):
			continue
		(edges["dependents"][edge["dep"]] as Array).erase(edge["dependent"])
		var indegree: Array[int] = edges["indegree"]
		indegree[edge["dependent"]] -= 1
		optional.remove_at(k)
		return true
	return false

func _node_reaches(start: int, target: int, dependents: Dictionary, emitted: Dictionary) -> bool:
	var seen: Dictionary = {}
	# Plain Array: an untyped Array cannot be assigned to an Array[int] var.
	var stack: Array = (dependents.get(start, []) as Array).duplicate()
	while not stack.is_empty():
		var x: int = stack.pop_back()
		if emitted.has(x):
			continue
		if x == target:
			return true
		if seen.has(x):
			continue
		seen[x] = true
		for y in dependents.get(x, []):
			if not emitted.has(y):
				stack.append(y)
	return false

# What loads and in what order: loading, boot, the order panel and the launch
# button all read this. It returns the live entry dicts.
func _loadable_enabled_entries(log_skips := false) -> Dictionary:
	var enabled: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if entry["enabled"]:
			enabled.append(entry)
	enabled.sort_custom(_compare_load_order)
	var ordering := _apply_dependency_ordering(enabled)
	return {
		"loadable": _drop_blocked(ordering["ordered"], log_skips),
		"enabled_count": enabled.size(),
		"adjusted": ordering["adjusted"],
		"cycle_keys": ordering["cycle_keys"],
	}

func _enable_required_deps(entry: Dictionary) -> void:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var queue: Array = entry["required_dependencies"].duplicate()
	var seen: Dictionary = {}
	while not queue.is_empty():
		var dep_key: String = queue.pop_front().strip_edges().to_lower()
		if dep_key == "" or seen.has(dep_key) or LOADER_ID_ALIASES.has(dep_key):
			continue
		seen[dep_key] = true
		if installed_by_id.has(dep_key):
			installed_by_id[dep_key]["enabled"] = true
			queue.append_array(installed_by_id[dep_key]["required_dependencies"])

func _dependency_display_for_id(dep_id: String, installed_by_id: Dictionary) -> String:
	var dep_key := dep_id.strip_edges().to_lower()
	if installed_by_id.has(dep_key):
		return installed_by_id[dep_key]["mod_name"]
	return dep_id

func _refresh_dependency_status() -> Dictionary:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var enabled_by_id := _entries_by_mod_id(_ui_mod_entries.filter(func(e): return e["enabled"]))
	for entry in _ui_mod_entries:
		entry["dependency_warnings"] = []
		entry["dependency_blockers"] = []
		entry["dependency_blockers_info"] = []
	var pick := _loadable_enabled_entries()
	var loadable_by_id := _entries_by_mod_id(pick["loadable"])
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		var entry_key := _entry_mod_key(entry)
		var warnings: Array[String] = []
		var blockers: Array[String] = []
		var info: Array[Dictionary] = []
		if pick["cycle_keys"].has(entry_key):
			warnings.append("load order could not be fully resolved (dependency cycle in chain)")
		for raw: String in entry["required_dependencies"]:
			var dep_id := raw.strip_edges()
			var dep_key := dep_id.to_lower()
			if dep_id == "":
				continue
			if dep_key == entry_key:
				warnings.append("lists itself as a dependency (ignored)")
				continue
			if LOADER_ID_ALIASES.has(dep_key):
				continue
			# Satisfied only if the owner the load filter binds to loads; a raw-id test
			# would let a blocked id escape to an alias.
			var owner_key := _dep_owner_key(dep_key, enabled_by_id, installed_by_id)
			if loadable_by_id.has(owner_key) and _entry_mod_key(loadable_by_id[owner_key]) == owner_key:
				continue
			var status := _dep_status(dep_key, installed_by_id)
			var display := dep_id
			if installed_by_id.has(dep_key):
				display = _dependency_display(installed_by_id[dep_key])
			blockers.append(dep_id)
			info.append({"id": dep_id, "status": status, "display": display, "fixable": status == "disabled"})
		entry["dependency_warnings"] = warnings
		entry["dependency_blockers_info"] = info
		# "Load anyway": nothing blocks the mod, but the row keeps the reasons.
		if entry.get("dependency_ignored", false):
			entry["dependency_blockers"] = []
		else:
			entry["dependency_blockers"] = blockers
	return pick
