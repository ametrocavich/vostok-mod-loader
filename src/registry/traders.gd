# trader_pools sets a trader's boolean flag on an ItemData, which Trader.FillTraderBucket filters
# LT_Master by; trader_tasks are TaskData entries in a TraderData's `tasks` array.

const _TRADER_POOL_FLAGS := ["generalist", "doctor", "gunsmith", "grandma", "driver", "hunter"]

const _TRADER_PATHS := {
	"Generalist": "res://Traders/Generalist/Generalist.tres",
	"Doctor": "res://Traders/Doctor/Doctor.tres",
	"Gunsmith": "res://Traders/Gunsmith/Gunsmith.tres",
	"Driver": "res://Traders/Driver/Driver.tres",
	"Hunter": "res://Traders/Hunter/Hunter.tres",
}

func _register_trader_pool(id: String, data: Variant) -> bool:
	var reg := _bucket(_registry_registered, "trader_pools")
	if reg.has(id):
		push_warning("[Registry] register('trader_pools', '%s'): already registered (pick a unique handle)" % id)
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('trader_pools', '%s', ...) expects Dictionary {item, trader}, got %s" \
				% [id, type_string(typeof(data))])
		return false
	var d: Dictionary = data
	if not d.has("item") or not d.has("trader"):
		push_warning("[Registry] register('trader_pools', '%s', ...) data dict missing 'item' or 'trader' key" % id)
		return false
	var item = d["item"]
	if not _looks_like_item_data(item):
		push_warning("[Registry] register('trader_pools', '%s'): item is not an ItemData Resource" % id)
		return false
	var trader = d["trader"]
	if not (trader is String):
		push_warning("[Registry] register('trader_pools', '%s'): trader must be a String (e.g. 'Generalist')" % id)
		return false
	var flag: String = trader.to_lower()
	if not (flag in _TRADER_POOL_FLAGS):
		push_warning("[Registry] register('trader_pools', '%s'): unknown trader '%s' (valid: %s)" \
				% [id, trader, _TRADER_POOL_FLAGS])
		return false
	if not _object_has_property(item, flag):
		push_warning("[Registry] register('trader_pools', '%s'): item has no '%s' flag field (not a standard ItemData?)" \
				% [id, flag])
		return false
	# A second handle on the same (item, flag) inherits the first one's original: the live
	# value is that handle's `true`, which would leave the flag stuck on after both go.
	var original_value = item.get(flag)
	var sharing := _trader_pool_handle_for(reg, item, flag)
	if sharing != "":
		original_value = reg[sharing]["original"]
	item.set(flag, true)
	reg[id] = {
		"item": item,
		"trader": trader,
		"flag": flag,
		"original": original_value,
	}
	_log_debug("[Registry] registered trader_pool '%s' (%s item.%s=true, was %s)" \
			% [id, item.get("file"), flag, original_value])
	return true

func _trader_pool_handle_for(reg: Dictionary, item: Resource, flag: String) -> String:
	for existing_id in reg.keys():
		var e: Dictionary = reg[existing_id]
		if e["item"] == item and e["flag"] == flag:
			return existing_id
	return ""

func _remove_trader_pool(id: String) -> bool:
	var reg := _bucket(_registry_registered, "trader_pools")
	if not reg.has(id):
		push_warning("[Registry] remove('trader_pools', '%s'): not registered by a mod" % id)
		return false
	var entry: Dictionary = reg[id]
	reg.erase(id)
	# The last handle on an (item, flag) pair puts the original back.
	if _trader_pool_handle_for(reg, entry["item"], entry["flag"]) == "":
		(entry["item"] as Resource).set(entry["flag"], entry["original"])
	_log_debug("[Registry] removed trader_pool '%s'" % id)
	return true

func _revert_trader_pool(id: String) -> bool:
	return _remove_trader_pool(id)

func _resolve_trader_data(trader_ref: String) -> Resource:
	return _resolve_named_resource("trader_tasks", "trader", trader_ref, _TRADER_PATHS, "tasks", "TraderData")

func _looks_like_task_data(res: Variant) -> bool:
	return res is Resource and _has_properties(res, ["trader", "deliver", "receive"])
