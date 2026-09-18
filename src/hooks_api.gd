## ----- hooks_api.gd -----
## Public surface that mods call via Engine.get_meta("RTVModLib"):
## hook/unhook/has_hooks/has_replace/get_replace_owner/skip_super/seq, the
## version accessors, plus the internal dispatch helpers. Also owns
## frameworks_ready emission.

var _next_id: int = 1
var _seq: int = 0
var _is_ready: bool = false              # public: true once frameworks_ready has emitted
# Warn-once dedupe for legacy 2-arg post-hook callbacks, keyed by
# "<hook_name>::<callback object_id>".
var _post_legacy_warned: Dictionary = {}

# A per-script wrap mask is {method_name: true} for the declared methods, and
# an empty Dictionary is the wildcard: wrap every method. These two functions
# are the only places that convention is read or written.
static func _mask_is_wildcard(mask: Dictionary) -> bool:
	return mask.is_empty()

# Promote a mask to the wildcard in place; a wildcard is a superset of any list.
static func _mask_widen(mask: Dictionary) -> void:
	mask.clear()

# Version accessors, for mods gating features on modloader version.
static func version() -> String:
	return MODLOADER_VERSION

static func major_version() -> int:
	return int(MODLOADER_VERSION.split(".")[0])

static func minor_version() -> int:
	return int(MODLOADER_VERSION.split(".")[1])

static func patch_version() -> int:
	return int(MODLOADER_VERSION.split(".")[2])

# Called before the launcher opens and again by every boot path; the second
# call finds the loader itself and does nothing.
func _register_rtv_modlib_meta() -> void:
	if Engine.has_meta("RTVModLib"):
		if Engine.get_meta("RTVModLib") != self:
			_log_warning("[RTVModLib] Engine.meta 'RTVModLib' already set -- not overwriting")
		return
	Engine.set_meta("RTVModLib", self)
	_log_info("[RTVModLib] modloader registered as Engine.meta('RTVModLib')")

# Mods that await Engine.get_meta("RTVModLib").frameworks_ready block until
# this fires.
func _emit_frameworks_ready() -> void:
	_is_ready = true
	_register_core_hooks()
	_scene_nodes_connect_listener()
	frameworks_ready.emit()
	_log_info("[RTVModLib] frameworks_ready emitted")
	# Mod autoload _ready() calls (where overrideScript() fires
	# take_over_path) have finished: verify each declared override landed
	# and watch node_added for PackedScene ext_resource staleness that
	# take_over_path can't fix.
	_verify_script_overrides()

## Extract the hook_base ("<script>-<method>") by stripping any
## -pre/-post/-callback suffix; a bare (replace) name is its own base.
static func _hook_base_of(hook_name: String) -> String:
	if hook_name.ends_with("-pre"):
		return hook_name.substr(0, hook_name.length() - 4)
	if hook_name.ends_with("-post"):
		return hook_name.substr(0, hook_name.length() - 5)
	if hook_name.ends_with("-callback"):
		return hook_name.substr(0, hook_name.length() - 9)
	return hook_name


## Register a hook callback. Name grammar: "<script stem lowercase>-<method
## lowercase>" plus optional "-pre" / "-post" / "-callback"; the bare name is
## the single-owner replace slot. Returns a hook id for unhook(), or -1 when
## the replace slot is already owned. Callbacks run in ascending `priority`
## order; ties are not stable (sort_custom), so use distinct priorities when
## order matters.
##
## Wrap-surface contract: registering here does not wrap the vanilla method.
## The wrap surface is fixed at _generate_hook_pack time from [hooks]
## sections, literal .hook("...") calls found by source scan, add_hook(), or
## the core seed. A hook name built at runtime registers fine but never
## fires unless the target was wrapped by one of those declarations.
func hook(hook_name: String, callback: Callable, priority: int = 100) -> int:
	var is_replace := not (hook_name.ends_with("-pre") \
			or hook_name.ends_with("-post") \
			or hook_name.ends_with("-callback"))
	# Unknown-suffix trap: the grammar allows exactly one hyphen for a
	# replace hook, so two-plus hyphens with no recognized suffix is a typo
	# ("-per") or a new hook variant not added everywhere (see the hook
	# variant recipe in rewriter_parse.gd). Either way the registration would
	# be silently misfiled as a replace hook that never fires.
	if is_replace and hook_name.count("-") >= 2:
		push_warning("[RTVModLib] hook('%s'): unrecognized suffix '-%s' -- registering as a REPLACE hook, which will never fire under that name. Did you mean -pre, -post, or -callback?" \
				% [hook_name, hook_name.get_slice("-", hook_name.count("-"))])
	if is_replace and _hooks.has(hook_name) and (_hooks[hook_name] as Array).size() > 0:
		var owner_id: int = (_hooks[hook_name] as Array)[0]["id"]
		# Debug-level, not warning: rejection is normal API behavior (replace
		# slots are single-owner) and the caller checks the -1 return; a
		# warning here spams stderr on every expected conflict check.
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

