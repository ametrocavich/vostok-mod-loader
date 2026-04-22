## ----- hooks_api.gd -----
## Public surface that mods call via Engine.get_meta("RTVModLib"):
## hook/unhook/has_hooks/has_replace/get_replace_owner/skip_super/seq, the
## version accessors, plus the internal dispatch helpers. Also owns
## frameworks_ready emission.

# Version accessors. Mods call these to gate features on modloader version:
#   if lib.major_version() >= 3: use_new_api()
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
		_log_warning("[RTVModLib] Engine.meta 'RTVModLib' already set -- not overwriting")
		return
	Engine.set_meta("RTVModLib", self)
	_log_info("[RTVModLib] modloader registered as Engine.meta('RTVModLib')")

# Mods that await Engine.get_meta("RTVModLib").frameworks_ready block until
# we fire this.
func _emit_frameworks_ready() -> void:
	_is_ready = true
	_register_core_hooks()
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")
	# All mod autoloads have now finished their _ready() calls, which is
	# where overrideScript() calls typically fire take_over_path. Verify
	# each declared override actually landed in the ResourceCache and
	# subscribe to node_added so we can report whether NEW instances
	# spawn with the mod's script vs. vanilla (catches PackedScene
	# ext_resource staleness that take_over_path can't fix).
	_verify_script_overrides()

func hook(hook_name: String, callback: Callable, priority: int = 100) -> int:
	var is_replace := not (hook_name.ends_with("-pre") \
			or hook_name.ends_with("-post") \
			or hook_name.ends_with("-callback"))
	if is_replace and _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0:
		var owner_id: int = (_hooks[hook_name] as Array)[0]["id"]
		# Info-level, not warning: rejection is normal API behavior (replace
		# slots are single-owner by design). Caller checks the -1 return
		# code. Promoting this to push_warning() made every test assertion
		# and every mod-conflict check spam Godot's stderr even though it's
		# expected. Debug-gated so verbose logs still show it when needed.
		_log_debug("[RTVModLib] replace hook '%s' already owned (id=%d), registration rejected" \
				% [hook_name, owner_id])
		return -1
	if not _hooks.has(hook_name):
		_hooks[hook_name] = []
	var entry := { "callback": callback, "priority": priority, "id": _next_id }
	(_hooks[hook_name] as Array).append(entry)
	(_hooks[hook_name] as Array).sort_custom(func(a, b): return a["priority"] < b["priority"])
	# Flip the global short-circuit so dispatch wrappers stop skipping.
	_any_mod_hooked = true
	var id := _next_id
	_next_id += 1
	return id

## Remove a hook by ID.
func unhook(hook_id: int) -> void:
	for hook_name in _hooks:
		var arr: Array = _hooks[hook_name]
		for i in range(arr.size() - 1, -1, -1):
			if arr[i]["id"] == hook_id:
				arr.remove_at(i)
				return

## Any hooks registered at this name?
func has_hooks(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

## Is a replace hook registered at this bare name (no -pre/-post/-callback)?
func has_replace(hook_name: String) -> bool:
	return _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0

## ID of the current replace owner, or -1 if none. Lets a mod detect a
## pre-existing replace and fall back to pre/post rather than getting rejected.
func get_replace_owner(hook_name: String) -> int:
	if not _hooks.has(hook_name) or (_hooks[hook_name] as Array).size() == 0:
		return -1
	return (_hooks[hook_name] as Array)[0]["id"]

## From inside a replace hook: prevent super() from running on return.
func skip_super() -> void:
	_skip_super = true

## Monotonic dispatch counter, for tests + debug logging.
func seq() -> int:
	return _seq

# Internal dispatch -- called from the generated framework wrappers.

func _dispatch(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	# Snapshot before iterating so callbacks that hook()/unhook() mid-dispatch
	# see consistent semantics: hooks registered during dispatch don't fire
	# in the CURRENT dispatch (they join the next one), and the new hook()'s
	# sort_custom on the live array can't re-enter our iteration. Matches
	# C03/C16/C17/C18 test expectations.
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.callv(args)

func _dispatch_deferred(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.bindv(args).call_deferred()

func _get_hooks(hook_name: String) -> Array:
	if not _hooks.has(hook_name):
		return []
	var callbacks := []
	for entry in _hooks[hook_name]:
		callbacks.append(entry["callback"])
	return callbacks
