# The surface mods reach through Engine.get_meta("RTVModLib"): hooks, versions and
# mod queries, plus the dispatch the generated wrappers call. Hooks.md is the contract.

var _next_id: int = 1
var _seq: int = 0
var _is_ready: bool = false
var _post_warned_once: Dictionary = {}

# A per-script wrap mask is {lowercased_method: true}; {} is the wildcard (every method).
# add_hook, mod_loading.gd and main_menu_hook.gd fill _hooked_methods; none adds a key to {}.
static func _mask_is_wildcard(mask: Dictionary) -> bool:
	return mask.is_empty()

static func _mask_widen(mask: Dictionary) -> void:
	mask.clear()

static func version() -> String:
	return MODLOADER_VERSION

static func major_version() -> int:
	return int(MODLOADER_VERSION.split(".")[0])

static func minor_version() -> int:
	return int(MODLOADER_VERSION.split(".")[1])

static func patch_version() -> int:
	return int(MODLOADER_VERSION.split(".")[2])

func _register_rtv_modlib_meta() -> void:
	if Engine.has_meta("RTVModLib"):
		if Engine.get_meta("RTVModLib") != self:
			_log_warning("[RTVModLib] Engine.meta 'RTVModLib' already set -- not overwriting")
		return
	Engine.set_meta("RTVModLib", self)
	_log_info("[RTVModLib] modloader registered as Engine.meta('RTVModLib')")

func _emit_frameworks_ready() -> void:
	_is_ready = true
	_register_core_hooks()
	_scene_nodes_connect_listener()
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")
	# The mod autoloads' _ready() calls, where overrideScript() runs, are done now.
	_verify_script_overrides()

const _HOOK_SUFFIXES: Array[String] = ["-pre", "-post", "-callback"]

# "<script>-<method>" without its suffix; a bare name is the replace slot and its own base.
static func _hook_base_of(hook_name: String) -> String:
	for suffix in _HOOK_SUFFIXES:
		if hook_name.ends_with(suffix):
			return hook_name.substr(0, hook_name.length() - suffix.length())
	return hook_name

# Returns the hook id for unhook(), or -1 when the replace slot is taken. Registering
# does not wrap anything: Hooks.md "Wrap surface" says which declarations do.
func hook(hook_name: String, callback: Callable, priority: int = 100) -> int:
	var is_replace := _hook_base_of(hook_name) == hook_name
	# A replace name has one hyphen; two and no known suffix is a typo like "-per".
	if is_replace and hook_name.count("-") >= 2:
		_log_warning("[RTVModLib] hook('%s'): unrecognized suffix '-%s', filed as a replace hook that never fires" \
				% [hook_name, hook_name.get_slice("-", hook_name.count("-"))])
	# _live_hook_entries first: an owner that was freed gives the slot up.
	if is_replace and _live_hook_entries(hook_name).size() > 0:
		_log_debug("[RTVModLib] replace hook '%s' already owned (id=%d), registration rejected" \
				% [hook_name, _hooks[hook_name][0]["id"]])
		return -1
	if not _hooks.has(hook_name):
		_hooks[hook_name] = []
	_hooks[hook_name].append({"callback": callback, "priority": priority, "id": _next_id})
	_hooks[hook_name].sort_custom(func(a, b): return a["priority"] < b["priority"])
	_any_mod_hooked = true
	var base := _hook_base_of(hook_name)
	_hooked_bases[base] = _hooked_bases.get(base, 0) + 1
	var id := _next_id
	_next_id += 1
	return id

# godot-mod-loader's add_hook(path, method, cb, before) as a -pre/-post hook. It must run
# before _generate_hook_pack to widen the wrap surface; a bare filename means res://Scripts/.
func add_hook(script_path: String, method_name: String, callback: Callable, is_before: bool = true) -> int:
	var stem := script_path.get_file().get_basename().to_lower()
	var suffix := "pre" if is_before else "post"
	var hook_name := "%s-%s-%s" % [stem, method_name.to_lower(), suffix]
	var res_path := script_path
	if not res_path.begins_with("res://"):
		res_path = "res://Scripts/" + script_path.get_file()
	# Mask keys are lowercase: the pack compares lowercased method names.
	if not _hooked_methods.has(res_path):
		_hooked_methods[res_path] = {method_name.to_lower(): true}
	elif not _mask_is_wildcard(_hooked_methods[res_path]):
		# A key added to the wildcard would narrow it to this one method.
		_hooked_methods[res_path][method_name.to_lower()] = true
	return hook(hook_name, callback, 100)

# Returns {ok, results: {hook_name: id or -1}}; ok is false when any registration failed.
func hook_many(entries: Dictionary, priority: int = 100) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for hook_name in entries.keys():
		var callback: Variant = entries[hook_name]
		if not (callback is Callable):
			_log_warning("[RTVModLib] hook_many('%s'): value must be a Callable, got %s. Skipping." \
					% [str(hook_name), type_string(typeof(callback))])
			results[hook_name] = -1
			all_ok = false
			continue
		var id: int = hook(str(hook_name), callback, priority)
		results[hook_name] = id
		if id == -1:
			all_ok = false
	return {"ok": all_ok, "results": results}

