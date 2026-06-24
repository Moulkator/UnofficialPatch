# grid_ruler.gd
# Photoshop-like grid ruler overlay around the map viewport.
#
# Toggle with CTRL+R. Shows cell coordinates from the top-left origin (0,0).
# The ruler stays at a fixed size in screen space, but its tick marks and
# labels follow the map as the user pans or zooms. Label density adapts to
# the current zoom level to avoid clutter.
#
# The mouse position on the map is projected onto the rulers as a crosshair,
# and the exact cell coordinate is shown in the corner box.

var _g
var ui_util
var ui_scaler   # ui_scaler_builtin reference, injected by Main.gd

const _SAVE_KEY       = "GridRuler"
const _SETTINGS_FILE  = "user://UnofficialPatch/grid_ruler.json"

# ── Layout (base values — scaled each frame by _ui_scale()) ───────────────
const BASE_RULER_SIZE  = 30.0   # ruler thickness in screen pixels @ scale 1.0
const BASE_TOOLBAR_FBK = 32.0   # fallback top offset if dynamic detection fails
const BASE_TICK_MINOR  = 3.0
const BASE_TICK_MAJOR  = 5.0

# ── Colors ────────────────────────────────────────────────────────────────
const COL_BG       = Color(0.10, 0.10, 0.12, 0.88)
const COL_CORNER   = Color(0.16, 0.16, 0.20, 0.95)
const COL_LINE     = Color(0.75, 0.75, 0.78, 0.55)
const COL_MAJOR    = Color(1.00, 1.00, 1.00, 0.85)
const COL_TEXT     = Color(1.00, 1.00, 1.00, 1.00)
const COL_CURSOR   = Color(0.30, 0.85, 1.00, 0.95)
const COL_COORDS   = Color(1.00, 0.80, 0.30, 1.00)  # cursor coord text

# ── State ─────────────────────────────────────────────────────────────────
var _enabled       := false
var _canvas_layer  : CanvasLayer = null
var _ruler_ctrl    : Control = null
var _input_listener: Node = null
var _bar_button    : CheckButton = null
var _top_edge_cache    := -1.0
var _top_edge_frame    := -1
var _left_edge_cache   := -1.0
var _right_edge_cache  := -1.0
var _side_edge_frame   := -1

var _destroyed := false

# ── Redraw gating (perf) ──────────────────────────────────────────────────
# On ne redessine que si la caméra, la souris ou la taille du viewport ont
# changé. Un heartbeat périodique force malgré tout un redraw pour rattraper
# les changements de mise en page (ouverture d'un panneau d'outil, etc.).
var _last_xform : Transform2D = Transform2D()
var _last_mouse : Vector2 = Vector2(-99999, -99999)
var _last_size  : Vector2 = Vector2.ZERO
var _last_draw_frame : int = -1


func initialize() -> void:
	_load_settings()
	_create_overlay()
	_install_input_listener()
	call_deferred("_try_inject_bar_button", 0)
	print("[GridRuler] Initialized (enabled=%s)" % str(_enabled))


func cleanup() -> void:
	_destroyed = true
	_enabled = false
	# Remove overlay (canvas layer + ruler control)
	if _canvas_layer != null and is_instance_valid(_canvas_layer):
		_canvas_layer.queue_free()
	_canvas_layer = null
	_ruler_ctrl = null
	# Remove input listener
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	# Remove bar button from its parent
	if _bar_button != null and is_instance_valid(_bar_button):
		_bar_button.queue_free()
	_bar_button = null
	print("[GridRuler] Cleaned up")


# ── Overlay creation ──────────────────────────────────────────────────────

func _create_overlay() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "GridRulerLayer"
	# Above regular UI (~0), below popup/modal layers (100+).
	_canvas_layer.layer = 50

	_ruler_ctrl = Control.new()
	_ruler_ctrl.name = "GridRuler"
	_ruler_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ruler_ctrl.anchor_right = 1.0
	_ruler_ctrl.anchor_bottom = 1.0

	# _process gère trois choses chaque frame :
	#  1. dedup : DD ré-instancie le mod au load d'une carte ; le CanvasLayer
	#     vit sur root (persiste) → un orphelin gelé subsisterait. Le layer le
	#     plus récent (instance id le plus élevé) survit et libère les autres.
	#  2. visibilité : masquée tant que la carte n'est pas prête / qu'un écran
	#     de loading est affiché (évite le dessin par-dessus le loading et la
	#     frame gelée d'un Control caché).
	#  3. redraw conditionnel (perf) via _should_redraw.
	var script = GDScript.new()
	script.source_code = "extends Control\nvar handler = null\nfunc _ready():\n\tset_process(true)\nfunc _process(_d):\n\tif handler == null:\n\t\treturn\n\thandler._dedup_overlays(self)\n\tvar want = handler._enabled and handler._map_ready()\n\tif visible != want:\n\t\tvisible = want\n\t\tif want:\n\t\t\tupdate()\n\tif want and handler._should_redraw(self):\n\t\tupdate()\nfunc _draw():\n\tif handler != null:\n\t\thandler._draw_ruler(self)\n"
	script.reload()
	_ruler_ctrl.set_script(script)
	_ruler_ctrl.handler = self
	_ruler_ctrl.visible = false

	_canvas_layer.add_child(_ruler_ctrl)

	# Racine via get_main_loop() (indépendant de _g.World, qui peut être null
	# pendant le load) pour garantir l'ajout de l'overlay.
	var tree = Engine.get_main_loop()
	if tree is SceneTree and tree.root != null:
		tree.root.call_deferred("add_child", _canvas_layer)


