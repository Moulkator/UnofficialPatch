# pattern_paint_bucket.gd
# Paint Bucket pour le PatternShape Tool.
#
# Utilisation :
#   - Dans le PatternShapeTool, cliquer sur l'icône seau dans la barre des formes
#   - Clic gauche n'importe où dans la map → remplit la région contenant le clic.
#     Les bordures d'une région peuvent être un mix de : murs (fermés ou ouverts),
#     paths (fermés ou ouverts), et bords de la map. Les formes fermées internes
#     à la région deviennent des trous (multi-trous supporté).
#   - Shift+clic → inclut aussi les PatternShapes existants comme barrières
#   - Cliquer sur une autre forme (rect/circle/polygon) désactive le mode fill
#
# Implémentation :
#   1. Rectangle aux bornes de la map.
#   2. Pour chaque mur/path : inflater la polyline en fine bande (offset_polyline_2d).
#      Les endpoints proches d'un bord de map sont snappés sur le bord pour
#      fermer correctement les régions.
#   3. Soustraire toutes ces bandes du rectangle (clip_polygons_2d).
#   4. Région = polygone contenant le clic ; trous = polygones intérieurs
#      avec winding opposé.
#   5. Bridge-cut chaque trou dans la région pour produire un polygone simple
#      (PatternShape ne supporte pas les holes nativement).

var _g
var ui_util
var input_listener: Node
const _META_KEY = "PatternPaintBucketListener"

# UI
var _bucket_button: Button = null
var _bucket_active := false
var _shape_buttons: Array = []
var _shape_hbox = null
var _prev_mode := -1

# Curseur
var _bucket_cursor_tex: Texture = null
var _bucket_cursor_crossed_tex: Texture = null
var _cursor_applied := false
var _cursor_is_crossed := false

# Géométrie
const BARRIER_THICKNESS = 2.0       # px de chaque côté de la polyline. Doit être suffisant
                                    # pour que deux barrières perpendiculaires se chevauchent
                                    # de façon robuste au croisement (sinon Clipper peut les
                                    # voir comme juste tangentes, et la peinture passe à travers).
const EDGE_SNAP_THRESHOLD = 16.0    # endpoint à <N px d'un bord → snappé sur le bord
const EDGE_OVERSHOOT = 2.0          # quand on snappe, on dépasse de N px pour bien couper


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_load_cursor_texture()
	_inject_ui()
	_install_listener()
	print("[PatternPaintBucket] initialized")


func _load_cursor_texture():
	var path = _g.Root + "icons/bucket_cursor.png"
	var img = Image.new()
	if img.load(path) != OK:
		print("[PatternPaintBucket] bucket_cursor.png not found at ", path)
		return
	_bucket_cursor_tex = ImageTexture.new()
	_bucket_cursor_tex.create_from_image(img, 0)

	var path_crossed = _g.Root + "icons/bucket_cursor_crossed.png"
	var img_crossed = Image.new()
	if img_crossed.load(path_crossed) != OK:
		print("[PatternPaintBucket] bucket_cursor_crossed.png not found at ", path_crossed)
		return
	_bucket_cursor_crossed_tex = ImageTexture.new()
	_bucket_cursor_crossed_tex.create_from_image(img_crossed, 0)


func _load_icon_texture(filename: String) -> Texture:
	var path = _g.Root + "icons/" + filename
	var img = Image.new()
	if img.load(path) != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject_ui():
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null:
		print("[PatternPaintBucket] PatternShapeTool not found")
		return

	var tool_panel = _g.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if tool_panel == null:
		print("[PatternPaintBucket] PatternShapeTool panel not found")
		return

	var align = tool_panel.get("Align")
	if align == null:
		print("[PatternPaintBucket] Align not found")
		return

	# Chercher le HBoxContainer contenant les boutons de forme (toggle group)
	_shape_hbox = null
	for child in align.get_children():
		if child is HBoxContainer:
			var has_toggles = false
			for btn in child.get_children():
				if btn is Button and btn.toggle_mode:
					has_toggles = true
					break
			if has_toggles:
				_shape_hbox = child
				break

	if _shape_hbox == null:
		print("[PatternPaintBucket] Shape buttons HBox not found, inserting before EditPoints")
		var ep_btn = pat_tool.get("EditPoints")
		if ep_btn != null:
			_shape_hbox = ep_btn.get_parent()

	if _shape_hbox == null:
		print("[PatternPaintBucket] Cannot find a place to inject button")
		return

	_shape_buttons = []
	for child in _shape_hbox.get_children():
		if child is Button and child.toggle_mode:
			_shape_buttons.append(child)
			if not child.is_connected("pressed", self, "_on_shape_button_pressed"):
				child.connect("pressed", self, "_on_shape_button_pressed")

	_bucket_button = Button.new()
	_bucket_button.toggle_mode = true
	_bucket_button.hint_tooltip = "Paint Bucket: click any region bounded by walls, paths, or map edges. Shift to include existing pattern shapes as barriers."
	var icon = _load_icon_texture("bucket.png")
	if icon != null:
		_bucket_button.icon = icon
	_bucket_button.connect("toggled", self, "_on_bucket_toggled")

	_shape_hbox.add_child(_bucket_button)

	print("[PatternPaintBucket] Bucket button injected in shape buttons row (%d existing buttons)" % _shape_buttons.size())