## godot-mod-loader compat shim: translates upstream `add_hook(path, method,
## cb, before)` into native hook("<stem>-<method>-pre/post") and enrolls the
## path into _hooked_methods for the wrap surface.
##
## Timing: pack generation reads _hooked_methods up front, so add_hook()
## must run before _generate_hook_pack (in practice, from a `!`-prefixed
## early autoload's _init), or the mod must also declare the path in [hooks].
##
## Path shape: bare filenames normalize to `res://Scripts/<file>`; pass a
## fully-qualified res:// path for targets elsewhere, or the wrap silently
## no-ops.
func add_hook(script_path: String, method_name: String, callback: Callable, is_before: bool = true) -> int:
	var stem := script_path.get_file().get_basename().to_lower()
	var suffix := "pre" if is_before else "post"
	var hook_name := "%s-%s-%s" % [stem, method_name.to_lower(), suffix]
	# Mask keys are lowercase (hook_pack.gd compares `fe["name"].to_lower()`
	# against the mask), so lowercase the method name on write.
	var res_path := script_path
	if not res_path.begins_with("res://"):
		res_path = "res://Scripts/" + script_path.get_file()
	if not _hooked_methods.has(res_path):
		_hooked_methods[res_path] = {method_name.to_lower(): true}
	else:
		var mask: Dictionary = _hooked_methods[res_path] as Dictionary
		# An existing empty dict is the "[hooks] <path> = *" wildcard
		# sentinel (wrap every method); inserting a key would narrow it and
		# silently kill the wildcard mod's runtime-registered hooks.
		if not mask.is_empty():
			mask[method_name.to_lower()] = true
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
## Same body as has_hooks: a bare-name key only ever holds replace entries.
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


## ---- Mod-discovery API ----
## Lets a mod ask "is this other mod loaded?" to integrate with peers or
## skip features. All calls take mod_id strings (the `id="..."` field in
## mod.txt; folder/zip name as fallback).

## True when a mod with the given id is loaded. Optional `min_version` does
## a numeric component-wise compare; mods declaring no version compare as
## 0.0.0 (pass min_version "0", fail anything stricter).
func has_mod(mod_id: String, min_version: String = "") -> bool:
	if not _loaded_mod_ids.has(mod_id):
		return false
	if min_version == "":
		return true
	var info = _loaded_mod_ids[mod_id]
	var have: String = ""
	if info is Dictionary:
		have = String(info.get("version", ""))
	# Bare-true legacy values: treat as unknown version, fail strict checks.
	return _compare_versions(have, min_version) >= 0


## Returns the full info dict for a loaded mod, or {} if not loaded.
## Shape: {mod_id, mod_name, version, file_name, priority,
## required_dependencies, optional_dependencies}. Stable enough for mods to
## inspect for debug prints / MCM displays.
func mod_info(mod_id: String) -> Dictionary:
	var info = _loaded_mod_ids.get(mod_id, null)
	if info is Dictionary:
		# deep=true: a shallow duplicate would hand mods live references
		# into the loader registry.
		return (info as Dictionary).duplicate(true)
	return {}


## All loaded mod ids. Order is not guaranteed; callers wanting consistent
## display order should sort the result.
func loaded_mods() -> Array[String]:
	var out: Array[String] = []
	for k in _loaded_mod_ids.keys():
		out.append(String(k))
	return out


# Component-wise compare of dotted version strings; returns -1 / 0 / 1.
# Non-numeric components compare as 0; missing trailing components are 0.
# No semver pre-release/build parsing -- RTV mods don't use it.
func _compare_versions(a: String, b: String) -> int:
	# A leading "v" is common in mod.txt versions; unstripped, "v1" reads as 0.
	var pa: PackedStringArray = a.lstrip("vV").split(".")
	var pb: PackedStringArray = b.lstrip("vV").split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var ai: int = 0 if i >= pa.size() else _to_version_int(pa[i])
		var bi: int = 0 if i >= pb.size() else _to_version_int(pb[i])
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0

func _to_version_int(s: String) -> int:
	if s.is_valid_int():
		return int(s)
	return 0


# Internal dispatch -- called from the generated framework wrappers.

func _dispatch(hook_name: String, args: Array) -> void:
	if not _hooks.has(hook_name):
		return
	# Snapshot before iterating: hooks registered during dispatch join the
	# next dispatch, and a mid-dispatch hook()'s sort_custom on the live
	# array cannot re-enter this iteration.
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		cb.callv(args)

# Post-hook chained dispatch for non-void wrapped methods. Preferred
# callback signature: `func(<vanilla args>, _result)`; returning non-null
# replaces _result for the next callback, null passes through (a literal
# null return can't be modeled -- documented limitation). Legacy callbacks
# without the trailing _result still work: arity is detected via
# get_argument_count() and a one-shot deprecation warning fires per
# (hook_name, callback). Priority order matches _dispatch; ties not stable.
func _dispatch_post(hook_name: String, args: Array, current_result: Variant) -> Variant:
	if not _hooks.has(hook_name):
		return current_result
	# Snapshot: same rationale as _dispatch.
	var entries: Array = (_hooks[hook_name] as Array).duplicate()
	var expected_with_result: int = args.size() + 1
	for entry in entries:
		_seq += 1
		var cb: Callable = entry["callback"]
		var argc: int = cb.get_argument_count()
		var ret: Variant = null
		if argc == expected_with_result:
			ret = cb.callv(args + [current_result])
		else:
			# Legacy form: fire on args only, ignore return. Warn once per
			# (hook_name, object, method) so object_id-0 statics each warn.
			var warn_key: String = "%s::%d::%s" % [hook_name, cb.get_object_id(), str(cb.get_method())]
			if not _post_legacy_warned.has(warn_key):
				_post_legacy_warned[warn_key] = true
				_log_warning("[RTVModLib] post hook '%s' callback uses legacy %d-arg signature (expected %d for non-void wrapper). Add a trailing _result param to your callback to receive + optionally mutate the return value; the legacy form will be removed in a future major version." \
						% [hook_name, argc, expected_with_result])
			cb.callv(args)
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