# Garde un overlay unique sur root. Appelé chaque frame par le Control actif :
# il libère tout autre CanvasLayer "GridRulerLayer*" dont l'instance id est
# inférieur au sien (donc plus ancien). Tiebreaker déterministe → pas
# d'annihilation mutuelle entre l'ancien Control et le nouveau ; le plus
# récent (la nouvelle instance du mod) gagne et l'ancien orphelin disparaît.
func _dedup_overlays(ctrl: Control) -> void:
	var mine = ctrl.get_parent()
	if mine == null:
		return
	var my_id : int = mine.get_instance_id()
	var tree = Engine.get_main_loop()
	if not (tree is SceneTree) or tree.root == null:
		return
	for child in tree.root.get_children():
		if child is CanvasLayer and child != mine \
				and str(child.name).begins_with("GridRulerLayer") \
				and child.get_instance_id() < my_id:
			child.queue_free()


# La carte est-elle prête à afficher le ruler ? False pendant le load (monde
# absent/hors-arbre, caméra absente) et tant que l'écran de loading du patch
# (UPLoadingOverlay, un Panel sur le canvas layer 0) est affiché — sinon notre
# CanvasLayer (layer 50) se dessinerait par-dessus.
func _map_ready() -> bool:
	if _g == null:
		return false
	if _g.World == null or not is_instance_valid(_g.World):
		return false
	if not _g.World.is_inside_tree():
		return false
	if _g.Camera == null or not is_instance_valid(_g.Camera):
		return false
	var tree = Engine.get_main_loop()
	if tree is SceneTree and tree.root != null:
		for child in tree.root.get_children():
			if str(child.name).begins_with("UPLoadingOverlay"):
				return false
	return true


func _install_input_listener() -> void:
	_input_listener = Node.new()
	_input_listener.name = "GridRulerListener"
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -200\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World:
		_g.World.call_deferred("add_child", _input_listener)


# ── Input: CTRL+R toggle ──────────────────────────────────────────────────

func _on_input(event) -> void:
	if _destroyed:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if not event.control or event.scancode != KEY_R:
		return
	# Don't intercept while typing in a LineEdit / TextEdit
	if _is_text_focused():
		return
	_toggle()
	_input_listener.get_tree().set_input_as_handled()


func _is_text_focused() -> bool:
	var vp = _input_listener.get_viewport() if _input_listener != null else null
	if vp == null:
		return false
	if not vp.has_method("gui_get_focus_owner"):
		return false
	var focused = vp.gui_get_focus_owner()
	if focused == null:
		return false
	return focused is LineEdit or focused is TextEdit


func _toggle() -> void:
	_enabled = not _enabled
	if _ruler_ctrl != null and is_instance_valid(_ruler_ctrl):
		# La visibilité réelle est pilotée chaque frame par _process (selon
		# l'état carte-prête) ; on déclenche juste un redraw immédiat.
		if _enabled:
			_ruler_ctrl.update()
	_sync_bar_button()
	_save_settings()
	print("[GridRuler] %s" % ("enabled" if _enabled else "disabled"))


func _sync_bar_button() -> void:
	if _bar_button == null or not is_instance_valid(_bar_button):
		return
	if _bar_button.pressed == _enabled:
		return
	if _bar_button.has_method("set_pressed_no_signal"):
		_bar_button.set_pressed_no_signal(_enabled)
	else:
		_bar_button.set_block_signals(true)
		_bar_button.pressed = _enabled
		_bar_button.set_block_signals(false)


# ── Bottom bar button injection ───────────────────────────────────────────
# Adds a "Rulers" CheckButton next to Grid/Snap/Lighting in the floating
# map-options bar at the bottom of the screen.

