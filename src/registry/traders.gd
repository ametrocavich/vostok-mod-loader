## ----- registry/traders.gd -----
## Two related registries that both mutate trader-adjacent state:
##
## - trader_pools: enables an ItemData to appear in a named trader's supply
##   bucket. Trader.FillTraderBucket() walks LT_Master and filters by
##   boolean trader flags on each item (itemData.generalist / .doctor /
##   .gunsmith / .grandma). So "register an item into the Doctor's pool" =
##   set itemData.doctor = true. Register / remove only; no override or
##   patch (entries are single boolean flags, there's nothing to override).
##
## - trader_tasks: appends/overrides/patches TaskData entries in a
##   TraderData.tasks array. Structurally identical to recipes: register
##   adds, override swaps (requires `replaces`), patch mutates fields on a
##   TaskData (String handle OR direct TaskData ref).
##
## Timing: same as loot/recipes/events. Trader.gd fills its local bucket in
## _ready() from LT_Master's pre-mutated items and TraderData.tasks. Mods
## must register during their own _ready() or changes won't propagate into
## a trader that's already initialized.

const _TRADER_POOL_FLAGS := {
	"generalist": "generalist",
	"doctor": "doctor",
	"gunsmith": "gunsmith",
	"grandma": "grandma",
}

# Known TraderData paths. Mods can also pass an absolute res:// path for a
# custom trader (e.g., one added by another mod via a file-level addition).
const _TRADER_PATHS := {
	"Generalist": "res://Traders/Generalist/Generalist.tres",
	"Doctor": "res://Traders/Doctor/Doctor.tres",
	"Gunsmith": "res://Traders/Gunsmith/Gunsmith.tres",
}

# -------- trader_pools --------

func _normalize_trader_flag(trader_name: String) -> String:
	# Accepts "Generalist", "generalist", "GENERALIST" -> "generalist".
	# The ItemData flags are lowercased; the TraderData.name fields are
	# capitalized. trader_pools keys by the flag name.
	var lower := trader_name.to_lower()
	if _TRADER_POOL_FLAGS.has(lower):
		return lower
	return ""

