# lib.setup(plan): runs each [verb, ...args] entry in order (schema: docs/wiki/Setup-Plans.md).
# A failing entry reports ok=false and the next one still runs.

func setup(plan: Array) -> Dictionary:
	var results: Array = []
	var all_ok := true
	for entry in plan:
		var r := _run_setup_entry(entry)
		results.append(r)
		if not r["ok"]:
			all_ok = false
	return {"ok": all_ok, "results": results}

# String() does not convert: a non-String name would raise a runtime error that
# aborts the whole plan instead of failing this entry.
func _setup_is_name(v: Variant) -> bool:
	return v is String or v is StringName

func _run_setup_entry(entry: Variant) -> Dictionary:
	if not (entry is Array):
		return {"verb": "<malformed>", "ok": false, "error": "entry is not an Array"}
	var arr: Array = entry
	if arr.is_empty():
		return {"verb": "<empty>", "ok": false, "error": "entry is empty"}
	if not _setup_is_name(arr[0]):
		return {"verb": "<malformed>", "ok": false, "error": "verb (1st element) must be a String"}
	var verb := String(arr[0])
	var n := arr.size()
	var error := ""
	var res: Dictionary = {}
	match verb:
		"register", "override", "patch", "revert":
			if n != 3:
				error = "expected [\"%s\", reg, {id: payload}]" % verb
			elif not _setup_is_name(arr[1]):
				error = "registry name (2nd element) must be a String"
			elif not (arr[2] is Dictionary):
				error = "expected payload dict as 3rd arg"
			else:
				res = call(verb + "_many", String(arr[1]), arr[2])
		"append", "prepend", "remove_from":
			if n != 4 and n != 5:
				error = "expected [\"%s\", reg, field, {id: values}, allow_duplicates?]" % verb
			elif not _setup_is_name(arr[1]):
				error = "registry name (2nd element) must be a String"
			elif not _setup_is_name(arr[2]):
				error = "field name (3rd element) must be a String"
			elif not (arr[3] is Dictionary):
				error = "expected payload dict as 4th arg"
			elif verb == "remove_from":
				# remove_from takes no allow_duplicates; a 5th element is ignored.
				res = remove_from_many(String(arr[1]), String(arr[2]), arr[3])
			else:
				# bool(null) is a runtime error, and a mod may pass null as allow_duplicates.
				res = call(verb + "_many", String(arr[1]), String(arr[2]), arr[3], n == 5 and _json_truthy(arr[4]))
		"remove":
			if n != 3:
				error = "expected [\"remove\", reg, [ids]]"
			elif not _setup_is_name(arr[1]):
				error = "registry name (2nd element) must be a String"
			elif not (arr[2] is Array):
				error = "expected ids Array as 3rd arg"
			else:
				res = remove_many(String(arr[1]), arr[2])
		"hooks":
			if n != 2:
				error = "expected [\"hooks\", {name: cb, ...}]"
			elif not (arr[1] is Dictionary):
				error = "expected hooks dict as 2nd arg"
			else:
				res = hook_many(arr[1])
		"register_item", "register_weapon", "register_magazine", "register_attachment", \
		"register_furniture", "register_ai_loadout":
			if n != 2:
				error = "expected [\"%s\", {id: data, ...}]" % verb
			elif not (arr[1] is Dictionary):
				error = "expected payload dict as 2nd arg"
			else:
				res = call(verb, arr[1])
		"when":
			if n != 3:
				error = "expected [\"when\", predicate, sub_plan]"
			elif not (arr[2] is Array):
				error = "sub_plan must be an Array"
			elif not _setup_predicate(arr[1]):
				return {"verb": "when", "evaluated": false, "ok": true}
			else:
				var inner := setup(arr[2])
				return {"verb": "when", "evaluated": true, "ok": inner["ok"], "results": inner["results"]}
		_:
			# Warned as well as reported: most mods never read setup()'s result.
			push_warning("[Registry] setup: unknown verb '%s' -- entry skipped" % verb)
			error = "unknown verb"
	if error != "":
		return {"verb": verb, "ok": false, "error": error}
	return {"verb": verb, "ok": res["ok"], "results": res["results"]}

# A bool, int or float, or a Callable returning one; anything else warns and reads
# as false, since bool() on null or a String is a runtime error.
func _setup_predicate(p: Variant) -> bool:
	if p is Callable:
		if not (p as Callable).is_valid():
			push_warning("[Registry] setup: when-predicate Callable is no longer valid; treating as false")
			return false
		p = (p as Callable).call()
	if p is bool or p is int or p is float:
		return bool(p)
	if p == null:
		return false
	push_warning("[Registry] setup: when-predicate has unexpected type %s; treating as false" % typeof(p))
	return false
