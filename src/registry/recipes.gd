# Recipes.tres: seven Array[RecipeData] category fields that Interface.gd walks per crafting
# tab. The verbs are the array-entry ones in array_entries.gd.

const _RECIPE_CATEGORIES := ["consumables", "medical", "equipment", "weapons", "electronics", "misc", "furniture"]
const _RECIPES_PATH := "res://Crafting/Recipes.tres"

# Vanilla ships these two tabs disabled and faded because their arrays are empty, so a
# recipe registered into one unlocks its button. Values are Interface.tscn node paths.
const _LOCKED_CATEGORY_BUTTONS := {
	"equipment": "Tools/Crafting/Types/Margin/Buttons/Equipment",
	"misc": "Tools/Crafting/Types/Margin/Buttons/Misc",
}

func _recipes_resource() -> Resource:
	return _registry_resource(_RECIPES_PATH, "recipes")

func _looks_like_recipe_data(res: Variant) -> bool:
	return res is Resource and _has_properties(res, ["name", "input", "output"])

func _register_recipe(id: String, data: Variant) -> bool:
	if not _array_entry_register("recipes", id, data):
		return false
	_unlock_crafting_button(_registry_registered["recipes"][id]["category"])
	return true

func _unlock_crafting_button(category: String) -> void:
	if not _LOCKED_CATEGORY_BUTTONS.has(category):
		return
	# Only the button goes to full alpha; its icon keeps vanilla's 0.5, like the sibling tabs.
	_patch_scene_node("res://UI/Interface.tscn#%s" % _LOCKED_CATEGORY_BUTTONS[category], {
		"disabled": false,
		"modulate": Color(1.0, 1.0, 1.0, 1.0),
	})
