# ui_inspector.gd
#
# Diagnostic Settings tool to identify UI element groupings.
#
# Usage:
#   1. Open the "UI Inspector" tool in the Settings tab
#   2. Toggle "Inspector ON"
#   3. Hover over UI elements — same color = same parent (siblings)
#   4. Press INSERT to pin the currently-hovered element to the list
#   5. Click Copy to push the pinned list to the clipboard

var _g
var ui_util

const TOOL_CATEGORY = "Settings"
const TOOL_ID       = "ui_inspector"
const TOOL_NAME     = "UI Inspector"

var _enabled        = false
var _canvas         = null
var _overlay        = null
var _listener       = null
var _input_listener = null
var _tool_panel     = null

var _hover_node    = null
var _hover_parent  = null
var _hover_color   = Color()

# Pinned list (each entry: "[Type] /path/to/node  (parent: Name)")
var _pinned_lines = []

# UI refs
var _toggle_btn   = null
var _info_label   = null
var _pin_textedit = null
var _status_lbl   = null


func initialize() -> void:
	_create_overlay()
	_install_listener()
	_install_input_listener()
	_register_tool_panel()
	print("[UIInspector] Initialized")


# ── Overlay (highlight rectangles) ───────────────────────────────────────

func _create_overlay() -> void:
	_canvas = CanvasLayer.new()
	_canvas.name  = "UIInspectorLayer"
	_canvas.layer = 500

	_overlay = Control.new()
	_overlay.name = "UIInspectorOverlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.anchor_left   = 0
	_overlay.anchor_top    = 0
	_overlay.anchor_right  = 1
	_overlay.anchor_bottom = 1

	var script = GDScript.new()
	script.source_code = """extends Control
var handler = null
func _draw():
	if handler != null:
		handler._draw_overlay(self)
"""
	script.reload()
	_overlay.set_script(script)
	_overlay.handler = self
	_canvas.add_child(_overlay)

	var tree = _g.World.get_tree() if _g.World else null
	if tree and tree.root:
		tree.root.call_deferred("add_child", _canvas)


func _draw_overlay(ctrl) -> void:
	if not _enabled:
		return
	if _hover_node == null or not is_instance_valid(_hover_node):
		return

	# Siblings (faded)
	if _hover_parent != null and is_instance_valid(_hover_parent):
		for sib in _hover_parent.get_children():
			if sib == _hover_node:
				continue
			if not (sib is Control):
				continue
			if not sib.visible:
				continue
			var r : Rect2 = sib.get_global_rect()
			if r.size.x <= 0 or r.size.y <= 0:
				continue
			var fill = _hover_color
			fill.a = 0.12
			ctrl.draw_rect(r, fill, true)
			var border = _hover_color
			border.a = 0.55
			ctrl.draw_rect(r, border, false, 1.0)

	# Hovered element (strong)
	var rect : Rect2 = _hover_node.get_global_rect()
	var f2 = _hover_color
	f2.a = 0.30
	ctrl.draw_rect(rect, f2, true)
	var b2 = _hover_color
	b2.a = 1.0
	ctrl.draw_rect(rect, b2, false, 2.5)


# ── Frame listener (track mouse) ─────────────────────────────────────────

func _install_listener() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _process(d):
	if handler != null:
		handler._on_process(d)
"""
	script.reload()
	_listener = Node.new()
	_listener.name = "UIInspectorListener"
	_listener.set_script(script)
	_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _listener)


func _on_process(_delta) -> void:
	if not _enabled:
		return
	if _g == null or _g.World == null:
		return
	var tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		return
	var mouse : Vector2 = tree.root.get_viewport().get_mouse_position()
	var ctrl = _find_topmost(tree.root, mouse)

	if ctrl != _hover_node:
		_hover_node = ctrl
		if ctrl != null:
			var p = ctrl.get_parent()
			_hover_parent = p if (p is Control) else null
			var key_node = _hover_parent if _hover_parent != null else ctrl
			_hover_color = _color_for(key_node)
			_update_info_label()
		else:
			_hover_parent = null
			if _info_label != null and is_instance_valid(_info_label):
				_info_label.text = "(Move mouse over UI...)"

	if _overlay != null and is_instance_valid(_overlay):
		_overlay.update()


func _find_topmost(root, pos):
	# Walk the whole tree, collect every Control whose rect contains the
	# mouse, then return the SMALLEST by area. This avoids returning the
	# fullscreen Editor/Draw canvas (which is the first Control hit by a
	# naive top-down walk) and naturally favors the actual UI element.
	var ctx = {"best": null, "best_area": 1e18, "best_depth": -1}
	_collect_at(root, pos, ctx, 0)
	return ctx.best


func _collect_at(node, pos, ctx, depth) -> void:
	if node == _canvas:
		return
	if node is CanvasItem and not node.visible:
		return
	if node is Control:
		var r : Rect2 = node.get_global_rect()
		if r.size.x > 0 and r.size.y > 0 and r.has_point(pos):
			var a = r.size.x * r.size.y
			# Smallest area wins; on ties, deeper wins.
			if a < ctx.best_area or (abs(a - ctx.best_area) < 0.5 and depth > ctx.best_depth):
				ctx.best = node
				ctx.best_area = a
				ctx.best_depth = depth
	for c in node.get_children():
		_collect_at(c, pos, ctx, depth + 1)


# ── Input listener (INSERT to pin) ───────────────────────────────────────

func _install_input_listener() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -101
func _input(event):
	if handler != null:
		handler._on_input(event)
"""
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "UIInspectorInputListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", _input_listener)