func _try_inject_bar_button(attempt: int) -> void:
	if not _bar_button_setting_enabled():
		return
	if attempt > 25:
		print("[GridRuler] Bar button injection gave up after 25 attempts")
		return
	if _bar_button != null and is_instance_valid(_bar_button):
		return   # already injected

	var zoom_opts = _g.Editor.get("ZoomOptions") if _g.Editor else null
	if zoom_opts == null or not is_instance_valid(zoom_opts):
		_retry_inject_bar_button(attempt)
		return
	var parent = zoom_opts.get_parent()
	if parent == null or not is_instance_valid(parent):
		_retry_inject_bar_button(attempt)
		return

	# Walk backwards from ZoomOptions to find a labelled toggle button
	# (Grid / Snap / Lighting). We skip icon-only toggle buttons such as
	# DD's native Ruler Tool, whose icon and shortcut "(R)" would otherwise
	# leak into ours via duplicate(). Cloning a labelled button inherits
	# DD's custom theme (round indicator on the left).
	var zoom_idx : int = zoom_opts.get_index()
	var insert_idx : int = zoom_idx
	var reference_btn : Node = null
	for i in range(zoom_idx - 1, -1, -1):
		var child = parent.get_child(i)
		if child is BaseButton and child.get("toggle_mode") == true:
			var txt = str(child.get("text")) if child.get("text") != null else ""
			if txt != "":
				reference_btn = child
				insert_idx = i + 1
				break

	if reference_btn != null:
		# Duplicate preserves class, theme overrides, stylebox and icon.
		# Default flags (15) also copy signals — we strip them below so our
		# button doesn't fire DD's Grid/Snap/Lighting handlers.
		_bar_button = reference_btn.duplicate()
		_disconnect_all_signals(_bar_button)
		# Clear any inherited icon/shortcut just in case the cloned button
		# had them set explicitly (would otherwise render alongside text).
		if _bar_button.get("icon") != null:
			_bar_button.set("icon", null)
		if _bar_button.get("shortcut") != null:
			_bar_button.set("shortcut", null)
	else:
		# Fallback: plain CheckButton (iOS-style toggle)
		_bar_button = CheckButton.new()

	_bar_button.text = "Guides"
	_bar_button.hint_tooltip = "(Ctrl + R)"
	_bar_button.pressed = _enabled
	_bar_button.focus_mode = Control.FOCUS_NONE
	_bar_button.connect("toggled", self, "_on_bar_button_toggled")
	parent.add_child(_bar_button)
	parent.move_child(_bar_button, insert_idx)
	print("[GridRuler] Bar button injected at index %d" % insert_idx)


func _disconnect_all_signals(n: Object) -> void:
	if n == null:
		return
	for sig in n.get_signal_list():
		var conns = n.get_signal_connection_list(sig.name)
		for c in conns:
			if n.is_connected(sig.name, c.target, c.method):
				n.disconnect(sig.name, c.target, c.method)


# Called by Main.gd when the "Guides Floatbar Button" setting changes.
func set_bar_button_enabled(on: bool) -> void:
	if on:
		if _bar_button == null or not is_instance_valid(_bar_button):
			_try_inject_bar_button(0)
	else:
		if _bar_button != null and is_instance_valid(_bar_button):
			_bar_button.queue_free()
		_bar_button = null


func _bar_button_setting_enabled() -> bool:
	var ms = null
	if _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("ruler_guide_bar_button")


func _retry_inject_bar_button(attempt: int) -> void:
	var tree = _g.World.get_tree() if _g.World else null
	if tree == null:
		return
	var t = tree.create_timer(0.3)
	t.connect("timeout", self, "_try_inject_bar_button", [attempt + 1])


func _on_bar_button_toggled(pressed: bool) -> void:
	# Only act if the state actually differs — prevents feedback loops when
	# _sync_bar_button updates the button via set_pressed_no_signal.
	if pressed == _enabled:
		return
	_toggle()


# ── Drawing ───────────────────────────────────────────────────────────────

# Détermine s'il faut redessiner cette frame. Renvoie false quand rien de
# pertinent n'a bougé (caméra immobile, souris immobile, viewport identique),
# ce qui évite un _draw complet inutile à 60 fps. Un heartbeat toutes les
# ~12 frames force un redraw pour rattraper les changements de layout
# (ouverture/fermeture de panneau) qui ne touchent pas la caméra.
func _should_redraw(ctrl: Control) -> bool:
	var camera = _g.Camera
	if camera == null or not is_instance_valid(camera):
		return false
	var frame : int = Engine.get_frames_drawn()
	var force : bool = (frame - _last_draw_frame) >= 12
	var xform : Transform2D = camera.get_canvas_transform()
	var vp = ctrl.get_viewport()
	var mouse : Vector2 = vp.get_mouse_position() if vp != null else Vector2.ZERO
	var size : Vector2 = ctrl.rect_size
	if not force and xform == _last_xform and mouse == _last_mouse and size == _last_size:
		return false
	_last_xform = xform
	_last_mouse = mouse
	_last_size = size
	_last_draw_frame = frame
	return true


