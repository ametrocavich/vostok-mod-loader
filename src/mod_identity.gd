## Mod identity, version comparison and duplicate selection.

# -1/0/1 for a < b, equal, a > b. A leading "v" and "+build" are ignored; a
# "-suffix" is a semver prerelease and ranks below the bare version.
func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var core_a := a.lstrip("vV").get_slice("+", 0)
	var core_b := b.lstrip("vV").get_slice("+", 0)
	var base_a := core_a.get_slice("-", 0)
	var base_b := core_b.get_slice("-", 0)
	var pa := base_a.split(".")
	var pb := base_b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var ca := _version_component(pa[i] if i < pa.size() else "0")
		var cb := _version_component(pb[i] if i < pb.size() else "0")
		# Array < compares slot by slot, which is the order _version_component builds.
		if ca != cb:
			return -1 if ca < cb else 1
	var pre_a := core_a.substr(base_a.length()).lstrip("-")
	var pre_b := core_b.substr(base_b.length()).lstrip("-")
	if pre_a == "" or pre_b == "":
		return 0 if pre_a == pre_b else (1 if pre_a == "" else -1)
	return _compare_prerelease(pre_a, pre_b)

# [number, rank, letters, trailing number] of one component, in compare order. Rank 0 is a
# prerelease word (rc, alpha, beta, pre, dev), 1 no tail, 2 any other ("1.0.0b" > 1.0.0).
func _version_component(s: String) -> Array:
	var i := 0
	while i < s.length() and s.unicode_at(i) >= 48 and s.unicode_at(i) <= 57:
		i += 1
	var num := int(s.substr(0, i)) if i > 0 else 0
	var tail := s.substr(i).strip_edges().to_lower()
	var rank := 1
	if tail != "":
		rank = 2
		for word in ["rc", "alpha", "beta", "pre", "dev"]:
			if tail.begins_with(word):
				rank = 0
				break
	var j := tail.length()
	while j > 0 and tail.unicode_at(j - 1) >= 48 and tail.unicode_at(j - 1) <= 57:
		j -= 1
	var tail_num := int(tail.substr(j)) if j < tail.length() else -1
	return [num, rank, tail.substr(0, j), tail_num]

# Semver prerelease tails ("beta.1" < "beta.10"): numeric identifiers rank below
# words, and a shorter run ranks lower on an equal prefix.
func _compare_prerelease(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		if i >= pa.size():
			return -1
		if i >= pb.size():
			return 1
		var a_num := pa[i].is_valid_int()
		var b_num := pb[i].is_valid_int()
		if a_num and b_num:
			if pa[i].to_int() != pb[i].to_int():
				return -1 if pa[i].to_int() < pb[i].to_int() else 1
		elif a_num != b_num:
			return -1 if a_num else 1
		elif pa[i] != pb[i]:
			return -1 if pa[i] < pb[i] else 1
	return 0

# Collapse copies of one mod (CoolMod_v1.zip + CoolMod_v1.1.zip): the best copy
# stays where the first one was and lists the others in duplicates_hidden.
func _dedupe_by_mod_id(entries: Array[Dictionary]) -> Array[Dictionary]:
	var groups: Dictionary = {}
	for e in entries:
		var key := _dedupe_group_key(e)
		if not key.is_empty():
			(groups.get_or_add(key, []) as Array).append(e)
	for key in groups:
		var members: Array = groups[key]
		if members.size() == 1:
			continue
		members.sort_custom(_compare_dedup_priority)
		var winner: Dictionary = members[0]
		var hidden: Array[Dictionary] = []
		for loser: Dictionary in members.slice(1):
			hidden.append({"file_name": loser["file_name"], "version": loser["version"]})
			_log_warning("Duplicate mod_id '%s' detected: keeping %s (%s), hiding %s (%s)" % [winner["mod_id"],
					winner["file_name"], _version_label(winner["version"]),
					loser["file_name"], _version_label(loser["version"])])
		winner["duplicates_hidden"] = hidden
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []
	for e in entries:
		var key := _dedupe_group_key(e)
		if key.is_empty():
			out.append(e)
		elif not seen.has(key):
			seen[key] = true
			out.append(groups[key][0])
	return out

func _version_label(version: Variant) -> String:
	return ("v" + str(version)) if str(version) != "" else "(unversioned)"

# "" means never collapse: a .pck has no identity beyond its file.
func _dedupe_group_key(entry: Dictionary) -> String:
	if entry["ext"] == "pck":
		return ""
	if not entry["profile_key"].begins_with("zip:"):
		return _entry_mod_key(entry)
	var stem := _normalized_mod_stem(entry["file_name"])
	return "stem:" + stem if not stem.is_empty() else ""

# The file name lowercased without its extension and one trailing version token
# ("CoolMod_v1.2" -> "coolmod"); a head with no letter left keeps the whole stem.
func _normalized_mod_stem(file_name: String) -> String:
	# The "100-" priority prefix is not part of the name, as in _entry_from_config.
	var pm := _re_filename_priority.search(file_name)
	var stem := (pm.get_string(2) if pm else file_name).get_basename().to_lower().strip_edges()
	var m := _re_mod_stem_version.search(stem)
	if m != null:
		var head := m.get_string(1).strip_edges()
		if _re_mod_stem_named.search(head) != null:
			return head
	return stem

# Higher version wins, then the newer file, then the lower file name.
func _compare_dedup_priority(a: Dictionary, b: Dictionary) -> bool:
	var vc := compare_versions(a["version"], b["version"])
	if vc != 0:
		return vc > 0
	var am := FileAccess.get_modified_time(a["full_path"])
	var bm := FileAccess.get_modified_time(b["full_path"])
	if am != bm:
		return am > bm
	return a["file_name"].to_lower() < b["file_name"].to_lower()