# ── Quand l'utilisateur clique un bouton de forme DD (rect/circle/polygon) ───

func _on_shape_button_pressed():
	if _bucket_active:
		_prev_mode = -1
		_bucket_button.pressed = false


# ── Quand le bucket est toggled ──────────────────────────────────────────────

func _on_bucket_toggled(pressed: bool):
	_bucket_active = pressed

	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	if pressed:
		_prev_mode = pat_tool.get("Mode") if pat_tool.get("Mode") != null else 0
		for btn in _shape_buttons:
			if is_instance_valid(btn):
				btn.pressed = false

		var ep = pat_tool.get("EditPoints")
		if ep != null and ep.get("pressed") == true:
			ep.set("pressed", false)

		_apply_cursor()
		_hide_preview()
	else:
		if _prev_mode >= 0 and _prev_mode < _shape_buttons.size():
			if is_instance_valid(_shape_buttons[_prev_mode]):
				_shape_buttons[_prev_mode].pressed = true

		_remove_cursor()
		_show_preview()

	print("[PatternPaintBucket] Bucket mode: ", pressed)


# ── Preview pointer (le pointeur jaune sur la map) ──────────────────────────

var _saved_cursor_mode := -1


func _hide_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var cur = world_ui.get("CursorMode")
	if cur != null and cur != 0:
		_saved_cursor_mode = cur
	world_ui.set("CursorMode", 0)


func _show_preview():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	if _saved_cursor_mode >= 0:
		world_ui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1
	else:
		world_ui.set("CursorMode", 1)


# ── Listener ─────────────────────────────────────────────────────────────────

func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "PatternPaintBucketListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# ── Curseur ──────────────────────────────────────────────────────────────────

func _apply_cursor(crossed := false):
	var tex = _bucket_cursor_crossed_tex if crossed else _bucket_cursor_tex
	if tex != null:
		Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(0, 0))
		_cursor_applied = true
		_cursor_is_crossed = crossed


func _remove_cursor():
	if _cursor_applied:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_applied = false
		_cursor_is_crossed = false


func _get_mouse_world_pos() -> Vector2:
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return Vector2.ZERO
	var vp = world_ui.get_viewport()
	if vp == null: return Vector2.ZERO
	var canvas_xform = vp.get_canvas_transform()
	return canvas_xform.affine_inverse().xform(vp.get_mouse_position())


func _is_over_fillable_zone() -> bool:
	# Fillable = dans les bornes de la map (on ne refait pas tout le calcul de
	# région à chaque frame). Si le clic tombe pile sur l'épaisseur d'un mur,
	# _do_fill bailera silencieusement.
	var mouse_world = _get_mouse_world_pos()
	var bounds = _get_map_bounds_polygon()
	if bounds.size() < 3:
		return false
	return _point_in_polygon(mouse_world, bounds)


# ── Détection du PatternShapeTool actif ──────────────────────────────────────

func _is_pattern_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	var tool_name = editor.get("ActiveToolName")
	return tool_name == "PatternShapeTool"


# ── Accès aux données du niveau ──────────────────────────────────────────────

func _get_current_level():
	if _g == null: return null
	var world = _g.get("World")
	if world == null: return null
	return world.call("GetCurrentLevel")


func _get_all_pattern_shapes() -> Array:
	var level = _get_current_level()
	if level == null: return []
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return []
	if not ps_node.has_method("GetShapes"): return []
	var shapes = ps_node.call("GetShapes")
	if shapes == null: return []
	return shapes


# ── Extraction des polylines & polygones ─────────────────────────────────────

func _get_path_polyline(path_node) -> Array:
	# Les paths DD sont des Line2D : `.points` contient la polyline interpolée
	# (avec les points de courbe) en coords locales — c'est ce que voit l'utilisateur.
	# `GlobalEditPoints` ne contient que les sommets d'édition (sans interpolation),
	# trop approximatif pour les courbes.
	var raw = path_node.get("points")
	if raw == null or raw.size() < 2:
		raw = path_node.get("GlobalEditPoints")
		if raw == null: return []
		return _to_array(raw)
	var xform = path_node.get_global_transform()
	var pts = []
	for p in raw:
		pts.append(xform.xform(p))
	return pts


func _get_pattern_polygon(shape) -> Array:
	var raw = shape.get("GlobalPolygon")
	if raw == null: return []
	return _to_array(raw)


func _to_array(pool) -> Array:
	var a = []
	for p in pool: a.append(p)
	return a


# ── Géométrie ────────────────────────────────────────────────────────────────

