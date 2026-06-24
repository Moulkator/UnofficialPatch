# light_tool_fix.gd
# Adds Rotation slider to LightTool panel
# Adds Shift+scroll to cycle light styles in LightTool

var _g
var ui_util
var input_listener: Node

var _rot_label = null
var _rot_hbox = null
var _rot_slider = null
var _rot_spin = null
var _ui_injected = false
var _updating_ui = false

var _lt_item_list = null
var _last_rotation = 0.0
var _last_preview_id = 0
var _last_style_idx = -1
var _restore_rotation_pending = false

func initialize():
	_install_input_listener()
	# Defer UI injection to let DD finish building panels
	print("[LightToolFix] Initialized")


# Lit le toggle "Light Tool Works Like the Object Tool" du Settings panel.
# OFF = on n'intercepte ni le right-click rotation ni le wheel rotation
# (Z+wheel, Shift+Z+wheel inclus). Les behaviors light-specific (Shift+wheel
# = style cycle, Alt+wheel = range) restent quoi qu'il arrive.
func _is_lt_object_tool_like_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("light_tool_object_like")

func _install_input_listener():
	input_listener = Node.new()
	input_listener.name = "LightToolFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	# High priority: process before other nodes
	process_priority = -100
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	# Add to scene tree root to intercept events early
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", input_listener)


# ==================== UI INJECTION ====================

# Resolve the LightTool panel's Align VBoxContainer.
# ResizeLeftPanel (3rd-party mod) reparents Align into an intermediate
# HBoxContainer so it's no longer a direct child of lt_panel. The
# lt_panel.Align property still points to the same node, so we use it
# first and only fall back to the direct-child scan if it's missing.
func _get_lt_align(lt_panel):
	if lt_panel == null:
		return null
	var align = lt_panel.get("Align")
	if align != null and is_instance_valid(align):
		return align
	for child in lt_panel.get_children():
		if child is VBoxContainer:
			return child
	return null


func _inject_ui():
	if _ui_injected:
		return
	
	var lt_panel = _g.Editor.Toolset.GetToolPanel("LightTool")
	if lt_panel == null:
		return
	
	var align = _get_lt_align(lt_panel)
	if align == null:
		return
	
	# Structure:
	# 0: Label (Range)
	# 1: HBox (Range slider+spin)
	# 2: Label (Intensity)  
	# 3: HBox (Intensity slider+spin)
	# 4: CheckButton (Shadows)
	# ...
	# We insert Rotation after index 3 (Intensity HBox)
	
	if align.get_child_count() < 5:
		return
	
	# Load reset icon
	# (none needed, _make_reset_button loads it)
	
	# Add reset button to Range HBox (index 1)
	var range_hbox = align.get_child(1)
	if range_hbox is HBoxContainer:
		var btn = _make_reset_button("Reset range")
		btn.connect("pressed", self, "_on_reset_range")
		range_hbox.add_child(btn)
	
	# Add reset button to Intensity HBox (index 3)
	var intensity_hbox = align.get_child(3)
	if intensity_hbox is HBoxContainer:
		var btn = _make_reset_button("Reset intensity")
		btn.connect("pressed", self, "_on_reset_intensity")
		intensity_hbox.add_child(btn)
		# Expand Intensity bounds on DD-native controls
		for c in intensity_hbox.get_children():
			if c is Range:
				c.min_value = 0.1
				c.max_value = 5.0
	
	# Create Rotation controls
	_rot_label = Label.new()
	_rot_label.text = "Rotation"
	
	_rot_hbox = HBoxContainer.new()
	_rot_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	_rot_slider = HSlider.new()
	_rot_slider.min_value = -180.0
	_rot_slider.max_value = 180.0
	_rot_slider.step = 1.0
	_rot_slider.value = 0.0
	_rot_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rot_slider.connect("value_changed", self, "_on_rotation_changed")
	
	_rot_spin = SpinBox.new()
	_rot_spin.min_value = -180.0
	_rot_spin.max_value = 180.0
	_rot_spin.step = 1.0
	_rot_spin.value = 0.0
	_rot_spin.connect("value_changed", self, "_on_rotation_changed")
	
	var rot_reset = _make_reset_button("Reset rotation")
	rot_reset.connect("pressed", self, "_on_reset_rotation")
	
	_rot_hbox.add_child(_rot_slider)
	_rot_hbox.add_child(_rot_spin)
	_rot_hbox.add_child(rot_reset)
	
	# Insert after intensity (index 3) -> new indices 4, 5
	align.add_child(_rot_label)
	align.move_child(_rot_label, 4)
	align.add_child(_rot_hbox)
	align.move_child(_rot_hbox, 5)
	
	_ui_injected = true
	print("[LightToolFix] Rotation slider injected")
	
	# Lower Range minimum to 0.1
	var lt = _g.Editor.Tools["LightTool"]
	if lt:
		var range_ctrl = lt.get("Range")
		if range_ctrl and range_ctrl is Range:
			range_ctrl.min_value = 0.1


