## ----- framework_wrappers.gd -----
## Helper for walking the scene tree by class_name after source-rewrite hook
## packs apply. Used by hook_pack.gd's post-apply verification to find nodes
## whose attached script descends from a given class_name.
##
## The legacy extends-wrapper pipeline (node_added / Framework<X>.gd /
## _activate_hooked_scripts / _register_override / _connect_node_swap /
## _deferred_swap) was removed in 3.0.1 -- dead code under the
## source-rewrite model. The surviving helper below is the only live code
## still referenced from this file.

# Recursively walk the scene tree, collecting nodes whose attached script
# (or any ancestor in its extends chain) has the given class_name. Base
# chain walk is needed because mods that override vanilla via
# take_over_path typically use extends-by-path (no class_name of their
# own), so their instances report get_global_name() == "". Matching via
# base chain catches IXP's Controller which extends our class_name
# Controller rewrite.
func _rtv_collect_nodes_by_class(node: Node, cls_name: String, out: Array) -> void:
	var scr := node.get_script() as GDScript
	if scr != null:
		var matched := false
		var s: GDScript = scr
		var depth := 0
		while s != null and depth < 8:
			if str(s.get_global_name()) == cls_name:
				matched = true
				break
			s = s.get_base_script() as GDScript
			depth += 1
		if matched:
			out.append(node)
	for child in node.get_children():
		_rtv_collect_nodes_by_class(child, cls_name, out)