func _point_in_polygon(point: Vector2, polygon: Array) -> bool:
	var n = polygon.size()
	if n < 3: return false
	var inside = false
	var j = n - 1
	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
			(point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


func _polygon_area(pts: Array) -> float:
	var area = 0.0
	var n = pts.size()
	for i in range(n):
		var j = (i + 1) % n
		area += pts[i].x * pts[j].y
		area -= pts[j].x * pts[i].y
	return abs(area) * 0.5


# Tous les sommets de `inner` doivent être dans `outer`. OK pour des polygones
# qui ne se croisent pas (cas standard après clipping).
func _polygon_inside_polygon(inner: Array, outer: Array) -> bool:
	for p in inner:
		if not _point_in_polygon(p, outer): return false
	return true


# ── Bornes de la map ─────────────────────────────────────────────────────────

func _get_map_bounds_polygon() -> Array:
	if _g == null: return []
	var world = _g.get("World")
	if world == null: return []
	var cs = world.get("GridCellSize")
	var w_tiles = world.get("Width")
	var h_tiles = world.get("Height")
	if cs == null or w_tiles == null or h_tiles == null: return []
	var w = float(w_tiles) * cs.x
	var h = float(h_tiles) * cs.y
	# Pas de marge ici : la map_rect est exactement aux bornes. Les endpoints
	# de murs qui doivent toucher le bord sont snappés avec un léger overshoot.
	return [Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h)]


func _snap_endpoint_to_map_edge(p: Vector2, threshold: float) -> Vector2:
	if _g == null: return p
	var world = _g.get("World")
	if world == null: return p
	var cs = world.get("GridCellSize")
	var w_tiles = world.get("Width")
	var h_tiles = world.get("Height")
	if cs == null or w_tiles == null or h_tiles == null: return p
	var w = float(w_tiles) * cs.x
	var h = float(h_tiles) * cs.y
	var dl = p.x
	var dr = w - p.x
	var dt = p.y
	var db = h - p.y
	var dmin = min(min(dl, dr), min(dt, db))
	if dmin > threshold:
		return p
	# Snap sur le bord le plus proche, léger overshoot pour garantir que le
	# barrier dépasse vraiment le rectangle après inflate.
	if dmin == dl: return Vector2(-EDGE_OVERSHOOT, p.y)
	if dmin == dr: return Vector2(w + EDGE_OVERSHOOT, p.y)
	if dmin == dt: return Vector2(p.x, -EDGE_OVERSHOOT)
	if dmin == db: return Vector2(p.x, h + EDGE_OVERSHOOT)
	return p


# ── Construction des barriers ────────────────────────────────────────────────

func _build_barriers(include_patterns: bool) -> Dictionary:
	# Retourne un Dictionary :
	#   closed_pairs : liste de {outer: Array, inner: Array (ou null)} pour les
	#       polylines fermées. Pour chaque mur fermé : on soustrait outer (offset
	#       extérieur, retire mur+pièce) PUIS on ajoute inner (offset intérieur,
	#       réintroduit la pièce comme région à part). Le traitement entrelacé
	#       permet aux outer des murs INTÉRIEURS de couper correctement les inner
	#       des murs EXTÉRIEURS déjà ajoutés.
	#   subs_last : polylines ouvertes + patterns. Soustraits après — ils coupent
	#       à travers tout, y compris les intérieurs de pièces.
	var result = {"closed_pairs": [], "subs_last": []}
	var level = _get_current_level()
	if level == null: return result

	# Murs (ouverts ou fermés)
	var walls_node = level.get("Walls")
	if walls_node != null:
		for child in walls_node.get_children():
			if not is_instance_valid(child): continue
			var pts_raw = child.get("Points")
			if pts_raw == null or pts_raw.size() < 2: continue
			# Les Points d'un Wall sont en espace LOCAL au nœud : appliquer son
			# transform global (no-op si identité). Sans ça, un mur déplacé/tourné
			# via l'outil Select donne une région décalée.
			var xform = child.get_global_transform()
			var pts = []
			for p in pts_raw:
				pts.append(xform.xform(p))
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	# Paths (ouverts ou fermés)
	var paths_node = level.get("Pathways")
	if paths_node != null:
		for child in paths_node.get_children():
			if not is_instance_valid(child): continue
			var pts = _get_path_polyline(child)
			if pts.size() < 2: continue
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	# PatternShapes (filled polygons soustraits APRÈS — pour qu'ils coupent à travers les pièces)
	if include_patterns:
		for shape in _get_all_pattern_shapes():
			var pts = _get_pattern_polygon(shape)
			if pts.size() >= 3:
				result.subs_last.append(pts)

	return result


# Offsette CHAQUE segment de la polyline en rectangle convexe (END_SQUARE) et
# l'ajoute aux barriers à soustraire. Robuste aux auto-intersections : des
# rectangles simples ne génèrent jamais de "trou de remplissage" Clipper au
# croisement (contrairement à un offset global d'une bande auto-intersectante).
# END_SQUARE fait dépasser chaque rectangle de BARRIER_THICKNESS → les segments
# consécutifs se recouvrent aux sommets et scellent les coins.
# Si `closed`, le segment de fermeture (dernier → premier) est inclus.
func _append_segment_quads(pts: Array, closed: bool, out: Dictionary):
	var n = pts.size()
	if n < 2: return
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		if a.distance_to(b) < 0.01:
			continue
		var seg_offset = Geometry.offset_polyline_2d([a, b], BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_SQUARE)
		for poly in seg_offset:
			if poly.size() >= 3:
				out.subs_last.append(_to_array(poly))


