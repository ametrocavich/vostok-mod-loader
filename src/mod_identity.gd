## Mod identity, version comparison and duplicate selection.
## Discovery, profile matching and update checks share these rules.

# Returns -1/0/1 for version comparison (a < b, equal, a > b). Dotted numeric
# components, a leading "v" ignored, "+build" metadata ignored. A "-suffix" is
# a semver prerelease: it ranks below the same version without one, and two
# suffixes compare by _compare_prerelease.
func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var core_a := a.lstrip("vV").get_slice("+", 0)
	var core_b := b.lstrip("vV").get_slice("+", 0)
	var cores := _compare_version_cores(core_a.get_slice("-", 0), core_b.get_slice("-", 0))
	if cores != 0:
		return cores
	var pre_a := core_a.substr(core_a.get_slice("-", 0).length()).lstrip("-")
	var pre_b := core_b.substr(core_b.get_slice("-", 0).length()).lstrip("-")
	if pre_a == "" or pre_b == "":
		return 0 if pre_a == pre_b else (1 if pre_a == "" else -1)
	return _compare_prerelease(pre_a, pre_b)

# The dotted numeric part of two versions; a missing or non-numeric component is 0.
func _compare_version_cores(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var sa := pa[i] if i < pa.size() else "0"
		var sb := pb[i] if i < pb.size() else "0"
		var va := int(sa) if sa.is_valid_int() else 0
		var vb := int(sb) if sb.is_valid_int() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0

# Compare two semver prerelease tails ("beta.1" vs "beta.10"). Numeric
# identifiers rank below non-numeric; a shorter run ranks lower on an equal prefix.
func _compare_prerelease(a: String, b: String) -> int:
	if a == b:
		return 0
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		if i >= pa.size():
			return -1
		if i >= pb.size():
			return 1
		var ia: String = pa[i]
		var ib: String = pb[i]
		var a_num := ia.is_valid_int()
		var b_num := ib.is_valid_int()
		if a_num and b_num:
			var va := ia.to_int()
			var vb := ib.to_int()
			if va != vb:
				return -1 if va < vb else 1
		elif a_num != b_num:
			return -1 if a_num else 1
		elif ia != ib:
			return -1 if ia < ib else 1
	return 0

# Collapse same-id duplicates (CoolMod_v1.zip + CoolMod_v1.1.zip). Mods with
# no declared id group by normalized filename stem; .pck files never collapse.
func _dedupe_by_mod_id(entries: Array[Dictionary]) -> Array[Dictionary]:
	# Group on the lowercased key so ids differing only in case collapse too.
	var groups: Dictionary = {}
	for e in entries:
		var mid := _dedupe_group_key(e)
		if mid.is_empty():
			continue
		if not groups.has(mid):
			groups[mid] = []
		(groups[mid] as Array).append(e)

	var winners_by_id: Dictionary = {}
	for mid in groups.keys():
		var members: Array = groups[mid]
		if members.size() == 1:
			winners_by_id[mid] = members[0]
			continue
		members.sort_custom(_compare_dedup_priority)
		var winner: Dictionary = members[0]
		var hidden: Array[Dictionary] = []
		var w_v: String = ("v" + str(winner["version"])) if str(winner["version"]) != "" else "(unversioned)"
		for j in range(1, members.size()):
			var loser: Dictionary = members[j]
			hidden.append({"file_name": loser["file_name"], "version": loser["version"]})
			var l_v: String = ("v" + str(loser["version"])) if str(loser["version"]) != "" else "(unversioned)"
			_log_warning("Duplicate mod_id '" + str(winner["mod_id"]) + "' detected: keeping "
					+ str(winner["file_name"]) + " (" + w_v + "), hiding "
					+ str(loser["file_name"]) + " (" + l_v + ")")
		winner["duplicates_hidden"] = hidden
		winners_by_id[mid] = winner

	var seen_ids: Dictionary = {}
	var out: Array[Dictionary] = []
	for e in entries:
		var mid := _dedupe_group_key(e)
		if mid.is_empty():
			out.append(e)
			continue
		if seen_ids.has(mid):
			continue
		seen_ids[mid] = true
		out.append(winners_by_id[mid])
	return out

# Identity used to collapse duplicates; "" means never collapse.
func _dedupe_group_key(entry: Dictionary) -> String:
	if str(entry.get("ext", "")) == "pck":
		return ""
	if not str(entry.get("profile_key", "")).begins_with("zip:"):
		return _entry_mod_key(entry)
	var stem := _normalized_mod_stem(str(entry.get("file_name", "")))
	return "stem:" + stem if not stem.is_empty() else ""

# Filename reduced to what survives a re-package: extension gone, lowercased,
# one trailing version token stripped ("CoolMod_v1.2" -> "coolmod"). What
# survives must contain a letter, or bare-numeric filenames would all collapse.
func _normalized_mod_stem(file_name: String) -> String:
	var stem := file_name.get_basename().to_lower().strip_edges()
	var m := _re_mod_stem_version.search(stem)
	if m != null:
		# A head with no letter left is a bare version, not a name.
		var head := m.get_string(1).strip_edges()
		if _re_mod_stem_named.search(head) != null:
			return head
	return stem

# Higher version wins; tiebreak newer mtime, then alphabetically lower filename.
func _compare_dedup_priority(a: Dictionary, b: Dictionary) -> bool:
	var vc := compare_versions(str(a.get("version", "")), str(b.get("version", "")))
	if vc != 0:
		return vc > 0
	var am: int = FileAccess.get_modified_time(str(a["full_path"]))
	var bm: int = FileAccess.get_modified_time(str(b["full_path"]))
	if am != bm:
		return am > bm
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()
