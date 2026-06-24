# alt_deselect.gd
# Loaded dynamically by Core.gd

var _g

var select_tool = null
var select_tool_panel = null
var _alt_click_processed = false
var _ctrl_fix_processed = false
var _last_selection = []
var _shift_alt_dragging = false

func initialize():
	select_tool = _g.Editor.Tools["SelectTool"]
	select_tool_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	print("[AltDeselect] initialized")


func update(delta):
	# Defensive: bail early if any of the required state isn't ready.
	# When other mods (e.g. Custom Snap Mod) modify the SelectTool panel
	# or register their own tools, accessing un-ready properties at the
	# wrong moment can cause a hard segfault rather than a script error.
	if select_tool == null or not is_instance_valid(select_tool):
		return
	if _g == null or _g.Editor == null:
		return
	var toolset = _g.Editor.get("Toolset")
	if toolset == null:
		return
	var tool_panels = toolset.get("ToolPanels")
	if tool_panels == null or not (tool_panels is Dictionary):
		return
	if not tool_panels.has("SelectTool"):
		return
	var select_panel = tool_panels["SelectTool"]
	if select_panel == null or not is_instance_valid(select_panel):
		return
	var lmb = Input.is_mouse_button_pressed(BUTTON_LEFT)
	if not lmb and select_panel.visible:
		var sel = select_tool.get("Selected")
		if sel != null:
			var count = sel.size()
			if count > 0:
				_last_selection = []
				var idx = 0
				while idx < count:
					_last_selection.append(sel[idx])
					idx += 1
	if lmb and Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT):
		_shift_alt_dragging = true
	# While DragSelectWalls' custom box is in an active drag, suppress
	# the shift+alt drag-deselect logic entirely. Otherwise, holding
	# shift+alt during a custom transform queues _on_shift_alt_drag_end
	# at mouse release, which then deselects whatever is inside DD's
	# (stale) boxBegin/boxEnd rectangle — observable as paths and other
	# assets vanishing from selection right after an Alt+Shift transform.
	# Same protection for selection_resize when it owns the drag.
	if _g.ModMapData != null and (_g.ModMapData.get("_drag_select_walls_active", false) or _g.ModMapData.get("_selection_resize_active", false)):
		_shift_alt_dragging = false
	if _shift_alt_dragging and not lmb:
		_shift_alt_dragging = false
		call_deferred("_on_shift_alt_drag_end")
	if lmb and Input.is_key_pressed(KEY_ALT) and not Input.is_key_pressed(KEY_SHIFT):
		if not _alt_click_processed:
			_alt_click_processed = true
			# Skip when cursor is on a transform handle (rotate=2, scale=3).
			# Otherwise Alt+click on a handle gets treated as Alt+click on the
			# asset's edge and deselects, killing Alt+resize / Alt+rotate mods.
			var _tm = select_tool.get("transformMode")
			# Also skip when DragSelectWalls' custom box is in the middle
			# of a drag — its overlay forces transformMode to 0 (Native
			# None) so the _tm check above wouldn't catch this case, and
			# handle_alt_click() would re-enable DD's native transform
			# box on top of our custom one. Same for selection_resize:
			# its _hide_box() resets transformMode away from 3, fooling
			# the _tm check, so we honor its flag too.
			var dsw_active = false
			var sr_active = false
			if _g.ModMapData != null:
				dsw_active = _g.ModMapData.get("_drag_select_walls_active", false)
				sr_active = _g.ModMapData.get("_selection_resize_active", false)
			if not dsw_active and not sr_active and (_tm == null or (_tm != 2 and _tm != 3)):
				handle_alt_click()
	else:
		_alt_click_processed = false
	if Input.is_key_pressed(KEY_CONTROL) and Input.is_mouse_button_pressed(BUTTON_LEFT):
		if not _ctrl_fix_processed:
			_ctrl_fix_processed = true
			call_deferred("_check_ctrl_ghost")
	else:
		_ctrl_fix_processed = false