# La polyline se croise-t-elle elle-même ? Teste chaque paire de segments non
# adjacents. O(N²), suffisant pour des murs. Si `closed`, inclut le segment de
# fermeture et traite premier/dernier segments comme adjacents.
func _polyline_self_intersects(pts: Array, closed: bool) -> bool:
	var n = pts.size()
	if n < 4: return false
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a1 = pts[i]
		var a2 = pts[(i + 1) % n]
		for j in range(i + 1, seg_count):
			if j == i + 1:
				continue  # segments adjacents : partagent un sommet
			if closed and i == 0 and j == seg_count - 1:
				continue  # fermeture adjacente au premier segment
			var b1 = pts[j]
			var b2 = pts[(j + 1) % n]
			if Geometry.segment_intersects_segment_2d(a1, a2, b1, b2) != null:
				return true
	return false


func _classify_polyline_barrier(pts: Array, loop: bool, out: Dictionary):
	if pts.size() < 2: return

	# Détection de duplicate closing point (commune aux paths Loop=true avec
	# duplicate et aux polylines fermées par coïncidence)
	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) < 2.0:
		pts.pop_back()
		loop = true
	if pts.size() < 2: return

	if not loop:
		# Polyline ouverte : snap endpoints au bord de map, puis soustraction
		# par segment (cf. _append_segment_quads).
		pts[0] = _snap_endpoint_to_map_edge(pts[0], EDGE_SNAP_THRESHOLD)
		pts[pts.size() - 1] = _snap_endpoint_to_map_edge(pts[pts.size() - 1], EDGE_SNAP_THRESHOLD)
		_append_segment_quads(pts, false, out)
		return

	# Loop qui se croise lui-même (plusieurs cellules tracées par un seul mur,
	# ex. une grille de pièces) : l'offset global END_JOINED ne renvoie qu'un
	# couple outer/inner et ne sépare pas les cellules internes — on ne peut
	# remplir qu'une cellule. On retombe sur la soustraction par segment, qui
	# produit une subdivision planaire complète → chaque cellule devient sa
	# propre région remplissable.
	if _polyline_self_intersects(pts, true):
		_append_segment_quads(pts, true, out)
		return

	# Polyline fermée simple : offset extérieur + offset intérieur
	var offset_result = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_JOINED)
	var polys = []
	for b in offset_result:
		if b.size() >= 3:
			polys.append(_to_array(b))
	if polys.size() == 0:
		return
	if polys.size() == 1:
		# Anneau dégénéré (intérieur collapsé sur mur trop fin) : juste soustraire
		out.closed_pairs.append({"outer": polys[0], "inner": null})
		return
	# Plus gros = offset extérieur (à soustraire), plus petit = intérieur (à ajouter)
	var i_big := 0
	var i_small := 1
	if _polygon_area(polys[1]) > _polygon_area(polys[0]):
		i_big = 1; i_small = 0
	out.closed_pairs.append({"outer": polys[i_big], "inner": polys[i_small]})
	# Polygones supplémentaires (auto-intersection rare) : soustractions sans inner
	for i in range(polys.size()):
		if i == i_big or i == i_small: continue
		out.closed_pairs.append({"outer": polys[i], "inner": null})


# ── Bridge cut : extérieur + trou → polygone simple ──────────────────────────

# Splice un trou dans un polygone extérieur via une "coupe invisible" : on relie
# le sommet de `outer` le plus proche d'un sommet de `hole`, on parcourt le trou,
# puis on revient. Les deux arêtes du pont se superposent (aire nulle).
# Les windings de outer et hole doivent être opposés.
func _build_bridged_polygon(outer: Array, hole: Array) -> Array:
	var h = []
	for p in hole: h.append(p)
	if Geometry.is_polygon_clockwise(outer) == Geometry.is_polygon_clockwise(h):
		h.invert()

	var bi := 0
	var bj := 0
	var bd := INF
	for i in range(outer.size()):
		for j in range(h.size()):
			var d = outer[i].distance_squared_to(h[j])
			if d < bd:
				bd = d; bi = i; bj = j

	var out = []
	for k in range(bi + 1):
		out.append(outer[k])
	var n = h.size()
	for k in range(n + 1):
		out.append(h[(bj + k) % n])
	out.append(outer[bi])
	for k in range(bi + 1, outer.size()):
		out.append(outer[k])
	return out


