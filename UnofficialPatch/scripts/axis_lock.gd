# axis_lock.gd
# Photoshop-like axis constraint for Path / Wall / Pattern Shape / Roof tools.
#
# While the modifier is held (Ctrl, or Cmd on macOS) during freeform drawing,
# the segment being drawn (last marked point -> cursor) is constrained to the
# nearest of the 8 cardinal/diagonal axes (0/45/90/.../315 degrees), like
# holding Shift in Photoshop.
#
# Hooks:
#   1. Root _input listener (INPUT phase, before WorldUI._unhandled_input):
#      rewrites the mouse event position + pushes MousePosition. Drives the
#      tool-side previews refreshed during input (PathTool / RoofTool textured
#      preview) and MarkPolyPoint placement on click.
#   2. Late _process node (process_priority high, after WorldUI._process and
#      before its _draw): re-pins MousePosition so WallTool / PatternShapeTool's
#      native "yellow line" preview (drawn by WorldUI from the re-polled OS
#      cursor) follows the axis too.
#
# SnappedPosition is read only in the API, so we never write it; DD derives it
# from MousePosition. arc_draw owns Ctrl in native curve (Arc Point) mode, so we
# bail out there. RoofTool's Quickbox (box-drag) mode builds no polyline and is
# excluded. The event is never consumed. Zero cost when the modifier isn't held.

var script_class = "tool"
var _g

var _input_listener: Node = null
var _frame_node: Node = null
const _INPUT_META = "AxisLockInputListener"
const _FRAME_META = "AxisLockFrameNode"

var _supported_tools = ["PathTool", "WallTool", "PatternShapeTool", "RoofTool"]

const _ANGLE_STEP = PI / 4.0   # 45 degrees -> 8 axes
const _DEADZONE_SQ = 0.0001    # ignore sub-pixel deltas


# ── Lifecycle ────────────────────────────────────────────────────────────────

func initialize():
	_install_input_listener()
	_install_frame_node()
	print("[AxisLock] initialized")


func cleanup() -> void:
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	if Engine.has_meta(_INPUT_META):
		Engine.remove_meta(_INPUT_META)
	if _frame_node != null and is_instance_valid(_frame_node):
		_frame_node.handler = null
		_frame_node.queue_free()
	_frame_node = null
	if Engine.has_meta(_FRAME_META):
		Engine.remove_meta(_FRAME_META)
	print("[AxisLock] cleaned up")


func update(_delta) -> void:
	pass


func _install_input_listener() -> void:
	if Engine.has_meta(_INPUT_META):
		var old = Engine.get_meta(_INPUT_META)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "AxisLockInputListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null:\n\t\treturn\n\thandler._on_input(e)\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_INPUT_META, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	_input_listener = node


func _install_frame_node() -> void:
	if Engine.has_meta(_FRAME_META):
		var old = Engine.get_meta(_FRAME_META)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "AxisLockFrameNode"
	var s = GDScript.new()
	# High process_priority => run after WorldUI's _process (which re-polls the
	# OS cursor) and before its _draw, so the native polyline preview uses our
	# locked MousePosition.
	s.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tprocess_priority = 1000\n\tset_process(true)\nfunc _process(_d):\n\tif handler != null:\n\t\thandler._frame_pin()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_FRAME_META, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	_frame_node = node


# ── Modifier ─────────────────────────────────────────────────────────────────

func _modifier_held() -> bool:
	if OS.get_name() == "OSX":
		return Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CONTROL)
	return Input.is_key_pressed(KEY_CONTROL)


# ── Shared context ───────────────────────────────────────────────────────────
# Returns { wui, editor, tnode, atn } if the lock may apply, else null.

func _ctx():
	if _g == null:
		return null
	if not _modifier_held():
		return null
	var wui = _g.get("WorldUI")
	if wui == null or not is_instance_valid(wui):
		return null
	var editor = _g.get("Editor")
	if editor == null or not is_instance_valid(editor):
		return null
	var atn = editor.get("ActiveToolName")
	if atn == null or not (atn in _supported_tools):
		return null
	var tools = editor.get("Tools")
	if tools == null:
		return null
	var active_tool = tools.get(atn)
	if active_tool == null or not is_instance_valid(active_tool):
		return null
	if _is_native_curve_mode(wui):
		return null
	return {"wui": wui, "editor": editor, "tnode": active_tool, "atn": atn}


