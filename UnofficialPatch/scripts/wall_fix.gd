# wall_fix.gd
# Hover highlight + force-select for walls that DD can't detect
# Uses green shader highlight

var _g
var select_tool
var ui_util
var input_listener: Node

var _hover_wall = null
var _hover_saved_materials := []  # Array of [child, original_material]
var _highlight_material = null

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_create_highlight_material()
	_install_input_listener()
	print("[WallFix] Initialized")


func _create_highlight_material() -> void:
	var shader = Shader.new()
	shader.code = """shader_type canvas_item;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (tex.a > 0.01) {
		COLOR = vec4(tex.rgb * vec3(0.337, 0.737, 0.588), min(tex.a + 0.5, 1.0));
	} else {
		COLOR = tex;
	}
}
"""
	_highlight_material = ShaderMaterial.new()
	_highlight_material.shader = shader


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "WallFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _process(delta) -> void:\n\tif handler != null:\n\t\thandler._on_process(delta)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


# === INPUT ===

var _left_pressed := false
var _drag_threshold_passed := false
var _left_press_pos := Vector2.ZERO

func _on_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_left_pressed = true
			_drag_threshold_passed = false
			_left_press_pos = event.position
		else:
			_left_pressed = false
			_drag_threshold_passed = false
	if event is InputEventMouseMotion and _left_pressed and not _drag_threshold_passed:
		if event.position.distance_to(_left_press_pos) > 4:
			_drag_threshold_passed = true


# === PROCESS ===

func _on_process(_delta) -> void:
	if not _is_select_tool_active():
		_clear_hover_highlight()
		return
	_suppress_dd_highlight()
	# Highlight gere par overlay_tool


func _suppress_dd_highlight() -> void:
	# Disabled: select_tool.get("highlighted") crashes when lights exist on the map
	pass


func _is_select_tool_active() -> bool:
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel and panel is CanvasItem:
		return panel.is_visible_in_tree()
	return false


func _is_dragging() -> bool:
	if _left_pressed and _drag_threshold_passed:
		return true
	return false


func _update_hover_highlight() -> void:
	if not _is_select_tool_active() or ui_util.is_mouse_over_ui(input_listener):
		_clear_hover_highlight()
		return

	# Don't highlight during drag
	if _is_dragging():
		_clear_hover_highlight()
		return

	var level = _g.World.GetCurrentLevel()
	if level == null:
		_clear_hover_highlight()
		return
	var walls = level.get("Walls")
	if walls == null:
		_clear_hover_highlight()
		return

	var mouse_world = _g.WorldUI.MousePosition
	var best = null

	for child in walls.get_children():
		if child.has_method("IsMouseWithin") and child.IsMouseWithin(mouse_world):
			best = child
			break

	if best != null:
		if best != _hover_wall:
			_clear_hover_highlight()
			_hover_wall = best
			# Apply shader to all child Line2Ds
			for sub in best.get_children():
				if sub is Line2D:
					_hover_saved_materials.append([sub, sub.material])
					sub.material = _highlight_material
	else:
		_clear_hover_highlight()


func _clear_hover_highlight() -> void:
	for entry in _hover_saved_materials:
		var sub = entry[0]
		var orig = entry[1]
		if is_instance_valid(sub):
			sub.material = orig
	_hover_saved_materials = []
	_hover_wall = null