# ── Multi-trous : splice tous les trous en étoile depuis l'outer ─────────────
# Le bridge cut itératif (chaque trou bridgé dans le résultat du précédent)
# fait croiser des bridges quand les trous sont nombreux ou proches. Ici chaque
# trou est connecté DIRECTEMENT à l'outer original avec un bridge qui évite
# explicitement de traverser les autres trous. On splice ensuite tous les
# bridges en une seule passe en parcourant l'outer.
func _bridge_holes_into_outer(outer: Array, holes: Array) -> Array:
	if holes.size() == 0:
		return outer

	var outer_cw = Geometry.is_polygon_clockwise(outer)

	# Préparer chaque trou avec winding opposé à l'outer
	var prepared = []
	for h in holes:
		var h_pts = []
		for p in h: h_pts.append(p)
		if Geometry.is_polygon_clockwise(h_pts) == outer_cw:
			h_pts.invert()
		prepared.append(h_pts)

	# Pour chaque trou : pont par PROJECTION du sommet le plus proche sur la
	# frontière (arête) de outer. Donne un pont court et perpendiculaire à outer,
	# au lieu d'une longue diagonale entre sommets. Moins de risque que des clips
	# ultérieurs (path, autres murs) coupent le pont et créent des frontières
	# fantômes le long de la trajectoire diagonale.
	var bridges = []
	for h_idx in range(prepared.size()):
		var info = _find_projection_bridge(outer, prepared[h_idx])
		bridges.append(info)

	# Trier par (edge_idx, t) pour traverser outer en un seul passage. Plusieurs
	# ponts sur la même arête sont spliçés par ordre de t croissant.
	bridges.sort_custom(self, "_sort_bridges_by_edge_and_t")

	var result = []
	var b_idx = 0
	for i in range(outer.size()):
		result.append(outer[i])
		while b_idx < bridges.size() and bridges[b_idx].edge_idx == i:
			var b = bridges[b_idx]
			# Insère le point de pont (projection sur l'arête outer[i]→outer[i+1])
			result.append(b.bridge_pt)
			# Parcourt le trou en cycle complet depuis hi
			var h_pts = b.hole
			var n = h_pts.size()
			for k in range(n + 1):
				result.append(h_pts[(b.hi + k) % n])
			# Revient au point de pont (arête coincidente avec celle d'entrée)
			result.append(b.bridge_pt)
			b_idx += 1
	return result


# Trouve le pont de longueur minimale entre la frontière d'outer et un sommet
# de hole. Pour chaque sommet de hole, calcule sa projection sur chaque arête
# d'outer. Retourne la projection la plus proche.
func _find_projection_bridge(outer: Array, hole: Array) -> Dictionary:
	var best_d := INF
	var best_hi := 0
	var best_edge_idx := 0
	var best_t := 0.0
	var best_bridge_pt := Vector2.ZERO
	var n_out = outer.size()
	for h_idx in range(hole.size()):
		var h_pt: Vector2 = hole[h_idx]
		for e_idx in range(n_out):
			var a: Vector2 = outer[e_idx]
			var b: Vector2 = outer[(e_idx + 1) % n_out]
			var ab = b - a
			var len_sq = ab.length_squared()
			if len_sq < 0.001: continue
			var t = clamp(ab.dot(h_pt - a) / len_sq, 0.0, 1.0)
			var proj = a + ab * t
			var d = h_pt.distance_squared_to(proj)
			if d < best_d:
				best_d = d
				best_hi = h_idx
				best_edge_idx = e_idx
				best_t = t
				best_bridge_pt = proj
	return {
		"hi": best_hi,
		"edge_idx": best_edge_idx,
		"t": best_t,
		"bridge_pt": best_bridge_pt,
		"hole": hole,
	}


func _sort_bridges_by_edge_and_t(a, b) -> bool:
	if a.edge_idx != b.edge_idx:
		return a.edge_idx < b.edge_idx
	return a.t < b.t


# Le segment p1-p2 traverse-t-il l'intérieur du polygone ? On ignore les
# intersections aux endpoints (un bridge peut légitimement toucher la frontière
# d'un autre trou en ses propres extrémités, mais ne doit pas la traverser).
# (Plus utilisé par le bridge projection-based, conservé pour référence.)
func _segment_crosses_polygon(p1: Vector2, p2: Vector2, polygon: Array) -> bool:
	var n = polygon.size()
	if n < 3: return false
	for i in range(n):
		var q1 = polygon[i]
		var q2 = polygon[(i + 1) % n]
		var inter = Geometry.segment_intersects_segment_2d(p1, p2, q1, q2)
		if inter == null: continue
		if inter.distance_squared_to(p1) > 1.0 and inter.distance_squared_to(p2) > 1.0:
			return true
	return false


