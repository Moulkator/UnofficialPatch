# material_square_bucket.gd
# Square Brush + Paint Bucket + Hide Borders for the Material Tool.
#
# The Material Tool is NOT polygon-based: MaterialMesh is a marching-squares
# cell grid (128 px cells, BorderedMesh -> MarchingSquaresMesh). Everything
# here works by writing bits straight into the mesh Bitmap, between the mesh's
# own OnDrawingBegin()/OnDrawingEnd() calls — so rendering, borders AND undo
# (ChangeMesh bitmap diff) are fully native.
#
# UI mirrors the Terrain Brush layout: a radio row of 3 mode icons (Round /
# Square / Bucket) plus a Size slider replacing DD's native brush-size preset
# circles. In Round mode the slider drives the native brush size (1..7 cells,
# synced with the mouse wheel); in Square mode it is the square side in tiles
# (0.5 steps); in Bucket mode it is grayed out.
#
# Modes (radio row: Round / Square / Bucket, like the Terrain Tool):
#   Square — stamps n x n cell squares (minimum 128 px = 0.5 tile, in 0.5 tile
#     steps). Edges land on the mesh's own half-cell lattice (offset 64 px from
#     the map grid lines — a marching-squares constraint) and are slightly
#     organic because of DD's woxel vertex noise; the yellow preview shows the
#     nominal rectangle. Hold DD's brush-erase modifier when starting a stroke
#     to erase. One stroke = one undo.
#   Bucket — click a region bounded by the enabled barrier types (walls /
#     paths / patterns + map edges) to fill it with the current material.
#     The region is eroded by half a cell before rasterization so that the
#     marching-squares expansion lands the visual edge back on the region
#     boundary instead of overshooting under/past walls. Hold the erase
#     modifier while clicking to clear the region instead. Native undo.
#
# Hide Borders:
#   A per-material checkbox. MaterialMesh has no DisableBorder like water, and
#   SetBorderTexture(null) crashes DD's border loop, so borders (the Line2D
#   children DD rebuilds after every edit) are simply kept hidden every frame
#   for flagged meshes. Session-only: re-check it after reloading the map.

var _g
var ui_util
var input_listener: Node
const _META_KEY = "MaterialSquareBucketListener"

# DD's brush erase modifier scancode (same constant MaterialBrush tests).
const ERASE_KEY = 16777240

# Modes
const MODE_NORMAL = 0
const MODE_SQUARE = 1
const MODE_BUCKET = 2
var _mode := MODE_NORMAL

# WorldUI.ECursorMode value of the yellow brush circle.
const CURSOR_CIRCLE = 5

# UI
var _normal_button: Button = null
var _square_button: Button = null
var _bucket_button: Button = null
var _size_row = null
var _size_label: Label = null
var _size_slider: HSlider = null
var _size_spin: SpinBox = null
var _slider_guard := false
var _square_saved_tiles := 0.5      # square size memory across mode switches

# Native brush size range shown on the slider in Normal mode (DD Size 0..6
# rendered as 1..7 cells).
const ROUND_MIN = 1.0
const ROUND_MAX = 7.0
var _opts_hbox = null
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null
var _borders_row = null
var _cb_hide_borders: CheckBox = null
var _hide_borders_guard := false

var _square_active := false
var _bucket_active := false
var _suspended := false

# Square stroke state
var _painting := false
var _stroke_value := true          # false when erasing
var _stroke_mesh = null
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