func _check_ctrl_ghost():
	if select_tool == null:
		return
	if not is_instance_valid(select_tool):
		return
	var sel = select_tool.get("Selected")
	if sel == null:
		return
	if sel.size() == 0:
		select_tool.EnableTransformBox(false)


func _on_shift_alt_drag_end():
	var saved = _last_selection
	if saved.size() == 0:
		return
	var bb = select_tool.boxBegin
	var be = select_tool.boxEnd
	var rx = min(bb.x, be.x)
	var ry = min(bb.y, be.y)
	var rw = abs(be.x - bb.x)
	var rh = abs(be.y - bb.y)
	if rw < 10 and rh < 10:
		return
	var box_rect = Rect2(rx, ry, rw, rh)
	print("[AltDeselect] SHIFT+ALT box: " + str(box_rect))
	var keep = []
	for node in saved:
		if node == null:
			continue
		var dominated = false
		if node.get("global_position") != null:
			if box_rect.has_point(node.global_position):
				dominated = true
		if dominated:
			print("[AltDeselect] Box removing: " + str(node.name))
		else:
			keep.append(node)
	print("[AltDeselect] Keeping " + str(keep.size()) + "/" + str(saved.size()))
	_restore_selection(keep)


func _restore_selection(nodes):
	select_tool.transformMode = 0
	for node in select_tool.Selected:
		select_tool.SelectThing(node, false)
	select_tool.EnableTransformBox(false)
	var irt = select_tool.get("initialRelativeTransforms")
	if irt != null:
		irt.clear()
	if nodes.size() == 0:
		select_tool.DeselectAll()
		return
	for node in nodes:
		select_tool.SelectThing(node, true)
	var rect = select_tool.GetSelectionRect()
	select_tool.boxBegin = rect.position
	select_tool.boxEnd = rect.position + rect.size
	select_tool.EnableTransformBox(true)
	select_tool.GetTransformMode()
	var sel_type = _get_sel_type()
	if sel_type > 0:
		select_tool_panel.OnSelect(sel_type)


func handle_alt_click():
	if select_tool == null:
		return
	if not _g.Editor.Toolset.ToolPanels["SelectTool"].visible:
		return
	var selected = select_tool.Selected
	if selected == null or selected.size() == 0:
		return
	var viewport = _g.World.get_viewport()
	var mouse_pos = viewport.get_mouse_position()
	var canvas_transform = viewport.get_canvas_transform()
	var world_pos = canvas_transform.affine_inverse().xform(mouse_pos)
	var node_to_deselect = find_topmost_selected_under_mouse(world_pos, selected)
	if node_to_deselect == null:
		return
	print("[AltDeselect] Deselecting " + str(node_to_deselect.name))
	# Set transformMode to None to prevent ApplyTransforms crash
	select_tool.transformMode = 0
	# Deselect the node
	select_tool.SelectThing(node_to_deselect, false)
	# Clean initialRelativeTransforms
	var irt = select_tool.get("initialRelativeTransforms")
	if irt != null:
		var valid = {}
		for s in select_tool.RawSelectables:
			valid[s] = true
		var to_remove = []
		for key in irt.keys():
			if not valid.has(key):
				to_remove.append(key)
		for key in to_remove:
			irt.erase(key)
	var remaining = select_tool.Selected.size()
	if remaining > 0:
		select_tool.EnableTransformBox(false)
		var rect = select_tool.GetSelectionRect()
		select_tool.boxBegin = rect.position
		select_tool.boxEnd = rect.position + rect.size
		select_tool.EnableTransformBox(true)
		select_tool.GetTransformMode()
		var sel_type = _get_sel_type()
		if sel_type > 0:
			select_tool_panel.OnSelect(sel_type)
	else:
		select_tool.EnableTransformBox(false)
		select_tool.DeselectAll()
	print("[AltDeselect] Remaining: " + str(remaining))


func _get_sel_type() -> int:
	if select_tool.RawSelectables.size() == 0:
		return 0
	var first_type = select_tool.RawSelectables[0].Type
	for s in select_tool.RawSelectables:
		if s.Type != first_type:
			return 0
	return first_type


