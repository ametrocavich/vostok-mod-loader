## ----- framework_wrappers.gd -----
## Scene-tree walk by class_name, used by the developer-mode hook probes in
## debug.gd.

# Collect nodes whose attached script (or any ancestor in its extends chain)
# has the given class_name. The base-chain walk matters: take_over_path mod
# scripts usually extend by path, so get_global_name() == "" on the instance.
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
