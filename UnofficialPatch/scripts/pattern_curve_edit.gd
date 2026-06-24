# pattern_curve_edit.gd
# Ajoute le mode courbe (Shift+clic sur segment) en Edit Points mode pour le PatternShape Tool.
#
# Utilisation :
#   - Être dans le PatternShape Tool en Edit Points mode
#   - Shift+clic gauche sur un segment → entre en mode courbe (segment magenta)
#   - Bouger la souris → la courbe se met à jour en temps réel
#   - Clic gauche ou droit → confirme
#   - Échap → annule
#   - Shift+Alt+clic → aplatit le segment

var script_class = "tool"
var _g
var input_listener: Node
var _destroyed := false
const _META_KEY = "PatternCurveEditListener"

enum State { IDLE, HOVER, FLATTEN_HOVER, CURVE_PREVIEW }
var _state = State.IDLE

var _edit_shape       = null
var _original_pts: Array = []
var _overlay_line     = null
var _hover_shape      = null
var _hover_ai: int    = -1
var _hover_bi: int    = -1
var _anchor_a_idx: int = -1
var _anchor_b_idx: int = -1

const CLICK_THRESHOLD = 80.0
const MAGENTA = Color(1.0, 0.0, 1.0, 1.0)
const BLUE    = Color(0.0, 0.647, 1.0, 1.0)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_state        = State.IDLE
	_edit_shape   = null
	_original_pts = []
	_anchor_a_idx = -1
	_anchor_b_idx = -1
	_overlay_line = null
	_hover_shape  = null
	_hover_ai     = -1
	_hover_bi     = -1
	_install_listener()
	print("[PatternCurveEdit] initialized")



func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "PatternCurveEditListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# ── Détection du mode Edit Points ─────────────────────────────────────────────

func _is_edit_points_mode() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	var tool = editor.get("ActiveTool")
	if tool == null: return false
	var tools = editor.get("Tools")
	if tools == null: return false
	var pst = tools.get("PatternShapeTool")
	if pst == null or tool != pst: return false
	var btn = pst.get("EditPoints")
	if btn == null: return false
	return btn.get("pressed") == true


# ── Accès aux PatternShapes ────────────────────────────────────────────────────

func _get_all_shapes() -> Array:
	if _g == null: return []
	var world = _g.get("World")
	if world == null: return []
	var level = world.call("GetCurrentLevel")
	if level == null: return []
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return []
	if not ps_node.has_method("GetShapes"): return []
	var shapes = ps_node.call("GetShapes")
	if shapes == null: return []
	return shapes


# ── Lecture / écriture des points ─────────────────────────────────────────────

func _read_global_pts(shape) -> Array:
	# GlobalPolygon = points en world space, READ ONLY
	var raw = shape.get("GlobalPolygon")
	if raw == null: return []
	var result = []
	for p in raw:
		result.append(p)
	return result


func _write_pts(shape, pts: Array):
	# PatternShape est un Polygon2D natif Godot.
	# set_polygon() prend des coords en LOCAL space → convertir depuis world space.
	var pool = PoolVector2Array()
	for p in pts:
		pool.append(shape.to_local(p))
	shape.call("set_polygon", pool)


# ── Parsing de la structure ancre / points interpolés ────────────────────────

const MIN_CURVE_ANGLE = 0.03
const MAX_STEP_ANGLE  = 0.30
const MAX_TOTAL_ANGLE = 3.14159


func _find_curve_end(pts: Array, start: int) -> int:
	var n = pts.size()
	if start + 2 >= n: return start + 1
	var total_angle = 0.0
	var prev_dir = (pts[start + 1] - pts[start])
	if prev_dir.length() < 0.01: return start + 1
	prev_dir = prev_dir.normalized()
	var i = start + 1
	while i + 1 < n:
		var next_dir = (pts[i + 1] - pts[i])
		if next_dir.length() < 0.01: break
		next_dir = next_dir.normalized()
		var angle = acos(clamp(prev_dir.dot(next_dir), -1.0, 1.0))
		if angle < MIN_CURVE_ANGLE: break
		if angle > MAX_STEP_ANGLE: break
		if total_angle + angle > MAX_TOTAL_ANGLE: break
		total_angle += angle
		prev_dir = next_dir
		i += 1
	return i


# ── Géométrie ─────────────────────────────────────────────────────────────────

