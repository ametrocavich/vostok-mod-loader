# LootTable `items` arrays, named by vanilla table or absolute res:// path. The verbs are the
# array-entry ones in array_entries.gd, without patch and the array ops.

const _LOOT_TABLE_PATHS := {
	"LT_Master": "res://Loot/LT_Master.tres",
	"LT_Airdrop_01": "res://Loot/Custom/LT_Airdrop_01.tres",
	"LT_Airdrop_02": "res://Loot/Custom/LT_Airdrop_02.tres",
	"LT_Airdrop_03": "res://Loot/Custom/LT_Airdrop_03.tres",
	"LT_Patient_Report": "res://Loot/Custom/LT_Patient_Report.tres",
	"LT_Punisher_01": "res://Loot/Custom/LT_Punisher_01.tres",
	"LT_Punisher_02": "res://Loot/Custom/LT_Punisher_02.tres",
	"LT_Punisher_03": "res://Loot/Custom/LT_Punisher_03.tres",
	"LT_Bogeyman_01": "res://Loot/Custom/LT_Bogeyman_01.tres",
	"LT_Oil_Sample": "res://Loot/Custom/LT_Oil_Sample.tres",
	"LT_Weapons_01": "res://Loot/Tutorial/LT_Weapons_01.tres",
	"LT_Weapons_02": "res://Loot/Tutorial/LT_Weapons_02.tres",
	"LT_Weapons_03": "res://Loot/Tutorial/LT_Weapons_03.tres",
	"LT_Weapons_04": "res://Loot/Tutorial/LT_Weapons_04.tres",
	"LT_Ammo": "res://Loot/Tutorial/LT_Ammo.tres",
	"LT_Medical": "res://Loot/Tutorial/LT_Medical.tres",
	"LT_Equipment": "res://Loot/Tutorial/LT_Equipment.tres",
	"LT_Armor": "res://Loot/Tutorial/LT_Armor.tres",
	"LT_Grenades": "res://Loot/Tutorial/LT_Grenades.tres",
	"LT_Attachments": "res://Loot/Tutorial/LT_Attachments.tres",
	"LT_Items": "res://Loot/Tutorial/LT_Items.tres",
	"Kit_Colt": "res://Loot/Kits/Kit_Colt.tres",
	"Kit_Glock": "res://Loot/Kits/Kit_Glock.tres",
	"Kit_MP5K": "res://Loot/Kits/Kit_MP5K.tres",
	"Kit_Makarov": "res://Loot/Kits/Kit_Makarov.tres",
	"Kit_Mosin": "res://Loot/Kits/Kit_Mosin.tres",
	"Kit_Remington": "res://Loot/Kits/Kit_Remington.tres",
}

func _resolve_loot_table(table_ref: String) -> Resource:
	return _resolve_named_resource("loot", "table", table_ref, _LOOT_TABLE_PATHS, "items", "LootTable")
