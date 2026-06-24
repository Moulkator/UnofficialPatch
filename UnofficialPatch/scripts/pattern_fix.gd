# pattern_fix.gd
# Fix: Allow changing a selected PatternShape to the X pattern (plain color, no texture)
# in the SelectTool. DD crashes because GridMenu.OnItemSelected calls LoadPNG(null)
# for the X pattern (item 0, no texture path).
# We intercept clicks on the SelectTool's pattern ItemList via an _input listener
# and call set_input_as_handled() so DD's _gui_input (and thus OnItemSelected) never
# runs on the X pattern. The ItemList keeps MOUSE_FILTER_STOP (default) so it still
# receives hover events, which means per-item tooltips continue to show normally.
# For the X pattern: apply SetOptions(null, color, rot) directly.
# For normal items: forward to OnItemSelected as usual.
#
# Also injects an Outline on/off toggle button in the SelectTool panel, mirroring
# the one that exists in the PatternShapeTool. The button is only visible when at
# least one selected object is a PatternShape.
# We intentionally do NOT use the toggled signal — instead we poll the button state
# each frame to avoid crashing when calling C# property setters from a signal callback.
# The outline texture (default_border.png) is loaded from .import at startup.

var _g
var _select_pattern_list = null
var _x_pattern_index = -1
var _input_listener = null
var _initialized = false

var _outline_button = null
var _outline_last_pressed = false
var _outline_last_shapes = []
var _cached_outline_texture = null


func initialize():
	pass


func update(_delta):
	if not _g or not _g.Editor:
		return

	if not _initialized:
		_try_init()
		return

	if _select_pattern_list and is_instance_valid(_select_pattern_list):
		if _select_pattern_list.mouse_filter != Control.MOUSE_FILTER_STOP:
			_select_pattern_list.mouse_filter = Control.MOUSE_FILTER_STOP

	_poll_outline_button()


func _try_init():
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		return

	_inject_outline_button(panel)
	_cache_outline_texture()

	_select_pattern_list = _find_pattern_list(panel)
	if _select_pattern_list == null:
		_initialized = true
		return

	for i in range(_select_pattern_list.get_item_count()):
		var tooltip = _select_pattern_list.get_item_tooltip(i)
		if tooltip == "" or tooltip == null:
			var icon = _select_pattern_list.get_item_icon(i)
			if icon and icon.get_class() == "StreamTexture":
				_x_pattern_index = i
				break

	if _x_pattern_index < 0:
		_initialized = true
		return

	_select_pattern_list.mouse_filter = Control.MOUSE_FILTER_STOP
	_install_input_listener()
	_initialized = true


func _cache_outline_texture():
	# First try: grab from any existing outlined PatternShape in the scene.
	var tex = _search_tree_for_outline_texture(_g.World)
	if tex != null:
		_cached_outline_texture = tex
		return

	# Second try: load default_border.png from the .import directory.
	var candidates = ["default_border.png", "narrow_line.png", "thick_line.png"]
	var path = _find_stex_by_prefix("res:///.import", candidates)
	if path != "":
		var t = ResourceLoader.load(path, "StreamTexture")
		if t != null:
			_cached_outline_texture = t


func _find_stex_by_prefix(import_dir: String, prefixes: Array) -> String:
	var dir = Directory.new()
	if dir.open(import_dir) != OK:
		return ""
	dir.list_dir_begin(true, true)
	var entry = dir.get_next()
	while entry != "":
		for prefix in prefixes:
			if entry.begins_with(prefix + "-") and entry.ends_with(".stex"):
				dir.list_dir_end()
				return import_dir + "/" + entry
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


func _find_pattern_list(panel) -> ItemList:
	var vboxes = []
	_find_all_of_class(panel, "VBoxContainer", vboxes)

	for vbox in vboxes:
		var found_label = false
		for child in vbox.get_children():
			if not is_instance_valid(child):
				continue
			if child is Label and child.text == "PATTERN":
				found_label = true
			elif found_label and child is ItemList:
				return child
	return null