func _dist_point_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var len_sq = ab.dot(ab)
	if len_sq < 0.001: return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + t * ab)


func _find_shape_and_segment(mouse_w: Vector2) -> Array:
	var best_shape = null
	var best_pts   = []
	var best_ai    = -1
	var best_bi    = -1
	var best_dist: float = CLICK_THRESHOLD

	for shape in _get_all_shapes():
		if not is_instance_valid(shape): continue
		var rect = shape.get("GlobalRect")
		if rect != null and not rect.grow(CLICK_THRESHOLD).has_point(mouse_w): continue

		var pts = _read_global_pts(shape)
		if pts.size() < 2: continue

		var n = pts.size()
		# PatternShape = polygone fermé → toujours loop
		var closest_i = -1
		var closest_d = CLICK_THRESHOLD
		for j in range(n):  # segment j → (j+1)%n, incluant le segment de fermeture
			var a_pt = pts[j]
			var b_pt = pts[(j + 1) % n]
			var d = _dist_point_to_seg(mouse_w, a_pt, b_pt)
			if d < closest_d:
				closest_d = d
				closest_i = j

		if closest_i < 0: continue

		# Budget angulaire partagé entre arrière et avant : 180° total cumulé.
		# Sans partage, back(180°) + fwd(180°) = 360° → cercle entier sélectionné.
		# Budget symétrique : MAX_TOTAL_ANGLE / 2 de chaque côté du curseur.
		var half_budget = MAX_TOTAL_ANGLE * 0.5

		# Expansion vers l'arrière
		var ai = closest_i
		var back_used = 0.0
		var steps_back = 0
		while steps_back < n - 2:
			var prev_i = (ai - 1 + n) % n
			var next_i = (ai + 1) % n
			var dp = pts[ai] - pts[prev_i]
			var dc = pts[next_i] - pts[ai]
			if dp.length() < 0.01 or dc.length() < 0.01: break
			var a = acos(clamp(dp.normalized().dot(dc.normalized()), -1.0, 1.0))
			if a < MIN_CURVE_ANGLE: break
			if a > MAX_STEP_ANGLE: break
			if back_used + a > half_budget: break
			back_used += a
			ai = prev_i
			steps_back += 1

		# Expansion vers l'avant
		var bi = (closest_i + 1) % n
		var fwd_used = 0.0
		var steps_fwd = 0
		while steps_fwd < n - 2:
			var next_i = (bi + 1) % n
			var dp = pts[bi] - pts[(bi - 1 + n) % n]
			var dc = pts[next_i] - pts[bi]
			if dp.length() < 0.01 or dc.length() < 0.01: break
			var a = acos(clamp(dp.normalized().dot(dc.normalized()), -1.0, 1.0))
			if a < MIN_CURVE_ANGLE: break
			if a > MAX_STEP_ANGLE: break
			if fwd_used + a > half_budget: break
			fwd_used += a
			bi = next_i
			steps_fwd += 1

		if closest_d < best_dist:
			best_dist  = closest_d
			best_shape = shape
			best_pts   = pts
			best_ai    = ai
			best_bi    = bi

	if best_shape == null: return []
	return [best_shape, best_pts, best_ai, best_bi]


func _make_curve_pts(a: Vector2, b: Vector2, m: Vector2) -> Array:
	var ctrl = 2.0 * m - 0.5 * (a + b)
	var pts = []
	for i in range(1, 18):
		var t = float(i) / 17.0
		pts.append((1.0-t)*(1.0-t)*a + 2.0*(1.0-t)*t*ctrl + t*t*b)
	return pts


func _build_pts(original: Array, ai: int, bi: int, curve_pts: Array) -> Array:
	var n = original.size()
	var out = []
	if ai <= bi:
		for i in range(ai + 1):
			out.append(original[i])
		for p in curve_pts:
			out.append(p)
		for i in range(bi + 1, n):
			out.append(original[i])
	else:
		# Cas wrappé : le segment passe par la "fermeture" du polygone
		# curve_pts[-1] = bi = pts[0] → doublon → on le saute
		for i in range(bi, ai + 1):
			out.append(original[i])
		for k in range(curve_pts.size() - 1):
			out.append(curve_pts[k])
	return out


func _flatten_pts(original: Array, ai: int, bi: int) -> Array:
	var n = original.size()
	var out = []
	if ai <= bi:
		for i in range(ai + 1):
			out.append(original[i])
		for i in range(bi, n):
			out.append(original[i])
	else:
		for i in range(bi, ai + 1):
			out.append(original[i])
	return out


