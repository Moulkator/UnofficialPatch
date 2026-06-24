# select_collapse.gd
# Collapse a fixed set of controls in the SelectTool panel.
#
# Structure:
#   ??? [parent of Divider — likely VBoxContainer]
#     [Select header label etc.]
#     Divider [HBoxContainer]   ← pos=(0,64)
#       Buttons [VBoxContainer]
#       SelectToolPanel [ScrollContainer]  ← _select_panel
#         Align [VBoxContainer]
#
# The toggle row is inserted in Divider's parent, just before Divider.
# SelectToolPanel is NEVER reparented (would break C# references).

var _g

var _select_panel      = null
var _align             = null
var _toggle_row        = null
var _left_icon         = null
var _right_icon        = null
var _line              = null
var _collapsed         = false
var _collapsible_items = []
var _initialized       = false

var _icon_down  = null
var _icon_right = null
var _icon_left  = null

const ROW_H    = 20
const ARROW_SZ = 16

const LINE_NORMAL  = Color(1.0, 1.0, 1.0, 0.55)
const LINE_HOVER   = Color(1.0, 1.0, 1.0, 1.0)
const LINE_PRESS   = Color(0.204, 0.627, 1.0, 1.0)

const ARROW_NORMAL = Color(1, 1, 1, 0.7)
const ARROW_HOVER  = Color(1, 1, 1, 1.0)
const ARROW_PRESS  = Color(0.204, 0.627, 1.0, 1.0)


func initialize():
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")

	var root = _g.Root
	_icon_down  = _load_icon(root + "icons/down_arrow.png")
	_icon_right = _load_icon(root + "icons/right_arrow.png")
	_icon_left  = _load_icon(root + "icons/left_arrow.png")

	print("[SelectCollapse] initialized")


func cleanup() -> void:
	# Restaure la visibilite des items au cas ou ils etaient collapsed.
	if _collapsed:
		for item in _collapsible_items:
			if is_instance_valid(item):
				item.visible = true
		_collapsed = false
	if _toggle_row != null and is_instance_valid(_toggle_row):
		_toggle_row.queue_free()
	_toggle_row = null
	_left_icon = null
	_right_icon = null
	_line = null
	_collapsible_items = []
	_initialized = false
	print("[SelectCollapse] Cleaned up")


func _load_icon(path):
	var img = Image.new()
	if img.load(path) != OK:
		print("[SelectCollapse] could not load icon: " + path)
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func update(_delta):
	if _initialized or _select_panel == null:
		return
	if not _select_panel.visible:
		return
	_setup()


func _find_align(node, depth):
	if depth > 4:
		return null
	for child in node.get_children():
		if child is VBoxContainer and child.name == "Align":
			return child
		var result = _find_align(child, depth + 1)
		if result != null:
			return result
	return null


func _setup():
	# Find Align inside SelectToolPanel — may be nested if ResizeLeftPanel
	# has wrapped it in an intermediate HBoxContainer.
	_align = _find_align(_select_panel, 0)
	if _align == null:
		print("[SelectCollapse] Align not found, retrying next frame")
		return

	# Collect the fixed list up to and including the 2nd HSeparator
	var sep_count = 0
	for child in _align.get_children():
		if child is HSeparator:
			sep_count += 1
			_collapsible_items.append(child)
			if sep_count == 2:
				break
		else:
			_collapsible_items.append(child)

	if _collapsible_items.empty():
		return

	# Build the toggle row
	_toggle_row = HBoxContainer.new()
	_toggle_row.rect_min_size       = Vector2(0, ROW_H)
	_toggle_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_toggle_row.mouse_filter        = Control.MOUSE_FILTER_STOP
	_toggle_row.connect("gui_input",     self, "_on_gui_input")
	_toggle_row.connect("mouse_entered", self, "_on_hover_enter")
	_toggle_row.connect("mouse_exited",  self, "_on_hover_exit")

	_left_icon = TextureRect.new()
	_left_icon.expand              = true
	_left_icon.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_left_icon.rect_min_size       = Vector2(ARROW_SZ, ARROW_SZ)
	_left_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_left_icon.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	_left_icon.modulate            = ARROW_NORMAL
	_left_icon.texture             = _icon_down
	_toggle_row.add_child(_left_icon)

	_line = ColorRect.new()
	_line.color                 = LINE_NORMAL
	_line.rect_min_size         = Vector2(0, 1)
	_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	_line.mouse_filter          = Control.MOUSE_FILTER_IGNORE
	_toggle_row.add_child(_line)

	_right_icon = TextureRect.new()
	_right_icon.expand              = true
	_right_icon.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_right_icon.rect_min_size       = Vector2(ARROW_SZ, ARROW_SZ)
	_right_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_right_icon.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	_right_icon.modulate            = ARROW_NORMAL
	_right_icon.texture             = _icon_down
	_toggle_row.add_child(_right_icon)

	# Insert into Divider's parent, just before Divider.
	# This avoids touching SelectToolPanel (C# node) entirely.
	var divider = _select_panel.get_parent()          # HBoxContainer "Divider"
	var divider_parent = divider.get_parent()          # should be VBoxContainer
	var divider_idx = divider.get_index()

	divider_parent.add_child(_toggle_row)
	divider_parent.move_child(_toggle_row, divider_idx)

	print("[SelectCollapse] inserted in %s [%s] at index %d, %d items" % [
		divider_parent.name, divider_parent.get_class(),
		divider_idx, _collapsible_items.size()])

	_initialized = true


func _on_hover_enter():
	_line.color          = LINE_HOVER
	_left_icon.modulate  = ARROW_HOVER
	_right_icon.modulate = ARROW_HOVER


func _on_hover_exit():
	_line.color          = LINE_NORMAL
	_left_icon.modulate  = ARROW_NORMAL
	_right_icon.modulate = ARROW_NORMAL


func _on_gui_input(event):
	if not event is InputEventMouseButton or event.button_index != BUTTON_LEFT:
		return
	if event.pressed:
		_line.color          = LINE_PRESS
		_left_icon.modulate  = ARROW_PRESS
		_right_icon.modulate = ARROW_PRESS
	else:
		_on_toggle()
		_line.color          = LINE_HOVER
		_left_icon.modulate  = ARROW_HOVER
		_right_icon.modulate = ARROW_HOVER


func _on_toggle():
	_collapsed = not _collapsed
	_left_icon.texture  = _icon_right if _collapsed else _icon_down
	_right_icon.texture = _icon_left  if _collapsed else _icon_down
	for item in _collapsible_items:
		if is_instance_valid(item):
			item.visible = not _collapsed
