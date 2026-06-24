var _g

# Lit le toggle "Hide Lights Transform Box" du Settings panel.
func _is_hide_lights_box_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("hide_lights_transform_box")


var _original_box_style = null
var _original_corner_style = null
var _transparent_style = null
var _state = 0  # 0=normal, 1=transparent, 2=disabled
var _cursor_active = false
var _resize_cursor_cache := {}  # int(degrees) → ImageTexture
var _cursor_node : Node = null
var _active_lights := []  # lights to track for cursor, set by update()
const CURSOR_ANGLE_STEP = 5

# UI controls injected into SelectTool panel
var _light_vbox = null  # The light-specific VBoxContainer in SelectTool panel
var _range_label = null
var _range_hbox = null
var _range_slider = null
var _range_spin = null
var _rot_label = null
var _rot_hbox = null
var _rot_slider = null
var _rot_spin = null
var _shadow_cb = null
var _ui_injected = false
var _updating_ui = false  # prevent feedback loops
var _prev_light_ids = []  # track selection changes

# Références aux contrôles DD natifs détectés par scan
var _orig_intensity_label = null
var _orig_intensity_hbox = null
var _orig_color_label = null
var _orig_color_hbox = null
var _orig_style_label = null
var _orig_style_node = null    # ItemList ou autre

# Style cycling removed — handled by light_tool_fix.gd
var ui_util

# Mirror button grey-out when lights are selected
var _mirror_button = null
var _mirror_orig_disabled = false
var _mirror_disabled_by_us = false

const SMALL_LIGHT_THRESHOLD = 512.0
const HANDLE_TOLERANCE = 30.0

func _get_selectables_safe() -> Dictionary:
	# Replaces select_tool.Selectables which calls ToDictionary() internally
	# and crashes when keys are null (e.g. prefabs with missing assets).
	var result = {}
	var select_tool = _g.Editor.Tools["SelectTool"]
	var raw = select_tool.RawSelectables
	if raw == null: return result
	for s in raw:
		if s == null or not is_instance_valid(s): continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing): continue
		var type = select_tool.GetSelectableType(thing)
		result[thing] = type
	return result


func initialize():
	_transparent_style = StyleBoxFlat.new()
	_transparent_style.bg_color = Color(0, 0, 0, 0)
	_transparent_style.border_color = Color(0, 0, 0, 0)
	_transparent_style.border_width_top = 0
	_transparent_style.border_width_bottom = 0
	_transparent_style.border_width_left = 0
	_transparent_style.border_width_right = 0
	_load_resize_cursor_cache()
	_setup_cursor_node()

func _load_cursor(filename):
	var path = _g.Root + filename
	var img = Image.new()
	var err = img.load(path)
	if err != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _load_resize_cursor_cache() -> void:
	var img = Image.new()
	if img.load(_g.Root + "icons/resize-ns2.png") != OK:
		print("[LightFix] Failed to load resize-ns cursor")
		return
	var orig_w = img.get_width()
	var orig_h = img.get_height()
	# Upscale 4x for clean rotation, then downscale back
	var big = Image.new()
	big.copy_from(img)
	big.resize(orig_w * 4, orig_h * 4, Image.INTERPOLATE_BILINEAR)
	# resize-ns points at 90°. Rotate by (target - 90) to aim at target angle.
	for deg in range(0, 180, CURSOR_ANGLE_STEP):
		var rotation = deg2rad(float(deg - 90))
		var rotated = _rotate_image(big, rotation)
		rotated.resize(orig_w, orig_h, Image.INTERPOLATE_BILINEAR)
		var tex = ImageTexture.new()
		tex.create_from_image(rotated, 0)
		_resize_cursor_cache[deg] = tex
	print("[LightFix] Cursor cache built: %d entries" % _resize_cursor_cache.size())


func _rotate_image(src: Image, angle: float) -> Image:
	var w = src.get_width()
	var h = src.get_height()
	var cx = w / 2.0
	var cy = h / 2.0
	var dst = Image.new()
	dst.create(w, h, false, src.get_format())
	src.lock()
	dst.lock()
	var cos_a = cos(-angle)
	var sin_a = sin(-angle)
	for y in range(h):
		for x in range(w):
			var sx = cos_a * (x - cx) - sin_a * (y - cy) + cx
			var sy = sin_a * (x - cx) + cos_a * (y - cy) + cy
			dst.set_pixel(x, y, _sample_bilinear(src, sx, sy, w, h))
	src.unlock()
	dst.unlock()
	return dst