# ==================== ROTATION CALLBACK ====================

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	image.load(_g.Root + icon_path)
	if scale != 1.0:
		var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
		image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _make_reset_button(tooltip: String) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	btn.icon = _load_icon("icons/reset.png", 0.5)
	return btn

func _on_reset_range():
	var lt = _g.Editor.Tools["LightTool"]
	if lt:
		var range_ctrl = lt.get("Range")
		if range_ctrl and range_ctrl is Range:
			range_ctrl.value = 5.0

func _on_reset_intensity():
	var lt = _g.Editor.Tools["LightTool"]
	if lt:
		lt.set("Intensity", 1.0)
		# Also update the slider
		var lt_panel = _g.Editor.Toolset.GetToolPanel("LightTool")
		var align = _get_lt_align(lt_panel)
		if align and align.get_child_count() > 3:
			var hbox = align.get_child(3)
			if hbox is HBoxContainer:
				for c in hbox.get_children():
					if c is Range:
						c.value = 1.0
						break

func _on_reset_rotation():
	_last_rotation = 0.0
	var lt = _g.Editor.Tools["LightTool"]
	if lt:
		var preview = lt.get("preview")
		if preview and is_instance_valid(preview):
			preview.rotation_degrees = 0.0
	_updating_ui = true
	_rot_slider.value = 0.0
	_rot_spin.value = 0.0
	_updating_ui = false

func _on_rotation_changed(value):
	if _updating_ui:
		return
	_updating_ui = true
	
	if _rot_slider.value != value:
		_rot_slider.value = value
	if _rot_spin.value != value:
		_rot_spin.value = value
	
	_last_rotation = value
	
	# Apply to LightTool preview
	var lt = _g.Editor.Tools["LightTool"]
	if lt:
		var preview = lt.get("preview")
		if preview and is_instance_valid(preview):
			preview.rotation_degrees = value
	
	_updating_ui = false


# ==================== UPDATE ====================

func update(delta):
	if _g.Editor.ActiveToolName != "LightTool":
		return
	_inject_ui()
	_sync_rotation_from_preview()
	_snap_preview_to_grid()


func _sync_rotation_from_preview():
	if not _ui_injected or _updating_ui:
		return
	var lt = _g.Editor.Tools["LightTool"]
	if lt == null:
		return
	
	# Detect asset (style) change via ItemList selection.
	# DD may either recreate the preview (caught by pid change below) or
	# reuse the existing preview node and reset its rotation; this catches both.
	if not _lt_item_list or not is_instance_valid(_lt_item_list):
		_cache_style_item_list()
	if _lt_item_list and is_instance_valid(_lt_item_list):
		var sel = _lt_item_list.get_selected_items()
		var cur_idx = -1
		if sel.size() > 0:
			cur_idx = sel[0]
		if cur_idx != _last_style_idx:
			if _last_style_idx != -1:
				_restore_rotation_pending = true
			_last_style_idx = cur_idx
	
	var preview = lt.get("preview")
	if preview and is_instance_valid(preview):
		var pid = preview.get_instance_id()
		# Restore rotation when preview is replaced (placement) or asset changes
		if pid != _last_preview_id or _restore_rotation_pending:
			if _last_preview_id != 0 or _restore_rotation_pending:
				preview.rotation_degrees = _last_rotation
			_last_preview_id = pid
			_restore_rotation_pending = false
		
		var rot = preview.rotation_degrees
		_last_rotation = rot
		_updating_ui = true
		if abs(_rot_slider.value - rot) > 0.5:
			_rot_slider.value = rot
		if abs(_rot_spin.value - rot) > 0.5:
			_rot_spin.value = rot
		_updating_ui = false


func _snap_preview_to_grid():
	var lt = _g.Editor.Tools["LightTool"]
	if lt == null:
		return
	var preview = lt.get("preview")
	if not preview or not is_instance_valid(preview):
		return
	# Only snap when snap is enabled (SnappedPosition differs from MousePosition)
	var snapped = _g.WorldUI.SnappedPosition
	var mouse = _g.WorldUI.MousePosition
	if snapped.distance_to(mouse) < 1.0:
		return  # Snap disabled or already on grid
	preview.global_position = snapped


# ==================== STYLE CYCLING ====================

func _cache_style_item_list():
	if _lt_item_list and is_instance_valid(_lt_item_list):
		return
	var lt_panel = _g.Editor.Toolset.GetToolPanel("LightTool")
	if lt_panel:
		var all_lists = []
		_find_all_item_lists(lt_panel, all_lists)
		if all_lists.size() >= 2:
			_lt_item_list = all_lists[1]
		elif all_lists.size() == 1:
			_lt_item_list = all_lists[0]

func _find_all_item_lists(node, result):
	if node is ItemList:
		result.append(node)
	for child in node.get_children():
		if is_instance_valid(child):
			_find_all_item_lists(child, result)