# ── Overlay visuel ────────────────────────────────────────────────────────────

func _get_preview_line(shape) -> Node:
	if shape == null or not is_instance_valid(shape): return null
	# PatternShape.Outline est la Line2D du contour
	var outline = shape.get("Outline")
	if outline != null and outline.get_class() == "Line2D":
		return outline
	# Fallback : chercher parmi les enfants
	for child in shape.get_children():
		if child.get_class() == "Line2D":
			return child
	return null


func _set_line_texture_null(line):
	if line.has_method("set_texture"):
		line.call("set_texture", null)
	else:
		line.set("texture", null)


func _create_overlay(pts_a: Vector2, pts_b: Vector2):
	var line = _get_preview_line(_edit_shape)
	if line == null: return
	_overlay_line = line
	_overlay_line.default_color = MAGENTA
	_set_line_texture_null(_overlay_line)
	_overlay_line.width = 4.0
	_overlay_line.loop  = false
	_overlay_line.visible = true
	_overlay_line.points = PoolVector2Array([
		_edit_shape.to_local(pts_a),
		_edit_shape.to_local(pts_b)
	])


func _update_overlay(curve_pts: Array):
	if _overlay_line == null or not is_instance_valid(_overlay_line): return
	var pool = PoolVector2Array()
	pool.append(_edit_shape.to_local(_original_pts[_anchor_a_idx]))
	for p in curve_pts:
		pool.append(_edit_shape.to_local(p))
	_overlay_line.points = pool


func _remove_overlay():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points = PoolVector2Array()
		_overlay_line.visible = false
		_overlay_line.loop = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if _destroyed:
		return false
	if event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
		if _state == State.CURVE_PREVIEW:
			_cancel_curve()
			return true
		return false

	if not (event is InputEventMouseButton): return false
	if not event.pressed: return false

	if _state == State.CURVE_PREVIEW:
		if event.button_index == BUTTON_LEFT:
			_confirm_curve()
			return true
		if event.button_index == BUTTON_RIGHT:
			_confirm_curve()
			return false  # laisser DD traiter le clic droit
		return false

	if event.button_index != BUTTON_LEFT: return false
	if not event.shift: return false
	if not _is_edit_points_mode(): return false

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	var canvas_xform = world_ui.get_viewport().get_canvas_transform()
	var mouse_w: Vector2 = canvas_xform.affine_inverse().xform(event.position)

	if event.alt:
		return _try_flatten(mouse_w)
	return _try_start_curve(mouse_w)


func _try_start_curve(mouse_w: Vector2) -> bool:
	var found = _find_shape_and_segment(mouse_w)
	if found.empty():
		print("[PatternCurveEdit] aucun segment proche (threshold=%d)" % int(CLICK_THRESHOLD))
		return false

	_edit_shape   = found[0]
	_original_pts = found[1]
	_anchor_a_idx = found[2]
	_anchor_b_idx = found[3]

	_create_overlay(_original_pts[_anchor_a_idx], _original_pts[_anchor_b_idx])
	_state = State.CURVE_PREVIEW
	print("[PatternCurveEdit] mode courbe — segment [%d → %d]" % [_anchor_a_idx, _anchor_b_idx])
	return true


func _try_flatten(mouse_w: Vector2) -> bool:
	var found = _find_shape_and_segment(mouse_w)
	if found.empty():
		print("[PatternCurveEdit] flatten: aucun segment proche")
		return false
	var shape = found[0]
	var pts   = found[1]
	var ai    = found[2]
	var bi    = found[3]
	var new_pts = _flatten_pts(pts, ai, bi)
	_write_pts(shape, new_pts)
	_record_points_change(shape, pts, new_pts)
	print("[PatternCurveEdit] segment [%d → %d] aplati" % [ai, bi])
	return true


func _confirm_curve():
	# The live update loop has already written the final curved points into
	# the pattern shape. Snapshot them now, before we clear state, so we
	# can pair them with _original_pts (captured at _try_start_curve) into
	# a record.
	if _edit_shape != null and is_instance_valid(_edit_shape):
		var after = _read_global_pts(_edit_shape)
		_record_points_change(_edit_shape, _original_pts, after)
	_remove_overlay()
	_state        = State.IDLE
	_edit_shape   = null
	_original_pts = []
	print("[PatternCurveEdit] courbe confirmée")


