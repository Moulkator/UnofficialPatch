# wall_curve_edit.gd
# Ajoute le mode courbe (Shift+clic sur segment) en Edit Points mode pour les Walls.
#
# Utilisation :
#   - Être en Edit Points mode (bouton dans le panel PathTool)
#   - Shift+clic gauche sur un segment → entre en mode courbe (segment magenta)
#   - Bouger la souris → la courbe se met à jour en temps réel
#   - Clic gauche → confirme
#   - Échap → annule

var script_class = "tool"
var _g
var input_listener: Node
var _destroyed := false
const _META_KEY = "WallCurveEditListener"

enum State { IDLE, HOVER, FLATTEN_HOVER, CURVE_PREVIEW }
var _state = State.IDLE

var _edit_path        = null
var _original_pts: Array = []
var _overlay_line = null
var _hover_path = null
var _hover_ai: int = -1
var _hover_bi: int = -1
var _anchor_a_idx: int = -1
var _anchor_b_idx: int = -1

const CLICK_THRESHOLD = 80.0
const MAGENTA       = Color(1.0, 0.0, 1.0, 1.0)
const BLUE          = Color(0.0, 0.647, 1.0, 1.0)  # #00a5ff


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	# Nettoyer l'état au cas où on recharge une map
	_state        = State.IDLE
	_edit_path    = null
	_original_pts = []
	_anchor_a_idx = -1
	_anchor_b_idx = -1
	_overlay_line = null
	_hover_path   = null
	_hover_ai     = -1
	_hover_bi     = -1
	_install_listener()
	print("[WallEdit] initialized")


func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "WallCurveEditListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# ── Détection du mode Edit Points ────────────────────────────────────────────

func _is_edit_points_mode() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	var tool = editor.get("ActiveTool")
	if tool == null: return false
	# Identification positive : doit être exactement le WallTool
	var tools = editor.get("Tools")
	if tools == null: return false
	var wt = tools.get("WallTool")
	if wt == null or tool != wt: return false
	# Vérifier le bouton EditPoints
	var btn = wt.get("EditPoints")
	if btn == null:
		if wt.has_method("get_EditPoints"):
			btn = wt.call("get_EditPoints")
	if btn == null: return false
	return btn.get("pressed") == true


# ── Accès aux Pathways via Level ──────────────────────────────────────────────

func _get_all_walls() -> Array:
	if _g == null: return []
	var world = _g.get("World")
	if world == null: return []
	var level = world.call("GetCurrentLevel")
	if level == null: return []
	for child in level.get_children():
		if child.name == "Walls":
			var result = []
			for w in child.get_children():
				# Exclure les walls du FloorShape Tool (Type=0)
				if w.has_method("get_Type") and w.call("get_Type") == 0: continue
				result.append(w)
			return result
	return []


# ── Lecture sûre des EditPoints (via str + parsing) ───────────────────────────

func _read_global_pts(wall) -> Array:
	var raw = wall.call("get_Points")
	if raw == null: return []
	return _parse_pts(str(raw))


func _parse_pts(s: String) -> Array:
	var result = []
	s = s.strip_edges()
	if s.begins_with("[") and s.ends_with("]"):
		s = s.substr(1, s.length() - 2)
	if s.empty(): return result
	var parts = s.split("), (")
	for part in parts:
		part = part.strip_edges().trim_prefix("(").trim_suffix(")")
		var coords = part.split(", ")
		if coords.size() == 2:
			result.append(Vector2(float(coords[0]), float(coords[1])))
	return result


func _write_pts(wall, pts: Array):
	var was_loop = wall.call("get_Loop")
	var pool = PoolVector2Array()
	for p in pts: pool.append(p)
	wall.call("set_Points", pool)
	if was_loop:
		wall.call("set_Loop", true)
	wall.call("RemakeLines")
	if was_loop:
		wall.call("set_Loop", true)


# ── Parsing de la structure ancre / points interpolés ────────────────────────

# Angle minimum par pas pour être considéré "en train de courber"
const MIN_CURVE_ANGLE  = 0.03   # ~2° par pas minimum pour être "en courbe"
const MAX_STEP_ANGLE   = 0.30   # ~17° par pas max — au-delà = ancre angulaire
const MAX_TOTAL_ANGLE  = 3.14159 # 180° cumulé max


func _get_anchor_indices(pts: Array) -> Array:
	# Détecte les blocs de courbe par géométrie : séquence de points où chaque
	# pas tourne d'au moins MIN_CURVE_ANGLE et le total ne dépasse pas 180°.
	var n = pts.size()
	if n < 2: return []
	var anchors = [0]
	var i = 0
	while i < n - 1:
		var end = _find_curve_end(pts, i)
		if end > i + 1:
			anchors.append(end)
			i = end
		else:
			anchors.append(i + 1)
			i += 1
	return anchors


