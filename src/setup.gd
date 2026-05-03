## ----- setup.gd -----
##
## lib.setup(plan) -- declarative mod-installation entry point.
##
## A "plan" is an Array of [verb, ...args] entries. Order is insertion order,
## so register-then-patch flows work naturally. Each entry maps to one of the
## existing public verbs (register, override, patch, append, prepend,
## remove_from, revert, remove, hooks) plus a meta verb `when` for
## conditional sub-plans.
##
## Why this exists: mods that lean heavily on the hook + registry systems
## tend to accumulate dozens of administrative lines in _ready (one per
## hook, one per registration). setup() collapses that into one
## declarative literal that can be a const at module scope or a runtime-
## built local in _ready.
##
## Schema reference (Array of arrays):
##   ["register",    reg, {id: data, ...}]
##   ["override",    reg, {id: data, ...}]
##   ["patch",       reg, {id: fields_dict, ...}]
##   ["append",      reg, field, {id: values, ...}]                       # de-dup default
##   ["append",      reg, field, {id: values, ...}, true]                 # allow_duplicates
##   ["prepend",     reg, field, {id: values, ...}]                       # de-dup default
##   ["prepend",     reg, field, {id: values, ...}, true]                 # allow_duplicates
##   ["remove_from", reg, field, {id: values, ...}]
##   ["revert",      reg, {id: fields_array, ...}]   # [] = full revert of that id
##   ["remove",      reg, [id, id, ...]]
##   ["hooks",       {hook_name: callback, ...}]
##   ["when",        predicate, sub_plan]            # predicate: bool | Callable -> bool
##
## Predicate evaluation: at setup() traversal time. If a plan is built in
## _ready (typical), runtime state is queryable in the predicate. A const
## plan with non-Callable predicates evaluates them at script-parse time --
## fine for compile-time bools but wrong for runtime state, so prefer
## Callable/lambda predicates in const plans.
##
## Return shape (Dictionary):
##   {
##     "ok": bool,                # true only if every executed entry succeeded
##     "results": Array,          # one entry per top-level plan entry
##   }
##
## Per-result entries match their verb:
##   {"verb": "register", "ok": bool, "results": {id: bool}}
##   {"verb": "patch",    "ok": bool, "results": {id: bool}}
##   {"verb": "hooks",    "ok": bool, "results": {hook_name: int}}
##   {"verb": "when",     "evaluated": bool, "ok": bool, "results": [...]?}
##                                  # results present only when evaluated=true
##   {"verb": "<unknown>", "ok": false, "error": "..."}   # malformed entry
##
## Failures isolate. A bad entry produces a result with ok=false and the
## next entry runs anyway -- consistent with the singular verbs and the
## _many forms.

func setup(plan: Array) -> Dictionary:
	var results: Array = []
	var all_ok := true
	for entry in plan:
		var r: Dictionary = _setup_run_entry(entry)
		results.append(r)
		if not bool(r.get("ok", false)):
			all_ok = false
	return {"ok": all_ok, "results": results}


# Dispatch a single plan entry. Returns the per-entry result Dictionary.
func _setup_run_entry(entry: Variant) -> Dictionary:
	if not (entry is Array):
		return {"verb": "<malformed>", "ok": false, "error": "entry is not an Array"}
	var arr: Array = entry
	if arr.is_empty():
		return {"verb": "<empty>", "ok": false, "error": "entry is empty"}
	var verb: String = String(arr[0])
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
		"when":
			return _setup_dispatch_when(arr)
		_:
			return {"verb": verb, "ok": false, "error": "unknown verb"}


# Common shape: [verb, reg, {id: payload}]. The Callable invokes the
# corresponding _many form.
func _setup_dispatch_many(verb: String, arr: Array, many_fn: Callable) -> Dictionary:
	if arr.size() != 3:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, {id: payload}]" % verb}
	if not (arr[2] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 3rd arg"}
	var res: Dictionary = many_fn.call(String(arr[1]), arr[2])
	return {"verb": verb, "ok": res.ok, "results": res.results}


# Array-op shape: [verb, reg, field, {id: values}, allow_duplicates?].
# allow_duplicates only applies to append/prepend; remove_from ignores it.
func _setup_dispatch_array_op(verb: String, arr: Array) -> Dictionary:
	if arr.size() < 4 or arr.size() > 5:
		return {"verb": verb, "ok": false, "error": "expected [\"%s\", reg, field, {id: values}, allow_duplicates?]" % verb}
	if not (arr[3] is Dictionary):
		return {"verb": verb, "ok": false, "error": "expected payload dict as 4th arg"}
	var reg: String = String(arr[1])
	var field: String = String(arr[2])
	var entries: Dictionary = arr[3]
	var allow_dups: bool = arr.size() == 5 and bool(arr[4])
	var res: Dictionary
	match verb:
		"append":      res = append_many(reg, field, entries, allow_dups)
		"prepend":     res = prepend_many(reg, field, entries, allow_dups)
		"remove_from": res = remove_from_many(reg, field, entries)
		_:
			return {"verb": verb, "ok": false, "error": "internal: bad array-op verb"}
	return {"verb": verb, "ok": res.ok, "results": res.results}


# When-shape: [when, predicate, sub_plan]. Recurse on sub_plan if predicate
# evaluates truthy. Skipped when-blocks return ok=true (vacuously: nothing
# failed because nothing ran).
func _setup_dispatch_when(arr: Array) -> Dictionary:
	if arr.size() != 3:
		return {"verb": "when", "ok": false, "error": "expected [\"when\", predicate, sub_plan]"}
	if not (arr[2] is Array):
		return {"verb": "when", "ok": false, "error": "sub_plan must be an Array"}
	var truthy: bool = _setup_evaluate_predicate(arr[1])
	if not truthy:
		return {"verb": "when", "evaluated": false, "ok": true}
	# Predicate true -- recurse. Inner plan returns its own {ok, results};
	# bubble up the same shape so callers can introspect nested outcomes.
	var inner: Dictionary = setup(arr[2])
	return {"verb": "when", "evaluated": true, "ok": inner.ok, "results": inner.results}


# Predicate accepts plain bool, Callable, or anything bool()-coercible. Any
# other type is treated as false (with a warning) -- safer than running the
# sub-plan on a typo.
func _setup_evaluate_predicate(p: Variant) -> bool:
	if p is Callable:
		return bool((p as Callable).call())
	if p is bool or p is int or p is float:
		return bool(p)
	if p == null:
		return false
	push_warning("[Registry] setup: when-predicate has unexpected type %s; treating as false" % typeof(p))
	return false


# These helpers wrap the _many methods as Callables so the dispatcher can
# pass them through _setup_dispatch_many. Saves a small amount of repetition.
func _bind_register_many() -> Callable: return Callable(self, "register_many")
func _bind_override_many() -> Callable: return Callable(self, "override_many")
func _bind_patch_many() -> Callable:    return Callable(self, "patch_many")
func _bind_revert_many() -> Callable:   return Callable(self, "revert_many")


# Aggregator-shape: [verb, {id: data, ...}]. No `reg` arg -- each aggregator
# is registry-implicit. Maps to the public aggregator helpers, which already
# accept and return a Dictionary.
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