func _cancel_curve():
	_remove_overlay()
	if _edit_shape != null and is_instance_valid(_edit_shape):
		_write_pts(_edit_shape, _original_pts)
	_state        = State.IDLE
	_edit_shape   = null
	_original_pts = []
	print("[PatternCurveEdit] courbe annulée")


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _destroyed:
		return
	if _g == null: return
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var mouse_w = world_ui.get("MousePosition")
	if mouse_w == null: return

	if _state == State.CURVE_PREVIEW:
		if _edit_shape == null or not is_instance_valid(_edit_shape):
			_reset_state()
			return
		var a: Vector2 = _original_pts[_anchor_a_idx]
		var b: Vector2 = _original_pts[_anchor_b_idx]
		var curve_pts  = _make_curve_pts(a, b, mouse_w)
		var new_pts    = _build_pts(_original_pts, _anchor_a_idx, _anchor_b_idx, curve_pts)
		_write_pts(_edit_shape, new_pts)
		_update_overlay(curve_pts)
		return

	# Hover preview : Shift + Edit Points mode
	if _is_edit_points_mode() and Input.is_key_pressed(KEY_SHIFT):
		var is_alt = Input.is_key_pressed(KEY_ALT)
		var found = _find_shape_and_segment(mouse_w)
		if not found.empty():
			var shape = found[0]
			var pts   = found[1]
			var ai: int = found[2]
			var bi: int = found[3]
			var color = BLUE if is_alt else MAGENTA
			var segment_changed = shape != _hover_shape or ai != _hover_ai or bi != _hover_bi \
				or (_state == State.HOVER and is_alt) \
				or (_state == State.FLATTEN_HOVER and not is_alt)
			if segment_changed:
				_clear_hover()
				_hover_shape = shape
				_hover_ai    = ai
				_hover_bi    = bi
			var line = _get_preview_line(shape)
			if line:
				_overlay_line = line
				_set_line_texture_null(line)
				line.width   = 4.0
				line.visible = true
				line.loop    = false
				line.default_color = color
				var n = pts.size()
				var pool = PoolVector2Array()
				if ai <= bi:
					for j in range(ai, bi + 1):
						pool.append(shape.to_local(pts[j]))
				else:
					for j in range(ai, n):
						pool.append(shape.to_local(pts[j]))
					for j in range(0, bi + 1):
						pool.append(shape.to_local(pts[j]))
				line.points = pool
			if is_alt:
				_state = State.FLATTEN_HOVER
			else:
				_state = State.HOVER
			return
	# Shift relâché ou hors mode
	if _state == State.HOVER or _state == State.FLATTEN_HOVER:
		_clear_hover()


func _clear_hover():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points   = PoolVector2Array()
		_overlay_line.visible  = false
		_overlay_line.loop     = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null
	_hover_shape  = null
	_hover_ai     = -1
	_hover_bi     = -1
	if _state == State.HOVER or _state == State.FLATTEN_HOVER:
		_state = State.IDLE


func _reset_state():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points   = PoolVector2Array()
		_overlay_line.visible  = false
		_overlay_line.loop     = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null
	_hover_shape  = null
	_hover_ai     = -1
	_hover_bi     = -1
	_edit_shape   = null
	_original_pts = []
	_anchor_a_idx = -1
	_anchor_b_idx = -1
	_state        = State.IDLE


# ── Undo ─────────────────────────────────────────────────────────────────────
# Points-based custom record. Called from _confirm_curve (after the live
# update loop has written the final curve into the pattern shape) and
# from _try_flatten (single-shot action).

var _PointsRecordScript = null


func _load_record_script() -> void:
	if _PointsRecordScript != null:
		return
	_PointsRecordScript = ResourceLoader.load(
		_g.Root + "library/points_history_record.gd", "GDScript", true)
	if _PointsRecordScript == null:
		print("[PatternCurveEdit] WARN: library/points_history_record.gd not found; undo disabled")


func _record_points_change(node, before: Array, after: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	if before.size() == 0 or after.size() == 0:
		return
	_load_record_script()
	if _PointsRecordScript == null:
		return
	if _g.Editor.get("History") == null:
		return
	var record = _PointsRecordScript.new()
	record.main_script = self
	record.node = node
	record.points_before = before.duplicate()
	record.points_after  = after.duplicate()
	_g.Editor.History.CreateCustomRecord(record)