# ── Calcul de la région à remplir ────────────────────────────────────────────
# Pipeline :
#   1. Pour chaque mur fermé simple (trié par aire extérieure DÉCROISSANTE) :
#        - soustraire son offset extérieur (retire mur+pièce)
#        - ajouter son offset intérieur (réintroduit la pièce comme région à part)
#   2. Soustraire les barrières "subs_last" : polylines ouvertes, loops
#      auto-intersectants (rectangles par segment) et patterns.
#
# Après CHAQUE soustraction on recombine via _combine_outer_holes : les trous
# sont pontés dans leur outer pour reformer un polygone simple. C'est nécessaire
# pour la topologie : le clip suivant opère alors sur un anneau unique incluant
# les trous précédents comme fentes, ce qui permet de détacher correctement les
# pièces fermées (cellules) au fur et à mesure. Le pontage utilise earcut
# (_eliminate_holes), qui produit des ponts non-croisants — contrairement à
# l'ancien pontage par projection qui pouvait générer des polygones
# auto-intersectants refusés par DrawPolygon ("Bad Polygon").
func _compute_region(mouse_world: Vector2, include_patterns: bool) -> Dictionary:
	var map_rect = _get_map_bounds_polygon()
	if map_rect.size() < 3:
		return {"outer": [], "holes": []}

	var b = _build_barriers(include_patterns)

	# Tri des paires fermées par aire de l'outer décroissante (extérieur d'abord)
	b.closed_pairs.sort_custom(self, "_sort_closed_pairs_by_outer_area_desc")

	var regions = [map_rect]

	# Étape 1 : pour chaque mur fermé simple, entrelacer subtract+add
	for pair in b.closed_pairs:
		regions = _subtract_and_combine(regions, pair.outer)
		if regions.size() == 0: break
		if pair.inner != null:
			regions.append(pair.inner)

	# Étape 2 : soustraire polylines ouvertes, loops auto-intersectants, patterns
	for s in b.subs_last:
		regions = _subtract_and_combine(regions, s)
		if regions.size() == 0: break

	# La plus petite région (filled-area via even-odd) contenant le clic.
	# Les polygones sont déjà recombinés (trous pontés) par _subtract_and_combine.
	var outer = []
	var outer_area = INF
	for r in regions:
		if r.size() < 3: continue
		if not _point_in_polygon(mouse_world, r): continue
		var a = _polygon_area(r)
		if a < outer_area:
			outer_area = a
			outer = r

	# Holes vide : le polygone retourné encode déjà ses trous via bridge cuts.
	return {"outer": outer, "holes": []}


func _sort_closed_pairs_by_outer_area_desc(a, b) -> bool:
	return _polygon_area(a.outer) > _polygon_area(b.outer)


# Soustrait un barrier de chaque polygone du pool, puis recombine les outers +
# trous retournés par Clipper en polygones simples-avec-trou (bridge cut earcut).
# Le résultat est un pool de polygones simples ré-injectables dans la soustraction
# suivante : le clip suivant voit les trous précédents comme des fentes, ce qui
# permet de détacher les pièces fermées (cellules) progressivement.
func _subtract_and_combine(regions: Array, barrier: Array) -> Array:
	var new_regions = []
	for r in regions:
		var clipped = Geometry.clip_polygons_2d(r, barrier)
		var combined = _combine_outer_holes(clipped)
		for c in combined:
			if c.size() >= 3:
				new_regions.append(_to_array(c))
	return new_regions


# Prend la sortie brute de clip_polygons_2d (peut contenir des paires outer+hole
# imbriquées) et la recombine en polygones simples-avec-trou via bridge cut.
# Utilise une classification par profondeur dans la hiérarchie de containment :
#   - profondeur paire = polygone "outer" (région filled)
#   - profondeur impaire = polygone "hole" (trou de son parent immédiat)
# Cela gère correctement les nestings arbitraires : un outer dans un trou est
# une nouvelle région à part, pas un trou de plus.
func _combine_outer_holes(polygons_pool: Array) -> Array:
	var polys = []
	for p in polygons_pool:
		if p.size() >= 3:
			polys.append(_to_array(p))
	if polys.size() <= 1:
		return polys

	# Parent immédiat de chaque polygone = plus petit polygone le contenant
	var parents = []
	for i in range(polys.size()):
		parents.append(_find_immediate_parent_idx(i, polys))

	# Profondeur dans la hiérarchie
	var depths = []
	for i in range(polys.size()):
		var d = 0
		var p_idx = parents[i]
		while p_idx >= 0:
			d += 1
			p_idx = parents[p_idx]
		depths.append(d)

	# Outers (profondeur paire) avec leurs trous immédiats (profondeur impaire, parent = cet outer)
	var result = []
	for i in range(polys.size()):
		if depths[i] % 2 != 0: continue  # skip holes
		var outer = polys[i]
		var outer_holes = []
		for j in range(polys.size()):
			if depths[j] % 2 == 0: continue  # skip outers
			if parents[j] == i:
				outer_holes.append(polys[j])
		if outer_holes.size() == 0:
			result.append(outer)
		else:
			result.append(_eliminate_holes(outer, outer_holes))
	return result