# Meshes whose borders are hidden: instance_id -> weakref(mesh)
var _hidden_border_meshes := {}


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	var geo_script = ResourceLoader.load(_g.Root + "library/region_geometry.gd", "GDScript", true)
	if geo_script != null:
		_region_geo = geo_script.new()
		_region_geo._g = _g
	else:
		print("[MaterialSquareBucket] WARNING: could not load library/region_geometry.gd; bucket fill disabled")
	_progress_script = ResourceLoader.load(_g.Root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		print("[MaterialSquareBucket] WARNING: library/progress_dialog.gd not found; no progress bar")
	_bucket_cursor_tex = _load_icon_tex("icons/bucket_cursor.png")
	_inject_ui()
	_install_listener()
	print("[MaterialSquareBucket] initialized")


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
		print("[MaterialSquareBucket] icon not found: %s" % rel)
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
	var dd_tool = _g.Editor.Tools["MaterialBrush"]
	var tool_panel = _g.Editor.Toolset.GetToolPanel("MaterialBrush")
	if dd_tool == null or tool_panel == null:
		print("[MaterialSquareBucket] MaterialBrush tool/panel not found")
		return
	var align = tool_panel.get("Align")
	if align == null:
		print("[MaterialSquareBucket] Align not found")
		return

	# Hide DD's brush-size preset circles (replaced by the Size slider below).
	_hide_native_size_widgets(dd_tool, align)

	# Radio mode row: Normal (round brush) / Square / Bucket.
	var grp = ButtonGroup.new()
	_normal_button = _make_mode_button(_load_icon_tex("icons/brush_round.png", 0.8), "N", \
		"Round brush (native material brush)", grp, MODE_NORMAL)
	_square_button = _make_mode_button(_load_icon_tex("icons/brush_square.png", 0.8), "S", \
		"Square brush — stamps square cells of material.\nSize slider = side in tiles (0.5 tile steps, minimum 0.5 tile). Edges follow the material grid (offset half a\ncell from the map grid) and keep DD's organic woxel look.\nHold the brush-erase modifier when starting a stroke to erase.", grp, MODE_SQUARE)
	_bucket_button = _make_mode_button(_load_icon_tex("icons/bucket.png", 0.8), "B", \
		"Bucket fill — click a region bounded by the enabled barrier types\n(see the Stopped by options) to fill it with the current material.\nHold the brush-erase modifier while clicking to clear the region.", grp, MODE_BUCKET)

	var row = HBoxContainer.new()
	row.name = "MaterialBrushModeRow"
	row.alignment = BoxContainer.ALIGN_BEGIN
	row.add_child(_normal_button)
	row.add_child(_square_button)
	row.add_child(_bucket_button)
	align.add_child(row)
	align.move_child(row, 0)

	# "Size" slider row (drives the native brush size in Round mode, the
	# square side in Square mode; locked in Bucket mode).
	_size_row = HBoxContainer.new()
	_size_row.name = "MaterialBrushSizeRow"
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
	_opts_hbox.name = "MaterialBucketStoppedByBlock"
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

	# "Hide borders" row (always visible).
	_borders_row = HBoxContainer.new()
	_borders_row.name = "MaterialHideBordersRow"
	_cb_hide_borders = CheckBox.new()
	_cb_hide_borders.text = "Hide borders (this material)"
	_cb_hide_borders.hint_tooltip = "Hides the border strips of the CURRENT layer + material mesh\n(the *_border.png outline). Session-only: not saved in the map,\nre-check it after reloading. Applies to display and export."
	_cb_hide_borders.connect("toggled", self, "_on_hide_borders_toggled")
	_borders_row.add_child(_cb_hide_borders)
	align.add_child(_borders_row)
	align.move_child(_borders_row, _opts_hbox.get_index() + 1)

	_normal_button.pressed = true
	print("[MaterialSquareBucket] Mode row injected")


func _make_mode_button(tex, fallback_text: String, tip: String, grp: ButtonGroup, mode: int) -> Button:
	var b = Button.new()
	b.toggle_mode = true
	b.group = grp
	b.hint_tooltip = tip
	b.focus_mode = Control.FOCUS_NONE
	b.rect_min_size = Vector2(30, 27)
	if tex != null:
		b.icon = tex
	else:
		b.text = fallback_text
	b.connect("toggled", self, "_on_mode_toggled", [mode])
	return b


func _on_mode_toggled(pressed: bool, mode: int):
	if not pressed:
		return
	_set_mode(mode)


func _set_mode(mode: int):
	_mode = mode
	_square_active = (mode == MODE_SQUARE)
	_bucket_active = (mode == MODE_BUCKET)
	if _opts_hbox != null:
		_opts_hbox.visible = _bucket_active
	_apply_slider_for_mode(mode)
	if _square_active:
		_hide_dd_cursor()
		_create_hover_preview()
	else:
		_end_stroke_abort()
		_remove_hover_preview()
	if _bucket_active:
		_hide_dd_cursor()
	else:
		_clear_bucket_cursor()
	if mode == MODE_NORMAL:
		_restore_dd_cursor()
	print("[MaterialSquareBucket] Mode: ", mode)


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
	elif _is_material_tool_active():
		world_ui.set("CursorMode", CURSOR_CIRCLE)


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


# ── Mesh access / cell math ──────────────────────────────────────────────────

func _get_active_mesh():
	var dd_tool = _g.Editor.Tools["MaterialBrush"]
	if dd_tool == null: return null
	var tex = dd_tool.get("Texture")
	if tex == null: return null
	var level = _get_current_level()
	if level == null: return null
	var layer = dd_tool.get("ActiveLayer")
	if layer == null: layer = -400
	var smooth = dd_tool.get("Smooth")
	if smooth == null: smooth = false
	# Same call DD's own SetMaterial makes (creates the mesh if missing).
	return level.call("GetOrMakeMaterialMesh", int(layer), tex, bool(smooth))


func _mesh_cell_size(mesh) -> float:
	var cs = mesh.get("CellSize")
	if cs != null and float(cs) > 0:
		return float(cs)
	return 128.0


func _mesh_edge_buffer(mesh) -> int:
	var b = mesh.get("MapEdgeBuffer")
	if b != null:
		return int(b)
	return 1


# Number of cells per stamped square side.
func _square_cells(mesh) -> int:
	var tiles = _square_saved_tiles
	if _size_slider != null and _mode == MODE_SQUARE:
		tiles = _size_slider.value
	var cell = _mesh_cell_size(mesh)
	var grid = 256.0
	var world_ui = _g.get("WorldUI")
	if world_ui != null:
		var gc = world_ui.get("CellSize")
		if gc != null and gc is Vector2 and gc.x > 0:
			grid = float(gc.x)
	return int(max(1, round(tiles * grid / cell)))


# Top-left NODE index of the n x n node block whose rendered square (which
# extends half a cell around the set nodes) best matches the cursor.
func _square_node_origin(mesh, mouse: Vector2, n: int) -> Vector2:
	var cs = _mesh_cell_size(mesh)
	var buf = _mesh_edge_buffer(mesh)
	var half = float(n) * cs * 0.5
	var ax = int(round((mouse.x - half) / cs + 0.5)) + buf
	var ay = int(round((mouse.y - half) / cs + 0.5)) + buf
	return Vector2(ax, ay)


# World-space rendered rect of the node block [a .. a+n-1] (marching squares
# fills half a cell around every set node).
func _node_block_world_rect(mesh, origin: Vector2, n: int) -> Rect2:
	var cs = _mesh_cell_size(mesh)
	var buf = _mesh_edge_buffer(mesh)
	var tl = Vector2((origin.x - 0.5 - buf) * cs, (origin.y - 0.5 - buf) * cs)
	return Rect2(tl, Vector2(n, n) * cs)


func _set_node_block(mesh, origin: Vector2, n: int, value: bool) -> bool:
	var bm = mesh.get("Bitmap")
	if bm == null: return false
	var w = int(mesh.get("MapWidth"))
	var h = int(mesh.get("MapHeight"))
	var changed = false
	for y in range(int(origin.y), int(origin.y) + n):
		if y < 0 or y >= h: continue
		for x in range(int(origin.x), int(origin.x) + n):
			if x < 0 or x >= w: continue
			var p = Vector2(x, y)
			if bm.get_bit(p) != value:
				bm.set_bit(p, value)
				changed = true
	return changed


# ── Size slider ──────────────────────────────────────────────────────────────

func _round_size_display() -> float:
	var dd_tool = _g.Editor.Tools["MaterialBrush"]
	if dd_tool != null:
		var sz = dd_tool.get("Size")
		if sz != null:
			return clamp(float(int(sz) + 1), ROUND_MIN, ROUND_MAX)
	return 2.0


func _apply_slider_for_mode(mode: int):
	if _size_slider == null: return
	_slider_guard = true
	if mode == MODE_SQUARE:
		_size_slider.min_value = 0.5
		_size_slider.max_value = 8.0
		_size_slider.step = 0.5
		_size_spin.min_value = 0.5
		_size_spin.max_value = 8.0
		_size_spin.step = 0.5
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
	_set_size_row_locked(mode == MODE_BUCKET)


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
		var dd_tool = _g.Editor.Tools["MaterialBrush"]
		if dd_tool != null:
			dd_tool.set("Size", int(round(v)) - 1)  # setter updates radius + cursor
	elif _mode == MODE_SQUARE:
		_square_saved_tiles = v


# Nudge the size by one slider step (mouse wheel in Square mode).
func _wheel_size(dir: int):
	if _size_slider == null: return
	_size_slider.value = _size_slider.value + _size_slider.step * dir


# Hide DD's native brush-size preset circles. Two strategies, with diagnostics
# printed so misdetections can be reported and refined:
#   1) the tool's Controls dictionary (any key containing "size"),
#   2) buttons whose pressed/toggled signal targets a method containing "size".
func _hide_native_size_widgets(dd_tool, align):
	var hidden = 0
	var ctrls = dd_tool.get("Controls")
	if ctrls != null and ctrls is Dictionary:
		var keys = []
		for k in ctrls.keys():
			keys.append(String(k))
		print("[MaterialSquareBucket] Tool Controls keys: ", keys)
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
					print("[MaterialSquareBucket] Hidden size control via Controls['%s']" % String(k))
	if hidden == 0:
		var btns = []
		_collect_size_buttons(align, btns)
		var parents = {}
		for b in btns:
			var p = b.get_parent()
			if p != null and p is Control:
				parents[p.get_instance_id()] = p
		for pid in parents.keys():
			parents[pid].visible = false
			hidden += 1
			print("[MaterialSquareBucket] Hidden size row via signal heuristic: ", parents[pid].name)
	if hidden == 0:
		print("[MaterialSquareBucket] WARNING: native size circles not found (left visible)")


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


# ── Hover preview (yellow square under the cursor) ───────────────────────────

func _create_hover_preview():
	if _hover_preview != null: return
	_hover_preview = Line2D.new()
	_hover_preview.name = "MaterialSquareBrushPreview"
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
	var mesh = _get_active_mesh()
	if mesh == null:
		_hover_preview.visible = false
		return
	var n = _square_cells(mesh)
	var origin = _square_node_origin(mesh, mouse, n)
	var r = _node_block_world_rect(mesh, origin, n)
	_hover_preview.visible = true
	_hover_preview.points = PoolVector2Array([
		r.position,
		r.position + Vector2(r.size.x, 0),
		r.position + r.size,
		r.position + Vector2(0, r.size.y),
		r.position
	])
	var vp = world_ui.get_viewport()
	if vp != null:
		var zoom = vp.get_canvas_transform().get_scale().x
		if zoom > 0:
			_hover_preview.width = 2.0 / zoom


# ── Square stroke ────────────────────────────────────────────────────────────

func _begin_stroke() -> bool:
	var mesh = _get_active_mesh()
	if mesh == null:
		print("[MaterialSquareBucket] No material selected; stroke ignored")
		return false
	_stroke_mesh = mesh
	_stroke_value = not Input.is_key_pressed(ERASE_KEY)
	_last_stamp_mouse = null
	_painting = true
	mesh.call("OnDrawingBegin")
	return true


func _stamp_path(mouse: Vector2):
	if _stroke_mesh == null or not is_instance_valid(_stroke_mesh):
		_end_stroke_abort()
		return
	var n = _square_cells(_stroke_mesh)
	var cs = _mesh_cell_size(_stroke_mesh)
	var changed = false
	if _last_stamp_mouse == null:
		changed = _set_node_block(_stroke_mesh, _square_node_origin(_stroke_mesh, mouse, n), n, _stroke_value)
	else:
		var from: Vector2 = _last_stamp_mouse
		var dist = from.distance_to(mouse)
		var step = max(1.0, float(n) * cs * 0.5)
		var count = int(ceil(dist / step))
		for i in range(1, count + 1):
			var p = from.linear_interpolate(mouse, float(i) / float(count))
			if _set_node_block(_stroke_mesh, _square_node_origin(_stroke_mesh, p, n), n, _stroke_value):
				changed = true
	_last_stamp_mouse = mouse
	if changed:
		_stroke_mesh.call("ForceUpdateMesh")


func _end_stroke_abort():
	# Close any half-open native drawing session so undo state stays sane.
	if _painting and _stroke_mesh != null and is_instance_valid(_stroke_mesh):
		_stroke_mesh.call("OnDrawingEnd")
	_painting = false
	_stroke_mesh = null
	_last_stamp_mouse = null


func _commit_stroke():
	if _stroke_mesh != null and is_instance_valid(_stroke_mesh):
		_stroke_mesh.call("OnDrawingEnd")  # records the native ChangeMesh undo
	_painting = false
	_stroke_mesh = null
	_last_stamp_mouse = null


# ── Bucket fill ──────────────────────────────────────────────────────────────

func _do_fill(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool, value: bool):
	if _region_geo == null:
		print("[MaterialSquareBucket] region_geometry unavailable; fill disabled")
		return
	if _filling:
		return
	var mesh = _get_active_mesh()
	if mesh == null:
		print("[MaterialSquareBucket] No material selected; fill ignored")
		return
	_filling = true
	_fill_started = OS.get_ticks_msec()
	var progress = _new_progress("Filling material…")
	_active_progress = progress
	if progress != null:
		progress.set_progress(0.0, "Computing fill region\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")
	var t_start = OS.get_ticks_msec()

	var region = _region_geo.compute_region_async(mouse_world, stop_walls, stop_paths, stop_patterns, progress, 0.0, 0.85, null, true)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")

	if progress != null and region.get("cancelled") == true:
		progress.close()
		print("[MaterialSquareBucket] Fill cancelled by the user")
		_filling = false
		_active_progress = null
		return

	var t_compute = OS.get_ticks_msec() - t_start
	if region.outer.size() < 3:
		if progress != null: progress.close()
		print("[MaterialSquareBucket] No region found (clicked on a wall?) — %d ms" % t_compute)
		_filling = false
		_active_progress = null
		return

	print("[MaterialSquareBucket] Region: %d points, %d hole(s) — computed in %d ms" % [region.outer.size(), region.get("holes", []).size(), t_compute])

	var st = _rasterize_region_to_mesh(mesh, region.outer, region.get("holes", []), value, progress)
	if st is GDScriptFunctionState:
		yield(st, "completed")

	if progress != null:
		progress.set_progress(1.0, "Done")
		yield(_g.Editor.get_tree(), "idle_frame")
		yield(_g.Editor.get_tree(), "idle_frame")
		progress.close()
	_filling = false
	_active_progress = null


# Erode the region by half a cell (marching squares re-expands the rendered
# surface by half a cell around every set node, so the visual edge lands back
# on the region boundary), then scanline-rasterize node centers (even-odd
# across outer + holes) into the mesh bitmap. Undo is native (ChangeMesh).
func _rasterize_region_to_mesh(mesh, outer: Array, holes: Array, value: bool, progress):
	var cs = _mesh_cell_size(mesh)
	var buf = _mesh_edge_buffer(mesh)
	var w = int(mesh.get("MapWidth"))
	var h = int(mesh.get("MapHeight"))
	var half = cs * 0.5

	var rings = []
	var eroded = Geometry.offset_polygon_2d(PoolVector2Array(outer), -half)
	for r in eroded:
		if r.size() >= 3:
			rings.append(r)
	if rings.size() == 0:
		print("[MaterialSquareBucket] Region too thin for the material grid (< 1 cell)")
		return
	for hring in holes:
		if hring.size() < 3:
			continue
		var grown = Geometry.offset_polygon_2d(PoolVector2Array(hring), half)
		for r in grown:
			if r.size() >= 3:
				rings.append(r)

	# Bounding box of the eroded outers, in node indices.
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for r in eroded:
		for p in r:
			mn = Vector2(min(mn.x, p.x), min(mn.y, p.y))
			mx = Vector2(max(mx.x, p.x), max(mx.y, p.y))
	var x0 = int(max(0, floor(mn.x / cs) + buf - 1))
	var x1 = int(min(w - 1, ceil(mx.x / cs) + buf + 1))
	var y0 = int(max(0, floor(mn.y / cs) + buf - 1))
	var y1 = int(min(h - 1, ceil(mx.y / cs) + buf + 1))

	var bm = mesh.get("Bitmap")
	if bm == null:
		print("[MaterialSquareBucket] Mesh bitmap unavailable")
		return
	mesh.call("OnDrawingBegin")

	var tree = _g.Editor.get_tree()
	var rows_total = max(1, y1 - y0 + 1)
	var changed = false
	for y in range(y0, y1 + 1):
		var wy = (float(y) - buf) * cs
		# Even-odd scanline: gather all ring crossings at this node row.
		var xs = []
		for r in rings:
			var rn = r.size()
			for i in range(rn):
				var a: Vector2 = r[i]
				var b: Vector2 = r[(i + 1) % rn]
				if (a.y > wy) != (b.y > wy):
					xs.append(a.x + (wy - a.y) * (b.x - a.x) / (b.y - a.y))
		if xs.size() >= 2:
			xs.sort()
			var k = 0
			while k + 1 < xs.size():
				var nx0 = int(max(x0, ceil(xs[k] / cs + buf)))
				var nx1 = int(min(x1, floor(xs[k + 1] / cs + buf)))
				for x in range(nx0, nx1 + 1):
					var p = Vector2(x, y)
					if bm.get_bit(p) != value:
						bm.set_bit(p, value)
						changed = true
				k += 2
		if progress != null and (y - y0) % 16 == 15 and progress.pump():
			progress.set_progress(0.85 + 0.13 * float(y - y0) / float(rows_total), "Applying material\u2026")
			yield(tree, "idle_frame")
			if progress.cancelled:
				break

	mesh.call("ForceUpdateMesh")
	mesh.call("OnDrawingEnd")
	if not changed:
		print("[MaterialSquareBucket] Fill produced no change")


# ── Hide Borders ─────────────────────────────────────────────────────────────

func _on_hide_borders_toggled(pressed: bool):
	if _hide_borders_guard:
		return
	var mesh = _get_active_mesh()
	if mesh == null:
		print("[MaterialSquareBucket] No material selected")
		return
	var mid = mesh.get_instance_id()
	if pressed:
		_hidden_border_meshes[mid] = weakref(mesh)
		_apply_border_visibility(mesh, false)
	else:
		_hidden_border_meshes.erase(mid)
		_apply_border_visibility(mesh, true)
	print("[MaterialSquareBucket] Borders %s for current material mesh" % ("hidden" if pressed else "shown"))


func _apply_border_visibility(mesh, visible: bool):
	if mesh == null or not is_instance_valid(mesh): return
	for child in mesh.get_children():
		if child is Line2D:
			child.visible = visible


# Keep flagged meshes' borders hidden (DD rebuilds the Line2D strips after
# every edit) and sync the checkbox to the currently selected mesh.
func _maintain_hidden_borders():
	var dead = []
	for mid in _hidden_border_meshes.keys():
		var mesh = _hidden_border_meshes[mid].get_ref()
		if mesh == null or not is_instance_valid(mesh):
			dead.append(mid)
			continue
		_apply_border_visibility(mesh, false)
	for mid in dead:
		_hidden_border_meshes.erase(mid)


func _sync_hide_borders_checkbox():
	if _cb_hide_borders == null: return
	var mesh = _get_active_mesh()
	var should = false
	if mesh != null:
		should = _hidden_border_meshes.has(mesh.get_instance_id())
	if _cb_hide_borders.pressed != should:
		_hide_borders_guard = true
		_cb_hide_borders.pressed = should
		_hide_borders_guard = false


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _square_active and not _bucket_active: return false
	if not _is_material_tool_active(): return false

	# Handle the left RELEASE before the UI guard: only consume it if WE were
	# painting (see terrain_paint_bucket for the scrollbar-drag rationale).
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
			_do_fill(mouse_w, sw, sp, spat, not Input.is_key_pressed(ERASE_KEY))
			return true
		return false

	# Square brush (continuous painting).
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		if _begin_stroke():
			_stamp_path(mouse_w)
		return true
	if event is InputEventMouseMotion and _painting:
		_stamp_path(mouse_w)
		return true
	return false


func _get_raw_mouse_world(world_ui, event):
	# Source of truth: WorldUI.MousePosition (Retina/DPI-safe, matches DD's
	# native tools). Manual conversion is only the historical fallback.
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

	_maintain_hidden_borders()

	if not _is_material_tool_active():
		if (_square_active or _bucket_active) and not _suspended:
			_suspended = true
			_end_stroke_abort()
			_remove_hover_preview()
			_clear_bucket_cursor()
			var world_ui = _g.get("WorldUI")
			if world_ui != null:
				world_ui.set("CursorMode", 0)
		return

	if (_square_active or _bucket_active) and _suspended:
		_suspended = false
		if _square_active:
			_create_hover_preview()

	_sync_hide_borders_checkbox()

	# Round mode: make sure the yellow size circle is visible (on the first
	# activation of the tool DD may come up without it).
	if _mode == MODE_NORMAL:
		var wui = _g.get("WorldUI")
		if wui != null and wui.get("CursorMode") == 0:
			var dd_tool = _g.Editor.Tools["MaterialBrush"]
			if dd_tool != null:
				dd_tool.call("UpdateBrushRadius")
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
	node.name = "MaterialSquareBucketListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	var wt = Timer.new()
	wt.wait_time = 2.0
	wt.autostart = true
	node.add_child(wt)
	wt.connect("timeout", self, "_watchdog_tick")
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# Failsafe: re-arm the bucket if the fill coroutine dies (see the terrain and
# pattern buckets for the rationale).
func _watchdog_tick():
	if not _filling:
		return
	var alive = _fill_started
	if _active_progress != null:
		alive = max(alive, _active_progress.last_activity)
	if OS.get_ticks_msec() - alive < FILL_WATCHDOG_MS:
		return
	print("[MaterialSquareBucket] WARNING: fill watchdog fired — the fill coroutine died (check the errors above). Bucket re-armed.")
	_filling = false
	if _active_progress != null:
		if _active_progress.has_method("force_close"):
			_active_progress.force_close()
		_active_progress = null


# ── Helpers ──────────────────────────────────────────────────────────────────

func _is_material_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	return editor.get("ActiveToolName") == "MaterialBrush"


func _get_current_level():
	if _g == null: return null
	var world = _g.get("World")
	if world == null or not is_instance_valid(world): return null
	return world.call("GetCurrentLevel")