func _draw_ruler(ctrl: Control) -> void:
	if not _enabled:
		return
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var camera = _g.Camera
	if camera == null or not is_instance_valid(camera):
		return

	var vp = ctrl.get_viewport()
	var vp_size : Vector2 = ctrl.rect_size
	if vp_size.x <= 0 or vp_size.y <= 0:
		if vp != null:
			vp_size = vp.size
		if vp_size.x <= 0 or vp_size.y <= 0:
			return

	var canvas_xform : Transform2D = camera.get_canvas_transform()
	var zoom : float = canvas_xform.get_scale().x
	if zoom <= 0.0:
		return

	var world_rect : Rect2 = _g.World.WorldRect
	var grid_size : Vector2 = _g.World.GridCellSize
	var cells_w : int = int(_g.World.Width)
	var cells_h : int = int(_g.World.Height)
	if grid_size.x <= 0 or grid_size.y <= 0 or cells_w <= 0 or cells_h <= 0:
		return

	# ── Custom Snap (snappy_mod) compatibility ──────────────────────────
	# If the third-party Custom Snap mod is active AND its "Custom Grid"
	# option is on, override grid_size / cell counts / world origin so
	# our ruler matches the visual grid that snappy_mod draws.
	var snappy = _find_snappy_mod()
	if snappy != null:
		var s_enabled = snappy.get("custom_snap_enabled")
		var g_enabled = snappy.get("custom_grid_enabled")
		if s_enabled == true and g_enabled == true:
			var custom_gs = _snappy_grid_size(snappy)
			if custom_gs is Vector2 and custom_gs.x > 0 and custom_gs.y > 0:
				grid_size = custom_gs
				var offset = snappy.get("snap_offset")
				if offset is Vector2:
					world_rect = Rect2(
						world_rect.position + offset,
						world_rect.size - offset)
				cells_w = int(ceil(world_rect.size.x / grid_size.x))
				cells_h = int(ceil(world_rect.size.y / grid_size.y))
				if cells_w <= 0: cells_w = 1
				if cells_h <= 0: cells_h = 1
				if not _snappy_override_logged:
					_snappy_override_logged = true
					var geom = snappy.get("active_geometry")
					print("[GridRuler] using snappy grid: geom=", geom,
						" → grid_size=", grid_size, " cells=",
						cells_w, "x", cells_h)

	# Apply UI scale (from UIScaler if active) to all ruler-chrome pixels.
	# Font size is scaled automatically by UIScaler's theme registration,
	# so font.get_string_size() / get_ascent() return already-scaled values.
	var s : float = _ui_scale()
	var ruler_size : float = BASE_RULER_SIZE * s
	var tick_major : float = BASE_TICK_MAJOR * s
	var tick_minor : float = BASE_TICK_MINOR * s

	# ── Drawable area (avoid covering side panels / top toolbar) ─────────
	var edges : Array = _get_side_edges(ctrl, vp_size)
	var left_edge : float = edges[0]
	var right_edge : float = edges[1]
	var top_edge : float = _get_top_edge(ctrl, vp_size)
	if right_edge - left_edge < ruler_size * 3.0:
		return

	# Font info (needed for vertical ruler width computation).
	# We pull DD's theme.default_font directly because UIScaler registers
	# a FontScaler on that exact font instance — reading it here guarantees
	# we get the scaled size. ctrl.get_font("font") would only work if our
	# Control's theme chain resolved to the same font, which is not reliable
	# for Controls attached to a standalone CanvasLayer.
	var font = _get_scaled_font()
	if font == null:
		font = ctrl.get_font("font")
	var ascent : float = 12.0 * s
	if font != null:
		ascent = font.get_ascent()

	# Vertical ruler width adapts to the widest Y label (e.g. "100", "2500").
	# Horizontal ruler height stays ruler_size (text fits vertically).
	var v_ruler_w : float = ruler_size
	if font != null:
		var max_label_w : float = font.get_string_size(str(cells_h)).x
		var needed : float = max_label_w + tick_major + 5.0 * s
		if needed > v_ruler_w:
			v_ruler_w = needed

	# Ruler strips: horizontal (top) + vertical (left) within the map area
	var top_y    : float = top_edge
	var left_x   : float = left_edge
	var strip_x0 : float = left_x + v_ruler_w   # labels start after corner box
	var strip_y0 : float = top_y + ruler_size

	# Backgrounds
	ctrl.draw_rect(Rect2(left_x, top_y, right_edge - left_x, ruler_size), COL_BG)
	ctrl.draw_rect(Rect2(left_x, top_y, v_ruler_w, vp_size.y - top_y), COL_BG)
	# Corner box (origin marker)
	ctrl.draw_rect(Rect2(left_x, top_y, v_ruler_w, ruler_size), COL_CORNER)

	# Adaptive label step based on cell size in screen pixels.
	# Thresholds scale with UI so labels don't overlap at larger UI scales.
	var cell_screen : float = grid_size.x * zoom
	var step : int = 1
	if cell_screen < 14.0 * s:
		step = 10
	elif cell_screen < 28.0 * s:
		step = 5
	elif cell_screen < 56.0 * s:
		step = 2

	# ── Horizontal ruler (X axis) ────────────────────────────────────────
	# Fenêtrage : on ne parcourt que les cellules visibles à l'écran plutôt
	# que [0..cells_w]. Caméra DD sans rotation → sx = zoom*wx + origin.x,
	# donc on inverse les bornes écran [strip_x0..right_edge] en indices.
	var ox : float = canvas_xform.origin.x
	var wx_lo : float = (strip_x0 - ox) / zoom
	var wx_hi : float = (right_edge - ox) / zoom
	var x_start : int = int(floor((wx_lo - world_rect.position.x) / grid_size.x)) - 1
	var x_end   : int = int(ceil((wx_hi - world_rect.position.x) / grid_size.x)) + 1
	if x_start < 0:
		x_start = 0
	if x_end > cells_w:
		x_end = cells_w
	for x in range(x_start, x_end + 1):
		var wx : float = world_rect.position.x + x * grid_size.x
		var sx : float = canvas_xform.xform(Vector2(wx, world_rect.position.y)).x
		if sx < strip_x0 - 2 or sx > right_edge + 2:
			continue
		var is_major : bool = (x % step == 0) or (x == cells_w)
		var color : Color = COL_MAJOR if is_major else COL_LINE
		var tick : float = tick_major if is_major else tick_minor
		ctrl.draw_line(Vector2(sx, top_y + ruler_size - tick),
			Vector2(sx, top_y + ruler_size), color, 1.0)

		if is_major and font != null:
			var text : String = str(x)
			var ts : Vector2 = font.get_string_size(text)
			var tx : float = sx - ts.x * 0.5
			if tx < strip_x0 + 1:
				tx = strip_x0 + 1
			if tx + ts.x > right_edge - 1:
				tx = right_edge - 1 - ts.x
			var ty : float = top_y + ascent + 1
			ctrl.draw_string(font, Vector2(tx, ty), text, COL_TEXT)

	# ── Vertical ruler (Y axis) ──────────────────────────────────────────
	# Même fenêtrage que l'axe X, sur les bornes écran [strip_y0..vp_size.y].
	var oy : float = canvas_xform.origin.y
	var wy_lo : float = (strip_y0 - oy) / zoom
	var wy_hi : float = (vp_size.y - oy) / zoom
	var y_start : int = int(floor((wy_lo - world_rect.position.y) / grid_size.y)) - 1
	var y_end   : int = int(ceil((wy_hi - world_rect.position.y) / grid_size.y)) + 1
	if y_start < 0:
		y_start = 0
	if y_end > cells_h:
		y_end = cells_h
	for y in range(y_start, y_end + 1):
		var wy : float = world_rect.position.y + y * grid_size.y
		var sy : float = canvas_xform.xform(Vector2(world_rect.position.x, wy)).y
		if sy < strip_y0 - 2 or sy > vp_size.y + 2:
			continue
		var is_major : bool = (y % step == 0) or (y == cells_h)
		var color : Color = COL_MAJOR if is_major else COL_LINE
		var tick : float = tick_major if is_major else tick_minor
		ctrl.draw_line(Vector2(left_x + v_ruler_w - tick, sy),
			Vector2(left_x + v_ruler_w, sy), color, 1.0)

		if is_major and font != null:
			var text : String = str(y)
			var ts : Vector2 = font.get_string_size(text)
			var tx : float = left_x + v_ruler_w - tick - ts.x - 2
			if tx < left_x + 1:
				tx = left_x + 1
			var ty : float = sy + ts.y * 0.35
			if ty - ts.y < strip_y0:
				ty = strip_y0 + ts.y
			ctrl.draw_string(font, Vector2(tx, ty), text, COL_TEXT)

	# ── Cursor crosshair + coords in corner box ──────────────────────────
	if vp != null:
		var mouse_screen : Vector2 = vp.get_mouse_position()
		var in_map : bool = mouse_screen.x >= strip_x0 and mouse_screen.x <= right_edge \
			and mouse_screen.y >= strip_y0 and mouse_screen.y <= vp_size.y
		if in_map:
			# Cursor ticks on both rulers
			ctrl.draw_line(Vector2(mouse_screen.x, top_y),
				Vector2(mouse_screen.x, top_y + ruler_size), COL_CURSOR, 1.0)
			ctrl.draw_line(Vector2(left_x, mouse_screen.y),
				Vector2(left_x + v_ruler_w, mouse_screen.y), COL_CURSOR, 1.0)

			# Cell under cursor, drawn in the corner box
			var mouse_world : Vector2 = canvas_xform.affine_inverse().xform(mouse_screen)
			var rel : Vector2 = mouse_world - world_rect.position
			var cell_x : int = int(floor(rel.x / grid_size.x))
			var cell_y : int = int(floor(rel.y / grid_size.y))
			if font != null:
				var ctext : String = "%d,%d" % [cell_x, cell_y]
				var cts : Vector2 = font.get_string_size(ctext)
				# Center in corner box if it fits, otherwise left-align
				var tx : float = left_x + (v_ruler_w - cts.x) * 0.5
				var ty : float = top_y + (ruler_size + ascent) * 0.5 - 1
				if cts.x > v_ruler_w - 2:
					tx = left_x + 1
				ctrl.draw_string(font, Vector2(tx, ty), ctext, COL_COORDS)