func _find_curve_end(pts: Array, start: int) -> int:
	# Retourne l'index de fin du bloc de courbe commençant à start.
	# Retourne start+1 si pas de courbe (= segment droit).
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

		if angle < MIN_CURVE_ANGLE: break         # trop droit → fin du bloc
		if angle > MAX_STEP_ANGLE: break          # trop anguleux → ancre → fin
		if total_angle + angle > MAX_TOTAL_ANGLE: break  # dépasserait 180° → fin
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


func _find_wall_and_segment(mouse_w: Vector2) -> Array:
	# Retourne [path, pts, anchor_a_idx, anchor_b_idx] ou []
	# La sélection est centrée sur le point le plus proche du curseur,
	# étendue dans les deux directions jusqu'à MAX_TOTAL_ANGLE/2 de chaque côté.
	var best_path  = null
	var best_pts   = []
	var best_ai    = -1
	var best_bi    = -1
	var best_dist: float = CLICK_THRESHOLD

	for pw in _get_all_walls():
		if not is_instance_valid(pw): continue
		var rect = pw.get("GlobalRect")
		if rect != null and not rect.grow(CLICK_THRESHOLD).has_point(mouse_w): continue

		var pts = _read_global_pts(pw)
		if pts.size() < 2: continue

		# Trouver le point le plus proche du curseur
		var n0 = pts.size()
		var is_closed0 = pw.call("get_Loop") == true
		var closest_i = -1
		var closest_d = CLICK_THRESHOLD
		var seg_count = n0 - 1 + (1 if is_closed0 else 0)
		for j in range(seg_count):
			var a_pt = pts[j]
			var b_pt = pts[(j + 1) % n0]
			var d = _dist_point_to_seg(mouse_w, a_pt, b_pt)
			if d < closest_d:
				closest_d = d
				closest_i = j

		if closest_i < 0: continue

		var n = pts.size()
		var is_closed = pw.call("get_Loop") == true

		# Expansion centrée curseur : 90° de chaque côté, wrap sur path fermé, sans stops.
		var ai = closest_i
		var angle_back = 0.0
		var steps_back = 0
		while steps_back < n - 2:
			var prev_i = ai - 1
			if prev_i < 0:
				if is_closed: prev_i = n - 2
				else: break
			var next_i = ai + 1
			if next_i >= n: next_i = 1 if is_closed else n - 1
			var dp = pts[ai] - pts[prev_i]
			var dc = pts[next_i] - pts[ai]
			if dp.length() < 0.01 or dc.length() < 0.01:
				ai = prev_i
				continue
			var a = acos(clamp(dp.normalized().dot(dc.normalized()), -1.0, 1.0))
			if a > MAX_STEP_ANGLE: break
			if angle_back + a > MAX_TOTAL_ANGLE / 2.0: break
			angle_back += a
			ai = prev_i
			steps_back += 1

		var bi = (closest_i + 1) % n if is_closed else min(closest_i + 1, n - 1)
		var angle_fwd = 0.0
		var steps_fwd = 0
		while steps_fwd < n - 2:
			var next_i = bi + 1
			if next_i >= n:
				if is_closed: next_i = 0
				else: break
			var prev_i = bi - 1
			if prev_i < 0: prev_i = n - 2 if is_closed else 0
			var dc = pts[bi] - pts[prev_i]
			var dn = pts[next_i] - pts[bi]
			if dc.length() < 0.01 or dn.length() < 0.01:
				bi = next_i
				continue
			var a = acos(clamp(dc.normalized().dot(dn.normalized()), -1.0, 1.0))
			if a > MAX_STEP_ANGLE: break
			if angle_fwd + a > MAX_TOTAL_ANGLE / 2.0: break
			angle_fwd += a
			bi = next_i
			steps_fwd += 1

		if closest_d < best_dist:
			best_dist = closest_d
			best_path = pw
			best_pts  = pts
			best_ai   = ai
			best_bi   = bi

	if best_path == null: return []
	return [best_path, best_pts, best_ai, best_bi]


func _make_curve_pts(a: Vector2, b: Vector2, m: Vector2) -> Array:
	# Bézier quadratique passant par m à t=0.5 — endpoint inclus (t=17/17=1.0)
	var ctrl = 2.0 * m - 0.5 * (a + b)
	var pts = []
	for i in range(1, 18):
		var t = float(i) / 17.0
		pts.append((1.0-t)*(1.0-t)*a + 2.0*(1.0-t)*t*ctrl + t*t*b)
	return pts