# ── Élimination de trous robuste (façon earcut) ──────────────────────────────
# Convertit un outer + N trous en UN seul polygone simple non auto-intersectant.
# Le pont de chaque trou relie son sommet le plus à gauche à un sommet VISIBLE de
# l'outer (rayon vers la gauche + raffinement par sommets réflexes), ce qui
# garantit des ponts qui ne se croisent pas — contrairement au pontage par
# projection qui, avec beaucoup de trous, produisait des polygones
# auto-intersectants refusés par DrawPolygon ("Bad Polygon").
# Tout le calcul se fait en coords y-inversées (convention math d'earcut : outer
# CCW / trous CW), puis on ré-inverse le résultat.
func _eliminate_holes(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = _flip_y(outer_in)
	if _ring_signed_area(outer) < 0.0:
		outer.invert()  # outer en CCW (aire signée positive)
	var prepared = []
	for h in holes_in:
		var hp = _flip_y(h)
		if _ring_signed_area(hp) > 0.0:
			hp.invert()  # trous en CW (aire signée négative)
		prepared.append(hp)
	prepared.sort_custom(self, "_sort_rings_by_leftmost_x")
	for hole in prepared:
		outer = _eliminate_hole(outer, hole)
	return _flip_y(outer)


func _flip_y(ring: Array) -> Array:
	var r = []
	for p in ring:
		r.append(Vector2(p.x, -p.y))
	return r


func _ring_signed_area(ring: Array) -> float:
	var a = 0.0
	var n = ring.size()
	for i in range(n):
		var j = (i + 1) % n
		a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
	return a * 0.5


func _sort_rings_by_leftmost_x(a, b) -> bool:
	return _ring_min_x(a) < _ring_min_x(b)


func _ring_min_x(ring: Array) -> float:
	var mx = INF
	for p in ring:
		if p.x < mx: mx = p.x
	return mx


func _eliminate_hole(outer: Array, hole: Array) -> Array:
	var hi = 0
	var minx = INF
	for i in range(hole.size()):
		if hole[i].x < minx:
			minx = hole[i].x
			hi = i
	var bi = _find_hole_bridge(outer, hole, hi)
	if bi < 0:
		# Repli : sommet le plus proche (peut se croiser mais évite tout crash)
		var bd = INF
		bi = 0
		for i in range(outer.size()):
			var d = outer[i].distance_squared_to(hole[hi])
			if d < bd:
				bd = d; bi = i
	# Splice : outer[0..bi] + boucle complète du trou depuis hi + retour outer[bi]
	var res = []
	for k in range(bi + 1):
		res.append(outer[k])
	var n = hole.size()
	for k in range(n + 1):
		res.append(hole[(hi + k) % n])
	res.append(outer[bi])
	for k in range(bi + 1, outer.size()):
		res.append(outer[k])
	return res


func _signed_area3(p: Vector2, q: Vector2, r: Vector2) -> float:
	return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)


func _point_in_triangle(a: Vector2, b: Vector2, c: Vector2, p: Vector2) -> bool:
	return (c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y) >= 0.0 and \
		(a.x - p.x) * (b.y - p.y) - (b.x - p.x) * (a.y - p.y) >= 0.0 and \
		(b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y) >= 0.0


func _locally_inside(outer: Array, ai: int, b: Vector2) -> bool:
	var n = outer.size()
	var a = outer[ai]
	var aprev = outer[(ai - 1 + n) % n]
	var anext = outer[(ai + 1) % n]
	if _signed_area3(aprev, a, anext) < 0.0:
		return _signed_area3(a, b, anext) >= 0.0 and _signed_area3(a, aprev, b) >= 0.0
	else:
		return _signed_area3(a, b, aprev) < 0.0 or _signed_area3(a, anext, b) < 0.0


# Port d'earcut findHoleBridge : trouve l'index du sommet de `outer` auquel relier
# le sommet `hi` (le plus à gauche) de `hole`. Retourne -1 si rien trouvé.
func _find_hole_bridge(outer: Array, hole: Array, hi: int) -> int:
	var hx = hole[hi].x
	var hy = hole[hi].y
	var qx = -INF
	var m = -1
	var n = outer.size()
	# Rayon horizontal vers la gauche : arête traversée, endpoint de x max <= hx
	for i in range(n):
		var p = outer[i]
		var pnext = outer[(i + 1) % n]
		if hy <= p.y and hy >= pnext.y and pnext.y != p.y:
			var x = p.x + (hy - p.y) * (pnext.x - p.x) / (pnext.y - p.y)
			if x <= hx and x > qx:
				qx = x
				m = i if p.x < pnext.x else (i + 1) % n
				if x == hx:
					return m
	if m < 0:
		return -1
	# Raffinement : parmi les sommets réflexes dans le triangle (hole, intersection,
	# m), choisir celui de tangente minimale et localement visible.
	var mx = outer[m].x
	var my = outer[m].y
	var tan_min = INF
	var best = m
	for i in range(n):
		var pv = outer[i]
		if hx >= pv.x and pv.x >= mx and hx != pv.x:
			var a: Vector2
			var c: Vector2
			if hy < my:
				a = Vector2(hx, hy); c = Vector2(qx, hy)
			else:
				a = Vector2(qx, hy); c = Vector2(hx, hy)
			if _point_in_triangle(a, Vector2(mx, my), c, pv):
				var tanv = abs(hy - pv.y) / (hx - pv.x)
				if (tanv < tan_min or (tanv == tan_min and pv.x > outer[best].x)) and _locally_inside(outer, i, hole[hi]):
					best = i
					tan_min = tanv
	return best