func _snap(wui, editor, world: Vector2) -> Vector2:
	if editor.get("IsSnapping") == true and wui.has_method("GetSnappedPosition"):
		return wui.GetSnappedPosition(world)
	return world


# ── Hook 1: input phase (path/roof preview + click placement) ────────────────

func _on_input(e) -> void:
	if _g == null:
		return
	if not (e is InputEventMouseMotion or e is InputEventMouseButton):
		return
	var ctx = _ctx()
	if ctx == null:
		return
	var wui = ctx.wui
	var vp = wui.get_viewport()
	if vp == null:
		return
	var canvas = vp.get_canvas_transform()
	var world = canvas.affine_inverse().xform(e.position)
	var snapped = _snap(wui, ctx.editor, world)
	var locked = _draw_locked(ctx, snapped)
	if locked == null:
		return
	var locked_screen = canvas.xform(locked)
	e.position = locked_screen
	if "global_position" in e:
		e.global_position = locked_screen
	wui.set("MousePosition", locked)


# ── Hook 2: late frame phase (walls/patterns native yellow-line preview) ─────

func _frame_pin() -> void:
	var ctx = _ctx()
	if ctx == null:
		return
	var wui = ctx.wui
	var vp = wui.get_viewport()
	if vp == null:
		return
	var canvas = vp.get_canvas_transform()
	var world = canvas.affine_inverse().xform(vp.get_mouse_position())
	var snapped = _snap(wui, ctx.editor, world)
	var locked = _draw_locked(ctx, snapped)
	if locked != null:
		wui.set("MousePosition", locked)


# ── Draw-mode locked target ──────────────────────────────────────────────────

func _draw_locked(ctx, snapped: Vector2):
	var tnode = ctx.tnode
	var wui = ctx.wui
	if tnode.get("isDrawing") != true:
		return null
	# RoofTool: only the Manual mode draws a polyline; Quickbox is a box drag.
	if ctx.atn == "RoofTool":
		var m = tnode.get("Mode")
		if m == null or int(m) != 1:   # CreateMode.Manual == 1
			return null
	var poly = wui.get("Polyline")
	if poly == null or poly.size() < 1:
		return null
	# Don't fight loop-closing: when the cursor is over the first point, let DD
	# snap-close the polygon (or release the modifier to place freely).
	var first = _arcvec_position(poly[0])
	var thr = 16.0
	var cell = wui.get("CellSize")
	if cell != null and cell is Vector2:
		thr = max(cell.x * 0.5, 8.0)
	if snapped.distance_to(first) < thr:
		return null
	return _constrain(_arcvec_position(poly[poly.size() - 1]), snapped)


# ── Helpers ──────────────────────────────────────────────────────────────────

func _is_native_curve_mode(wui) -> bool:
	if wui.get("EditArcPoint") == true:
		return true
	var ind = wui.get("IndicateEditArcPoint")
	if ind != null and int(ind) != 0:
		return true
	return false


func _arcvec_position(av) -> Vector2:
	if av == null:
		return Vector2.ZERO
	if av is Vector2:
		return av
	if "Position" in av:
		return av.Position
	var p = av.get("Position")
	if p != null and p is Vector2:
		return p
	return Vector2.ZERO


func _constrain(anchor: Vector2, pos: Vector2) -> Vector2:
	var d = pos - anchor
	if d.length_squared() < _DEADZONE_SQ:
		return pos
	var snapped_angle = round(atan2(d.y, d.x) / _ANGLE_STEP) * _ANGLE_STEP
	var dir = Vector2(cos(snapped_angle), sin(snapped_angle))
	var t = max(d.dot(dir), 0.0)   # project the cursor onto the chosen axis
	return anchor + dir * t