# ── Custom Snap (snappy_mod) lookup ───────────────────────────────────────
# Locates the third-party snappy_mod instance so we can match its custom
# grid when both `custom_snap_enabled` and `custom_grid_enabled` are on.
# Cached after first successful find (cleared if the ref goes invalid).

var _snappy_cache = null
var _snappy_search_done := false
var _snappy_diag_done := false
var _snappy_override_logged := false


func _find_snappy_mod():
	if _snappy_cache != null and is_instance_valid(_snappy_cache):
		return _snappy_cache
	_snappy_cache = null
	if _snappy_search_done and (Engine.get_frames_drawn() % 60) != 0:
		return null
	_snappy_search_done = true
	if _g == null or _g.Editor == null:
		return null
	# Editor.Tools["snappy_mod"] returns a C# wrapper, not the GDScript
	# instance. The wrapper exposes `get_ScriptInstance()` which gives
	# us the actual snappy script — the only reliable way to access its
	# state. This is the same approach clipboard_fix.gd / no_micro_drag.gd
	# (two other mods that integrate with Custom Snap) use.
	if not ("Tools" in _g.Editor):
		return null
	var tools = _g.Editor.Tools
	if not tools.has("snappy_mod"):
		return null
	var wrapper = tools["snappy_mod"]
	if wrapper == null or not wrapper.has_method("get_ScriptInstance"):
		return null
	var inst = wrapper.get_ScriptInstance()
	if inst != null and _is_valid_snappy(inst):
		_snappy_cache = inst
		if not _snappy_diag_done:
			_snappy_diag_done = true
			print("[GridRuler] snappy_mod found via get_ScriptInstance")
		return _snappy_cache
	if not _snappy_diag_done:
		_snappy_diag_done = true
		print("[GridRuler] snappy NOT FOUND. wrapper=", wrapper,
			" inst=", inst)
	return null