func unhook(hook_id: int) -> void:
	for hook_name in _hooks:
		var arr: Array = _hooks[hook_name]
		for i in range(arr.size() - 1, -1, -1):
			if arr[i]["id"] == hook_id:
				arr.remove_at(i)
				var base := _hook_base_of(hook_name)
				var c: int = _hooked_bases[base] - 1
				if c <= 0:
					_hooked_bases.erase(base)
				else:
					_hooked_bases[base] = c
				return

# An entry whose owner was freed does not count, so a freed owner's slot reads as free.
func has_hooks(hook_name: String) -> bool:
	return _live_hook_entries(hook_name).size() > 0

# A bare-name key only ever holds replace entries, so this is has_hooks.
func has_replace(hook_name: String) -> bool:
	return has_hooks(hook_name)

func get_replace_owner(hook_name: String) -> int:
	var live := _live_hook_entries(hook_name)
	if live.is_empty():
		return -1
	return live[0]["id"]

func skip_super() -> void:
	_skip_super = true

func seq() -> int:
	return _seq

# min_version compares numeric components; a mod with no version is 0.0.0.
func has_mod(mod_id: String, min_version: String = "") -> bool:
	if not _loaded_mod_ids.has(mod_id):
		return false
	if min_version == "":
		return true
	return _compare_versions(str(_loaded_mod_ids[mod_id]["version"]), min_version) >= 0

# A deep copy: a shallow one would hand mods live references into the loader's record.
func mod_info(mod_id: String) -> Dictionary:
	if not _loaded_mod_ids.has(mod_id):
		return {}
	return _loaded_mod_ids[mod_id].duplicate(true)

func loaded_mods() -> Array[String]:
	var out: Array[String] = []
	for k in _loaded_mod_ids.keys():
		out.append(k)
	return out

# The profile this session's mods came from ("modpack__<name>" for a pack); "" until
# the mods are loaded, and fixed for the session since a switch restarts the game.
func active_profile() -> String:
	return _loaded_profile

# -1 / 0 / 1 over dotted components; a leading "v" is dropped, a non-numeric part is 0.
func _compare_versions(a: String, b: String) -> int:
	var pa: PackedStringArray = a.lstrip("vV").split(".")
	var pb: PackedStringArray = b.lstrip("vV").split(".")
	for i in max(pa.size(), pb.size()):
		var ai: int = int(pa[i]) if i < pa.size() and pa[i].is_valid_int() else 0
		var bi: int = int(pb[i]) if i < pb.size() and pb[i].is_valid_int() else 0
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0

# The callable entries of a hook name in dispatch order, unhooking any whose owner was
# freed. A snapshot: a hook() during dispatch re-sorts the live array, not this one.
func _live_hook_entries(hook_name: String) -> Array:
	var live: Array = []
	if not _hooks.has(hook_name):
		return live
	for entry in _hooks[hook_name].duplicate():
		if entry["callback"].is_valid():
			live.append(entry)
		else:
			_log_debug("[RTVModLib] hook '%s' id=%d: its owner was freed, unhooking" % [hook_name, entry["id"]])
			unhook(entry["id"])
	return live

func _dispatch(hook_name: String, args: Array) -> void:
	for entry in _live_hook_entries(hook_name):
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.callv(args)

# A callback taking args + [result] may return a replacement; null passes the result on.
# A legacy callback without the trailing result only observes.
func _dispatch_post(hook_name: String, args: Array, current_result: Variant) -> Variant:
	var expected_with_result: int = args.size() + 1
	for entry in _live_hook_entries(hook_name):
		_seq += 1
		var cb: Callable = entry["callback"]
		var argc: int = cb.get_argument_count()
		var ret: Variant = null
		if argc == expected_with_result:
			ret = cb.callv(args + [current_result])
		else:
			var legacy_key := "%s::%d::%s" % [hook_name, cb.get_object_id(), str(cb.get_method())]
			if not _post_warned_once.has(legacy_key):
				_post_warned_once[legacy_key] = true
				_log_warning("[RTVModLib] post hook '%s': legacy %d-arg callback; add a trailing _result param (%d)" \
						% [hook_name, argc, expected_with_result])
			cb.callv(args)
		# An awaiting callback returns its function state, not a value.
		if ret is Object and (ret as Object).get_class() == "GDScriptFunctionState":
			var await_key := "await::%s::%d::%s" % [hook_name, cb.get_object_id(), str(cb.get_method())]
			if not _post_warned_once.has(await_key):
				_post_warned_once[await_key] = true
				_log_warning("[RTVModLib] post hook '%s' awaits, so its return cannot replace the result" % hook_name)
			ret = null
		if ret != null:
			current_result = ret
	return current_result

func _dispatch_deferred(hook_name: String, args: Array) -> void:
	for entry in _live_hook_entries(hook_name):
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.bindv(args).call_deferred()

func _get_hooks(hook_name: String) -> Array:
	var callbacks := []
	for entry in _live_hook_entries(hook_name):
		callbacks.append(entry["callback"])
	return callbacks