func _sample_bilinear(img: Image, sx: float, sy: float, w: int, h: int) -> Color:
	if sx < 0.0 or sy < 0.0 or sx >= w - 1.0 or sy >= h - 1.0:
		# Clamp border: if partially inside, sample edge; otherwise transparent
		if sx < -0.5 or sy < -0.5 or sx >= w - 0.5 or sy >= h - 0.5:
			return Color(0, 0, 0, 0)
		sx = clamp(sx, 0.0, w - 1.001)
		sy = clamp(sy, 0.0, h - 1.001)
	var x0 = int(sx)
	var y0 = int(sy)
	var x1 = min(x0 + 1, w - 1)
	var y1 = min(y0 + 1, h - 1)
	var fx = sx - x0
	var fy = sy - y0
	var c00 = img.get_pixel(x0, y0)
	var c10 = img.get_pixel(x1, y0)
	var c01 = img.get_pixel(x0, y1)
	var c11 = img.get_pixel(x1, y1)
	return c00 * (1 - fx) * (1 - fy) + c10 * fx * (1 - fy) + c01 * (1 - fx) * fy + c11 * fx * fy


func _setup_cursor_node() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_internal(true)
func _process(_d):
	if handler != null:
		handler._apply_pending_cursor()
func _notification(what):
	if what == NOTIFICATION_INTERNAL_PROCESS and handler != null:
		handler._apply_pending_cursor()
func _input(event):
	if handler != null and event is InputEventMouseMotion:
		handler._apply_pending_cursor()
