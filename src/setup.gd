## ----- setup.gd -----
## lib.setup(plan) -- declarative mod-installation entry point. A plan is an
## Array of [verb, ...args] entries executed in order; each maps to one of
## the public verbs, plus the meta verb `when` for conditional sub-plans.
##
## Schema (Array of arrays):
##   ["register",    reg, {id: data, ...}]
##   ["override",    reg, {id: data, ...}]
##   ["patch",       reg, {id: fields_dict, ...}]
##   ["append",      reg, field, {id: values, ...}, allow_duplicates?]
##   ["prepend",     reg, field, {id: values, ...}, allow_duplicates?]
##   ["remove_from", reg, field, {id: values, ...}]
##   ["revert",      reg, {id: fields_array, ...}]   # [] = full revert of that id
##   ["remove",      reg, [id, id, ...]]
##   ["hooks",       {hook_name: callback, ...}]
##   ["when",        predicate, sub_plan]            # predicate: bool | Callable -> bool
##   ["register_item" / _furniture / _weapon / _magazine / _attachment /
##    _ai_loadout,   {id: data, ...}]                # registry-implicit aggregators
##
## Predicates evaluate at setup() traversal time; a const plan evaluates
## non-Callable predicates at script-parse time, so prefer Callables there.
##
## Returns {"ok": bool, "results": Array}: ok only if every executed entry
## succeeded, one result per entry shaped per verb. Failures isolate -- a
## bad entry reports ok=false and the next entry still runs.

func setup(plan: Array) -> Dictionary:
	var results: Array = []
	var all_ok := true
	for entry in plan:
		var r: Dictionary = _setup_run_entry(entry)
		results.append(r)
		if not bool(r.get("ok", false)):
			all_ok = false
	return {"ok": all_ok, "results": results}


func _setup_run_entry(entry: Variant) -> Dictionary:
	if not (entry is Array):
		return {"verb": "<malformed>", "ok": false, "error": "entry is not an Array"}
	var arr: Array = entry
	if arr.is_empty():
		return {"verb": "<empty>", "ok": false, "error": "entry is empty"}
	# String() is the non-converting constructor: a non-String verb would be
	# a runtime error aborting the whole plan instead of just this entry.
	if not (arr[0] is String or arr[0] is StringName):
		return {"verb": "<malformed>", "ok": false, "error": "verb (1st element) must be a String"}
	var verb: String = String(arr[0])
	# New verbs: one match arm here plus a schema line in the header. A
	# forgotten arm is not a compile error; it falls through to `_:`, which
	# warns and returns ok=false without aborting the rest of the plan.
	match verb:
		"register":
			return _setup_dispatch_many("register", arr, _bind_register_many())
		"override":
			return _setup_dispatch_many("override", arr, _bind_override_many())
		"patch":
			return _setup_dispatch_many("patch", arr, _bind_patch_many())
		"append":
			return _setup_dispatch_array_op("append", arr)
		"prepend":
			return _setup_dispatch_array_op("prepend", arr)
		"remove_from":
			return _setup_dispatch_array_op("remove_from", arr)
		"revert":
			return _setup_dispatch_many("revert", arr, _bind_revert_many())
		"remove":
			# remove takes an Array of ids, not a {id: ...} dict.
			if arr.size() != 3:
				return {"verb": verb, "ok": false, "error": "expected [\"remove\", reg, [ids]]"}
			if not (arr[1] is String or arr[1] is StringName):
				return {"verb": verb, "ok": false, "error": "registry name (2nd element) must be a String"}
			if not (arr[2] is Array):
				return {"verb": verb, "ok": false, "error": "expected ids Array as 3rd arg"}
			var rm: Dictionary = remove_many(String(arr[1]), arr[2])
			return {"verb": verb, "ok": rm.ok, "results": rm.results}
		"hooks":
			if arr.size() != 2:
				return {"verb": verb, "ok": false, "error": "expected [\"hooks\", {name: cb, ...}]"}
			if not (arr[1] is Dictionary):
				return {"verb": verb, "ok": false, "error": "expected hooks dict as 2nd arg"}
			var hr: Dictionary = hook_many(arr[1])
			return {"verb": verb, "ok": hr.ok, "results": hr.results}
		"register_item":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_item())
		"register_weapon":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_weapon())
		"register_magazine":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_magazine())
		"register_attachment":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_attachment())
		"register_furniture":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_furniture())
		"register_ai_loadout":
			return _setup_dispatch_aggregator(verb, arr, _bind_register_ai_loadout())
		"when":
			return _setup_dispatch_when(arr)
		_:
			# Loud as well as reported: most mods never inspect setup()'s
			# return, so a typo'd or unwired verb would vanish without trace.
			push_warning("[Registry] setup: unknown verb '%s' -- entry skipped (typo, or a verb missing its match arm in _setup_run_entry)" % verb)
			return {"verb": verb, "ok": false, "error": "unknown verb"}