func _is_valid_snappy(obj) -> bool:
	# Sanity check that obj is actually the snappy_mod script instance
	# (has the state vars we care about).
	if obj == null:
		return false
	if obj.get("custom_snap_enabled") == null:
		return false
	if obj.get("custom_grid_enabled") == null:
		return false
	if not (obj.get("snap_interval") is Vector2):
		return false
	return true


# Compute the axis-aligned grid spacing matching snappy's drawn mesh.
# snappy uses `mesh_size_multiplier = snap_interval_multiplier * 2.0`
# and the mesh is drawn at:
#   SQUARE  : snap_interval * mesh_size_multiplier on each axis
#   HEX_V   : hexes lined up vertically (flat-top hexes); x = sqrt(3)*size,
#             y = 1.5*size, where size = snap_interval / sqrt(3) or / 1.5
#   HEX_H   : pointy-top hexes; x = 1.5*size, y = sqrt(3)*size
#   ISO     : iso_mode_game uses 2:1 ratio (north_inc = x*2, east_inc = y)
# We return the x/y spacing so the ruler's axes each match the natural
# grid spacing for that mode (won't be pixel-perfect for hex/iso since
# the actual grid lines are diagonal — but x and y spacing will match
# the grid's natural projection on each axis).
func _snappy_grid_size(snappy):
	var interval = snappy.get("snap_interval")
	if not (interval is Vector2):
		return null
	if interval.x <= 0 or interval.y <= 0:
		return null
	var mult_raw = snappy.get("snap_interval_multiplier")
	var mult : float = 1.0
	if mult_raw != null and typeof(mult_raw) in [TYPE_REAL, TYPE_INT]:
		mult = float(mult_raw)
	if mult <= 0.0:
		mult = 1.0
	# snappy's mesh_size_multiplier
	var mesh_mult = mult * 2.0

	var geom = snappy.get("active_geometry")
	# enum GEOMETRY {SQUARE=0, HEX_V=1, HEX_H=2, ISOMETRIC=3}

	if geom == 0:
		# Square: matches snappy's _draw_square_surface_mesh exactly.
		return interval * mesh_mult

	if geom == 3:
		# Isometric: game mode has a 2:1 horizontal:vertical ratio.
		var iso_game = snappy.get("isometric_mode_game")
		if iso_game == true:
			return Vector2(interval.x * 2.0, interval.y) * mesh_mult
		# Non-game iso = horizontal triangle projection (treat as HEX_H).

	# Hex (or non-game iso): size depends on radial mode.
	var radial_corner = snappy.get("radial_mode_to_corner")
	var size : Vector2
	if radial_corner == true:
		size = interval / sqrt(3.0)
	else:
		size = interval / 1.5

	if geom == 1:
		# HEX_V (flat-top hexes lined up vertically).
		# East-west between adjacent hex centers in a row: sqrt(3)*size.x
		# North-south between rows (stagger of 1.5*size.y each row).
		return Vector2(sqrt(3.0) * size.x, 1.5 * size.y) * mult * 2.0

	# HEX_H (pointy-top hexes) and non-game iso fallthrough.
	return Vector2(1.5 * size.x, sqrt(3.0) * size.y) * mult * 2.0



# Read the current UI scale. Primary source: UI Rescaler publishes a
# meta "uir_general_scale" on _g.World after every apply. Fallback:
# ui_scaler_builtin's _ui_scale_value if injected. Final fallback: 1.0.

func _ui_scale() -> float:
	# UI Rescaler meta (preferred — works whether or not ui_scaler_builtin
	# is loaded, and reflects per-category General Scale × DD's enlarge_ui).
	if _g != null and _g.World != null and is_instance_valid(_g.World):
		if _g.World.has_meta("uir_general_scale"):
			var v = _g.World.get_meta("uir_general_scale")
			if typeof(v) in [TYPE_REAL, TYPE_INT] and float(v) > 0.0:
				return float(v)
	# Legacy fallback: ui_scaler_builtin instance injection.
	if ui_scaler != null and is_instance_valid(ui_scaler):
		var v2 = ui_scaler.get("_ui_scale_value")
		if v2 != null and v2 is float and v2 > 0.0:
			return v2
	# Theme meta fallback (UIScaler legacy).
	var theme = _find_dd_theme()
	if theme != null and theme.has_meta("_ui_scaler_applied"):
		var m = theme.get_meta("_ui_scaler_applied")
		if m is float and m > 0.0:
			return m
	return 1.0


