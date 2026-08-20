# water_square_bucket.gd
# Square Brush + Paint Bucket for the Water Tool.
#
# UI (mirrors the Terrain Brush layout):
#   - A radio row of 3 mode icons at the top of the panel: Round (native
#     brush) / Square / Bucket.
#   - DD's native brush-size preset circles are hidden and replaced by a
#     "Size" slider: in Round mode it drives the native brush size (1..7
#     cells, synced with the mouse wheel), in Square mode it is the square
#     side in tiles (0.25 steps, min 0.25 tile = 64 px), in Bucket mode it is
#     grayed out. The mouse wheel over the canvas changes the size in both
#     brush modes, like the native tools.
#   - DD's shape buttons (rect / circle / polygon) still work: picking one
#     switches the radio row back to Round.
#
# Square Brush:
#   - Paints crisp axis-aligned squares (no marching-squares softening),
#     aligned to the quarter-cell lattice, or to Snappy Mod's custom snap
#     points when its custom snap is enabled.
#   - Hold DD's brush-erase modifier when STARTING a stroke to erase.
#   - The whole stroke is committed as ONE WaterMesh.AddPolygon call (all
#     stamped squares chained into a single weakly-simple ring with zero-width
#     bridges; Clipper's NonZero fill resolves overlaps, disjoint groups and
#     enclosed holes). Native undo: one stroke = one undo step.
#
# Paint Bucket:
#   - Click any region bounded by the enabled barrier types (walls / paths /
#     patterns + map edges) to fill it with water. Region computation is
#     delegated to library/region_geometry.gd. Holes are preserved (islands
#     stay dry). Hold the erase modifier while clicking to REMOVE water from
#     the region instead. Native undo (one ChangeWaterMesh record per fill).

var _g
var ui_util
var input_listener: Node
const _META_KEY = "WaterSquareBucketListener"

# DD's brush erase modifier scancode (same constant WaterBrush/MeshBrush test).
const ERASE_KEY = 16777240

# Modes
const MODE_NORMAL = 0
const MODE_SQUARE = 1
const MODE_BUCKET = 2
const MODE_DDSHAPE = 3  # a native DD shape mode (rect/circle/polygon) is active
var _mode := MODE_NORMAL

# WorldUI.ECursorMode value of the yellow brush circle.
const CURSOR_CIRCLE = 5

# UI
var _shape_hbox = null
var _shape_buttons: Array = []      # DD's own toggle buttons in that row
var _normal_button: Button = null
var _square_button: Button = null
var _bucket_button: Button = null
var _ui_guard := false              # suppress toggle feedback loops
var _size_row = null
var _size_label: Label = null
var _size_slider: HSlider = null
var _size_spin: SpinBox = null
var _slider_guard := false
var _square_saved_tiles := 0.25     # square size memory across mode switches
var _opts_hbox = null               # "Stopped by" block (label + checkbox row)
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null

# Native brush size range shown on the slider in Round mode. The water
# premesh REMAPS brush sizes (WaterPreMesh: size > 3 -> size + 2) into a
# 7-entry brush table, so only DD Size 0..4 (displayed 1..5) is valid —
# Size 5+ indexes past the table and the brush silently stops working.
const ROUND_MIN = 1.0
const ROUND_MAX = 5.0

var _square_active := false
var _bucket_active := false
var _suspended := false

# Square stroke state
var _painting := false
var _stroke_invert := false
var _stroke_keys := {}              # "x_y" of stamped top-left corners
var _stroke_squares := []           # Array of [tl: Vector2, size: float]
var _stroke_overlay: Node2D = null  # merged fill previews while painting
var _preview_outers := []           # merged preview rings (no double-alpha)
var _preview_holes := []
var _last_stamp_mouse = null
var _hover_preview: Line2D = null

# Bucket state
var _region_geo = null
var _progress_script = null
var _filling := false
const FILL_WATCHDOG_MS = 6000
var _fill_started := 0
var _active_progress = null
var _bucket_cursor_tex: ImageTexture = null
var _bucket_cursor_active := false
const BUCKET_CURSOR_HOTSPOT_FRAC = Vector2(0.0, 1.0)

# DD cursor bookkeeping
var _saved_cursor_mode := -1