# Common shape: [verb, reg, {id: payload}]; many_fn is the matching _many form.
func _setup_dispatch_many(verb: String, arr: Array, many_fn: Callable) -> Dictionary:
	if arr.size() != 3:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, {id: payload}]" % verb}
	# Same String()-constructor guard as the verb check.
	if not (arr[1] is String or arr[1] is StringName):
		return {"verb": verb, "ok": false, "error": "registry name (2nd element) must be a String"}
	if not (arr[2] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 3rd arg"}
	var res: Dictionary = many_fn.call(String(arr[1]), arr[2])
	return {"verb": verb, "ok": res.ok, "results": res.results}


# Array-op shape: [verb, reg, field, {id: values}, allow_duplicates?];
# remove_from ignores the flag.
func _setup_dispatch_array_op(verb: String, arr: Array) -> Dictionary:
	if arr.size() < 4 or arr.size() > 5:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, field, {id: values}, allow_duplicates?]" % verb}
	if not (arr[1] is String or arr[1] is StringName):
		return {"verb": verb, "ok": false, "error": "registry name (2nd element) must be a String"}
	if not (arr[2] is String or arr[2] is StringName):
		return {"verb": verb, "ok": false, "error": "field name (3rd element) must be a String"}
	if not (arr[3] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 4th arg"}
	var reg: String = String(arr[1])
	var field: String = String(arr[2])
	var entries: Dictionary = arr[3]
	# arr is mod-supplied; bool(null) on an explicit null 5th element is a
	# runtime error that would abort the plan. Read null-tolerantly.
	var allow_dups: bool = arr.size() == 5 and _json_truthy(arr[4])
	var res: Dictionary
	match verb:
		"append":      res = append_many(reg, field, entries, allow_dups)
		"prepend":     res = prepend_many(reg, field, entries, allow_dups)
		"remove_from": res = remove_from_many(reg, field, entries)
		_:
			return {"verb": verb, "ok": false, "error": "internal: bad array-op verb"}
	return {"verb": verb, "ok": res.ok, "results": res.results}


# When-shape: [when, predicate, sub_plan]. Skipped when-blocks return
# ok=true (nothing ran, nothing failed).
func _setup_dispatch_when(arr: Array) -> Dictionary:
	if arr.size() != 3:
		return {"verb": "when", "ok": false, "error": "expected [\"when\", predicate, sub_plan]"}
	if not (arr[2] is Array):
		return {"verb": "when", "ok": false, "error": "sub_plan must be an Array"}
	var truthy: bool = _setup_evaluate_predicate(arr[1])
	if not truthy:
		return {"verb": "when", "evaluated": false, "ok": true}
	var inner: Dictionary = setup(arr[2])
	return {"verb": "when", "evaluated": true, "ok": inner.ok, "results": inner.results}


# Predicate: bool, int, float, or a Callable returning one of those; anything
# else warns and reads as false -- safer than running the sub-plan on a typo.
# A Callable's return goes through the same checks: bool() on a null or a
# String is a runtime error that would abort the plan.
func _setup_evaluate_predicate(p: Variant) -> bool:
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


func _bind_register_many() -> Callable: return Callable(self, "register_many")
func _bind_override_many() -> Callable: return Callable(self, "override_many")
func _bind_patch_many() -> Callable:    return Callable(self, "patch_many")
func _bind_revert_many() -> Callable:   return Callable(self, "revert_many")


# Aggregator shape: [verb, {id: data, ...}]; registry-implicit, no reg arg.
func _setup_dispatch_aggregator(verb: String, arr: Array, agg_fn: Callable) -> Dictionary:
	if arr.size() != 2:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", {id: data, ...}]" % verb}
	if not (arr[1] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 2nd arg"}
	var res: Dictionary = agg_fn.call(arr[1])
	return {"verb": verb, "ok": res.get("ok", false), "results": res.get("results", {})}


func _bind_register_item() -> Callable:       return Callable(self, "register_item")
func _bind_register_weapon() -> Callable:     return Callable(self, "register_weapon")
func _bind_register_magazine() -> Callable:   return Callable(self, "register_magazine")
func _bind_register_attachment() -> Callable: return Callable(self, "register_attachment")
func _bind_register_furniture() -> Callable:  return Callable(self, "register_furniture")
func _bind_register_ai_loadout() -> Callable: return Callable(self, "register_ai_loadout")