func _find_all_of_class(node, cls: String, result: Array):
	if not is_instance_valid(node):
		return
	if node.get_class() == cls:
		result.append(node)
	for child in node.get_children():
		_find_all_of_class(child, cls, result)


func _install_input_listener():
	_input_listener = Node.new()
	_input_listener.name = "PatternFixListener"
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -100
func _input(event):
	if handler != null:
		handler._on_input(event)
"""
	script.reload()
	_input_listener.set_script(script)
	_input_listener.handler = self

	var tree = _g.World.get_tree()
	if tree and tree.root:
		tree.root.call_deferred("add_child", _input_listener)


func _is_popup_visible_at(mouse_pos: Vector2) -> bool:
	var root = _input_listener.get_tree().root
	return _check_popups_recursive(root, mouse_pos)


func _check_popups_recursive(node, mouse_pos: Vector2) -> bool:
	if not is_instance_valid(node):
		return false
	if node is Popup and node.visible:
		var rect = node.get_global_rect()
		if rect.has_point(mouse_pos):
			return true
	for child in node.get_children():
		if _check_popups_recursive(child, mouse_pos):
			return true
	return false


func _on_input(event):
	if not (event is InputEventMouseButton):
		return
	if _select_pattern_list == null or not is_instance_valid(_select_pattern_list):
		return
	if not _select_pattern_list.is_visible_in_tree():
		return

	var mouse_pos = _input_listener.get_viewport().get_mouse_position()

	if _is_popup_visible_at(mouse_pos):
		return

	var rect = _select_pattern_list.get_global_rect()
	if not rect.has_point(mouse_pos):
		return

	if event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
		# If Shift is held, let asset_cycle handle it for pattern cycling — don't intercept.
		if Input.is_key_pressed(KEY_SHIFT):
			return
		var vscroll = _select_pattern_list.get_node_or_null("_v_scroll")
		if vscroll == null:
			for child in _select_pattern_list.get_children():
				if child is ScrollBar:
					vscroll = child
					break
		if vscroll and is_instance_valid(vscroll):
			var step = 30.0
			if event.button_index == BUTTON_WHEEL_UP:
				vscroll.value -= step
			else:
				vscroll.value += step
			_input_listener.get_tree().set_input_as_handled()
		return

	if not event.pressed or event.button_index != BUTTON_LEFT:
		return

	# Let clicks on the scrollbar pass through so dragging still works.
	for child in _select_pattern_list.get_children():
		if child is ScrollBar and child.get_global_rect().has_point(mouse_pos):
			return

	var local_pos = mouse_pos - rect.position
	var item_idx = _select_pattern_list.get_item_at_position(local_pos, true)

	if item_idx < 0:
		return

	_input_listener.get_tree().set_input_as_handled()

	if item_idx == _x_pattern_index:
		_select_pattern_list.select(_x_pattern_index)
		_apply_x_pattern()
	else:
		_select_pattern_list.select(item_idx)
		_apply_pattern_at_index(item_idx)


func _inject_outline_button(panel):
	var vboxes = []
	_find_all_of_class(panel, "VBoxContainer", vboxes)

	for vbox in vboxes:
		var children = vbox.get_children()
		var pattern_list_idx = -1
		var found_label = false
		for i in range(children.size()):
			var child = children[i]
			if not is_instance_valid(child):
				continue
			if child is Label and child.text == "PATTERN":
				found_label = true
			elif found_label and child is ItemList:
				pattern_list_idx = i
				break

		if pattern_list_idx < 0:
			continue

		_outline_button = CheckButton.new()
		_outline_button.text = "OUTLINE"
		_outline_button.visible = false
		# No signal connection — we poll state each frame to avoid C# interop crash.
		vbox.add_child(_outline_button)
		vbox.move_child(_outline_button, pattern_list_idx + 1)
		return


func _poll_outline_button():
	if _outline_button == null or not is_instance_valid(_outline_button):
		return

	var shapes = _get_selected_pattern_shapes()
	if shapes.empty():
		_outline_button.visible = false
		return

	_outline_button.visible = true

	var btn_state = _outline_button.pressed

	# Sync button to reflect shape state when selection changes.
	var shape_ids = []
	for n in shapes:
		shape_ids.append(n.get_instance_id())
	if shape_ids != _outline_last_shapes:
		_outline_last_shapes = shape_ids
		var ol = shapes[0].get_Outline()
		var shape_state = ol != null and is_instance_valid(ol) and ol.visible
		_outline_button.pressed = shape_state
		_outline_last_pressed = shape_state
		# Opportunistically cache texture from existing outlined shapes.
		if ol != null and is_instance_valid(ol) and ol.texture != null:
			_cached_outline_texture = ol.texture
		return

	# Apply to shapes when user clicks the button.
	if btn_state != _outline_last_pressed:
		var before_states := _capture_outline_states(shapes)
		for node in shapes:
			_apply_outline(node, btn_state)
		var after_states := _capture_outline_states(shapes)
		_record_outline_change(before_states, after_states)
		_outline_last_pressed = btn_state


func _apply_outline(node, enabled: bool):
	if enabled:
		var ol = node.get_Outline()
		if ol != null and is_instance_valid(ol):
			ol.visible = true
		else:
			node.SetOutline(node.get_polygon(), _cached_outline_texture)
	else:
		var ol = node.get_Outline()
		if ol != null and is_instance_valid(ol):
			ol.visible = false


# ── Outline undo helpers ──────────────────────────────────────────────────────

func _capture_outline_states(shapes: Array) -> Array:
	# For each shape, capture whether it had an Outline node and whether
	# it was visible. Used to reproduce the "before" or "after" state.
	var out: Array = []
	for node in shapes:
		if not is_instance_valid(node):
			continue
		var ol = node.get_Outline()
		var had = ol != null and is_instance_valid(ol)
		out.append({
			"ref": weakref(node),
			"had_outline": had,
			"was_visible": had and ol.visible,
		})
	return out


func _record_outline_change(before: Array, after: Array) -> void:
	if before.empty() or after.empty() or before.size() != after.size():
		return
	var changed := false
	for i in range(before.size()):
		if before[i]["had_outline"] != after[i]["had_outline"] \
				or before[i]["was_visible"] != after[i]["was_visible"]:
			changed = true
			break
	if not changed:
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_outline_states", [before],
		self, "_restore_outline_states", [after])


func _restore_outline_states(states: Array) -> void:
	# Writes each captured outline state back. If the state says
	# had_outline=true and was_visible=true, we enable the outline (which
	# creates it if missing). If had_outline=false, we hide any existing
	# outline (there's no API to delete it cleanly, so invisible is the
	# closest equivalent).
	for entry in states:
		var node = entry["ref"].get_ref()
		if node == null or not is_instance_valid(node):
			continue
		if entry["had_outline"] and entry["was_visible"]:
			_apply_outline(node, true)
		else:
			_apply_outline(node, false)
	# Sync the button's internal state so the next poll doesn't see this
	# as a user click and re-apply.
	if _outline_button != null and is_instance_valid(_outline_button):
		# Determine the current visual state from the first shape to
		# update the button. Use the states we just wrote.
		var any_visible := false
		for entry in states:
			if entry["had_outline"] and entry["was_visible"]:
				any_visible = true
				break
		_outline_button.pressed = any_visible
		_outline_last_pressed = any_visible


func _search_tree_for_outline_texture(node):
	if not is_instance_valid(node):
		return null
	if node is Line2D and node.texture != null:
		var parent = node.get_parent()
		if parent != null and parent.get_class() == "Polygon2D":
			return node.texture
	for child in node.get_children():
		var result = _search_tree_for_outline_texture(child)
		if result != null:
			return result
	return null


func _get_selected_pattern_shapes() -> Array:
	var result = []
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or st.Selected == null:
		return result
	for node in st.Selected:
		if not is_instance_valid(node):
			continue
		if node.has_method("SetOptions"):
			result.append(node)
	return result


func _notify_external_item_selected_listeners(item_idx: int) -> void:
	# Calling OnItemSelected directly bypasses the "item_selected" signal,
	# so handlers registered by other mods (EdgeBlurPatterns, etc.) never
	# fire and their per-pattern state (shaders, overrides) goes stale.
	# Iterate the connection list and call each external handler manually,
	# skipping any handler whose target is the ItemList itself (DD's own
	# C# OnItemSelected — already called directly, and would crash on the
	# X pattern anyway).
	if _select_pattern_list == null or not is_instance_valid(_select_pattern_list):
		return
	var conns = _select_pattern_list.get_signal_connection_list("item_selected")
	for conn in conns:
		var target = conn.get("target")
		if target == null or not is_instance_valid(target):
			continue
		if target == _select_pattern_list:
			continue
		var method = conn.get("method", "")
		if method == "" or not target.has_method(method):
			continue
		var binds = conn.get("binds", [])
		var args := [item_idx]
		if binds is Array:
			args.append_array(binds)
		target.callv(method, args)


func _apply_x_pattern():
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or st.Selected == null:
		return
	
	var shapes: Array = []
	for node in st.Selected:
		if is_instance_valid(node) and node.has_method("SetOptions"):
			shapes.append(node)
	if shapes.empty():
		return
	
	# Capture the "before" state of each shape so we can restore it via
	# SetOptions on undo. We capture texture/color/rotation because those
	# are the three params of SetOptions and fully describe the shape
	# appearance from the user's point of view.
	var before_states := _capture_pattern_states(shapes)
	
	for node in shapes:
		var color = node.get("color")
		if color == null:
			color = Color.white
		var rot = node.get("rotation")
		if rot == null:
			rot = 0.0
		node.SetOptions(null, color, rot)
	
	var after_states := _capture_pattern_states(shapes)
	_record_pattern_change(before_states, after_states)
	# Notify third-party listeners (e.g. EdgeBlurPatterns) so they can
	# re-apply their shader. We deliberately skip DD's own internal handler
	# here because it would crash on the X pattern (null texture).
	_notify_external_item_selected_listeners(_x_pattern_index)


func _apply_pattern_at_index(item_idx: int):
	# Wrapper for OnItemSelected that captures before/after state and
	# creates an undo record. Used by _on_input and cycle_pattern.
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or st.Selected == null:
		_select_pattern_list.OnItemSelected(item_idx)
		return
	
	var shapes: Array = []
	for node in st.Selected:
		if is_instance_valid(node) and node.has_method("SetOptions"):
			shapes.append(node)
	
	var before_states := _capture_pattern_states(shapes)
	_select_pattern_list.OnItemSelected(item_idx)
	# Calling OnItemSelected directly does not emit "item_selected", so
	# third-party listeners (e.g. EdgeBlurPatterns) miss the change and
	# fail to re-apply their shader to the new texture. Notify them now.
	_notify_external_item_selected_listeners(item_idx)
	var after_states := _capture_pattern_states(shapes)
	_record_pattern_change(before_states, after_states)


func _capture_pattern_states(shapes: Array) -> Array:
	# Returns [{node_id, save_dict}, ...] — one entry per shape.
	# We use Save(true) because PatternShape appearance depends on internal
	# fields (pattern path, color, rotation). node_id is the persistent
	# identifier set by DD's World; it survives across SetOptions and is
	# the right way to re-locate the shape at undo/redo time.
	var out: Array = []
	for node in shapes:
		if not is_instance_valid(node):
			continue
		var nid = node.get_meta("node_id") if node.has_meta("node_id") else -1
		if nid < 0 or not node.has_method("Save"):
			continue
		var dict = node.Save(true)
		out.append({
			"node_id": nid,
			"save_dict": dict,
		})
	return out


func _record_pattern_change(before: Array, after: Array) -> void:
	# Only create a record if at least one shape actually changed.
	if before.empty() or after.empty() or before.size() != after.size():
		return
	var something_changed := false
	for i in range(before.size()):
		if before[i]["save_dict"] != after[i]["save_dict"]:
			something_changed = true
			break
	if not something_changed:
		return
	
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_pattern_states", [before],
		self, "_restore_pattern_states", [after])


func _restore_pattern_states(states: Array) -> void:
	# Called on undo OR redo. For each captured state:
	#   - re-locate the PatternShape by its stable node_id
	#   - read back texture (from path), color, rotation from save_dict
	#   - call SetOptions to apply
	# If save_dict has no "texture" key, we pass null (X pattern).
	for entry in states:
		var nid = entry["node_id"]
		var dict = entry["save_dict"]
		var node = _find_shape_by_node_id(nid)
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_method("SetOptions"):
			continue
		
		var texture = null
		if dict.has("texture"):
			# The saved value is a resource path (String). Load it to get
			# the actual Texture instance that SetOptions expects.
			var path = dict["texture"]
			if typeof(path) == TYPE_STRING and ResourceLoader.exists(path):
				texture = load(path)
		
		var color_raw = dict.get("color", Color.white)
		var color = color_raw
		# save_dict stores color as a hex string. Convert if needed.
		if typeof(color_raw) == TYPE_STRING:
			color = _color_from_hex_string(color_raw)
		
		# Prefer "rotation" key, fall back to 0 for X pattern where it's absent.
		var rotation = dict.get("rotation", 0.0)
		
		print("[PatternFix DIAG] restore node_id=%d color_raw=%s color=%s" \
			% [nid, color_raw, color])
		
		node.SetOptions(texture, color, rotation)


func _color_from_hex_string(s: String) -> Color:
	# DD's Save() serializes Color as 8-character hex. Based on observation,
	# the layout is "aarrggbb" (alpha-first). Godot's Color(string) parser
	# supports several formats but we build from explicit bytes to remove
	# all ambiguity.
	if s.length() == 8:
		var a = ("0x" + s.substr(0, 2)).hex_to_int() / 255.0
		var r = ("0x" + s.substr(2, 2)).hex_to_int() / 255.0
		var g = ("0x" + s.substr(4, 2)).hex_to_int() / 255.0
		var b = ("0x" + s.substr(6, 2)).hex_to_int() / 255.0
		return Color(r, g, b, a)
	if s.length() == 6:
		var r = ("0x" + s.substr(0, 2)).hex_to_int() / 255.0
		var g = ("0x" + s.substr(2, 2)).hex_to_int() / 255.0
		var b = ("0x" + s.substr(4, 2)).hex_to_int() / 255.0
		return Color(r, g, b, 1.0)
	return Color.white


func _find_shape_by_node_id(nid: int):
	# Uses DD's node lookup table rather than iterating the scene.
	if _g == null or _g.get("World") == null:
		return null
	var world = _g.World
	if not world.has_method("HasNodeID") or not world.HasNodeID(nid):
		return null
	return world.GetNodeByID(nid)


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")


func cycle_pattern(up: bool):
	# Called by asset_cycle to cycle the pattern list safely.
	# Uses the same logic as a click: calls OnItemSelected (or _apply_x_pattern for X).
	if _select_pattern_list == null or not is_instance_valid(_select_pattern_list):
		return
	if not _select_pattern_list.is_visible_in_tree():
		return
	var count = _select_pattern_list.get_item_count()
	if count == 0:
		return
	var selected = _select_pattern_list.get_selected_items()
	var current = selected[0] if selected.size() > 0 else 0
	var direction = -1 if up else 1
	var new_idx = (current + direction) % count
	if new_idx < 0:
		new_idx += count
	_select_pattern_list.select(new_idx)
	if new_idx == _x_pattern_index:
		_apply_x_pattern()
	else:
		_apply_pattern_at_index(new_idx)
