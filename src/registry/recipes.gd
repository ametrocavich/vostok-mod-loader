## ----- registry/recipes.gd -----
##
## Recipes.tres is a Resource with seven Array[RecipeData] fields: consumables,
## medical, equipment, weapons, electronics, misc, furniture. Interface.gd
## const-preloads Recipes.tres, then walks whichever category array matches
## the crafting tab the player opened. Godot's Resource cache means every
## `load()` (or const preload) of Recipes.tres returns the same instance, so
## appending a RecipeData to a category array propagates to the crafting UI
## provided the mod mutates before Interface._ready() fires; same timing
## constraint as loot.
##
## RecipeData has no unique id field (just name + input + output + proximity
## flags), so the registry's id is a mod-chosen handle the same way loot
## works. Payloads:
##   register: {recipe: RecipeData, category: "consumables"}
##   override: {recipe: RecipeData, category, replaces: RecipeData}
##   patch:    id can be a String handle OR a RecipeData Resource ref
##             directly; lets mods patch vanilla recipes in one call
##             without registering a handle first.
##
## Patch rollback keys on object identity (get_instance_id) when the caller
## passed a Resource ref, or on the mod's String handle otherwise. Either way
## revert can find the stash and restore original field values.

const _RECIPE_CATEGORIES := ["consumables", "medical", "equipment", "weapons", "electronics", "misc", "furniture"]
const _RECIPES_PATH := "res://Crafting/Recipes.tres"

var _recipes_cache: Resource = null
var _recipes_warned: bool = false

func _recipes_resource() -> Resource:
	if _recipes_cache != null:
		return _recipes_cache
	var res = load(_RECIPES_PATH)
	if res == null:
		if not _recipes_warned:
			push_warning("[Registry] recipes: Recipes.tres missing at %s; recipes registry is inert" % _RECIPES_PATH)
			_recipes_warned = true
		return null
	_recipes_cache = res
	return res

# Shape check: does this Resource carry the RecipeData fields? Consistent
# with _looks_like_item_data / _looks_like_audio_event.
func _looks_like_recipe_data(res: Resource) -> bool:
	return _resource_has_property(res, "name") \
			and _resource_has_property(res, "input") \
			and _resource_has_property(res, "output")

func _valid_category(category: String) -> bool:
	return category in _RECIPE_CATEGORIES

# Validates {recipe, category} payload for register / override. Returns
# [recipe, category_array, category_string] or [null, null, ""] on error.
func _validate_recipe_data(id: String, verb: String, data: Variant) -> Array:
	if not (data is Dictionary):
		push_warning("[Registry] %s('recipes', '%s', ...) expects Dictionary {recipe, category}, got %s" % [verb, id, typeof(data)])
		return [null, null, ""]
	var d: Dictionary = data
	if not d.has("recipe") or not d.has("category"):
		push_warning("[Registry] %s('recipes', '%s', ...) data dict missing 'recipe' or 'category' key" % [verb, id])
		return [null, null, ""]
	var recipe = d["recipe"]
	if not (recipe is Resource) or not _looks_like_recipe_data(recipe):
		push_warning("[Registry] %s('recipes', '%s'): recipe is not a RecipeData Resource" % [verb, id])
		return [null, null, ""]
	var category = d["category"]
	if not (category is String) or not _valid_category(category):
		push_warning("[Registry] %s('recipes', '%s'): category must be one of %s, got '%s'" \
				% [verb, id, _RECIPE_CATEGORIES, category])
		return [null, null, ""]
	var recipes := _recipes_resource()
	if recipes == null:
		return [null, null, ""]
	var arr = recipes.get(category)
	if not (arr is Array):
		push_warning("[Registry] %s('recipes', '%s'): Recipes.%s is not an Array" % [verb, id, category])
		return [null, null, ""]
	return [recipe, arr, String(category)]