func _build_pts(original: Array, ai: int, bi: int, curve_pts: Array) -> Array:
	# curve_pts inclut l'endpoint (bi) via t=1.0.
	var out = []
	if ai <= bi:
		for i in range(ai + 1):
			out.append(original[i])
		for p in curve_pts:
			out.append(p)
		for i in range(bi + 1, original.size()):   # bi déjà dans curve_pts[-1]
			out.append(original[i])
	else:
		# Cas wrappé : curve_pts[-1] = bi = pts[0] = A → doublon → on le saute.
		# set_Loop ferme le dernier point interpolé → A proprement.
		for i in range(bi, ai + 1):
			out.append(original[i])
		for k in range(curve_pts.size() - 1):
			out.append(curve_pts[k])
	return out



# ── Overlay visuel ────────────────────────────────────────────────────────────
# Utilise le Line2D enfant natif du path (super=False, z_index=4096) —
# le même nœud que DD utilise pour la preview en mode draw.

func _get_preview_line(path) -> Node:
	if path == null or not is_instance_valid(path): return null
	for child in path.get_children():
		if child.get_class() == "Line2D" and child.z_index == 4096:
			return child
	return null


func _create_overlay(pts_a: Vector2, pts_b: Vector2):
	var line = _get_preview_line(_edit_path)
	if line == null: return
	_overlay_line = line
	_overlay_line.default_color = MAGENTA
	_overlay_line.set("texture", null)
	_overlay_line.width = 2.0
	_overlay_line.loop = false
	var parent = _edit_path
	_overlay_line.points = PoolVector2Array([parent.to_local(pts_a), parent.to_local(pts_b)])


func _update_overlay(curve_pts: Array):
	if _overlay_line == null or not is_instance_valid(_overlay_line): return
	var parent = _edit_path
	var pool = PoolVector2Array()
	pool.append(parent.to_local(_original_pts[_anchor_a_idx]))
	for p in curve_pts: pool.append(parent.to_local(p))
	# curve_pts[-1] est déjà l'endpoint → pas de doublon
	_overlay_line.points = pool


func _remove_overlay():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points = PoolVector2Array()
		_overlay_line.visible = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null


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

	# Clic droit OU clic gauche (avec ou sans Shift) = confirmer la courbe
	if _state == State.CURVE_PREVIEW:
		if event.button_index == BUTTON_RIGHT or event.button_index == BUTTON_LEFT:
			_confirm_curve()
			return true
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
	var found = _find_wall_and_segment(mouse_w)
	if found.empty():
		print("[WallEdit] aucun segment proche (threshold=%d)" % int(CLICK_THRESHOLD))
		return false

	_edit_path      = found[0]
	_original_pts   = found[1]
	_anchor_a_idx   = found[2]
	_anchor_b_idx   = found[3]

	pass  # pas de modification de texture

	_create_overlay(_original_pts[_anchor_a_idx], _original_pts[_anchor_b_idx])
	_state = State.CURVE_PREVIEW
	print("[WallEdit] mode courbe — segment [%d → %d]" % [_anchor_a_idx, _anchor_b_idx])
	return true


func _try_flatten(mouse_w: Vector2) -> bool:
	var found = _find_wall_and_segment(mouse_w)
	if found.empty():
		print("[WallEdit] flatten: aucun segment proche")
		return false
	var pw   = found[0]
	var pts  = found[1]
	var ai   = found[2]
	var bi   = found[3]
	var new_pts = _flatten_pts(pts, ai, bi)
	_write_pts(pw, new_pts)
	_record_points_change(pw, pts, new_pts)
	print("[WallEdit] segment [%d → %d] aplati" % [ai, bi])
	return true


func _flatten_pts(original: Array, ai: int, bi: int) -> Array:
	# Garde seulement pts[ai] et pts[bi], supprime tous les points intermédiaires.
	var out = []
	if ai <= bi:
		for i in range(ai + 1):
			out.append(original[i])
		for i in range(bi, original.size()):
			out.append(original[i])
	else:
		# Cas wrappé (segment DA) : on garde pts[0..ai] sans doublon final.
		# set_Loop(true) ferme DA en ligne droite automatiquement.
		for i in range(bi, ai + 1):
			out.append(original[i])
	return out


func _confirm_curve():
	# The live update loop has already written the final curved points into
	# the wall. Snapshot them now, before we clear state, so we can pair
	# them with _original_pts (captured at _try_start_curve) into a record.
	if _edit_path != null and is_instance_valid(_edit_path):
		var after = _read_global_pts(_edit_path)
		_record_points_change(_edit_path, _original_pts, after)
	_remove_overlay()
	_state        = State.IDLE
	_edit_path    = null
	_original_pts = []
	print("[WallEdit] courbe confirmée")