func find_topmost_selected_under_mouse(world_pos, selected):
	var best_node = null
	var best_priority = -1
	for node in selected:
		if node == null:
			continue
		if is_point_over_node(world_pos, node):
			var priority = get_node_render_priority(node)
			if priority > best_priority:
				best_priority = priority
				best_node = node
	return best_node


func get_node_render_priority(node) -> int:
	var priority = 0
	var selectable = select_tool.GetSelectable(node)
	var sel_type = 0
	if selectable != null:
		if selectable.get("Type") != null:
			sel_type = selectable.Type
	if sel_type == 4:
		priority = 2000
	elif sel_type == 6:
		priority = 5000
	elif sel_type == 5:
		priority = 1000
	elif sel_type == 7:
		priority = 500
	elif sel_type == 8:
		priority = 3000
	var layer = get_node_layer(node)
	priority += layer
	return priority


func get_node_layer(node) -> int:
	var parent = node.get_parent()
	if parent != null:
		var pn = parent.name
		if pn.begins_with("Layer "):
			return int(pn.substr(6))
	return 0


func is_point_over_node(world_pos, node) -> bool:
	# Get selectable type from DD
	var sel_type = select_tool.GetSelectableType(node)
	# Pathway: use IsMouseWithin(mousePos)
	if sel_type == 5:
		if node.has_method("IsMouseWithin"):
			return node.IsMouseWithin(world_pos)
	# PatternShape: use IsMouseWithin(mousePos)
	if sel_type == 7:
		if node.has_method("IsMouseWithin"):
			return node.IsMouseWithin(world_pos)
	# Wall: use IsMouseWithin()
	if sel_type == 1:
		if node.has_method("IsMouseWithin"):
			return node.IsMouseWithin()
	# Portal: use IsPointWithin(point)
	if sel_type == 2 or sel_type == 3:
		if node.has_method("IsPointWithin"):
			return node.IsPointWithin(world_pos)
		if node.has_method("IsMouseWithin"):
			return node.IsMouseWithin()
	# Roof
	if sel_type == 8:
		if node is Polygon2D:
			var polygon = node.polygon
			if polygon != null and polygon.size() > 2:
				var lp = node.global_transform.affine_inverse().xform(world_pos)
				return is_point_in_polygon(lp, polygon)
	# Object or Light (sel_type 4 or 6): check sprite bounds
	if sel_type == 4 or sel_type == 6:
		return _is_point_over_object(world_pos, node)
	# Fallback: generic check
	return _is_point_over_object(world_pos, node)


func _is_point_over_object(world_pos, node) -> bool:
	# First try: does the node itself have a texture?
	if node.get("texture") != null and node.texture != null:
		return _check_sprite_bounds(world_pos, node, node.texture)
	# Second try: search child sprites
	var cc = node.get_child_count()
	var i = 0
	while i < cc:
		var child = node.get_child(i)
		if child.get("texture") != null and child.texture != null:
			return _check_sprite_bounds(world_pos, child, child.texture)
		i += 1
	# Fallback: position distance
	if node.get("global_position") != null:
		var d = world_pos.distance_to(node.global_position)
		return d <= 96.0
	return false


func _check_sprite_bounds(world_pos, sprite_node, texture) -> bool:
	var lp = sprite_node.global_transform.affine_inverse().xform(world_pos)
	var ts = texture.get_size()
	var hx = ts.x / 2.0
	var hy = ts.y / 2.0
	# Adjust for offset
	if sprite_node.get("offset") != null:
		lp = lp - sprite_node.offset
	# Adjust for non-centered sprites
	if sprite_node.get("centered") != null:
		if not sprite_node.centered:
			lp.x = lp.x - hx
			lp.y = lp.y - hy
	return lp.x >= -hx and lp.x <= hx and lp.y >= -hy and lp.y <= hy


func is_point_in_polygon(point, polygon) -> bool:
	var inside = false
	var j = polygon.size() - 1
	var i = 0
	while i < polygon.size():
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
		i += 1
	return inside