func _register_recipe(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("recipes", {})
	if reg.has(id):
		push_warning("[Registry] register('recipes', '%s'): already registered (pick a unique handle)" % id)
		return false
	var parts := _validate_recipe_data(id, "register", data)
	var recipe = parts[0]
	var arr = parts[1]
	var category: String = parts[2]
	if recipe == null or arr == null:
		return false
	if not _typed_array_accepts(arr, recipe):
		push_warning("[Registry] register('recipes', '%s'): recipe type doesn't match Recipes.%s typed array" % [id, category])
		return false
	if recipe in arr:
		push_warning("[Registry] register('recipes', '%s'): recipe is already present in category '%s'; use override instead" % [id, category])
		return false
	arr.append(recipe)
	reg[id] = {"recipe": recipe, "category": category}
	_registry_registered["recipes"] = reg
	_log_debug("[Registry] registered recipe '%s' (category=%s, name=%s)" % [id, category, recipe.get("name")])
	return true

func _override_recipe(id: String, data: Variant) -> bool:
	var ov: Dictionary = _registry_overridden.get("recipes", {})
	if ov.has(id):
		push_warning("[Registry] override('recipes', '%s'): already overridden (revert first to re-override)" % id)
		return false
	if not (data is Dictionary) or not data.has("replaces"):
		push_warning("[Registry] override('recipes', '%s', ...) requires {recipe, category, replaces: RecipeData}" % id)
		return false
	var parts := _validate_recipe_data(id, "override", data)
	var new_recipe = parts[0]
	var arr = parts[1]
	var category: String = parts[2]
	if new_recipe == null or arr == null:
		return false
	var old_recipe = data["replaces"]
	if not (old_recipe is Resource) or not _looks_like_recipe_data(old_recipe):
		push_warning("[Registry] override('recipes', '%s'): 'replaces' is not a RecipeData Resource" % id)
		return false
	if not _typed_array_accepts(arr, new_recipe):
		push_warning("[Registry] override('recipes', '%s'): recipe type doesn't match Recipes.%s typed array" % [id, category])
		return false
	var idx: int = arr.find(old_recipe)
	if idx < 0:
		push_warning("[Registry] override('recipes', '%s'): 'replaces' not present in category '%s'" % [id, category])
		return false
	if new_recipe in arr:
		push_warning("[Registry] override('recipes', '%s'): new recipe already in category; would duplicate" % id)
		return false
	arr[idx] = new_recipe
	ov[id] = {
		"recipe": new_recipe,
		"category": category,
		"replaced": old_recipe,
		"index": idx,
	}
	_registry_overridden["recipes"] = ov
	var reg: Dictionary = _registry_registered.get("recipes", {})
	reg[id] = {"recipe": new_recipe, "category": category}
	_registry_registered["recipes"] = reg
	_log_debug("[Registry] overrode recipe '%s' in %s" % [id, category])
	return true

# Resolves whatever the mod passed (String handle or RecipeData Resource) to:
#   [recipe, patch_key]
# where patch_key is the stable Variant we use in _registry_patched to
# track per-field original values. For handles it's the String; for direct
# refs it's the object's instance_id (int), so distinct Resource instances
# don't collide.
func _resolve_patch_target(id: Variant) -> Array:
	if id is String:
		var reg: Dictionary = _registry_registered.get("recipes", {})
		if reg.has(id):
			return [reg[id]["recipe"], id]
		push_warning("[Registry] patch('recipes', '%s'): no registered handle with that id (register first, or pass a RecipeData Resource ref directly)" % id)
		return [null, null]
	if id is Resource and _looks_like_recipe_data(id):
		return [id, "ref:%d" % id.get_instance_id()]
	push_warning("[Registry] patch('recipes', ...): id must be a String handle or a RecipeData Resource")
	return [null, null]

func _patch_recipe(id: Variant, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('recipes', ...): empty fields dict is a no-op")
		return false
	var resolved := _resolve_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	var patched: Dictionary = _registry_patched.get("recipes", {})
	var stash: Dictionary = patched.get(key, {})
	for field in fields.keys():
		var fname := String(field)
		if not _resource_has_property(target, fname):
			push_warning("[Registry] patch('recipes'): field '%s' doesn't exist on RecipeData" % fname)
			continue
		if not stash.has(fname):
			stash[fname] = target.get(fname)
		target.set(fname, fields[field])
	patched[key] = stash
	_registry_patched["recipes"] = patched
	_log_debug("[Registry] patched recipe (key=%s) fields %s" % [key, fields.keys()])
	return true

func _remove_recipe(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("recipes", {})
	if not reg.has(id):
		push_warning("[Registry] remove('recipes', '%s'): not a mod recipe registration" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("recipes", {})
	if ov.has(id):
		push_warning("[Registry] remove('recipes', '%s'): entry is an override, use revert instead" % id)
		return false
	var entry: Dictionary = reg[id]
	var category: String = entry["category"]
	var recipe: Resource = entry["recipe"]
	var recipes := _recipes_resource()
	if recipes != null:
		var arr = recipes.get(category)
		if arr is Array:
			var idx: int = arr.find(recipe)
			if idx >= 0:
				arr.remove_at(idx)
			else:
				push_warning("[Registry] remove('recipes', '%s'): recipe not found in %s; tracking cleared" % [id, category])
	reg.erase(id)
	_registry_registered["recipes"] = reg
	_log_debug("[Registry] removed recipe '%s'" % id)
	return true

func _revert_recipe(id: Variant, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("recipes", {})
	var patched: Dictionary = _registry_patched.get("recipes", {})
	# Patch key computation matches _resolve_patch_target so we find the same
	# stash entry regardless of whether the caller patches by handle or by ref.
	var patch_key = null
	var patch_target: Resource = null
	if id is String:
		patch_key = id
		var reg: Dictionary = _registry_registered.get("recipes", {})
		if reg.has(id):
			patch_target = reg[id]["recipe"]
	elif id is Resource and _looks_like_recipe_data(id):
		patch_key = "ref:%d" % id.get_instance_id()
		patch_target = id
	# Full revert: patches first (so stash restores onto current entry),
	# then override (swaps back to the vanilla recipe instance).
	if fields.is_empty():
		if patch_key != null and patched.has(patch_key):
			if patch_target != null:
				var stash: Dictionary = patched[patch_key]
				for fname in stash.keys():
					patch_target.set(fname, stash[fname])
			patched.erase(patch_key)
			_registry_patched["recipes"] = patched
			did_something = true
		if id is String and ov.has(id):
			var entry: Dictionary = ov[id]
			var recipes := _recipes_resource()
			if recipes != null:
				var arr = recipes.get(entry["category"])
				if arr is Array:
					var current_idx: int = arr.find(entry["recipe"])
					if current_idx >= 0:
						arr[current_idx] = entry["replaced"]
					else:
						push_warning("[Registry] revert('recipes', '%s'): override's recipe missing from %s, appending original at end" % [id, entry["category"]])
						arr.append(entry["replaced"])
			ov.erase(id)
			_registry_overridden["recipes"] = ov
			var reg2: Dictionary = _registry_registered.get("recipes", {})
			reg2.erase(id)
			_registry_registered["recipes"] = reg2
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('recipes'): nothing to revert for that id")
		return did_something
	# Per-field revert: only operates on patch stashes.
	if patch_key == null or not patched.has(patch_key):
		push_warning("[Registry] revert('recipes'): no patches found for that id")
		return false
	if patch_target == null:
		push_warning("[Registry] revert('recipes'): patch target no longer resolves")
		return false
	var stash2: Dictionary = patched[patch_key]
	for field in fields:
		var fname := String(field)
		if not stash2.has(fname):
			push_warning("[Registry] revert('recipes'): field '%s' wasn't patched" % fname)
			continue
		patch_target.set(fname, stash2[fname])
		stash2.erase(fname)
		did_something = true
	if stash2.is_empty():
		patched.erase(patch_key)
	else:
		patched[patch_key] = stash2
	_registry_patched["recipes"] = patched
	return did_something