func _cancel_curve():
	_remove_overlay()
	if _edit_path != null and is_instance_valid(_edit_path):
		_write_pts(_edit_path, _original_pts)
		_restore_color()
	_state        = State.IDLE
	_edit_path    = null
	_original_pts = []
	print("[WallEdit] courbe annulée")


func _restore_color():
	pass  # rien à restaurer, on ne touche plus à la texture


# ── Update ────────────────────────────────────────────────────────────────────

var _debug_wall_printed = false

func update(_delta):
	if _destroyed:
		return
	if _g == null: return
	var editor = _g.get("Editor")
	if editor == null: return
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var mouse_w = world_ui.get("MousePosition")
	if mouse_w == null: return

	if not _debug_wall_printed:
		var pws = _get_all_walls()
		if not pws.empty():
			var pw = pws[0]
			_debug_wall_printed = true
			var methods = []
			for m in pw.get_method_list():
				var n = m["name"].to_lower()
				if "loop" in n or "clos" in n: methods.append(m["name"])
			var props = []
			for p in pw.get_property_list():
				var n = p["name"].to_lower()
				if "loop" in n or "clos" in n: props.append(p["name"])

	if _state == State.CURVE_PREVIEW:
		if _edit_path == null or not is_instance_valid(_edit_path):
			_reset_state()
			return
		var a: Vector2 = _original_pts[_anchor_a_idx]
		var b: Vector2 = _original_pts[_anchor_b_idx]
		var curve_pts  = _make_curve_pts(a, b, mouse_w)
		var new_pts    = _build_pts(_original_pts, _anchor_a_idx, _anchor_b_idx, curve_pts)
		_write_pts(_edit_path, new_pts)
		_update_overlay(curve_pts)
		return

	# Hover preview : Shift enfoncé + Edit Points mode
	if _is_edit_points_mode() and Input.is_key_pressed(KEY_SHIFT):
		var is_alt = Input.is_key_pressed(KEY_ALT)
		var found = _find_wall_and_segment(mouse_w)
		if not found.empty():
			var pw = found[0]
			var pts = found[1]
			var ai: int = found[2]
			var bi: int = found[3]
			var color = BLUE if is_alt else MAGENTA
			# Redessiner à chaque frame — DD peut réinitialiser le Line2D natif entre deux frames.
			var segment_changed = pw != _hover_path or ai != _hover_ai or bi != _hover_bi or _state == State.HOVER and is_alt or _state == State.FLATTEN_HOVER and not is_alt
			if segment_changed:
				_clear_hover()
				_hover_path = pw
				_hover_ai   = ai
				_hover_bi   = bi
			var line = _get_preview_line(pw)
			if line:
				_overlay_line = line
				line.set("texture", null)
				line.width = 2.0
				line.visible = true
				line.loop = false
				line.default_color = color
				var pool = PoolVector2Array()
				if ai <= bi:
					for j in range(ai, bi + 1):
						pool.append(pw.to_local(pts[j]))
				else:
					for j in range(ai, pts.size()):
						pool.append(pw.to_local(pts[j]))
					for j in range(0, bi + 1):
						pool.append(pw.to_local(pts[j]))
				line.points = pool
			if is_alt:
				_state = State.FLATTEN_HOVER
			else:
				_state = State.HOVER
			return
	# Shift relâché ou hors Edit Points : nettoyer le hover
	if _state == State.HOVER or _state == State.FLATTEN_HOVER:
		_clear_hover()

func _clear_hover():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points = PoolVector2Array()
		_overlay_line.visible = false
		_overlay_line.loop = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null
	_hover_path   = null
	_hover_ai     = -1
	_hover_bi     = -1
	if _state == State.HOVER or _state == State.FLATTEN_HOVER:
		_state = State.IDLE


func _reset_state():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.points = PoolVector2Array()
		_overlay_line.visible = false
		_overlay_line.loop = false
		_overlay_line.default_color = Color(0.4, 0.5, 1.0, 1.0)
	_overlay_line = null
	_hover_path   = null
	_hover_ai     = -1
	_hover_bi     = -1
	_edit_path    = null
	_original_pts = []
	_anchor_a_idx = -1
	_anchor_b_idx = -1
	_state        = State.IDLE


# ── Undo ─────────────────────────────────────────────────────────────────────
# Points-based custom record. Called from _confirm_curve (after the live
# update loop has written the final curve into the wall) and from
# _try_flatten (single-shot action).

var _PointsRecordScript = null


func _load_record_script() -> void:
	if _PointsRecordScript != null:
		return
	_PointsRecordScript = ResourceLoader.load(
		_g.Root + "library/points_history_record.gd", "GDScript", true)
	if _PointsRecordScript == null:
		print("[WallEdit] WARN: library/points_history_record.gd not found; undo disabled")


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