func _on_input(event) -> void:
	if not _enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == KEY_INSERT:
			_pin_current()
			_g.World.get_tree().set_input_as_handled()


func _pin_current() -> void:
	if _hover_node == null or not is_instance_valid(_hover_node):
		_set_status("Nothing to pin.")
		return
	var typ : String = _hover_node.get_class()
	var path : String = str(_hover_node.get_path())
	var parent_name : String = "(none)"
	if _hover_parent != null and is_instance_valid(_hover_parent):
		parent_name = _hover_parent.name
	var line = "[%s] %s  (parent: %s)" % [typ, path, parent_name]
	_pinned_lines.append(line)
	_refresh_pin_textedit()
	_set_status("Pinned (%d)." % _pinned_lines.size())


# ── Color & info ─────────────────────────────────────────────────────────

func _color_for(node) -> Color:
	if node == null or not is_instance_valid(node):
		return Color(0.5, 0.5, 0.5)
	var path = str(node.get_path())
	var h = abs(path.hash()) % 360
	return Color.from_hsv(float(h) / 360.0, 0.75, 1.0)


func _update_info_label() -> void:
	if _info_label == null or not is_instance_valid(_info_label):
		return
	if _hover_node == null:
		_info_label.text = "(Nothing)"
		return
	var typ  : String = _hover_node.get_class()
	var nm   : String = _hover_node.name
	var path : String = str(_hover_node.get_path())
	var parent_name : String = "(none)"
	if _hover_parent != null and is_instance_valid(_hover_parent):
		parent_name = _hover_parent.name
	_info_label.text = "Type: %s\nName: %s\nGroup (parent): %s\n\nPath:\n%s" % [
		typ, nm, parent_name, path]


# ── Tool panel ───────────────────────────────────────────────────────────

func _register_tool_panel() -> void:
	if not _g.Editor or not _g.Editor.Toolset:
		return
	var icon_path = _g.Root + "icons/overlay_button.png"
	var f = File.new()
	if not f.file_exists(icon_path):
		icon_path = ""
	_tool_panel = _g.Editor.Toolset.CreateModTool(
		self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon_path)
	if _tool_panel == null:
		push_error("[UIInspector] CreateModTool failed")
		return

	_tool_panel.BeginSection(false)
	_tool_panel.CreateNote("Hover UI elements to identify groupings\n(same color = same parent).\nPress INSERT to pin the current element.")
	_tool_panel.CreateSeparator()

	_toggle_btn = CheckButton.new()
	_toggle_btn.text = "Inspector ON"
	_toggle_btn.pressed = _enabled
	_toggle_btn.connect("toggled", self, "_on_toggle")
	_tool_panel.Align.add_child(_toggle_btn)

	_tool_panel.CreateSeparator()
	_tool_panel.CreateLabel("Hovered")
	_info_label = Label.new()
	_info_label.text = "(Disabled)"
	_info_label.autowrap = true
	_info_label.rect_min_size = Vector2(0, 110)
	_tool_panel.Align.add_child(_info_label)

	_tool_panel.CreateSeparator()
	_tool_panel.CreateLabel("Pinned (press INSERT to add)")
	_pin_textedit = TextEdit.new()
	_pin_textedit.rect_min_size = Vector2(0, 160)
	_pin_textedit.wrap_enabled = true
	_pin_textedit.show_line_numbers = false
	_pin_textedit.readonly = false
	_tool_panel.Align.add_child(_pin_textedit)

	var btn_row = HBoxContainer.new()
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.connect("pressed", self, "_on_copy_pressed")
	btn_row.add_child(copy_btn)

	var clear_btn = Button.new()
	clear_btn.text = "Clear"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.connect("pressed", self, "_on_clear_pressed")
	btn_row.add_child(clear_btn)
	_tool_panel.Align.add_child(btn_row)

	_status_lbl = Label.new()
	_status_lbl.align = Label.ALIGN_CENTER
	_status_lbl.modulate = Color(0.7, 0.7, 0.7, 1)
	_status_lbl.text = ""
	_tool_panel.Align.add_child(_status_lbl)

	_tool_panel.EndSection()


func _on_toggle(pressed) -> void:
	_enabled = pressed
	if not pressed:
		_hover_node = null
		_hover_parent = null
		if _overlay != null and is_instance_valid(_overlay):
			_overlay.update()
		if _info_label != null and is_instance_valid(_info_label):
			_info_label.text = "(Disabled)"
	else:
		if _info_label != null and is_instance_valid(_info_label):
			_info_label.text = "(Move mouse over UI...)"


# ── Pin actions ──────────────────────────────────────────────────────────

func _refresh_pin_textedit() -> void:
	if _pin_textedit == null or not is_instance_valid(_pin_textedit):
		return
	var s = ""
	for l in _pinned_lines:
		s += l + "\n"
	_pin_textedit.text = s


func _on_copy_pressed() -> void:
	# Honor any manual edits the user made in the TextEdit.
	var s = ""
	if _pin_textedit != null and is_instance_valid(_pin_textedit):
		s = _pin_textedit.text
	else:
		for l in _pinned_lines:
			s += l + "\n"
	OS.clipboard = s
	var n = s.split("\n", false).size()
	_set_status("Copied to clipboard (%d line%s)." % [n, "" if n == 1 else "s"])


func _on_clear_pressed() -> void:
	_pinned_lines.clear()
	_refresh_pin_textedit()
	_set_status("Cleared.")


func _set_status(msg: String) -> void:
	if _status_lbl != null and is_instance_valid(_status_lbl):
		_status_lbl.text = msg
