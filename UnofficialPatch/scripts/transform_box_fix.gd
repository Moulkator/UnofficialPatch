# transform_box_fix.gd
# Fixes DD's transform box capturing clicks on other assets inside it.
# When clicking on a highlighted asset that's different from the selected one,
# deselects current selection first so DD can pick up the new asset.

var _g
var select_tool
var ui_util
var input_listener: Node

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[TransformBoxFix] Initialized")


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "TransformBoxFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


# Mouse is on/near a transform box handle (corner resize) or in the rotation
# zone just outside a corner. Mirrors the pattern used in selection_resize.gd:
# trust DD's transformCorner when available, fall back to corner-distance with
# a zoom-scaled tolerance for cases where a bigger asset under the box steals
# hover before DD flags the corner.
func _is_over_transform_handle() -> bool:
	if select_tool == null:
		return false
	# Decision native de DD sur ce press (si son _Input est passe avant nous) :
	# Move(1)/Rotate(2)/Scale(3) signifient tous "transformer la selection
	# courante" -> ne pas deselectionner.
	var tm = select_tool.get("transformMode")
	if tm != null and int(tm) != 0:
		return true
	# transformCorner is updated by DD's hover detection in real time
	# (0=TL, 1=TR, 2=BR, 3=BL, -1=none).
	var dd_corner = select_tool.get("transformCorner")
	if dd_corner != null and int(dd_corner) >= 0 and int(dd_corner) <= 3:
		return true

	# Interroger DIRECTEMENT le widget de la box : memes tests que DD, synchrones
	# et independants de l'ordre des handlers. C'est la source fiable pour la
	# zone de rotation (transformMode n'est pas encore pose si notre listener
	# tourne avant celui de DD, et transformCorner ne couvre que les coins).
	var tbox = select_tool.get("transformBox")
	if tbox != null and is_instance_valid(tbox) and tbox.visible:
		if tbox.has_method("IsMouseOnCorner") and int(tbox.IsMouseOnCorner()) != -1:
			return true
		var in_rotate = tbox.has_method("IsMouseInRotateZone") and tbox.IsMouseInRotateZone()
		var inside = tbox.has_method("IsMouseInside") and tbox.IsMouseInside()
		# Anneau de rotation = dans la zone mais hors de la box. L'interieur
		# (Move) reste deselectable pour basculer sur un autre asset sous la box.
		if in_rotate and not inside:
			return true

	# Repli geometrique world-space si le widget n'est pas accessible.
	if not select_tool.has_method("GetSelectionRect"):
		return false
	var rect = select_tool.GetSelectionRect()
	if not (rect is Rect2):
		return false
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return false
	if _g.WorldUI == null:
		return false
	var mouse: Vector2 = _g.WorldUI.MousePosition

	# Screen-tolerance scaled to world units via camera zoom.
	var zoom = 1.0
	var cam = _g.Editor.get("Camera") if _g.Editor else null
	if cam and is_instance_valid(cam) and cam is Camera2D:
		zoom = max(cam.zoom.x, 0.001)

	# Zone de rotation : a l'exterieur de la box mais dans la marge de rotation.
	var rotate_margin = 64.0 * zoom
	if rect.grow(rotate_margin).has_point(mouse) and not rect.has_point(mouse):
		return true

	# Corner area fallback (resize) for cases DD hasn't flagged transformCorner.
	var tl: Vector2 = rect.position
	var br: Vector2 = rect.position + rect.size
	var corners = [tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)]
	# 35 px matches the constant used in selection_resize.gd for DD's hit zone.
	var minor = min(rect.size.x, rect.size.y)
	var tol = min(35.0 * zoom, max(minor * 0.4, 8.0 * zoom))

	for c in corners:
		if mouse.distance_to(c) <= tol:
			return true
	return false


func _on_input(event) -> void:
	if not (event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed):
		return

	# Skip when the click lands on a UI panel/popup. The input listener fires
	# globally, so a click inside the SelectTool panel would otherwise reach
	# this handler — and since DD still reports a highlighted world asset
	# beneath the panel overlay, we'd deselect on a UI button press.
	if ui_util != null and ui_util.is_mouse_over_ui(input_listener):
		return

	# Only when SelectTool is active
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if not (panel and panel is CanvasItem and panel.is_visible_in_tree()):
		return

	# Only when something is selected
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return

	# Skip when cursor is on/near a transform handle or in the rotation zone.
	# Without this, grabbing a handle that overlaps a bigger asset beneath the
	# selection deselects instead of starting the rotate/resize.
	if _is_over_transform_handle():
		return

	# Check if DD sees a different asset under the mouse
	# Wrap in safety: highlighted can crash when lights exist
	var highlighted = select_tool.get("highlighted")
	if highlighted == null:
		return
	var hover_thing = null
	if typeof(highlighted) == TYPE_OBJECT and is_instance_valid(highlighted):
		hover_thing = highlighted.get("Thing")
	if hover_thing == null:
		return
	if typeof(hover_thing) == TYPE_OBJECT and not is_instance_valid(hover_thing):
		return

	# Check if the hovered thing is already selected
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var t = s.get("Thing")
		if t != null and is_instance_valid(t) and t == hover_thing:
			return  # Already selected, let DD handle normally

	# Different asset under mouse — deselect so DD picks up the new one
	if not Input.is_key_pressed(KEY_SHIFT):
		select_tool.DeselectAll()
		select_tool.EnableTransformBox(false)