func _find_dd_theme():
	# Kept for _ui_scale() meta fallback, but note on DD 1.2.0.1 theme
	# lookup often returns null (themes are attached further down the tree
	# than Master). We rely on ui_scaler._ui_scale_value as the primary
	# source of truth.
	if _g == null or _g.World == null:
		return null
	var tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		return null
	var root = tree.root
	var master = root.get_node_or_null("Master")
	if master is Control and master.theme != null:
		return master.theme
	for child in root.get_children():
		if child is Control and child.theme != null:
			return child.theme
	if _g.Editor is Control and _g.Editor.theme != null:
		return _g.Editor.theme
	return null


func _get_scaled_font():
	# Primary: pull any DynamicFont from DD's theme. UI Rescaler mutates
	# .size on these fonts in place after each apply, so any reference
	# we grab is already at the current scaled size.
	var theme = _find_dd_theme()
	if theme != null:
		for cls in ["Label", "Button", "LineEdit", "RichTextLabel"]:
			var f = theme.get_font("font", cls)
			if f is DynamicFont:
				return f
	# Legacy fallback: ui_scaler_builtin's FontScaler instances.
	if ui_scaler != null and is_instance_valid(ui_scaler):
		var agent = ui_scaler.get("_ui_scaling_agent")
		if agent != null:
			var scalers = agent.get("scalers")
			if scalers is Array:
				for sc in scalers:
					var f = sc.get("_font")
					if f != null and f is DynamicFont:
						return f
	return null


# ── Top toolbar detection ─────────────────────────────────────────────────
# Find the bottom Y of the top toolbar/menu bar area, so the ruler sits
# flush against it regardless of DD's actual UI height.

func _get_top_edge(ctrl: Control, vp_size: Vector2) -> float:
	var frame = Engine.get_frames_drawn()
	if frame == _top_edge_frame and _top_edge_cache >= 0.0:
		return _top_edge_cache
	_top_edge_frame = frame

	var tree = ctrl.get_tree()
	var max_bottom : float = 0.0
	# Primary: direct lookup of DD's top MenuBar (stable path). Tracks
	# the UI scale automatically since get_global_rect() reflects current
	# size. More reliable than heuristics that rely on pixel thresholds.
	if tree != null and tree.root != null:
		var menubar = tree.root.get_node_or_null(
			"Master/Editor/VPartition/MenuBar")
		if menubar != null and menubar is Control \
				and menubar.is_visible_in_tree():
			var rect : Rect2 = menubar.get_global_rect()
			if rect.size.y >= 10.0 and rect.position.y < 100.0:
				max_bottom = rect.position.y + rect.size.y
	# Fallback: heuristic scan (relevant if path changes in a future DD).
	if max_bottom <= 0.0 and tree != null and tree.root != null:
		max_bottom = _scan_top_panels(tree.root, vp_size, 0, max_bottom)
	if max_bottom < 10.0:
		max_bottom = BASE_TOOLBAR_FBK * _ui_scale()
	_top_edge_cache = max_bottom
	return max_bottom


func _scan_top_panels(node: Node, vp_size: Vector2, depth: int, current_max: float) -> float:
	if depth > 5:
		return current_max
	var result : float = current_max
	for child in node.get_children():
		if child is Control and child.is_visible_in_tree():
			var rect : Rect2 = child.get_global_rect()
			if rect.position.y < 80.0 \
				and rect.size.x > vp_size.x * 0.4 \
				and rect.size.y >= 10.0 \
				and rect.size.y < vp_size.y * 0.15:
				var bottom : float = rect.position.y + rect.size.y
				if bottom > result and bottom < 120.0:
					result = bottom
		if child is Control and not child.is_visible_in_tree():
			continue
		result = _scan_top_panels(child, vp_size, depth + 1, result)
	return result


# ── Side panel detection ──────────────────────────────────────────────────
# Broader than ui_util: catches the collapsed tool-options panel, which
# isn't a Panel/PanelContainer and can exceed 25% viewport width.

func _get_side_edges(ctrl: Control, vp_size: Vector2) -> Array:
	var frame = Engine.get_frames_drawn()
	if frame == _side_edge_frame and _left_edge_cache >= 0.0:
		return [_left_edge_cache, _right_edge_cache]
	_side_edge_frame = frame

	var left_edge : float = 0.0
	var right_edge : float = vp_size.x
	var tree = ctrl.get_tree()

	# First pass: ask DD directly for the tools column (the icon strip on
	# the far left). Its size tracks UI scale, so a relative-height scan
	# would miss it at small scales.
	var tools_right : float = _get_tools_column_right(tree)
	if tools_right > left_edge:
		left_edge = tools_right

	# Second pass: ask DD directly for the currently-active tool panel.
	# Tool panels expand wider than what the generic scan catches, so we
	# always want their right edge.
	var tool_right : float = _get_active_tool_panel_right(tree)
	if tool_right > left_edge:
		left_edge = tool_right

	# Third pass: generic scan catches anything else (right-side panels,
	# unusual layouts). Keeps the outermost (rightmost) left_edge.
	if tree != null and tree.root != null:
		var edges : Array = _scan_side_panels(tree.root, vp_size, 0, left_edge, right_edge)
		left_edge = edges[0]
		right_edge = edges[1]
	_left_edge_cache = left_edge
	_right_edge_cache = right_edge
	return [left_edge, right_edge]