func _on_input(event):
	if _g.Editor.ActiveToolName != "LightTool":
		return
	
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	
	# Don't intercept over UI
	if ui_util and ui_util.is_mouse_over_ui(input_listener):
		return
	
	var lt = _g.Editor.Tools["LightTool"]
	var preview = lt.get("preview")
	
	# --- Right Click = +90° rotation ---
	# Gated par "Light Tool Works Like the Object Tool" : OFF = on laisse
	# DD gerer le right-click natif (= context menu, etc).
	if event.button_index == BUTTON_RIGHT:
		if not _is_lt_object_tool_like_enabled():
			return
		if preview and is_instance_valid(preview):
			var rot = preview.rotation_degrees + 90.0
			if rot > 180.0:
				rot -= 360.0
			preview.rotation_degrees = rot
			_sync_rotation_from_preview()
		input_listener.get_tree().set_input_as_handled()
		return
	
	# --- Scroll wheel only from here ---
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return
	
	# Ctrl+scroll = zoom, don't intercept
	if Input.is_key_pressed(KEY_CONTROL):
		return
	
	var up = event.button_index == BUTTON_WHEEL_UP
	
	var shift_held = Input.is_key_pressed(KEY_SHIFT)
	var z_held = Input.is_key_pressed(KEY_Z)
	var alt_held = Input.is_key_pressed(KEY_ALT)
	var ot_like = _is_lt_object_tool_like_enabled()

	if ot_like:
		# === Mode "Similar to Object Tool" (ON) ===
		# Shift+scroll = cycle styles (sauf si Z aussi : precision rotation)
		if shift_held and not z_held:
			_do_style_cycle(lt, preview, up)
			input_listener.get_tree().set_input_as_handled()
			return
		# Alt+scroll = range
		if alt_held:
			_do_range_change(lt, preview, up)
			input_listener.get_tree().set_input_as_handled()
			return
		# Scroll = rotation (15° / Z=5° / Shift+Z=1°)
		if preview and is_instance_valid(preview):
			var step = 15.0
			if z_held and shift_held:
				step = 1.0
			elif z_held:
				step = 5.0
			if not up:
				step = -step
			var rot = preview.rotation_degrees + step
			# Wrap to -180..+180
			if rot > 180.0:
				rot -= 360.0
			elif rot < -180.0:
				rot += 360.0
			preview.rotation_degrees = rot
			_sync_rotation_from_preview()
			input_listener.get_tree().set_input_as_handled()
		return

	# === Mode "vanilla LightTool" (OFF) ===
	# Alt+scroll = rotation (15° / Z=5°). Pas de precision 1° en mode OFF
	# car Shift est reserve au scale.
	if alt_held:
		if preview and is_instance_valid(preview):
			var step = 15.0
			if z_held:
				step = 5.0
			if not up:
				step = -step
			var rot = preview.rotation_degrees + step
			if rot > 180.0:
				rot -= 360.0
			elif rot < -180.0:
				rot += 360.0
			preview.rotation_degrees = rot
			_sync_rotation_from_preview()
			input_listener.get_tree().set_input_as_handled()
		return
	# Shift+scroll = scale par steps de 0.1 sur le Range du LightTool.
	if shift_held:
		_do_range_step(lt, up, 0.1)
		input_listener.get_tree().set_input_as_handled()
		return
	# Plain scroll : on n'intercepte pas, DD gere son comportement natif (zoom).


func _do_range_change(lt, preview, up):
	var range_ctrl = lt.get("Range")
	if not (range_ctrl and range_ctrl is Range):
		return
	# Ensure min is 0.1
	if range_ctrl.min_value > 0.1:
		range_ctrl.min_value = 0.1
	var current = range_ctrl.value
	var step = max(current * 0.15, 0.1)
	if up:
		current += step
	else:
		current -= step
	current = clamp(current, range_ctrl.min_value, range_ctrl.max_value)
	range_ctrl.value = current


# Additive step on light range (used in OFF mode for Shift+wheel = scale
# by 0.1). Differs from _do_range_change which uses a 15% relative step.
func _do_range_step(lt, up: bool, step: float) -> void:
	var range_ctrl = lt.get("Range")
	if not (range_ctrl and range_ctrl is Range):
		return
	if range_ctrl.min_value > 0.1:
		range_ctrl.min_value = 0.1
	var current = range_ctrl.value
	if up:
		current += step
	else:
		current -= step
	current = clamp(current, range_ctrl.min_value, range_ctrl.max_value)
	range_ctrl.value = current


func _do_style_cycle(lt, preview, up):
	# Ensure we have the style ItemList
	if not _lt_item_list or not is_instance_valid(_lt_item_list):
		_cache_style_item_list()
	if not _lt_item_list or not is_instance_valid(_lt_item_list):
		return
	
	var count = _lt_item_list.get_item_count()
	if count == 0:
		return
	
	# Get current selection from ItemList
	var current_idx = 0
	var selected = _lt_item_list.get_selected_items()
	if selected.size() > 0:
		current_idx = selected[0]
	
	var direction = -1 if up else 1
	var new_idx = (current_idx + direction) % count
	if new_idx < 0:
		new_idx += count
	
	# Let DD handle the texture change via its own signal handler
	_lt_item_list.select(new_idx)
	_lt_item_list.emit_signal("item_selected", new_idx)