"""
	script.reload()
	_cursor_node = Node.new()
	_cursor_node.name = "LightFixCursorLate"
	_cursor_node.set_script(script)
	_cursor_node.handler = self
	_cursor_node.process_priority = 9999
	_g.World.call_deferred("add_child", _cursor_node)
	print("[LightFix] Late cursor node added")


func _apply_pending_cursor() -> void:
	if _active_lights.size() == 0:
		if _cursor_active:
			Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
			_cursor_active = false
		return
	var mouse_world = _g.WorldUI.MousePosition
	for light in _active_lights:
		if light == null or not is_instance_valid(light):
			continue
		var center = light.global_position
		var radius = _get_light_radius(light)
		var dist = mouse_world.distance_to(center)
		# DD's resize zone is ~64 world units around the circle edge
		if abs(dist - radius) < 66.0:
			var angle_deg = fmod(rad2deg((mouse_world - center).angle()), 180.0)
			if angle_deg < 0: angle_deg += 180.0
			var snapped = int(round(angle_deg / CURSOR_ANGLE_STEP)) * CURSOR_ANGLE_STEP % 180
			if _resize_cursor_cache.has(snapped):
				var tex = _resize_cursor_cache[snapped]
				Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2)
				_cursor_active = true
			return
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false


# ==================== UI INJECTION ====================

func _find_light_vbox():
	if _light_vbox != null and is_instance_valid(_light_vbox):
		return _light_vbox
	
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		return null
	
	# Try direct property access first (like objectOptions, wallOptions, etc.)
	for prop_name in ["lightOptions", "LightOptions"]:
		var opts = panel.get(prop_name)
		if opts != null and opts is VBoxContainer:
			_light_vbox = opts
			_hide_original_light_controls(opts)
			return opts
	
	# Fallback: scan children, but verify by CheckButton text, not just type
	var align = null
	for child in panel.get_children():
		if child is VBoxContainer:
			align = child
			break
	if align == null:
		return null
	
	for child in align.get_children():
		if not (child is VBoxContainer):
			continue
		if child.get_child_count() < 2:
			continue
		# Verify this is specifically the light panel by checking for
		# "Shadow" and "Block Light" CheckButtons (not just any 2 CheckButtons)
		var has_shadow_cb = false
		var has_block_light_cb = false
		for sub in child.get_children():
			if sub is CheckButton:
				var t = sub.text.to_lower() if sub.text != null else ""
				if "shadow" in t and not "soft" in t and not "drop" in t:
					has_shadow_cb = true
				if "block" in t and "light" in t:
					has_block_light_cb = true
		if has_shadow_cb and has_block_light_cb:
			_light_vbox = child
			_hide_original_light_controls(child)
			return child
	return null

func _hide_original_light_controls(vbox):
	# Cache uniquement les CheckButtons Shadows et Block Light (remplacés par nos contrôles).
	# Stocke les références aux contrôles DD natifs (Intensity, Color, Style)
	# pour pouvoir les reordonner dans _reorder_controls().
	# Color n'est plus caché ici : on le réaffiche dans le bon ordre.
	_orig_intensity_label = null
	_orig_intensity_hbox = null
	_orig_color_label = null
	_orig_color_hbox = null
	_orig_style_label = null
	_orig_style_node = null

	var children = vbox.get_children()
	var skip_next := false
	for i in range(children.size()):
		if skip_next:
			skip_next = false
			continue
		var child = children[i]

		# CheckButtons : cacher Shadows et Block Light
		if child is CheckButton:
			var t = (child.text if child.text != null else "").to_lower()
			if "shadow" in t or "block" in t:
				child.visible = false
			continue

		# Labels : identifier le groupe Label + contrôle suivant
		if child is Label:
			var t = (child.text if child.text != null else "").to_lower()
			var next = children[i + 1] if i + 1 < children.size() else null
			if "intensity" in t:
				_orig_intensity_label = child
				_orig_intensity_hbox = next
				skip_next = true
			elif "color" in t:
				_orig_color_label = child
				_orig_color_hbox = next
				# Cacher pour l'instant — réaffiché dans _reorder_controls
				child.visible = false
				if next: next.visible = false
				skip_next = true
			elif "style" in t or "texture" in t:
				_orig_style_label = child
				_orig_style_node = next
				skip_next = true
			continue

		# ItemList sans label précédent → probablement Style
		if child is ItemList and _orig_style_node == null:
			_orig_style_node = child

func _inject_ui():
	if _ui_injected:
		return
	
	var vbox = _find_light_vbox()
	if vbox == null:
		return
	
	# Expand Intensity bounds on DD-native intensity controls (kept as-is in vbox)
	# and add a reset button next to them.
	if _orig_intensity_hbox != null and is_instance_valid(_orig_intensity_hbox):
		for c in _orig_intensity_hbox.get_children():
			if c is Range:
				c.min_value = 0.1
				c.max_value = 5.0
		var int_reset = _make_reset_button("Reset intensity")
		int_reset.connect("pressed", self, "_on_reset_intensity")
		_orig_intensity_hbox.add_child(int_reset)
	
	# --- Range control ---
	_range_label = Label.new()
	_range_label.text = "Range"
	
	_range_hbox = HBoxContainer.new()
	_range_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	_range_slider = HSlider.new()
	_range_slider.min_value = 0.0
	_range_slider.max_value = 1.0
	_range_slider.step = 0.001
	_range_slider.value = _range_to_slider(5.0)
	_range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_range_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_range_slider.connect("value_changed", self, "_on_range_slider_changed")
	# Pour l'undo : on capture un snapshot au début du drag, on le commit
	# au relâchement. Ça fait 1 record par drag de slider et non pas 1
	# par value_changed. Les signaux drag_started/drag_ended existent sur
	# Slider depuis Godot 3.5.
	if _range_slider.has_signal("drag_started"):
		_range_slider.connect("drag_started", self, "_on_range_drag_started")
	if _range_slider.has_signal("drag_ended"):
		_range_slider.connect("drag_ended", self, "_on_range_drag_ended")
	
	_range_spin = SpinBox.new()
	_range_spin.min_value = 0.1
	_range_spin.max_value = 20.0
	_range_spin.step = 0.1
	_range_spin.value = 5.0
	_range_spin.connect("value_changed", self, "_on_range_spin_changed")
	
	_range_hbox.add_child(_range_slider)
	_range_hbox.add_child(_range_spin)
	var range_reset = _make_reset_button("Reset range")
	range_reset.connect("pressed", self, "_on_reset_range")
	_range_hbox.add_child(range_reset)
	
	# --- Rotation control ---
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
	_rot_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rot_slider.connect("value_changed", self, "_on_rotation_changed")
	if _rot_slider.has_signal("drag_started"):
		_rot_slider.connect("drag_started", self, "_on_rotation_drag_started")
	if _rot_slider.has_signal("drag_ended"):
		_rot_slider.connect("drag_ended", self, "_on_rotation_drag_ended")
	
	_rot_spin = SpinBox.new()
	_rot_spin.min_value = -180.0
	_rot_spin.max_value = 180.0
	_rot_spin.step = 1.0
	_rot_spin.value = 0.0
	_rot_spin.connect("value_changed", self, "_on_rotation_changed")
	
	_rot_hbox.add_child(_rot_slider)
	_rot_hbox.add_child(_rot_spin)
	var rot_reset = _make_reset_button("Reset rotation")
	rot_reset.connect("pressed", self, "_on_reset_rotation")
	_rot_hbox.add_child(rot_reset)

	# --- Shadows toggle ---
	_shadow_cb = CheckButton.new()
	_shadow_cb.text = "Shadows"
	_shadow_cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shadow_cb.connect("toggled", self, "_on_shadow_toggled")

	# Ajouter nos contrôles dans le vbox (l'ordre final est fixé par _reorder_controls)
	vbox.add_child(_range_label)
	vbox.add_child(_range_hbox)
	vbox.add_child(_rot_label)
	vbox.add_child(_rot_hbox)
	vbox.add_child(_shadow_cb)

	# Réordonner tous les contrôles dans l'ordre voulu
	_reorder_controls(vbox)

	_ui_injected = true
	print("[LightFix] UI injected into SelectTool panel")


func _reorder_controls(vbox: Node) -> void:
	# Ordre voulu : Range, Intensity, Rotation, Shadows, Color, Style
	# Les contrôles DD natifs non trouvés (null) sont simplement ignorés.
	if _orig_color_label: _orig_color_label.visible = true
	if _orig_color_hbox:  _orig_color_hbox.visible  = true

	var order := []
	order.append(_range_label)
	order.append(_range_hbox)
	if _orig_intensity_label: order.append(_orig_intensity_label)
	if _orig_intensity_hbox:  order.append(_orig_intensity_hbox)
	order.append(_rot_label)
	order.append(_rot_hbox)
	order.append(_shadow_cb)
	if _orig_color_label: order.append(_orig_color_label)
	if _orig_color_hbox:  order.append(_orig_color_hbox)
	if _orig_style_label: order.append(_orig_style_label)
	if _orig_style_node:  order.append(_orig_style_node)

	for i in range(order.size()):
		var ctrl = order[i]
		if ctrl != null and is_instance_valid(ctrl):
			vbox.move_child(ctrl, i)


# ==================== ICON / RESET HELPERS ====================

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
	_updating_ui = true
	_range_slider.value = _range_to_slider(5.0)
	_range_spin.value = 5.0
	_apply_range_with_undo(5.0)
	_updating_ui = false

func _on_shadow_toggled(pressed: bool) -> void:
	if _updating_ui:
		return
	var lights = _get_selected_lights()
	if lights.empty():
		return
	
	var undo = _get_undo_lib()
	var have_undo = undo != null and undo.begin_property_snapshot(lights, ["shadow_enabled"])
	
	for node in lights:
		if is_instance_valid(node):
			node.set("shadow_enabled", pressed)
	
	if have_undo:
		undo.commit_property_snapshot()


func _on_reset_rotation():
	_updating_ui = true
	_rot_slider.value = 0.0
	_rot_spin.value = 0.0
	var lights = _get_selected_lights()
	if lights.empty():
		_updating_ui = false
		return
	var undo = _get_undo_lib()
	var have_undo = undo != null and undo.begin_property_snapshot(lights, ["rotation_degrees"])
	for node in lights:
		if is_instance_valid(node):
			node.rotation_degrees = 0.0
	if have_undo:
		undo.commit_property_snapshot()
	_updating_ui = false


func _on_reset_intensity():
	# Reset intensity to 1.0 by driving DD's native slider — DD's own
	# value_changed handler propagates to the selected lights and keeps
	# slider/spinbox in sync. Avoids depending on the underlying property
	# name (which may differ across DD versions).
	if _orig_intensity_hbox == null or not is_instance_valid(_orig_intensity_hbox):
		return
	for c in _orig_intensity_hbox.get_children():
		if c is Range:
			c.value = 1.0


# ==================== UI CALLBACKS ====================

# Exponential mapping: slider 0..1 → range 0.1..20
# t=0 → 0.1, t=0.5 → ~1.4, t=1 → 20
const RANGE_MIN = 0.1
const RANGE_MAX = 20.0

func _slider_to_range(t: float) -> float:
	return RANGE_MIN * pow(RANGE_MAX / RANGE_MIN, t)

func _range_to_slider(r: float) -> float:
	if r <= RANGE_MIN:
		return 0.0
	return log(r / RANGE_MIN) / log(RANGE_MAX / RANGE_MIN)

func _on_range_slider_changed(t):
	if _updating_ui:
		return
	_updating_ui = true
	var value = _slider_to_range(t)
	value = stepify(value, 0.1) if value >= 1.0 else stepify(value, 0.01)
	_range_spin.value = value
	# Pendant un drag du slider, on applique sans ouvrir de record — le
	# snapshot a déjà été pris dans _on_range_drag_started et sera commit
	# dans _on_range_drag_ended. Pour les value_changed en dehors d'un
	# drag (ex: clic sur la piste sans drag, ou scroll molette), on fait
	# quand même un record ponctuel.
	if _range_drag_active:
		_apply_range(value)
	else:
		_apply_range_with_undo(value)
	_updating_ui = false

func _on_range_spin_changed(value):
	if _updating_ui:
		return
	_updating_ui = true
	_range_slider.value = _range_to_slider(value)
	_apply_range_with_undo(value)
	_updating_ui = false

# Version de _apply_range qui ouvre et ferme un snapshot undo autour de
# la mutation. Utilisé pour les mutations ponctuelles (spin, reset, clic
# sans drag sur la piste du slider).
func _apply_range_with_undo(value):
	var lights = _get_selected_lights()
	if lights.empty():
		return
	var undo = _get_undo_lib()
	var have_undo = undo != null and undo.begin_property_snapshot(lights, ["texture_scale"])
	_apply_range(value)
	if have_undo:
		undo.commit_property_snapshot()

func _apply_range(value):
	var selectables = _get_selectables_safe()
	if selectables:
		for node in selectables:
			if node != null and is_instance_valid(node) and selectables[node] == 6:
				node.set("texture_scale", value)
				_update_light_widget(node)

# --- Drag lifecycle pour le range slider ---
var _range_drag_active: bool = false

func _on_range_drag_started():
	var lights = _get_selected_lights()
	if lights.empty():
		return
	var undo = _get_undo_lib()
	if undo != null and undo.begin_property_snapshot(lights, ["texture_scale"]):
		_range_drag_active = true

func _on_range_drag_ended(value_changed: bool):
	if not _range_drag_active:
		return
	_range_drag_active = false
	var undo = _get_undo_lib()
	if undo == null:
		return
	if value_changed:
		undo.commit_property_snapshot()
	else:
		# Clic sur la piste sans changement final : rien à enregistrer.
		undo.cancel_property_snapshot()

# --- Helpers ---

func _get_selected_lights() -> Array:
	# Extrait uniquement les nodes Light (type 6) de la sélection.
	var out := []
	var selectables = _get_selectables_safe()
	if selectables:
		for node in selectables:
			if node != null and is_instance_valid(node) and selectables[node] == 6:
				out.append(node)
	return out

func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")

var _widget_logged = false

func _update_light_widget(light_node):
	for child in light_node.get_children():
		if child is Node2D and child.z_index == 4096:
			var tex = light_node.get("texture")
			var scale = light_node.get("texture_scale")
			if tex == null or scale == null:
				break
			var radius = tex.get_size().x * scale * 0.5
			
			for sub in child.get_children():
				if sub is Line2D and sub.get_point_count() > 10:
					# Rebuild circle points at new radius
					var count = sub.get_point_count()
					for i in range(count):
						var angle = (float(i) / float(count - 1)) * TAU
						sub.set_point_position(i, Vector2(cos(angle), sin(angle)) * radius)
			break

func _on_rotation_changed(value):
	if _updating_ui:
		return
	_updating_ui = true
	
	if _rot_slider.value != value:
		_rot_slider.value = value
	if _rot_spin.value != value:
		_rot_spin.value = value
	
	# Comme pour le range : pendant un drag du slider, pas de record par
	# tick — il est ouvert/fermé par drag_started/ended. Pour les
	# value_changed en dehors d'un drag (spin, clic sur la piste, scroll),
	# on ouvre un record ponctuel autour de l'application.
	if _rotation_drag_active:
		_apply_rotation(value)
	else:
		_apply_rotation_with_undo(value)
	
	_updating_ui = false

func _apply_rotation(value):
	var lights = _get_selected_lights()
	for node in lights:
		if is_instance_valid(node):
			node.rotation_degrees = value

func _apply_rotation_with_undo(value):
	var lights = _get_selected_lights()
	if lights.empty():
		return
	var undo = _get_undo_lib()
	var have_undo = undo != null and undo.begin_property_snapshot(lights, ["rotation_degrees"])
	for node in lights:
		if is_instance_valid(node):
			node.rotation_degrees = value
	if have_undo:
		undo.commit_property_snapshot()

# --- Drag lifecycle pour le rotation slider ---
var _rotation_drag_active: bool = false

func _on_rotation_drag_started():
	var lights = _get_selected_lights()
	if lights.empty():
		return
	var undo = _get_undo_lib()
	if undo != null and undo.begin_property_snapshot(lights, ["rotation_degrees"]):
		_rotation_drag_active = true

func _on_rotation_drag_ended(value_changed: bool):
	if not _rotation_drag_active:
		return
	_rotation_drag_active = false
	var undo = _get_undo_lib()
	if undo == null:
		return
	if value_changed:
		undo.commit_property_snapshot()
	else:
		undo.cancel_property_snapshot()


# ==================== UI SYNC ====================

func _sync_ui_from_selection(lights):
	if not _ui_injected or lights.size() == 0:
		return
	if _updating_ui:
		return
	
	# Always sync from current light values (tracks manual manipulation)
	var first = lights[0]
	
	_updating_ui = true
	
	var scale = first.get("texture_scale")
	if scale != null:
		var slider_val = _range_to_slider(scale)
		if abs(_range_slider.value - slider_val) > 0.005:
			_range_slider.value = slider_val
		if abs(_range_spin.value - scale) > 0.01:
			_range_spin.value = scale
	
	var rot = first.rotation_degrees
	if abs(_rot_slider.value - rot) > 0.5:
		_rot_slider.value = rot
	if abs(_rot_spin.value - rot) > 0.5:
		_rot_spin.value = rot

	var shadow = first.get("shadow_enabled")
	if shadow != null and _shadow_cb != null:
		var s = bool(shadow)
		if _shadow_cb.pressed != s:
			_shadow_cb.pressed = s

	_updating_ui = false


# ==================== MAIN UPDATE ====================

func update(delta):
	if _g.Editor.ActiveToolName != "SelectTool":
		_restore(true)
		_reset_cursor()
		_restore_mirror_button()
		_prev_light_ids = []
		if _light_vbox != null and is_instance_valid(_light_vbox):
			_light_vbox.visible = false
		return
	
	# Inject UI once
	_inject_ui()
	
	var select_tool = _g.Editor.Tools["SelectTool"]
	var selectables = _get_selectables_safe()
	if selectables == null or selectables.size() == 0:
		_restore(true)
		_reset_cursor()
		_restore_mirror_button()
		_prev_light_ids = []
		if _light_vbox != null and is_instance_valid(_light_vbox):
			_light_vbox.visible = false
		return
	
	var all_lights = true
	var min_size = INF
	var lights = []
	for node in selectables:
		if node == null or not is_instance_valid(node):
			all_lights = false
			break
		if selectables[node] != 6:
			all_lights = false
			break
		var size = _get_light_size(node)
		if size < min_size:
			min_size = size
		lights.append(node)
	
	if not all_lights:
		_restore(true)
		_reset_cursor()
		_restore_mirror_button()
		_prev_light_ids = []
		if _light_vbox != null and is_instance_valid(_light_vbox):
			_light_vbox.visible = false
		return
	
	# Sync sliders from selection
	_sync_ui_from_selection(lights)
	
	# Make sure the light sub-panel is visible
	if _light_vbox != null and is_instance_valid(_light_vbox) and not _light_vbox.visible:
		_light_vbox.visible = true
	
	# Gray out the Mirror button whenever one or more lights are selected
	_disable_mirror_button()

	# Toggle "Hide Lights Transform Box" : OFF = on n'applique aucune
	# logique de masquage/transparence. Le transform box DD reste visible
	# normalement quel que soit la taille de la light, exactement comme
	# pour un asset standard.
	if not _is_hide_lights_box_enabled():
		_restore(true)
	elif lights.size() >= 2:
		# Multiple lights: restore the normal (visible) transform box so the user
		# can move/rotate/scale them as a group. Mirror remains disabled above.
		_restore(true)
	elif min_size < SMALL_LIGHT_THRESHOLD:
		_restore(false)
		if _state != 2:
			select_tool.EnableTransformBox(false)
			_state = 2
		else:
			select_tool.EnableTransformBox(false)
	else:
		var was_disabled = (_state == 2)
		if was_disabled:
			select_tool.EnableTransformBox(true)
		if _state != 1:
			if _original_box_style == null:
				_original_box_style = _g.WorldUI.transformStyleBox
				_original_corner_style = _g.WorldUI.transformCornerStyleBox
			_g.WorldUI.transformStyleBox = _transparent_style
			_g.WorldUI.transformCornerStyleBox = _transparent_style
			_state = 1
		# Scale blocking removed — GetTransformMode() crashes when box state is unstable
	_update_resize_cursor(lights)
	
	# Observation des mutations directes (drag sur le widget de light, etc.)
	# DD ne crée pas de record pour ces interactions, donc on détecte les
	# changements de texture_scale frame par frame et on commit un record
	# au relâchement du bouton souris.
	_track_direct_light_drag(lights)


# ==================== DIRECT DRAG UNDO ====================
# Détecte quand l'utilisateur modifie texture_scale d'une light via le
# widget (drag direct sur le cercle extérieur), sans passer par nos
# sliders. Pattern similaire à edit_points_undo : snapshot au début, commit
# au relâchement, re-sync sur Ctrl+Z (détecté via LastIndex).

# Snapshot {light_instance_id → texture_scale} pris au mouse-down.
var _direct_drag_snapshot: Dictionary = {}
var _direct_drag_mouse_was_down: bool = false
var _direct_drag_last_history_index: int = -1

func _track_direct_light_drag(lights: Array) -> void:
	var mouse_down = Input.is_mouse_button_pressed(BUTTON_LEFT)
	var undo = _get_undo_lib()
	
	# Surveille si un autre mod/action vient de créer un record (ou de
	# défaire un Ctrl+Z) : dans ce cas on invalide notre snapshot pour
	# ne pas créer un record parasite de la même action.
	var history_index = -1
	if _g.Editor.get("History") != null and _g.Editor.History.has_method("get_LastIndex"):
		history_index = _g.Editor.History.call("get_LastIndex")
	if history_index != _direct_drag_last_history_index:
		_direct_drag_last_history_index = history_index
		_direct_drag_snapshot.clear()
		_direct_drag_mouse_was_down = mouse_down
		return
	
	# Transition up (mouse went down) : prendre un snapshot des lights
	# actuellement sélectionnées.
	if mouse_down and not _direct_drag_mouse_was_down:
		_direct_drag_snapshot.clear()
		for light in lights:
			if is_instance_valid(light):
				var iid = light.get_instance_id()
				_direct_drag_snapshot[iid] = {
					"ref": weakref(light),
					"texture_scale": light.get("texture_scale"),
					"rotation_degrees": light.rotation_degrees,
				}
	
	# Transition down (mouse released) : comparer avec le snapshot,
	# créer un record si au moins une light a changé.
	if not mouse_down and _direct_drag_mouse_was_down and not _direct_drag_snapshot.empty():
		_commit_direct_drag_if_changed(undo)
		_direct_drag_snapshot.clear()
	
	_direct_drag_mouse_was_down = mouse_down


func _commit_direct_drag_if_changed(undo) -> void:
	if undo == null:
		return
	
	# Construit la liste des lights encore valides avec les props à suivre.
	# On essaie d'abord texture_scale, puis rotation_degrees — on crée un
	# record avec les deux props, commit_property_snapshot ne gardera que
	# celles qui ont vraiment changé.
	var changed_lights: Array = []
	for iid in _direct_drag_snapshot:
		var entry = _direct_drag_snapshot[iid]
		var light = entry["ref"].get_ref()
		if light == null or not is_instance_valid(light):
			continue
		var cur_scale = light.get("texture_scale")
		var cur_rot = light.rotation_degrees
		if cur_scale != entry["texture_scale"] or abs(cur_rot - entry["rotation_degrees"]) > 1e-6:
			changed_lights.append(light)
	
	if changed_lights.empty():
		return
	
	# On ouvre un snapshot MAIS on a besoin de restaurer les "before" au
	# début pour que commit_property_snapshot enregistre bien les "before"
	# qu'on a en main — puis on ré-applique l'état final. C'est la seule
	# façon propre de faire vu l'API actuelle de undo_lib (le before est
	# capturé au begin_property_snapshot).
	var befores = {}
	for light in changed_lights:
		var iid = light.get_instance_id()
		befores[iid] = _direct_drag_snapshot[iid]
	
	# Sauvegarde l'état courant (after)
	var afters = {}
	for light in changed_lights:
		afters[light.get_instance_id()] = {
			"texture_scale": light.get("texture_scale"),
			"rotation_degrees": light.rotation_degrees,
		}
	
	# Restore before → begin snapshot → apply after → commit
	for light in changed_lights:
		var iid = light.get_instance_id()
		light.set("texture_scale", befores[iid]["texture_scale"])
		light.rotation_degrees = befores[iid]["rotation_degrees"]
	
	if not undo.begin_property_snapshot(changed_lights, ["texture_scale", "rotation_degrees"]):
		# Undo indisponible : reapplique l'état final et tant pis.
		for light in changed_lights:
			var iid = light.get_instance_id()
			light.set("texture_scale", afters[iid]["texture_scale"])
			light.rotation_degrees = afters[iid]["rotation_degrees"]
		return
	
	for light in changed_lights:
		var iid = light.get_instance_id()
		light.set("texture_scale", afters[iid]["texture_scale"])
		light.rotation_degrees = afters[iid]["rotation_degrees"]
	
	undo.commit_property_snapshot()
	
	# Re-synchroniser notre index pour ne pas détecter notre propre record
	# comme "action externe" au tick suivant.
	if _g.Editor.History.has_method("get_LastIndex"):
		_direct_drag_last_history_index = _g.Editor.History.call("get_LastIndex")


# ==================== HELPERS ====================

func _get_light_size(light_node):
	var tex = light_node.get("texture")
	var scale = light_node.get("texture_scale")
	if tex != null and scale != null:
		var tex_size = tex.get_size()
		return max(tex_size.x, tex_size.y) * scale
	var s = light_node.global_scale
	return max(abs(s.x), abs(s.y)) * 256.0

func _get_light_radius(light_node):
	var tex = light_node.get("texture")
	var scale = light_node.get("texture_scale")
	if tex != null and scale != null:
		return max(tex.get_size().x, tex.get_size().y) * scale * 0.5
	return 128.0

func _update_resize_cursor(lights):
	_active_lights = lights


func _get_widget_line(light: Node) -> Line2D:
	for child in light.get_children():
		if child is Node2D and child.z_index == 4096:
			for sub in child.get_children():
				if sub is Line2D:
					return sub
	return null

func _reset_cursor():
	_active_lights = []
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false

func _get_zoom():
	var level = _g.World.GetCurrentLevel()
	if level:
		var ct = level.get_canvas_transform()
		if ct:
			return 1.0 / ct.x.x if ct.x.x != 0 else 1.0
	return 1.0

func _restore(full_restore):
	if _state == 1:
		if _original_box_style != null:
			_g.WorldUI.transformStyleBox = _original_box_style
			_g.WorldUI.transformCornerStyleBox = _original_corner_style
	elif _state == 2 and full_restore:
		var select_tool = _g.Editor.Tools["SelectTool"]
		select_tool.EnableTransformBox(true)
	if full_restore:
		_state = 0
		_original_box_style = null
		_original_corner_style = null


# ==================== MIRROR BUTTON GREY-OUT ====================

func _find_mirror_button():
	# Return the cached button if still valid
	if _mirror_button != null and is_instance_valid(_mirror_button):
		return _mirror_button
	_mirror_button = null
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		return null
	# Try known property names (DD exposes panel buttons like copyButton/pasteButton)
	for prop_name in ["mirrorButton", "MirrorButton", "flipButton", "FlipButton"]:
		var btn = panel.get(prop_name)
		if btn is BaseButton and is_instance_valid(btn):
			_mirror_button = btn
			return btn
	# Fallback: scan the panel tree for a button whose tooltip/name mentions mirror/flip
	_mirror_button = _scan_for_mirror_button(panel)
	return _mirror_button


func _scan_for_mirror_button(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is BaseButton:
		var tip = ""
		if node.hint_tooltip != null:
			tip = String(node.hint_tooltip).to_lower()
		var nm = String(node.name).to_lower()
		if "mirror" in tip or "flip" in tip or "mirror" in nm or "flip" in nm:
			return node
	for child in node.get_children():
		var found = _scan_for_mirror_button(child)
		if found != null:
			return found
	return null


func _disable_mirror_button():
	var mb = _find_mirror_button()
	if mb == null or not is_instance_valid(mb):
		return
	# Capture the original disabled state the first time we take over
	if not _mirror_disabled_by_us:
		_mirror_orig_disabled = mb.disabled
		_mirror_disabled_by_us = true
	# Re-apply every frame in case DD's panel refresh re-enables it
	if not mb.disabled:
		mb.disabled = true


func _restore_mirror_button():
	if not _mirror_disabled_by_us:
		return
	var mb = _find_mirror_button()
	if mb != null and is_instance_valid(mb):
		mb.disabled = _mirror_orig_disabled
	_mirror_disabled_by_us = false