# The tools icon column lives at a stable path. Pulling it directly is
# more reliable than height-based heuristics, which fail at small UI
# scales when the column gets short.

func _get_tools_column_right(tree) -> float:
	if tree == null or tree.root == null:
		return 0.0
	# The actual icon column is `Toolset` (a VBoxContainer of category
	# buttons), not the wider `Tools` parent which includes padding /
	# the inactive tool panel area. Toolset's width tracks UI scale
	# cleanly via get_global_rect().
	var toolset = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels/Tools/Anchor/Toolset")
	if toolset != null and toolset is Control \
			and toolset.is_visible_in_tree():
		var trect : Rect2 = toolset.get_global_rect()
		if trect.position.x < 5.0 and trect.size.x >= 20.0 \
				and trect.size.x < 200.0:
			return trect.position.x + trect.size.x
	# Fallback: try the `Tools` container. Keep the original 300px cap
	# (NOT scaled) so we reject the full Tools container width and only
	# accept it when it's actually the icon strip itself.
	var tools = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels/Tools")
	if tools == null or not (tools is Control) or not tools.is_visible_in_tree():
		return 0.0
	var rect : Rect2 = tools.get_global_rect()
	if rect.position.x > 5.0 or rect.size.x > 300.0 or rect.size.x < 20.0:
		return 0.0
	return rect.position.x + rect.size.x


func _scan_side_panels(node: Node, vp_size: Vector2, depth: int, cur_left: float, cur_right: float) -> Array:
	if depth > 6:
		return [cur_left, cur_right]
	var left : float = cur_left
	var right : float = cur_right
	# Absolute cap — real DD side panels never exceed this, even when the
	# tool-options strip is expanded. Prevents catching map-viewport-sized
	# containers as "panels".
	var max_panel_w : float = min(vp_size.x * 0.25, 300.0)
	for child in node.get_children():
		# is_visible_in_tree() not just .visible: hidden popups (e.g. the
		# TerrainWindow) have descendants with local visible=true but the
		# popup itself is hidden — they'd otherwise be picked up as side
		# panels and shift the rulers inward by a meaningless amount.
		if child is Control and child.is_visible_in_tree():
			var rect : Rect2 = child.get_global_rect()
			# Any tall visible Control hugging the left or right edge.
			# Type filter is intentionally broad (not just Panel/PanelContainer)
			# so the collapsed tool-options bar is caught.
			if rect.size.y > vp_size.y * 0.75 \
				and rect.size.x > 30.0 \
				and rect.size.x < max_panel_w:
				if rect.position.x < 5.0:
					var edge : float = rect.position.x + rect.size.x
					if edge > left:
						left = edge
				elif rect.position.x + rect.size.x > vp_size.x - 5.0:
					if rect.position.x < right:
						right = rect.position.x
		# Recurse into Control children only when they're actually shown.
		# Stops descent into hidden popup subtrees too.
		if child is Control and not child.is_visible_in_tree():
			continue
		var sub : Array = _scan_side_panels(child, vp_size, depth + 1, left, right)
		left = sub[0]
		right = sub[1]
	return [left, right]


# Query DD directly for the currently-active tool panel and return its
# right edge (in global screen coords). This bypasses the heuristics in
# _scan_side_panels, which can fail when the tool panel hasn't yet grown
# to its "tall panel" dimensions (e.g. first frame after a tool is opened).

func _get_active_tool_panel_right(tree) -> float:
	if tree == null or tree.root == null:
		return 0.0
	var anchor = tree.root.get_node_or_null(
		"Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor == null:
		return 0.0
	var max_right : float = 0.0
	for child in anchor.get_children():
		if not (child is Control):
			continue
		if not child.is_visible_in_tree():
			continue
		# Skip placeholders: tool-panel container only has children when active.
		if child.get_child_count() == 0:
			continue
		var rect : Rect2 = child.get_global_rect()
		if rect.size.x < 30.0 or rect.size.y < 100.0:
			continue
		var edge : float = rect.position.x + rect.size.x
		if edge > max_right:
			max_right = edge
	return max_right


# ── Settings persistence ──────────────────────────────────────────────────

func _save_settings() -> void:
	var data = {"enabled": _enabled}
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir_recursive("user://UnofficialPatch")
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.WRITE) == OK:
		f.store_string(JSON.print(data))
		f.close()


func _load_settings() -> void:
	var f = File.new()
	if f.open(_SETTINGS_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var d : Dictionary = parsed.result
	if d.has("enabled"):
		_enabled = bool(d["enabled"])