func _register_trader_pool(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("trader_pools", {})
	if reg.has(id):
		push_warning("[Registry] register('trader_pools', '%s'): already registered (pick a unique handle)" % id)
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('trader_pools', '%s', ...) expects Dictionary {item, trader}, got %s" % [id, typeof(data)])
		return false
	var d: Dictionary = data
	if not d.has("item") or not d.has("trader"):
		push_warning("[Registry] register('trader_pools', '%s', ...) data dict missing 'item' or 'trader' key" % id)
		return false
	var item = d["item"]
	if not (item is Resource) or not _looks_like_item_data(item):
		push_warning("[Registry] register('trader_pools', '%s'): item is not an ItemData Resource" % id)
		return false
	var trader = d["trader"]
	if not (trader is String):
		push_warning("[Registry] register('trader_pools', '%s'): trader must be a String (e.g. 'Generalist')" % id)
		return false
	var flag := _normalize_trader_flag(trader)
	if flag == "":
		push_warning("[Registry] register('trader_pools', '%s'): unknown trader '%s' (valid: %s)" \
				% [id, trader, _TRADER_POOL_FLAGS.keys()])
		return false
	if not _resource_has_property(item, flag):
		push_warning("[Registry] register('trader_pools', '%s'): item has no '%s' flag field (not a standard ItemData?)" % [id, flag])
		return false
	# Stash the original flag value so remove/revert can restore it. Most
	# items default to false for a given trader flag, but we don't assume.
	var original_value = item.get(flag)
	item.set(flag, true)
	reg[id] = {
		"item": item,
		"trader": trader,
		"flag": flag,
		"original": original_value,
	}
	_registry_registered["trader_pools"] = reg
	_log_debug("[Registry] registered trader_pool '%s' (%s item.%s=true, was %s)" \
			% [id, item.get("file"), flag, original_value])
	return true

func _remove_trader_pool(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("trader_pools", {})
	if not reg.has(id):
		push_warning("[Registry] remove('trader_pools', '%s'): not registered by a mod" % id)
		return false
	var entry: Dictionary = reg[id]
	var item: Resource = entry["item"]
	var flag: String = entry["flag"]
	item.set(flag, entry["original"])
	reg.erase(id)
	_registry_registered["trader_pools"] = reg
	_log_debug("[Registry] removed trader_pool '%s'" % id)
	return true

# Revert on trader_pools is a straight alias for remove; there's no
# override layer. Accept it for API symmetry so mods can call revert
# uniformly across registries.
func _revert_trader_pool(id: String) -> bool:
	return _remove_trader_pool(id)

# -------- trader_tasks --------

var _trader_data_cache: Dictionary = {}  # name -> Resource

func _resolve_trader_data(trader_ref: String) -> Resource:
	if trader_ref == "":
		push_warning("[Registry] trader_tasks: empty trader name")
		return null
	if _trader_data_cache.has(trader_ref):
		return _trader_data_cache[trader_ref]
	var path := trader_ref
	if _TRADER_PATHS.has(trader_ref):
		path = _TRADER_PATHS[trader_ref]
	elif not trader_ref.begins_with("res://"):
		push_warning("[Registry] trader_tasks: unknown trader '%s' (valid: %s, or pass an absolute res:// path)" \
				% [trader_ref, _TRADER_PATHS.keys()])
		return null
	var res = load(path)
	if res == null:
		push_warning("[Registry] trader_tasks: couldn't load TraderData at '%s'" % path)
		return null
	if not ("tasks" in res):
		push_warning("[Registry] trader_tasks: resource at '%s' has no `tasks` array (not a TraderData?)" % path)
		return null
	_trader_data_cache[trader_ref] = res
	return res

# Shape check for TaskData.
func _looks_like_task_data(res: Resource) -> bool:
	return _resource_has_property(res, "trader") \
			and _resource_has_property(res, "deliver") \
			and _resource_has_property(res, "receive")

# Validates {task, trader} payload. Returns [task, tasks_arr, trader_name]
# or [null, null, ""] on error.
func _validate_trader_task(id: String, verb: String, data: Variant) -> Array:
	if not (data is Dictionary):
		push_warning("[Registry] %s('trader_tasks', '%s', ...) expects Dictionary {task, trader}, got %s" % [verb, id, typeof(data)])
		return [null, null, ""]
	var d: Dictionary = data
	if not d.has("task") or not d.has("trader"):
		push_warning("[Registry] %s('trader_tasks', '%s', ...) data dict missing 'task' or 'trader' key" % [verb, id])
		return [null, null, ""]
	var task = d["task"]
	if not (task is Resource) or not _looks_like_task_data(task):
		push_warning("[Registry] %s('trader_tasks', '%s'): task is not a TaskData Resource" % [verb, id])
		return [null, null, ""]
	var trader = d["trader"]
	if not (trader is String):
		push_warning("[Registry] %s('trader_tasks', '%s'): trader must be a String" % [verb, id])
		return [null, null, ""]
	var trader_res := _resolve_trader_data(trader)
	if trader_res == null:
		return [null, null, ""]
	var arr = trader_res.get("tasks")
	if not (arr is Array):
		push_warning("[Registry] %s('trader_tasks', '%s'): %s.tasks is not an Array" % [verb, id, trader])
		return [null, null, ""]
	return [task, arr, String(trader)]

func _register_trader_task(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("trader_tasks", {})
	if reg.has(id):
		push_warning("[Registry] register('trader_tasks', '%s'): already registered (pick a unique handle)" % id)
		return false
	var parts := _validate_trader_task(id, "register", data)
	var task = parts[0]
	var arr = parts[1]
	var trader: String = parts[2]
	if task == null or arr == null:
		return false
	if not _typed_array_accepts(arr, task):
		push_warning("[Registry] register('trader_tasks', '%s'): task type doesn't match %s.tasks typed array" % [id, trader])
		return false
	if task in arr:
		push_warning("[Registry] register('trader_tasks', '%s'): task already in %s.tasks; use override to swap" % [id, trader])
		return false
	arr.append(task)
	reg[id] = {"task": task, "trader": trader}
	_registry_registered["trader_tasks"] = reg
	_log_debug("[Registry] registered trader_task '%s' (trader=%s, name=%s)" % [id, trader, task.get("name")])
	return true

func _override_trader_task(id: String, data: Variant) -> bool:
	var ov: Dictionary = _registry_overridden.get("trader_tasks", {})
	if ov.has(id):
		push_warning("[Registry] override('trader_tasks', '%s'): already overridden (revert first)" % id)
		return false
	if not (data is Dictionary) or not data.has("replaces"):
		push_warning("[Registry] override('trader_tasks', '%s', ...) requires {task, trader, replaces: TaskData}" % id)
		return false
	var parts := _validate_trader_task(id, "override", data)
	var new_task = parts[0]
	var arr = parts[1]
	var trader: String = parts[2]
	if new_task == null or arr == null:
		return false
	var old_task = data["replaces"]
	if not (old_task is Resource) or not _looks_like_task_data(old_task):
		push_warning("[Registry] override('trader_tasks', '%s'): 'replaces' is not a TaskData Resource" % id)
		return false
	if not _typed_array_accepts(arr, new_task):
		push_warning("[Registry] override('trader_tasks', '%s'): task type doesn't match %s.tasks typed array" % [id, trader])
		return false
	var idx: int = arr.find(old_task)
	if idx < 0:
		push_warning("[Registry] override('trader_tasks', '%s'): 'replaces' not present in %s.tasks" % [id, trader])
		return false
	if new_task in arr:
		push_warning("[Registry] override('trader_tasks', '%s'): new task already in array; would duplicate" % id)
		return false
	arr[idx] = new_task
	ov[id] = {
		"task": new_task,
		"trader": trader,
		"replaced": old_task,
		"index": idx,
	}
	_registry_overridden["trader_tasks"] = ov
	var reg: Dictionary = _registry_registered.get("trader_tasks", {})
	reg[id] = {"task": new_task, "trader": trader}
	_registry_registered["trader_tasks"] = reg
	_log_debug("[Registry] overrode trader_task '%s' in %s" % [id, trader])
	return true

# Resolve a patch target (String handle or TaskData ref) -> [task, key].
func _resolve_trader_task_patch_target(id: Variant) -> Array:
	if id is String:
		var reg: Dictionary = _registry_registered.get("trader_tasks", {})
		if reg.has(id):
			return [reg[id]["task"], id]
		push_warning("[Registry] patch('trader_tasks', '%s'): no registered handle with that id (register first, or pass a TaskData Resource ref directly)" % id)
		return [null, null]
	if id is Resource and _looks_like_task_data(id):
		return [id, "ref:%d" % id.get_instance_id()]
	push_warning("[Registry] patch('trader_tasks', ...): id must be a String handle or a TaskData Resource")
	return [null, null]

func _patch_trader_task(id: Variant, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('trader_tasks', ...): empty fields dict is a no-op")
		return false
	var resolved := _resolve_trader_task_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	var patched: Dictionary = _registry_patched.get("trader_tasks", {})
	var stash: Dictionary = patched.get(key, {})
	for field in fields.keys():
		var fname := String(field)
		if not _resource_has_property(target, fname):
			push_warning("[Registry] patch('trader_tasks'): field '%s' doesn't exist on TaskData" % fname)
			continue
		if not stash.has(fname):
			stash[fname] = target.get(fname)
		target.set(fname, fields[field])
	patched[key] = stash
	_registry_patched["trader_tasks"] = patched
	_log_debug("[Registry] patched trader_task (key=%s) fields %s" % [key, fields.keys()])
	return true

func _remove_trader_task(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("trader_tasks", {})
	if not reg.has(id):
		push_warning("[Registry] remove('trader_tasks', '%s'): not a mod registration" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("trader_tasks", {})
	if ov.has(id):
		push_warning("[Registry] remove('trader_tasks', '%s'): entry is an override, use revert instead" % id)
		return false
	var entry: Dictionary = reg[id]
	var trader: String = entry["trader"]
	var task: Resource = entry["task"]
	var trader_res := _resolve_trader_data(trader)
	if trader_res != null:
		var arr = trader_res.get("tasks")
		if arr is Array:
			var idx: int = arr.find(task)
			if idx >= 0:
				arr.remove_at(idx)
			else:
				push_warning("[Registry] remove('trader_tasks', '%s'): task not found in %s.tasks; tracking cleared" % [id, trader])
	reg.erase(id)
	_registry_registered["trader_tasks"] = reg
	_log_debug("[Registry] removed trader_task '%s'" % id)
	return true

func _revert_trader_task(id: Variant, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("trader_tasks", {})
	var patched: Dictionary = _registry_patched.get("trader_tasks", {})
	var patch_key = null
	var patch_target: Resource = null
	if id is String:
		patch_key = id
		var reg: Dictionary = _registry_registered.get("trader_tasks", {})
		if reg.has(id):
			patch_target = reg[id]["task"]
	elif id is Resource and _looks_like_task_data(id):
		patch_key = "ref:%d" % id.get_instance_id()
		patch_target = id
	if fields.is_empty():
		if patch_key != null and patched.has(patch_key):
			if patch_target != null:
				var stash: Dictionary = patched[patch_key]
				for fname in stash.keys():
					patch_target.set(fname, stash[fname])
			patched.erase(patch_key)
			_registry_patched["trader_tasks"] = patched
			did_something = true
		if id is String and ov.has(id):
			var entry: Dictionary = ov[id]
			var trader_res := _resolve_trader_data(entry["trader"])
			if trader_res != null:
				var arr = trader_res.get("tasks")
				if arr is Array:
					var current_idx: int = arr.find(entry["task"])
					if current_idx >= 0:
						arr[current_idx] = entry["replaced"]
					else:
						push_warning("[Registry] revert('trader_tasks', '%s'): override's task missing from %s.tasks, appending original at end" % [id, entry["trader"]])
						arr.append(entry["replaced"])
			ov.erase(id)
			_registry_overridden["trader_tasks"] = ov
			var reg2: Dictionary = _registry_registered.get("trader_tasks", {})
			reg2.erase(id)
			_registry_registered["trader_tasks"] = reg2
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('trader_tasks'): nothing to revert for that id")
		return did_something
	if patch_key == null or not patched.has(patch_key):
		push_warning("[Registry] revert('trader_tasks'): no patches found for that id")
		return false
	if patch_target == null:
		push_warning("[Registry] revert('trader_tasks'): patch target no longer resolves")
		return false
	var stash2: Dictionary = patched[patch_key]
	for field in fields:
		var fname := String(field)
		if not stash2.has(fname):
			push_warning("[Registry] revert('trader_tasks'): field '%s' wasn't patched" % fname)
			continue
		patch_target.set(fname, stash2[fname])
		stash2.erase(fname)
		did_something = true
	if stash2.is_empty():
		patched.erase(patch_key)
	else:
		patched[patch_key] = stash2
	_registry_patched["trader_tasks"] = patched
	return did_something