# Snappy Mod (custom snap) integration
var _snappy_ref = null
var _snappy_searched := false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	var geo_script = ResourceLoader.load(_g.Root + "library/region_geometry.gd", "GDScript", true)
	if geo_script != null:
		_region_geo = geo_script.new()
		_region_geo._g = _g
	else:
		print("[WaterSquareBucket] WARNING: could not load library/region_geometry.gd; bucket fill disabled")
	_progress_script = ResourceLoader.load(_g.Root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		print("[WaterSquareBucket] WARNING: library/progress_dialog.gd not found; no progress bar")
	_bucket_cursor_tex = _load_icon_tex("icons/bucket_cursor.png")
	_inject_ui()
	_install_listener()
	print("[WaterSquareBucket] initialized")


func _new_progress(title: String):
	if _progress_script == null:
		return null
	var pg = _progress_script.new()
	pg._g = _g
	pg.start(title)
	return pg


func _load_icon_tex(rel: String, scale: float = 1.0) -> ImageTexture:
	if _g == null or _g.Root == null: return null
	var img = Image.new()
	if img.load(_g.Root + rel) != OK:
		print("[WaterSquareBucket] icon not found: %s" % rel)
		return null
	if scale != 1.0 and scale > 0.0:
		var nw = max(1, int(round(img.get_width() * scale)))
		var nh = max(1, int(round(img.get_height() * scale)))
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject_ui():
	var dd_tool = _g.Editor.Tools["WaterBrush"]
	var tool_panel = _g.Editor.Toolset.GetToolPanel("WaterBrush")
	if dd_tool == null or tool_panel == null:
		print("[WaterSquareBucket] WaterBrush tool/panel not found")
		return
	var align = tool_panel.get("Align")
	if align == null:
		print("[WaterSquareBucket] Align not found")
		return

	# Identify the native size-preset circle buttons FIRST (buttons whose
	# pressed/toggled signals target a method containing "size"). They are
	# toggle buttons too and come before the shape row, so a blind "first
	# HBox with toggles" pick hooked the WRONG row: the mouse wheel presses
	# these circles programmatically, which then masqueraded as shape clicks
	# and locked the slider.
	var size_btns = []
	_collect_size_buttons(align, size_btns)
	var size_btn_ids = {}
	for b in size_btns:
		size_btn_ids[b.get_instance_id()] = true

	# Shape row (rect / circle / polygon): first HBox whose toggle buttons are
	# NOT size circles.
	_shape_hbox = null
	for child in align.get_children():
		if child is HBoxContainer:
			var toggles = []
			for btn in child.get_children():
				if btn is Button and btn.toggle_mode:
					toggles.append(btn)
			if toggles.size() == 0:
				continue
			var only_size = true
			for btn in toggles:
				if not size_btn_ids.has(btn.get_instance_id()):
					only_size = false
					break
			if only_size:
				continue
			_shape_hbox = child
			break
	_shape_buttons = []
	if _shape_hbox != null:
		for child in _shape_hbox.get_children():
			if child is Button and child.toggle_mode and not size_btn_ids.has(child.get_instance_id()):
				_shape_buttons.append(child)
				if not child.is_connected("pressed", self, "_on_dd_shape_button_pressed"):
					child.connect("pressed", self, "_on_dd_shape_button_pressed")
				# Diagnostics: what does this button drive?
				var methods = []
				for sig_name in ["pressed", "toggled"]:
					for conn in child.get_signal_connection_list(sig_name):
						var m = conn.get("method")
						if m != null:
							methods.append(String(m))
				print("[WaterSquareBucket] Hooked shape button '%s' -> %s" % [child.name, methods])
	else:
		print("[WaterSquareBucket] WARNING: water shape buttons row not found")

	# Hide DD's brush-size preset circles (replaced by the Size slider below).
	_hide_native_size_widgets(dd_tool, align, size_btns)

	# Mode row: Round (native brush) / Square / Bucket. Manual radio behavior
	# (no ButtonGroup): picking a native DD shape must be able to deselect all
	# three, and DD's shape buttons live outside any group we control.
	_normal_button = _make_mode_button(_load_icon_tex("icons/brush_round.png", 0.8), "N", \
		"Round brush (native water brush)", MODE_NORMAL)
	_square_button = _make_mode_button(_load_icon_tex("icons/brush_square.png", 0.8), "S", \
		"Square brush — paint crisp grid-aligned squares of water.\nSize slider = side in tiles (quarter-cell steps). Hold the\nbrush-erase modifier when starting a stroke to erase.\nOne stroke = one undo.", MODE_SQUARE)
	_bucket_button = _make_mode_button(_load_icon_tex("icons/bucket.png", 0.8), "B", \
		"Bucket fill — click a region bounded by the enabled barrier\ntypes (see the Stopped by options) to fill it with water.\nIslands inside the region stay dry. Hold the brush-erase\nmodifier while clicking to remove water from the region instead.", MODE_BUCKET)

	var row = HBoxContainer.new()
	row.name = "WaterBrushModeRow"
	row.alignment = BoxContainer.ALIGN_BEGIN
	row.add_child(_normal_button)
	row.add_child(_square_button)
	row.add_child(_bucket_button)
	align.add_child(row)
	align.move_child(row, 0)

	# "Size" slider row (drives the native brush size in Round mode, the
	# square side in Square mode; locked in Bucket mode).
	_size_row = HBoxContainer.new()
	_size_row.name = "WaterBrushSizeRow"
	_size_label = Label.new()
	_size_label.text = "Size:"
	_size_row.add_child(_size_label)
	_size_slider = HSlider.new()
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_size_slider.min_value = ROUND_MIN
	_size_slider.max_value = ROUND_MAX
	_size_slider.step = 1.0
	_size_slider.value = _round_size_display()
	_size_slider.connect("value_changed", self, "_on_size_slider_changed")
	_size_row.add_child(_size_slider)
	_size_spin = SpinBox.new()
	_size_spin.min_value = ROUND_MIN
	_size_spin.max_value = ROUND_MAX
	_size_spin.step = 1.0
	_size_spin.value = _size_slider.value
	_size_spin.rounded = false
	_size_spin.connect("value_changed", self, "_on_size_spin_changed")
	_size_row.add_child(_size_spin)
	align.add_child(_size_row)
	align.move_child(_size_row, row.get_index() + 1)

	# "Stopped by" block (label + checkbox row, visible only in Bucket mode).
	_opts_hbox = VBoxContainer.new()
	_opts_hbox.name = "WaterBucketStoppedByBlock"
	_opts_hbox.visible = false
	var lbl_sb = Label.new()
	lbl_sb.text = "Stopped by:"
	_opts_hbox.add_child(lbl_sb)
	var cb_row = HBoxContainer.new()
	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	cb_row.add_child(_cb_walls)
	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = true
	cb_row.add_child(_cb_paths)
	_cb_patterns = CheckBox.new()
	_cb_patterns.text = "Patterns"
	_cb_patterns.pressed = false
	cb_row.add_child(_cb_patterns)
	_opts_hbox.add_child(cb_row)
	align.add_child(_opts_hbox)
	align.move_child(_opts_hbox, _size_row.get_index() + 1)

	_ui_guard = true
	_normal_button.pressed = true
	_ui_guard = false
	print("[WaterSquareBucket] Mode row injected (%d DD shape buttons hooked)" % _shape_buttons.size())


# Hide DD's native brush-size preset circles. The pre-collected size buttons
# (signal heuristic) are the primary source; the tool's Controls dictionary
# (any key containing "size") is the fallback. Diagnostics are printed so
# misdetections can be reported and refined.
func _hide_native_size_widgets(dd_tool, align, size_btns: Array):
	var hidden = 0
	var parents = {}
	for b in size_btns:
		var p = b.get_parent()
		if p != null and p is Control:
			parents[p.get_instance_id()] = p
	for pid in parents.keys():
		parents[pid].visible = false
		hidden += 1
		print("[WaterSquareBucket] Hidden size row via signal heuristic: ", parents[pid].name)
	if hidden == 0:
		var ctrls = dd_tool.get("Controls")
		if ctrls != null and ctrls is Dictionary:
			var keys = []
			for k in ctrls.keys():
				keys.append(String(k))
			print("[WaterSquareBucket] Tool Controls keys: ", keys)
			for k in ctrls.keys():
				if "size" in String(k).to_lower():
					var c = ctrls[k]
					if c != null and c is Control and is_instance_valid(c):
						var target = c
						var par = target.get_parent()
						if par is HBoxContainer and not (target is Container):
							target = par
						target.visible = false
						hidden += 1
						print("[WaterSquareBucket] Hidden size control via Controls['%s']" % String(k))
	if hidden == 0:
		print("[WaterSquareBucket] WARNING: native size circles not found (left visible)")


func _collect_size_buttons(node, out: Array):
	if node == null or not is_instance_valid(node) or not (node is Node):
		return
	if node is BaseButton:
		for sig_name in ["pressed", "toggled"]:
			for conn in node.get_signal_connection_list(sig_name):
				var m = conn.get("method")
				if m != null and "size" in String(m).to_lower():
					out.append(node)
					return
	for child in node.get_children():
		_collect_size_buttons(child, out)


func _make_mode_button(tex, fallback_text: String, tip: String, mode: int) -> Button:
	var b = Button.new()
	b.toggle_mode = true
	b.hint_tooltip = tip
	b.focus_mode = Control.FOCUS_NONE
	b.rect_min_size = Vector2(30, 27)
	if tex != null:
		b.icon = tex
	else:
		b.text = fallback_text
	b.connect("toggled", self, "_on_mode_toggled", [mode])
	return b


# ── Size slider ──────────────────────────────────────────────────────────────

func _round_size_display() -> float:
	var dd_tool = _g.Editor.Tools["WaterBrush"]
	if dd_tool != null:
		var sz = dd_tool.get("Size")
		if sz != null:
			return clamp(float(int(sz) + 1), ROUND_MIN, ROUND_MAX)
	return 2.0


func _apply_slider_for_mode(mode: int):
	if _size_slider == null: return
	_slider_guard = true
	if mode == MODE_SQUARE:
		_size_slider.min_value = 0.25
		_size_slider.max_value = 8.0
		_size_slider.step = 0.25
		_size_spin.min_value = 0.25
		_size_spin.max_value = 8.0
		_size_spin.step = 0.25
		_size_slider.value = _square_saved_tiles
		_size_spin.value = _square_saved_tiles
	elif mode == MODE_NORMAL:
		_size_slider.min_value = ROUND_MIN
		_size_slider.max_value = ROUND_MAX
		_size_slider.step = 1.0
		_size_spin.min_value = ROUND_MIN
		_size_spin.max_value = ROUND_MAX
		_size_spin.step = 1.0
		var v = _round_size_display()
		_size_slider.value = v
		_size_spin.value = v
	_slider_guard = false
	_set_size_row_locked(mode == MODE_BUCKET or mode == MODE_DDSHAPE)


func _set_size_row_locked(locked: bool):
	var col = Color(1, 1, 1, 0.35) if locked else Color(1, 1, 1, 1)
	if _size_row != null and is_instance_valid(_size_row):
		_size_row.modulate = col
	if _size_slider != null:
		_size_slider.editable = not locked
	if _size_spin != null:
		_size_spin.editable = not locked


func _on_size_slider_changed(v: float):
	if _slider_guard: return
	_slider_guard = true
	if _size_spin != null:
		_size_spin.value = v
	_slider_guard = false
	_on_size_value_applied(v)


func _on_size_spin_changed(v: float):
	if _slider_guard: return
	_slider_guard = true
	if _size_slider != null:
		_size_slider.value = v
	_slider_guard = false
	_on_size_value_applied(v)


func _on_size_value_applied(v: float):
	if _mode == MODE_NORMAL:
		var dd_tool = _g.Editor.Tools["WaterBrush"]
		if dd_tool != null:
			dd_tool.set("Size", int(round(v)) - 1)  # setter updates radius + cursor
	elif _mode == MODE_SQUARE:
		_square_saved_tiles = v


# Nudge the size by one slider step (mouse wheel in Square mode).
func _wheel_size(dir: int):
	if _size_slider == null: return
	_size_slider.value = _size_slider.value + _size_slider.step * dir


# ── Mode switching ───────────────────────────────────────────────────────────
# Round means BRUSH: selecting it releases every DD shape button and forces
# the tool back to brush mode (UpdateBrushRadius clears IsUsingShapes).
# Picking a DD shape button deselects all three of our buttons (MODE_DDSHAPE).

func _mode_button(mode: int) -> Button:
	if mode == MODE_NORMAL: return _normal_button
	if mode == MODE_SQUARE: return _square_button
	if mode == MODE_BUCKET: return _bucket_button
	return null


func _release_our_buttons(except_mode: int):
	for m in [MODE_NORMAL, MODE_SQUARE, MODE_BUCKET]:
		if m == except_mode: continue
		var b = _mode_button(m)
		if b != null and is_instance_valid(b) and b.pressed:
			b.pressed = false


func _release_dd_buttons():
	for btn in _shape_buttons:
		if is_instance_valid(btn) and btn.pressed:
			btn.pressed = false


func _on_dd_shape_button_pressed():
	# The user picked a native DD shape: deselect our three buttons and step
	# aside (DD's own handler set the shape mode).
	if _ui_guard: return
	_ui_guard = true
	_release_our_buttons(-1)
	_ui_guard = false
	_set_mode(MODE_DDSHAPE)


func _on_mode_toggled(pressed: bool, mode: int):
	if _ui_guard:
		return
	if not pressed:
		# Manual radio: clicking the active button again must not leave a dead
		# state — re-press it.
		if _mode == mode:
			_ui_guard = true
			var b = _mode_button(mode)
			if b != null:
				b.pressed = true
			_ui_guard = false
		return
	_ui_guard = true
	_release_our_buttons(mode)
	_release_dd_buttons()
	_ui_guard = false
	_set_mode(mode)


func _set_mode(mode: int):
	_mode = mode
	_square_active = (mode == MODE_SQUARE)
	_bucket_active = (mode == MODE_BUCKET)
	if _opts_hbox != null:
		_opts_hbox.visible = _bucket_active

	if _square_active:
		_hide_dd_cursor()
		_create_hover_preview()
	else:
		_end_stroke_abort()
		_remove_hover_preview()

	if not _bucket_active:
		_clear_bucket_cursor()

	if mode == MODE_NORMAL and _is_water_tool_active():
		# Force the native tool back to brush mode + show the size circle.
		var dd_tool = _g.Editor.Tools["WaterBrush"]
		if dd_tool != null:
			dd_tool.call("UpdateBrushRadius")  # IsUsingShapes = false + radius
		var world_ui = _g.get("WorldUI")
		if world_ui != null:
			world_ui.set("CursorMode", CURSOR_CIRCLE)
		_saved_cursor_mode = -1

	_apply_slider_for_mode(mode)
	print("[WaterSquareBucket] Mode: ", mode)


# ── DD cursor ────────────────────────────────────────────────────────────────

func _hide_dd_cursor():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var cur = world_ui.get("CursorMode")
	if cur != null and cur != 0:
		_saved_cursor_mode = cur
	world_ui.set("CursorMode", 0)


func _restore_dd_cursor():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	if _saved_cursor_mode >= 0:
		world_ui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1


func _set_bucket_cursor():
	if _bucket_cursor_active: return
	if _bucket_cursor_tex == null: return
	var sz = _bucket_cursor_tex.get_size()
	var hotspot = Vector2(sz.x * BUCKET_CURSOR_HOTSPOT_FRAC.x, sz.y * BUCKET_CURSOR_HOTSPOT_FRAC.y)
	Input.set_custom_mouse_cursor(_bucket_cursor_tex, Input.CURSOR_ARROW, hotspot)
	_bucket_cursor_active = true


func _clear_bucket_cursor():
	if not _bucket_cursor_active: return
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	_bucket_cursor_active = false


# ── Hover preview (yellow square under the cursor) ───────────────────────────

func _create_hover_preview():
	if _hover_preview != null: return
	_hover_preview = Line2D.new()
	_hover_preview.name = "WaterSquareBrushPreview"
	_hover_preview.width = 2.0
	_hover_preview.default_color = Color(1.0, 1.0, 0.0, 0.9)
	_hover_preview.z_index = 4096
	_hover_preview.z_as_relative = false
	_hover_preview.points = PoolVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var world = _g.get("World")
	if world != null and world is Node:
		world.add_child(_hover_preview)
	else:
		_g.Editor.get_tree().get_root().add_child(_hover_preview)


func _remove_hover_preview():
	if _hover_preview != null:
		if is_instance_valid(_hover_preview):
			_hover_preview.queue_free()
		_hover_preview = null


func _update_hover_preview():
	if _hover_preview == null or not is_instance_valid(_hover_preview): return
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var mouse = world_ui.get("MousePosition")
	if mouse == null:
		_hover_preview.visible = false
		return
	var s = _square_size()
	var tl = _square_top_left(mouse, s)
	_hover_preview.visible = true
	_hover_preview.points = PoolVector2Array([
		tl, tl + Vector2(s, 0), tl + Vector2(s, s), tl + Vector2(0, s), tl
	])
	var vp = world_ui.get_viewport()
	if vp != null:
		var zoom = vp.get_canvas_transform().get_scale().x
		if zoom > 0:
			_hover_preview.width = 2.0 / zoom


# ── Square geometry / snapping ───────────────────────────────────────────────

func _grid_cell() -> float:
	var world_ui = _g.get("WorldUI")
	if world_ui != null:
		var cell = world_ui.get("CellSize")
		if cell != null and cell is Vector2 and cell.x > 0:
			return float(cell.x)
	return 256.0


func _square_size() -> float:
	var tiles = _square_saved_tiles
	if _size_slider != null and _mode == MODE_SQUARE:
		tiles = _size_slider.value
	return max(1.0, tiles * _grid_cell())


# Top-left corner of the stamped square for a given cursor position.
# Snappy Mod's custom snap (when enabled) positions the square CENTER on the
# nearest custom snap point; otherwise the corner aligns to the quarter-cell
# lattice (64 px on a standard 256 px grid).
func _square_top_left(mouse: Vector2, s: float) -> Vector2:
	var snappy = _get_snappy_mod()
	if snappy and snappy.has_method("get_snapped_position") and snappy.get("custom_snap_enabled"):
		var center = snappy.get_snapped_position(mouse)
		return center - Vector2(s, s) * 0.5
	var q = _grid_cell() * 0.25
	var c = mouse - Vector2(s, s) * 0.5
	return Vector2(floor(c.x / q + 0.5) * q, floor(c.y / q + 0.5) * q)


func _get_snappy_mod():
	if _snappy_ref != null:
		return _snappy_ref
	if _snappy_searched:
		return null
	_snappy_searched = true
	var api = _g.get("API")
	if api and typeof(api) == TYPE_OBJECT:
		var s = api.get("snappy_mod")
		if s and s.has_method("get_snapped_position"):
			_snappy_ref = s
			return s
	var toolset = _g.Editor.get("Toolset")
	if toolset:
		var toolbars = toolset.get("Toolbars")
		if toolbars and toolbars is Dictionary:
			for key in toolbars.keys():
				var toolbar = toolbars[key]
				if toolbar is Node:
					var found = _find_snappy_from_panel(toolbar)
					if found:
						_snappy_ref = found
						return found
	return null


func _find_snappy_from_panel(node) -> Object:
	if node == null or not is_instance_valid(node) or not (node is Node):
		return null
	if node is BaseButton:
		for sig_name in ["pressed", "toggled"]:
			var connections = node.get_signal_connection_list(sig_name)
			for conn in connections:
				var target = conn.get("target")
				if target and target.has_method("get_snapped_position"):
					return target
	for child in node.get_children():
		var found = _find_snappy_from_panel(child)
		if found:
			return found
	return null


# ── Square stroke ────────────────────────────────────────────────────────────

func _begin_stroke():
	_painting = true
	_stroke_invert = Input.is_key_pressed(ERASE_KEY)
	_stroke_keys = {}
	_stroke_squares = []
	_last_stamp_mouse = null
	_create_stroke_overlay()


func _create_stroke_overlay():
	_clear_stroke_overlay()
	_preview_outers = []
	_preview_holes = []
	_stroke_overlay = Node2D.new()
	_stroke_overlay.name = "WaterSquareStrokeOverlay"
	_stroke_overlay.z_index = 4095
	_stroke_overlay.z_as_relative = false
	var world = _g.get("World")
	if world != null and world is Node:
		world.add_child(_stroke_overlay)
	else:
		_g.Editor.get_tree().get_root().add_child(_stroke_overlay)


func _clear_stroke_overlay():
	if _stroke_overlay != null:
		if is_instance_valid(_stroke_overlay):
			_stroke_overlay.queue_free()
		_stroke_overlay = null


func _stroke_color() -> Color:
	var world_ui = _g.get("WorldUI")
	if world_ui != null:
		var prop = "CursorSecondaryColor" if _stroke_invert else "CursorPrimaryColor"
		var c = world_ui.get(prop)
		if c != null and c is Color:
			return Color(c.r, c.g, c.b, 0.45)
	if _stroke_invert:
		return Color(1.0, 0.3, 0.2, 0.4)
	return Color(0.25, 0.6, 1.0, 0.4)


func _stamp_path(mouse: Vector2):
	# Interpolate along the mouse motion so fast drags leave no gaps.
	var s = _square_size()
	if _last_stamp_mouse == null:
		_stamp_at(mouse, s)
	else:
		var from: Vector2 = _last_stamp_mouse
		var dist = from.distance_to(mouse)
		var step = max(1.0, s * 0.5)
		var n = int(ceil(dist / step))
		for i in range(1, n + 1):
			_stamp_at(from.linear_interpolate(mouse, float(i) / float(n)), s)
	_last_stamp_mouse = mouse


func _stamp_at(mouse: Vector2, s: float):
	var tl = _square_top_left(mouse, s)
	var key = "%d_%d" % [int(round(tl.x)), int(round(tl.y))]
	if _stroke_keys.has(key):
		return
	_stroke_keys[key] = true
	_stroke_squares.append([tl, s])
	_preview_add_square(PoolVector2Array([tl, tl + Vector2(s, 0), tl + Vector2(s, s), tl + Vector2(0, s)]))


# Merge the stamped square into the preview ring set so overlapping stamps are
# drawn ONCE (a flat set of translucent Polygon2Ds would multiply their alpha
# in the overlap). Enclosed holes are shown as outlines only (a square painted
# back inside a hole may be momentarily swallowed by the preview — the commit
# path is exact regardless).
func _preview_add_square(sq: PoolVector2Array):
	var cur = sq
	var merged_any = true
	while merged_any:
		merged_any = false
		for i in range(_preview_outers.size()):
			var res = Geometry.merge_polygons_2d(cur, _preview_outers[i])
			var outers = []
			for r in res:
				if Geometry.is_polygon_clockwise(r):
					_preview_holes.append(r)
				else:
					outers.append(r)
			if outers.size() == 1 and res.size() != 2:
				cur = outers[0]
				_preview_outers.remove(i)
				merged_any = true
				break
			if outers.size() == 1 and res.size() == 2:
				# outer + hole: merged, the pair enclosed a hole
				cur = outers[0]
				_preview_outers.remove(i)
				merged_any = true
				break
			# 2 outers: disjoint — keep looking
	_preview_outers.append(cur)
	_rebuild_stroke_preview()


func _rebuild_stroke_preview():
	if _stroke_overlay == null or not is_instance_valid(_stroke_overlay):
		return
	for child in _stroke_overlay.get_children():
		child.queue_free()
	var col = _stroke_color()
	for ring in _preview_outers:
		var poly = Polygon2D.new()
		poly.polygon = ring
		poly.color = col
		_stroke_overlay.add_child(poly)
	var line_col = Color(col.r, col.g, col.b, 0.9)
	for hole in _preview_holes:
		var pts = Array(hole)
		if pts.size() > 0:
			pts.append(pts[0])
		var line = Line2D.new()
		line.points = PoolVector2Array(pts)
		line.width = 2.0
		line.default_color = line_col
		_stroke_overlay.add_child(line)


func _end_stroke_abort():
	_painting = false
	_stroke_keys = {}
	_stroke_squares = []
	_preview_outers = []
	_preview_holes = []
	_last_stamp_mouse = null
	_clear_stroke_overlay()


func _commit_stroke():
	_painting = false
	_preview_outers = []
	_preview_holes = []
	_clear_stroke_overlay()
	if _stroke_squares.size() == 0:
		return
	# Chain every stamped square into ONE weakly-simple ring: each square is a
	# consistently-oriented loop, spliced into the growing host at the closest
	# vertex pair with a zero-width bridge (out and back along the same
	# segment, net winding contribution zero). Clipper's NonZero fill then
	# resolves everything: overlapping squares (winding 2) stay filled,
	# disjoint groups separate cleanly, a closed loop of squares keeps its
	# enclosed center empty (winding 0).
	var host = _square_ring(_stroke_squares[0])
	for i in range(1, _stroke_squares.size()):
		host = _splice_rings(host, _square_ring(_stroke_squares[i]))
	var level = _get_current_level()
	if level == null:
		print("[WaterSquareBucket] No current level; stroke dropped")
		return
	var water_mesh = level.get("WaterMesh")
	if water_mesh == null:
		print("[WaterSquareBucket] WaterMesh not found; stroke dropped")
		return
	var bounds = _ring_bounds(host)
	water_mesh.call("AddPolygon", PoolVector2Array(host), bounds, _stroke_invert)
	_stroke_keys = {}
	_stroke_squares = []


func _square_ring(entry: Array) -> Array:
	var tl: Vector2 = entry[0]
	var s: float = entry[1]
	return [tl, tl + Vector2(s, 0), tl + Vector2(s, s), tl + Vector2(0, s)]


# Splice `ring` into `host` at the closest vertex pair, connected by a
# zero-width bridge. Works both for same-orientation rings (disjoint pieces,
# used by the square stroke) and opposite-orientation rings (holes, used by
# the bucket) — NonZero winding sorts it out either way.
func _splice_rings(host: Array, ring: Array) -> Array:
	var best_hi = 0
	var best_ri = 0
	var best_d = INF
	for hi in range(host.size()):
		var hp: Vector2 = host[hi]
		for ri in range(ring.size()):
			var d = hp.distance_squared_to(ring[ri])
			if d < best_d:
				best_d = d
				best_hi = hi
				best_ri = ri
	var res = []
	for k in range(best_hi + 1):
		res.append(host[k])
	var n = ring.size()
	for k in range(n + 1):
		res.append(ring[(best_ri + k) % n])
	res.append(host[best_hi])
	for k in range(best_hi + 1, host.size()):
		res.append(host[k])
	return res


func _ring_bounds(ring: Array) -> Rect2:
	if ring.size() == 0:
		return Rect2(0, 0, 0, 0)
	var mn: Vector2 = ring[0]
	var mx: Vector2 = ring[0]
	for p in ring:
		mn = Vector2(min(mn.x, p.x), min(mn.y, p.y))
		mx = Vector2(max(mx.x, p.x), max(mx.y, p.y))
	return Rect2(mn, mx - mn)


func _ring_signed_area(ring: Array) -> float:
	var a = 0.0
	var n = ring.size()
	for i in range(n):
		var j = (i + 1) % n
		a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
	return a * 0.5


# ── Bucket fill ──────────────────────────────────────────────────────────────

func _do_fill(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool, invert: bool):
	if _region_geo == null:
		print("[WaterSquareBucket] region_geometry unavailable; fill disabled")
		return
	if _filling:
		return
	_filling = true
	_fill_started = OS.get_ticks_msec()
	var progress = _new_progress("Filling water…")
	_active_progress = progress
	if progress != null:
		progress.set_progress(0.0, "Computing fill region\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")
	var t_start = OS.get_ticks_msec()

	# keep_holes = true: islands are spliced below with zero-width bridges.
	var region = _region_geo.compute_region_async(mouse_world, stop_walls, stop_paths, stop_patterns, progress, 0.0, 0.9, null, true)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")

	if progress != null and region.get("cancelled") == true:
		progress.close()
		print("[WaterSquareBucket] Fill cancelled by the user")
		_filling = false
		_active_progress = null
		return

	var t_compute = OS.get_ticks_msec() - t_start
	if region.outer.size() < 3:
		if progress != null: progress.close()
		print("[WaterSquareBucket] No region found (clicked on a wall?) — %d ms" % t_compute)
		_filling = false
		_active_progress = null
		return

	if progress != null:
		progress.set_progress(0.95, "Applying water\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")

	print("[WaterSquareBucket] Region: %d points, %d hole(s) — computed in %d ms" % [region.outer.size(), region.get("holes", []).size(), t_compute])
	_apply_water_fill(region.outer, region.get("holes", []), invert)

	if progress != null:
		progress.set_progress(1.0, "Done")
		yield(_g.Editor.get_tree(), "idle_frame")
		yield(_g.Editor.get_tree(), "idle_frame")
		progress.close()
	_filling = false
	_active_progress = null


func _apply_water_fill(outer: Array, holes: Array, invert: bool):
	var level = _get_current_level()
	if level == null:
		print("[WaterSquareBucket] No current level")
		return
	var water_mesh = level.get("WaterMesh")
	if water_mesh == null:
		print("[WaterSquareBucket] WaterMesh not found")
		return
	# Orientation: outer one way, holes the other, so NonZero winding inside
	# each hole nets zero (outer +1, hole -1) and islands stay dry.
	var ring = outer.duplicate()
	var outer_sign = sign(_ring_signed_area(ring))
	if outer_sign == 0:
		print("[WaterSquareBucket] Degenerate region; aborting")
		return
	for h in holes:
		if h.size() < 3:
			continue
		var hr = h.duplicate()
		if sign(_ring_signed_area(hr)) == outer_sign:
			hr.invert()
		ring = _splice_rings(ring, hr)
	water_mesh.call("AddPolygon", PoolVector2Array(ring), _ring_bounds(ring), invert)


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _square_active and not _bucket_active: return false
	if not _is_water_tool_active(): return false

	# Handle the left RELEASE before the UI guard: only consume it if WE were
	# painting (otherwise a scrollbar drag released over the canvas would get
	# its release swallowed). Ending here even over UI avoids a stuck stroke.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		if _painting:
			_commit_stroke()
			return true
		return false

	if ui_util != null and ui_util.is_mouse_over_hud(input_listener): return false

	# Mouse wheel over the canvas: Square mode resizes the square; Bucket mode
	# swallows it (DD would silently resize its hidden native brush).
	if event is InputEventMouseButton and (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN):
		if not event.pressed:
			return false
		if _square_active:
			_wheel_size(1 if event.button_index == BUTTON_WHEEL_UP else -1)
		return true

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	var mouse_w = _get_raw_mouse_world(world_ui, event)
	if mouse_w == null: return false

	if _bucket_active:
		if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
			if _filling:
				return true
			var sw = _cb_walls.pressed if _cb_walls != null else true
			var sp = _cb_paths.pressed if _cb_paths != null else true
			var spat = _cb_patterns.pressed if _cb_patterns != null else false
			_do_fill(mouse_w, sw, sp, spat, Input.is_key_pressed(ERASE_KEY))
			return true
		return false

	# Square brush (continuous painting).
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		_begin_stroke()
		_stamp_path(mouse_w)
		return true
	if event is InputEventMouseMotion and _painting:
		_stamp_path(mouse_w)
		return true
	return false


func _get_raw_mouse_world(world_ui, event):
	# Source of truth: WorldUI.MousePosition (same world-space position DD's
	# native tools use). Manual conversion of event.position drifts on some
	# configs (Retina/DPI/UI scaling).
	var mp = world_ui.get("MousePosition")
	if mp != null and mp is Vector2:
		return mp
	var vp = world_ui.get_viewport()
	if vp == null: return null
	var xform = vp.get_canvas_transform()
	return xform.affine_inverse().xform(event.position)


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _g == null: return
	var editor = _g.get("Editor")
	if editor == null or not is_instance_valid(editor): return

	if not _is_water_tool_active():
		if (_square_active or _bucket_active) and not _suspended:
			_suspended = true
			_end_stroke_abort()
			_remove_hover_preview()
			_clear_bucket_cursor()
			# Don't restore the DD cursor — the new tool manages its own.
			var world_ui = _g.get("WorldUI")
			if world_ui != null:
				world_ui.set("CursorMode", 0)
		return

	if (_square_active or _bucket_active) and _suspended:
		_suspended = false
		if _square_active:
			_create_hover_preview()

	# Round mode: keep the native tool in BRUSH mode. DD's panel starts with a
	# shape button pressed on its own (no user click, so our hook never fires):
	# release it and force brush mode back. A USER shape click switches us to
	# MODE_DDSHAPE synchronously via the pressed signal, before this runs.
	if _mode == MODE_NORMAL:
		var stray_shape = false
		for btn in _shape_buttons:
			if is_instance_valid(btn) and btn.pressed:
				btn.pressed = false
				stray_shape = true
		var wui = _g.get("WorldUI")
		if stray_shape or (wui != null and wui.get("CursorMode") == 0):
			var dd_tool = _g.Editor.Tools["WaterBrush"]
			if dd_tool != null:
				dd_tool.call("UpdateBrushRadius")  # IsUsingShapes = false
			if wui != null:
				wui.set("CursorMode", CURSOR_CIRCLE)

	# Round mode: reflect wheel-driven native size changes on the slider.
	if _mode == MODE_NORMAL and _size_slider != null and not _slider_guard:
		var want = _round_size_display()
		if abs(_size_slider.value - want) > 0.01:
			_slider_guard = true
			_size_slider.value = want
			if _size_spin != null:
				_size_spin.value = want
			_slider_guard = false

	if _square_active:
		_hide_dd_cursor()  # DD re-enables it every frame
		_update_hover_preview()
		if _hover_preview != null and is_instance_valid(_hover_preview):
			if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
				_hover_preview.visible = false

	if _bucket_active:
		_hide_dd_cursor()
		var over_ui = (ui_util != null and ui_util.is_mouse_over_hud(input_listener))
		if over_ui:
			_clear_bucket_cursor()
		else:
			_set_bucket_cursor()


# ── Listener ─────────────────────────────────────────────────────────────────

func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "WaterSquareBucketListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	# Watchdog timer (child of the listener so it lives in the SceneTree and
	# keeps ticking even when DD freezes the mod update loop behind a modal).
	var wt = Timer.new()
	wt.wait_time = 2.0
	wt.autostart = true
	node.add_child(wt)
	wt.connect("timeout", self, "_watchdog_tick")
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# Failsafe: if the fill coroutine dies from a runtime error, _filling would
# stay true forever and every bucket click would be silently swallowed. A long
# silence re-arms the bucket and force-closes any orphaned modal dialog.
func _watchdog_tick():
	if not _filling:
		return
	var alive = _fill_started
	if _active_progress != null:
		alive = max(alive, _active_progress.last_activity)
	if OS.get_ticks_msec() - alive < FILL_WATCHDOG_MS:
		return
	print("[WaterSquareBucket] WARNING: fill watchdog fired — the fill coroutine died (check the errors above). Bucket re-armed.")
	_filling = false
	if _active_progress != null:
		if _active_progress.has_method("force_close"):
			_active_progress.force_close()
		_active_progress = null


# ── Helpers ──────────────────────────────────────────────────────────────────

func _is_water_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	return editor.get("ActiveToolName") == "WaterBrush"


func _get_current_level():
	if _g == null: return null
	var world = _g.get("World")
	if world == null or not is_instance_valid(world): return null
	return world.call("GetCurrentLevel")
