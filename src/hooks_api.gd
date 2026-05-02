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
	_scene_nodes_connect_listener()
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")
	# All mod autoloads have now finished their _ready() calls, which is
	# where overrideScript() calls typically fire take_over_path. Verify
	# each declared override actually landed in the ResourceCache and
	# subscribe to node_added so we can report whether NEW instances
	# spawn with the mod's script vs. vanilla (catches PackedScene
	# ext_resource staleness that take_over_path can't fix).
	_verify_script_overrides()

## Extract the hook_base ("<script>-<method>") from a full hook name by
## stripping any -pre/-post/-callback suffix. A bare name (replace hook) is
## already its own base. Used to maintain _hooked_bases.
static func _hook_base_of(hook_name: String) -> String:
	if hook_name.ends_with("-pre"):
		return hook_name.substr(0, hook_name.length() - 4)
	if hook_name.ends_with("-post"):
		return hook_name.substr(0, hook_name.length() - 5)
	if hook_name.ends_with("-callback"):
		return hook_name.substr(0, hook_name.length() - 9)
	return hook_name


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
	# Refcount the hook_base so wrappers for never-hooked methods can
	# fast-path past dispatch. Pre/post/callback all share the same base.
	var base := _hook_base_of(hook_name)
	_hooked_bases[base] = int(_hooked_bases.get(base, 0)) + 1
	var id := _next_id
	_next_id += 1
	return id

## godot-mod-loader compat shim. Mods written against the upstream
## godot-mod-loader convention call `ModLoader.add_hook(path, method, cb,
## before)` to register a hook. Translate that into our native
## `hook("<stem>-<method>-pre/post", cb)`. Enroll the path into
## _hooked_methods so the wrap surface picks it up on pack generation.
##
## Limitation 1 -- timing: pack generation reads _hooked_methods up front.
## An add_hook() call that arrives AFTER `_generate_hook_pack` has already
## run won't get its vanilla script wrapped (the hook name registers fine,
## but there's no wrapper to dispatch it). To be wrapped, add_hook() must
## run before _generate_hook_pack -- in practice, from a `!`-prefixed early
## autoload's _init, or the mod must declare the path in [hooks] in mod.txt
## so the wrap mask is populated statically before any mod code runs.
##
## Limitation 2 -- path shape: bare filenames are normalized to
## `res://Scripts/<file>` to match RTV's game-script layout. If the actual
## vanilla lives elsewhere (`res://Scripts/Framework/X.gd`,
## `res://SomeOther/Y.gd`, etc.) the normalized path won't match any enumerated
## vanilla and the wrap silently no-ops. Pass a fully-qualified `res://` path
## when your target isn't directly under `res://Scripts/`.
func add_hook(script_path: String, method_name: String, callback: Callable, is_before: bool = true) -> int:
	var stem := script_path.get_file().get_basename().to_lower()
	var suffix := "pre" if is_before else "post"
	var hook_name := "%s-%s-%s" % [stem, method_name.to_lower(), suffix]
	# Enroll the path into _hooked_methods so the wrap surface picks it up.
	# Upstream godot-mod-loader accepts both fully-qualified res:// paths and
	# bare filenames; normalize bare filenames to res://Scripts/<file> to
	# match the game's script layout. Mask keys are lowercase (hook_pack.gd
	# checks `fe["name"].to_lower()` against the mask), so lowercase the
	# method name on write -- godot-mod-loader callers pass vanilla method
	# names preserving source casing (e.g. "UpdateToolTip").
	var res_path := script_path
	if not res_path.begins_with("res://"):
		res_path = "res://Scripts/" + script_path.get_file()
	if not _hooked_methods.has(res_path):
		_hooked_methods[res_path] = {}
	(_hooked_methods[res_path] as Dictionary)[method_name.to_lower()] = true
	return hook(hook_name, callback, 100)

## Batched form of hook(). `entries` is `{hook_name: callback, ...}`. Returns
## `{ok: bool, results: {hook_name: hook_id_or_-1, ...}}`. Failures (e.g. a
## replace name already owned by another mod) surface as -1 in the results
## dict; ok is false if any registration returned -1.
func hook_many(entries: Dictionary, priority: int = 100) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for hook_name in entries.keys():
		var id: int = hook(String(hook_name), entries[hook_name], priority)
		results[hook_name] = id
		if id == -1:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Remove a hook by ID.
func unhook(hook_id: int) -> void:
	for hook_name in _hooks:
		var arr: Array = _hooks[hook_name]
		for i in range(arr.size() - 1, -1, -1):
			if arr[i]["id"] == hook_id:
				arr.remove_at(i)
				var base := _hook_base_of(hook_name)
				var c: int = int(_hooked_bases.get(base, 0)) - 1
				if c <= 0:
					_hooked_bases.erase(base)
				else:
					_hooked_bases[base] = c
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

# Post-hook chained dispatch for non-void wrapped methods. Each callback
# may transform the running result by returning a non-null value.
#
# Callback signature (preferred): `func(<vanilla args>, _result)`. The
# trailing `_result` is whatever the prior post hook (or vanilla body)
# left behind. Returning non-null replaces _result for the next callback;
# returning null is a pass-through ("I observed but don't want to change
# anything"). Mods needing to actually return a literal null can't model
# that here -- documented limitation.
#
# Backwards compat: callbacks declared with the old 2-arg shape (no
# trailing _result) still work. The dispatcher detects arity via
# Callable.get_argument_count() and routes to the appropriate call form.
# A one-shot deprecation warning fires per (hook_name, callback) pair so
# legacy mods keep running without log spam, but authors get a clear
# nudge to update their signatures.
#
# Priority order matches _dispatch: ascending by `priority` field, ties
# broken by registration order (Array iteration).
func _dispatch_post(hook_name: String, args: Array, current_result: Variant) -> Variant:
	if not _hooks.has(hook_name):
		return current_result
	# Snapshot before iterating: same rationale as _dispatch -- mid-dispatch
	# hook()/unhook() calls don't disturb the in-flight pass.
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	var expected_with_result: int = args.size() + 1
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		var argc: int = cb.get_argument_count()
		var ret: Variant = null
		if argc == expected_with_result:
			# New 3-arg form: callback wants the result.
			ret = cb.callv(args + [current_result])
		else:
			# Legacy 2-arg form (or anything else). Fire-and-forget on
			# args only, ignore return. Warn once.
			var warn_key: String = "%s::%d" % [hook_name, cb.get_object_id()]
			if not _post_legacy_warned.has(warn_key):
				_post_legacy_warned[warn_key] = true
				_log_warning("[RTVModLib] post hook '%s' callback uses legacy %d-arg signature (expected %d for non-void wrapper). Add a trailing _result param to your callback to receive + optionally mutate the return value; the legacy form will be removed in a future major version." \
						% [hook_name, argc, expected_with_result])
			cb.callv(args)
		# null is the pass-through sentinel: prior _result survives untouched.
		if ret != null:
			current_result = ret
	return current_result

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