func _find_immediate_parent_idx(p_idx: int, polygons: Array) -> int:
	var p_area = _polygon_area(polygons[p_idx])
	var min_parent_area = INF
	var min_parent_idx = -1
	for q_idx in range(polygons.size()):
		if q_idx == p_idx: continue
		var q_area = _polygon_area(polygons[q_idx])
		if q_area <= p_area: continue  # un parent doit être plus gros que son enfant
		if not _polygon_inside_polygon(polygons[p_idx], polygons[q_idx]): continue
		if q_area < min_parent_area:
			min_parent_area = q_area
			min_parent_idx = q_idx
	return min_parent_idx


# ── Création du pattern shape ────────────────────────────────────────────────

func _create_pattern_at(points: Array):
	var pat_tool = _g.Editor.Tools["PatternShapeTool"]
	if pat_tool == null: return

	var level = _get_current_level()
	if level == null: return
	var ps_node = level.get("PatternShapes")
	if ps_node == null: return

	# Rotation courante du tool. On l'applique via SetNewRotation (qui ne touche
	# NI la texture NI la couleur), pas via SetOptions.
	var rotation_val = 0.0
	var rot_ctrl = pat_tool.get("Rotation")
	if rot_ctrl != null and rot_ctrl.has_method("get_value"):
		rotation_val = deg2rad(rot_ctrl.get_value())

	var node_id = _g.World.nextNodeID
	# DrawPolygon crée la PatternShape via le Tool : elle hérite directement de la
	# texture/couleur/rotation COURANTES du tool, exactement comme un tracé natif
	# (rect/circle), qui peint correctement les patterns de TOUS les packs, custom
	# inclus. On ne ré-applique donc PAS la texture nous-mêmes : l'ancien
	# SetOptions(texture, ...) avec une texture résolue à la main écrasait la bonne
	# texture par une fausse (null pour les custom packs, car ResourceLoader ne sait
	# pas charger res://packs/...) → couleur unie. On laisse DrawPolygon gérer la
	# texture et on ajuste seulement la rotation.
	ps_node.DrawPolygon(points, false)

	if _g.World.HasNodeID(node_id):
		var patternshape = _g.World.GetNodeByID(node_id)
		if patternshape.has_method("SetNewRotation"):
			patternshape.SetNewRotation(rotation_val)
		_g.World.AssignNodeID(patternshape)
		print("[PatternPaintBucket] Pattern créé avec %d points (aire=%.0f)" % [points.size(), _polygon_area(points)])
	else:
		print("[PatternPaintBucket] Erreur: impossible de créer le pattern")


# ── Fill ─────────────────────────────────────────────────────────────────────

func _do_fill(mouse_world: Vector2, include_patterns: bool):
	var t_start = OS.get_ticks_msec()
	var region = _compute_region(mouse_world, include_patterns)
	var t_compute = OS.get_ticks_msec() - t_start

	if region.outer.size() < 3:
		print("[PatternPaintBucket] Aucune région trouvée (clic sur un mur ?) — %d ms" % t_compute)
		return

	print("[PatternPaintBucket] Région : %d points — calcul %d ms" % [region.outer.size(), t_compute])
	_create_pattern_at(region.outer)


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _bucket_active: return false
	if not _is_pattern_tool_active(): return false
	if not (event is InputEventMouseButton): return false
	if not event.pressed: return false
	if event.button_index != BUTTON_LEFT: return false

	if ui_util != null and ui_util.is_mouse_over_ui(input_listener):
		return false

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	var canvas_xform = world_ui.get_viewport().get_canvas_transform()
	var mouse_world: Vector2 = canvas_xform.affine_inverse().xform(event.position)

	var include_patterns = event.shift
	_do_fill(mouse_world, include_patterns)
	return true


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	if _bucket_button == null: return

	if _bucket_active and not _is_pattern_tool_active():
		_remove_cursor()
		_saved_cursor_mode = -1
		return

	if _bucket_active and _is_pattern_tool_active():
		_hide_preview()
		if ui_util != null and ui_util.is_mouse_over_ui(input_listener):
			if _cursor_applied:
				Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
				_cursor_applied = false
				_cursor_is_crossed = false
		else:
			var over_zone = _is_over_fillable_zone()
			if over_zone:
				if not _cursor_applied or _cursor_is_crossed:
					_apply_cursor(false)
			else:
				if not _cursor_applied or not _cursor_is_crossed:
					_apply_cursor(true)

	if _bucket_active:
		var pat_tool = _g.Editor.Tools["PatternShapeTool"]
		if pat_tool != null:
			var ep = pat_tool.get("EditPoints")
			if ep != null and ep.get("pressed") == true:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return

	if _bucket_active:
		for btn in _shape_buttons:
			if is_instance_valid(btn) and btn.pressed:
				_bucket_active = false
				_bucket_button.pressed = false
				_remove_cursor()
				_show_preview()
				return
