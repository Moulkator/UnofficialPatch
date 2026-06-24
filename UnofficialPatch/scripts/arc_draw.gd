# arc_draw.gd
# Permet de tracer des arcs de cercle automatiques dans PathTool, WallTool, PatternShapeTool.
#
# Mode DRAW (pendant le tracé) :
#   - S'active UNIQUEMENT si le mode courbe (Arc Point) de DD est actif,
#     c-à-d après un shift+clic quand la souris ajuste la courbure du segment A→B.
#   - Maintenir Ctrl        → l'arc remplace visuellement la courbe Bézier entre A et B
#   - La POSITION DE LA SOURIS contrôle la forme de l'arc :
#       * composante perpendiculaire à la corde → flèche (sagitta)
#       * signe de cette composante             → orientation (gauche / droite)
#       * |flèche| < L/2  → arc mineur  (0° < angle < 180°)
#       * |flèche| = L/2  → demi-cercle (angle = 180°)
#       * |flèche| > L/2  → arc majeur  (180° < angle < 360°)
#     La composante le long de la corde est ignorée (arc symétrique).
#   - La ligne magenta devient VERTE quand l'arc est à 90°, 180° ou 270°.
#   - Clic gauche           → remplace la courbe Bézier par l'arc, continue le tracé
#   - Clic gauche sur P0    → remplace la courbe Bézier par l'arc ET ferme la boucle
#   - Clic droit            → remplace la courbe Bézier par l'arc ET termine (sauf patterns)
#   - Relâcher Ctrl / Échap → revient à la courbe Bézier
#
# Mode CURVE (quand un curve_edit est en mode preview Bézier sur path/wall/pattern existant) :
#   - Maintenir Ctrl        → transforme la courbe Bézier en arc contrôlé par la souris
#     (mêmes règles qu'en DRAW)
#   - Clic gauche/droit     → valide l'arc
#   - Échap / relâcher Ctrl → revient à la courbe Bézier
#   - La ligne magenta devient VERTE quand l'arc est à 90°, 180° ou 270°.
#
# Couleur de l'overlay :
#   - MAGENTA = arc libre
#   - VERT    = arc à 90°, 180° ou 270° (tolérance ~2°)

var script_class = "tool"
var _g
var input_listener: Node
const _META_KEY = "ArcDrawListener"

# Références aux mods curve_edit (passées depuis Main.gd)
var path_curve_edit = null
var wall_curve_edit = null
var pattern_curve_edit = null

# Outils supportés
var _supported_tools = ["PathTool", "WallTool", "PatternShapeTool"]

# État du mode arc
enum State { INACTIVE, DRAW_PREVIEW, CURVE_OVERRIDE }
var _state = State.INACTIVE

# Référence au mod curve_edit actif (pour CURVE_OVERRIDE)
var _active_curve_edit = null

# Mode DRAW : points A (avant-dernier) et B (dernier) de la polyline.
# L'arc s'applique sur le segment A→B dont la courbure Bézier est
# actuellement en train d'être éditée (mode Arc Point natif de DD).
var _arc_start_point: Vector2 = Vector2.ZERO
var _arc_end_point: Vector2 = Vector2.ZERO

# Mode EDIT : path/wall en cours d'édition
var _edit_path = null
var _edit_original_pts: Array = []
var _edit_ai: int = -1  # index du point A du segment
var _edit_bi: int = -1  # index du point B du segment

# Nombre de segments pour l'arc
const ARC_SEGMENTS = 16

# Couleur
const MAGENTA = Color(1.0, 0.0, 1.0, 1.0)
const GREEN = Color(0.2, 1.0, 0.3, 1.0)

# Rayons de "magnétisme" par cible — équilibrés en largeur de zone h à L=256.
# dθ/dh = 8L/(L²+4h²) décroît avec h, donc pour obtenir une sensation de
# zone "collante" similaire en mouvement souris, on utilise un rayon
# angulaire plus large sur 90° (h petit, pente forte) et plus serré sur
# 270° (h grand, pente faible).
const SNAP_RADIUS_90  = 7.0 * PI / 180.0  # ±7°   — zone h ~9 unités à L=256
const SNAP_RADIUS_180 = 4.0 * PI / 180.0  # ±4°   — zone h ~9 unités à L=256
const SNAP_RADIUS_270 = 2.0 * PI / 180.0  # ±2°   — zone h ~15 unités à L=256

# Zone d'approche : quand l'angle non-snappé tombe à ±ce rayon d'une cible,
# on ignore la grille et on utilise la position souris continue pour
# permettre un contrôle fin. Sinon, on reste sur la position grid-snappée
# (comportement habituel). Plus large que SNAP_RADIUS_* pour donner une
# "rampe" progressive vers le snap.
const APPROACH_RADIUS = 20.0 * PI / 180.0  # ±20°

# Tolérance pour considérer que le clic ferme la boucle (en unités world),
# utilisée uniquement en fallback si WorldUI.ArePolyEndPointsTouching est
# indisponible (vieilles versions de DD).
const LOOP_CLOSE_TOLERANCE = 2.0

# Overlay
var _overlay_line: Line2D = null

# Injection différée : sur clic gauche en DRAW_PREVIEW, on ne consomme pas
# l'événement — on laisse DD committer sa courbe (ce qui nettoie la ligne
# jaune), puis on fait notre UndoPolyPoint + AddPolyPoint sur la frame
# suivante. _pending_arc_points stocke les points à injecter.
var _pending_arc_points: Array = []
var _pending_finish_trace: bool = false
var _destroyed := false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	_state = State.INACTIVE
	_arc_start_point = Vector2.ZERO
	_arc_end_point = Vector2.ZERO
	_edit_path = null
	_edit_original_pts = []
	_edit_ai = -1
	_edit_bi = -1
	_active_curve_edit = null
	_install_listener()
	print("[ArcDraw] initialized")


func cleanup() -> void:
	_destroyed = true
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	if Engine.has_meta(_META_KEY):
		Engine.remove_meta(_META_KEY)
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.queue_free()
	_overlay_line = null
	_pending_arc_points = []
	_pending_finish_trace = false
	print("[ArcDraw] Cleaned up")


func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	
	var node = Node.new()
	node.name = "ArcDrawListener"
	var s = GDScript.new()
	s.source_code = """extends Node
var handler = null
func _input(e):
	if handler == null: return
	if handler._on_input(e):
		get_tree().set_input_as_handled()
"""
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# ══════════════════════════════════════════════════════════════════════════════
# MODE DRAW - Détection et helpers
# ══════════════════════════════════════════════════════════════════════════════

func _get_active_drawing_tool():
	"""Retourne l'outil actif s'il est en train de tracer, sinon null."""
	if _g == null: return null
	var editor = _g.get("Editor")
	if editor == null: return null
	var tools = editor.get("Tools")
	if tools == null: return null
	
	for tool_name in _supported_tools:
		var tool = tools.get(tool_name)
		if tool == null: continue
		if not is_instance_valid(tool): continue
		
		var active_tool = editor.get("ActiveTool")
		if active_tool != tool: continue
		
		var is_drawing = tool.get("isDrawing")
		if is_drawing != true: continue
		
		return tool
	
	return null


func _get_polyline_count() -> int:
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return 0
	var polyline = world_ui.get("Polyline")
	if polyline == null: return 0
	return polyline.size()


func _get_mouse_position() -> Vector2:
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return Vector2.ZERO
	var pos = world_ui.get("SnappedPosition")
	return pos if pos != null else Vector2.ZERO


func _is_native_curve_mode() -> bool:
	"""Vrai si DD est en mode courbe (Arc Point) : shift+clic a été fait et
	la souris ajuste maintenant la courbure avant le prochain clic."""
	if _g == null: return false
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false
	# IndicateEditArcPoint est un int, mis automatiquement par DD quand
	# l'UI affiche le mode arc-point. EditArcPoint est le flag d'édition.
	var indicate = world_ui.get("IndicateEditArcPoint")
	if indicate != null and int(indicate) != 0:
		return true
	var editing = world_ui.get("EditArcPoint")
	if editing != null and editing == true:
		return true
	return false


func _extract_arcvec_position(av) -> Vector2:
	"""Lit la Position d'un ArcVector2, avec fallback sur str()."""
	if av == null: return Vector2.ZERO
	if "Position" in av:
		return av.Position
	var pos = av.get("Position")
	if pos != null and pos is Vector2:
		return pos
	var s = str(av)
	var start = s.find("(")
	if start >= 0:
		var end = s.find(")", start)
		if end > start:
			var coords_str = s.substr(start + 1, end - start - 1)
			var parts = coords_str.split(",")
			if parts.size() >= 2:
				return Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))
	return Vector2.ZERO


func _get_last_two_anchors() -> Array:
	"""Retourne [A, B] = positions des 2 derniers points d'ancrage de la polyline,
	ou [] s'il n'y en a pas assez."""
	if _g == null: return []
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return []
	var polyline = world_ui.get("Polyline")
	if polyline == null or polyline.size() < 2: return []
	var n = polyline.size()
	var a = _extract_arcvec_position(polyline[n - 2])
	var b = _extract_arcvec_position(polyline[n - 1])
	return [a, b]


func _is_loop_closing_click() -> bool:
	"""Vrai si le clic gauche actuel va fermer la boucle.
	
	DD ferme atomiquement la boucle quand B (polyline[last]) est suffisamment
	proche de polyline[0] — son seuil interne dépasse les quelques unités
	d'une tolérance stricte. Ça se voit avec Snap To Grid désactivé : B
	atterrit à la position curseur brute, à plusieurs unités du premier point,
	mais DD ferme quand même.
	
	On utilise une tolérance proportionnelle à CellSize (~1/4 de tuile), qui
	correspond à la zone d'accroche visuelle de DD autour du premier vertex
	et s'adapte automatiquement à la résolution de la map. Le flag natif
	ArePolyEndPointsTouching est consulté en priorité (matche exactement la
	définition de DD), mais il est manifestement plus strict que la logique
	de fermeture réelle, donc on s'appuie surtout sur la distance."""
	if _g == null:
		return false
	var world_ui = _g.get("WorldUI")
	if world_ui == null:
		return false
	var polyline = world_ui.get("Polyline")
	# Au moins 3 points pour faire une boucle (P0, P1, P_close)
	if polyline == null or polyline.size() < 3:
		return false
	# Flag natif DD : true si polyline[last] est très proche / égal à polyline[0].
	var touching = world_ui.get("ArePolyEndPointsTouching")
	if touching == true:
		return true
	# Fallback principal : distance B↔polyline[0] avec une tolérance large.
	var first_pos = _extract_arcvec_position(polyline[0])
	return _arc_end_point.distance_to(first_pos) < _get_loop_close_tolerance()


func _get_loop_close_tolerance() -> float:
	"""Tolérance dynamique : 1/2 cellule du grid (typiquement 128 unités pour
	une tuile de 256). Couvre la zone d'accroche visuelle de DD autour du
	premier vertex — le seuil interne de DD pour fermer la boucle est plus
	généreux qu'on aurait cru, donc on s'aligne dessus. Fallback fixe
	LOOP_CLOSE_TOLERANCE si CellSize est indisponible."""
	if _g == null:
		return LOOP_CLOSE_TOLERANCE
	var world_ui = _g.get("WorldUI")
	if world_ui == null:
		return LOOP_CLOSE_TOLERANCE
	var cell = world_ui.get("CellSize")
	if cell != null and cell is Vector2 and cell.x > 0:
		return cell.x * 0.5
	return LOOP_CLOSE_TOLERANCE


func _ideal_h_for_angle(angle: float, L: float) -> float:
	"""Flèche exacte pour un arc d'angle θ sur une corde de longueur L :
	h = L·(1−cos(θ/2)) / (2·sin(θ/2))."""
	var half = angle * 0.5
	return L * (1.0 - cos(half)) / (2.0 * sin(half))


func _compute_arc_params(start: Vector2, end: Vector2, mouse: Vector2) -> Dictionary:
	"""Calcule angle et orientation d'un arc entre start→end à partir de la
	distance perpendiculaire de la souris à la corde.
	
	Formule de base : angle = 2·atan2(4·h·L, L² − 4·h²)
	
	Deux modes de souris :
	  • Mode GRID (par défaut) : on utilise le param `mouse` (grid-snappé
	    par l'appelant via _get_mouse_position/SnappedPosition). L'arc
	    "step" en suivant les positions grille.
	  • Mode LIBRE (zone d'approche) : quand l'angle naturel calculé à
	    partir de la position souris CONTINUE (WorldUI.MousePosition) tombe
	    à ±APPROACH_RADIUS d'une cible 90°/180°/270°, on ignore la grille
	    pour permettre un contrôle fin et laisser le magnétisme angulaire
	    (±5°/±2.5°/±1°) se déclencher naturellement.
	
	Magnétisme angulaire : si l'angle final (grid ou libre) tombe dans le
	rayon de snap d'une cible, on force l'angle exact et on recalcule h
	pour que la géométrie soit parfaite.
	
	Retourne {valid, angle, direction, arc_mid, h, chord_length, is_snapped}."""
	var result = {
		"valid": false,
		"angle": 0.0,
		"direction": 1,
		"arc_mid": Vector2.ZERO,
		"h": 0.0,
		"chord_length": 0.0,
		"is_snapped": false,
	}
	
	var L = start.distance_to(end)
	if L < 1.0: return result
	
	var chord_mid = (start + end) * 0.5
	var chord_dir = (end - start) / L
	var perp_raw = Vector2(-chord_dir.y, chord_dir.x)
	
	# Version GRID (grid-snappée, passée en argument par l'appelant)
	var offset_grid = (mouse - chord_mid).dot(perp_raw)
	var h_grid = abs(offset_grid)
	var natural_grid = 0.0
	if h_grid >= 1.0:
		natural_grid = 2.0 * atan2(4.0 * h_grid * L, L * L - 4.0 * h_grid * h_grid)
	
	# Version LIBRE (souris continue, non-snappée). Lecture directe de
	# WorldUI.MousePosition. Si indisponible, on retombe sur la souris grid.
	var mouse_free = mouse
	if _g != null:
		var wu = _g.get("WorldUI")
		if wu != null:
			var mp = wu.get("MousePosition")
			if mp != null and mp is Vector2:
				mouse_free = mp
	var offset_free = (mouse_free - chord_mid).dot(perp_raw)
	var h_free = abs(offset_free)
	var natural_free = 0.0
	if h_free >= 1.0:
		natural_free = 2.0 * atan2(4.0 * h_free * L, L * L - 4.0 * h_free * h_free)
	
	# On active le mode libre si l'angle naturel issu de la souris CONTINUE
	# est proche (±APPROACH_RADIUS) d'une des cibles. Ça désactive le snap
	# to grid et laisse le magnétisme angulaire catcher proprement.
	var use_free = false
	if h_free >= 1.0:
		for target in [PI * 0.5, PI, PI * 1.5]:
			if abs(natural_free - target) < APPROACH_RADIUS:
				use_free = true
				break
	
	var offset_signed = offset_free if use_free else offset_grid
	var h = h_free if use_free else h_grid
	var natural_angle = natural_free if use_free else natural_grid
	
	# Trop plat : pas d'arc visible (évite aussi division par ~0)
	if h < 1.0: return result
	
	# Convention : l'arc bulges du côté OPPOSÉ à perp_raw*direction.
	# Pour bulger vers la souris : direction = −sign(offset).
	var direction = -1 if offset_signed > 0.0 else 1
	var side = 1.0 if offset_signed > 0.0 else -1.0
	
	# Magnétisme angulaire sur l'angle choisi (grid ou libre)
	var snap_targets = [
		[PI * 0.5, SNAP_RADIUS_90],
		[PI, SNAP_RADIUS_180],
		[PI * 1.5, SNAP_RADIUS_270],
	]
	var angle = natural_angle
	var is_snapped = false
	for entry in snap_targets:
		var target = entry[0]
		var radius = entry[1]
		if abs(natural_angle - target) < radius:
			angle = target
			is_snapped = true
			h = _ideal_h_for_angle(target, L)
			break
	
	var arc_mid = chord_mid + side * h * perp_raw
	
	result.valid = true
	result.angle = angle
	result.direction = direction
	result.arc_mid = arc_mid
	result.h = h
	result.chord_length = L
	result.is_snapped = is_snapped
	return result


func _compute_arc_params_from_mouse() -> Dictionary:
	"""Wrapper pour le mode DRAW : utilise _arc_start_point / _arc_end_point
	et la position souris snappée."""
	return _compute_arc_params(_arc_start_point, _arc_end_point, _get_mouse_position())


func _is_snap_params(params: Dictionary) -> bool:
	"""Vrai si l'arc a été aimanté à un angle parfait 90°/180°/270°."""
	return params.valid and params.get("is_snapped", false)


func _apply_overlay_color(params: Dictionary):
	"""Colore l'overlay en vert si on est sur un snap 90°/180°/270°."""
	if _overlay_line == null or not is_instance_valid(_overlay_line):
		return
	_overlay_line.default_color = GREEN if _is_snap_params(params) else MAGENTA


func _set_curve_edit_overlay_visible(curve_edit, visible: bool):
	"""Masque ou restaure le tracé Bézier du curve_edit pour éviter d'avoir
	deux overlays magenta empilés pendant notre mode arc CURVE_OVERRIDE."""
	if curve_edit == null: return
	var line = curve_edit.get("_overlay_line")
	if line != null and is_instance_valid(line):
		line.visible = visible


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


func _read_path_pts(path) -> Array:
	var raw = path.get("GlobalEditPoints")
	if raw == null: return []
	return _parse_pts(str(raw))


func _read_wall_pts(wall) -> Array:
	var raw = wall.call("get_Points")
	if raw == null: return []
	return _parse_pts(str(raw))


func _write_path_pts(path, pts: Array):
	var was_loop = path.get("loop")
	if was_loop and pts.size() > 0:
		path.global_position = pts[0]
	var pool = PoolVector2Array()
	for p in pts: pool.append(p)
	path.call("SetEditPoints", pool)
	if was_loop:
		path.call("set_loop", true)


func _write_wall_pts(wall, pts: Array):
	var was_loop = wall.call("get_Loop")
	var pool = PoolVector2Array()
	for p in pts: pool.append(p)
	wall.call("set_Points", pool)
	if was_loop:
		wall.call("set_Loop", true)
	wall.call("RemakeLines")
	if was_loop:
		wall.call("set_Loop", true)


func _read_pattern_pts(shape) -> Array:
	var raw = shape.get("GlobalPolygon")
	if raw == null: return []
	var result = []
	for p in raw:
		result.append(p)
	return result


func _write_pattern_pts(shape, pts: Array):
	var pool = PoolVector2Array()
	for p in pts:
		pool.append(shape.to_local(p))
	shape.call("set_polygon", pool)


# ══════════════════════════════════════════════════════════════════════════════
# Calcul de l'arc
# ══════════════════════════════════════════════════════════════════════════════

func _calculate_arc_points(start: Vector2, end: Vector2, direction: int, angle: float) -> Array:
	var points = []
	
	var chord = end - start
	var chord_length = chord.length()
	if chord_length < 0.001:
		return [end]
	
	var chord_dir = chord.normalized()
	var perp = Vector2(-chord_dir.y, chord_dir.x) * direction
	
	var half_angle = angle / 2.0
	var sin_half = sin(half_angle)
	if abs(sin_half) < 0.001:
		return [end]
	
	var radius = chord_length / (2.0 * sin_half)
	
	var mid_point = start + chord * 0.5
	var center_offset = radius * cos(half_angle)
	var center = mid_point + perp * center_offset
	
	var start_angle = (start - center).angle()
	var angle_diff = angle * direction
	
	for i in range(1, ARC_SEGMENTS + 1):
		var t = float(i) / float(ARC_SEGMENTS)
		var current_angle = start_angle + angle_diff * t
		var point = center + Vector2(cos(current_angle), sin(current_angle)) * radius
		points.append(point)
	
	return points


# ══════════════════════════════════════════════════════════════════════════════
# Overlay visuel
# ══════════════════════════════════════════════════════════════════════════════

func _create_overlay():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		return
	
	_overlay_line = Line2D.new()
	_overlay_line.name = "ArcDrawOverlay"
	_overlay_line.width = 3.0
	_overlay_line.default_color = MAGENTA
	_overlay_line.z_index = 4096
	_overlay_line.antialiased = true
	
	var world = _g.get("World")
	if world != null:
		world.add_child(_overlay_line)
	else:
		var world_ui = _g.get("WorldUI")
		if world_ui != null:
			world_ui.add_child(_overlay_line)


func _update_overlay(start: Vector2, arc_points: Array):
	if _overlay_line == null or not is_instance_valid(_overlay_line):
		_create_overlay()
	
	if _overlay_line == null:
		return
	
	var pool = PoolVector2Array()
	pool.append(start)
	for p in arc_points:
		pool.append(p)
	
	_overlay_line.points = pool
	_overlay_line.visible = true


func _remove_overlay():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.queue_free()
	_overlay_line = null


# ══════════════════════════════════════════════════════════════════════════════
# Injection / Remplacement des points
# ══════════════════════════════════════════════════════════════════════════════

func _sync_native_bezier_at(arc_mid: Vector2):
	"""Aligne la courbe native de DD sur notre preview en écrivant le milieu
	de l'arc dans ArcPoint. DD rend un arc circulaire à 3 points (A, ArcPoint, B),
	donc passer le milieu de NOTRE arc définit exactement le même cercle."""
	if _state != State.DRAW_PREVIEW: return
	if _g == null: return
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var polyline = world_ui.get("Polyline")
	if polyline == null or polyline.size() == 0: return
	
	var last = polyline[polyline.size() - 1]
	if last == null: return
	if "HasArcPoint" in last:
		last.HasArcPoint = true
	if "ArcPoint" in last:
		last.ArcPoint = arc_mid
	
	# Force DD à re-tesseler immédiatement (sinon le rendu ne se met à jour
	# qu'au prochain InputEventMouseMotion).
	var tool = _get_active_drawing_tool()
	if tool != null and tool.has_method("UpdatePath"):
		tool.call("UpdatePath")
	if world_ui.has_method("update"):
		world_ui.call("update")


func _replace_segment_with_arc(arc_points: Array):
	"""Mode EDIT : remplace le segment [ai, bi] par l'arc."""
	if _edit_path == null or not is_instance_valid(_edit_path):
		return
	
	var pts = _edit_original_pts
	var ai = _edit_ai
	var bi = _edit_bi
	var n = pts.size()
	
	# Construire les nouveaux points
	var new_pts = []
	
	if ai < bi:
		# Cas normal : segment non wrappé
		# Points avant le segment (y compris ai)
		for i in range(ai + 1):
			new_pts.append(pts[i])
		
		# Points de l'arc (sans le dernier qui est bi)
		for i in range(arc_points.size() - 1):
			new_pts.append(arc_points[i])
		
		# Points à partir de bi
		for i in range(bi, n):
			new_pts.append(pts[i])
	else:
		# Cas wrappé : segment de fermeture (bi < ai, ex: ai=last, bi=0)
		# On garde pts[bi..ai], puis l'arc (sans le dernier point)
		for i in range(bi, ai + 1):
			new_pts.append(pts[i])
		for i in range(arc_points.size() - 1):
			new_pts.append(arc_points[i])
	
	# Écrire selon le type (path, wall, ou pattern)
	if _edit_path.get("GlobalEditPoints") != null:
		_write_path_pts(_edit_path, new_pts)
	elif _edit_path.has_method("get_Points"):
		_write_wall_pts(_edit_path, new_pts)
	elif _edit_path.get("GlobalPolygon") != null:
		_write_pattern_pts(_edit_path, new_pts)


# ══════════════════════════════════════════════════════════════════════════════
# Gestion des inputs
# ══════════════════════════════════════════════════════════════════════════════

func _on_input(event) -> bool:
	if _destroyed:
		return false
	# ─── Mode CURVE OVERRIDE (quand un curve_edit est en mode preview) ───
	if _is_curve_edit_active():
		return _handle_curve_override_input(event)
	
	# ─── Mode DRAW ───
	var draw_tool = _get_active_drawing_tool()
	if draw_tool != null and _get_polyline_count() >= 1:
		return _handle_draw_input(event)
	
	# Aucun mode actif
	if _state != State.INACTIVE:
		_exit_mode()
	return false


func _is_curve_edit_active() -> bool:
	"""Vérifie si un des mods curve_edit est en mode CURVE_PREVIEW."""
	if path_curve_edit != null and path_curve_edit._state == 3:  # CURVE_PREVIEW = 3
		return true
	if wall_curve_edit != null and wall_curve_edit._state == 3:
		return true
	if pattern_curve_edit != null and pattern_curve_edit._state == 3:
		return true
	return false


func _get_active_curve_edit():
	"""Retourne le mod curve_edit actif en mode CURVE_PREVIEW."""
	if path_curve_edit != null and path_curve_edit._state == 3:
		return path_curve_edit
	if wall_curve_edit != null and wall_curve_edit._state == 3:
		return wall_curve_edit
	if pattern_curve_edit != null and pattern_curve_edit._state == 3:
		return pattern_curve_edit
	return null


func _handle_curve_override_input(event) -> bool:
	"""Gère les inputs quand un curve_edit est en mode preview."""
	var curve_edit = _get_active_curve_edit()
	if curve_edit == null:
		return false
	
	# En mode CURVE_OVERRIDE : gérer clic de validation et échap
	# (pas de cycle molette/Tab — l'arc est mouse-driven en continu)
	if _state == State.CURVE_OVERRIDE:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == BUTTON_LEFT or event.button_index == BUTTON_RIGHT:
				_confirm_curve_override_arc()
				return true
		
		if event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
			# Restaure le tracé Bézier natif avant de sortir
			_set_curve_edit_overlay_visible(_active_curve_edit, true)
			_exit_mode()
			return true
	
	return false


func _handle_draw_input(event) -> bool:
	# En mode DRAW_PREVIEW : gérer clic de validation et échap
	# (pas de cycle molette/Tab — l'arc est mouse-driven en continu)
	if _state == State.DRAW_PREVIEW:
		if event is InputEventMouseButton and event.pressed:
			# Clic gauche OU droit qui ferme la boucle : DD ferme et finalise
			# atomiquement avec sa Bézier dans les deux cas, donc le
			# call_deferred arrive trop tard (tracé déjà fini). On fait tout
			# nous-mêmes. Le user peut fermer par clic gauche sur polyline[0]
			# OU par clic droit n'importe où (DD ferme aussi par habitude
			# "fin de tracé").
			if event.button_index == BUTTON_LEFT:
				if _is_loop_closing_click():
					return _apply_loop_closing_arc()
				return _queue_deferred_arc_injection(false)
			if event.button_index == BUTTON_RIGHT:
				if _is_loop_closing_click():
					return _apply_loop_closing_arc()
				return _queue_deferred_arc_injection(true)
		
		if event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
			_exit_mode()
			return true
	
	return false


func _queue_deferred_arc_injection(finish_trace: bool) -> bool:
	"""Prépare l'injection d'arc différée et laisse DD traiter le clic.
	
	CAS CLIC GAUCHE (finish_trace=false) :
	On ne consomme PAS l'événement (return false) : DD committe sa courbe
	naturellement (ce qui nettoie l'état interne, dont la ligne jaune) puis
	notre _apply_pending_arc_injection s'exécute à la frame suivante pour
	remplacer la courbe par nos points.
	
	CAS CLIC DROIT (finish_trace=true) :
	DD termine le tracé atomiquement sur clic droit en mode courbe — notre
	deferred s'exécuterait trop tard (tracé déjà fini, polyline vide). On
	intercepte donc le clic droit (consume), puis on SYNTHÉTISE un clic
	gauche : DD fait alors juste le commit de sa courbe (avec cleanup de la
	ligne jaune) sans terminer le tracé. Notre deferred s'exécute ensuite
	normalement, injecte les points, et finalise lui-même via
	EndPath/EndWall — en évitant Confirm() qui ajouterait le curseur comme
	point final (segment parasite)."""
	var params = _compute_arc_params_from_mouse()
	if not params.valid:
		_exit_mode()
		return finish_trace  # si clic droit invalide, on consomme pour ne pas
		                     # finir le tracé accidentellement avec une courbe DD
	
	var arc_points = _calculate_arc_points(
		_arc_start_point, _arc_end_point, params.direction, params.angle
	)
	_pending_arc_points = arc_points
	_pending_finish_trace = finish_trace
	
	var orientation = "gauche" if params.direction == 1 else "droite"
	var finish_str = " + fin du tracé" if finish_trace else ""
	print("[ArcDraw] Arc confirmé (%.1f° %s)%s" % [rad2deg(params.angle), orientation, finish_str])
	
	_exit_mode()  # empêche notre propre handler de traiter le clic synthétique
	call_deferred("_apply_pending_arc_injection")
	
	if finish_trace:
		# Clic droit : on intercepte et on synthétise un clic gauche pour
		# que DD fasse son commit de courbe sans terminer le tracé.
		var fake_click = InputEventMouseButton.new()
		fake_click.button_index = BUTTON_LEFT
		fake_click.pressed = true
		# Position viewport : on utilise la position actuelle de la souris
		# pour que DD traite le clic de façon cohérente.
		var root = _g.Editor.get_tree().get_root() if _g != null else null
		if root != null:
			fake_click.position = root.get_mouse_position()
		Input.parse_input_event(fake_click)
		
		# Release event pour que DD voie un clic complet
		var fake_release = InputEventMouseButton.new()
		fake_release.button_index = BUTTON_LEFT
		fake_release.pressed = false
		if root != null:
			fake_release.position = root.get_mouse_position()
		Input.parse_input_event(fake_release)
		
		return true  # on consomme le clic droit original
	
	return false  # clic gauche : on laisse passer pour que DD le traite


func _apply_loop_closing_arc() -> bool:
	"""Clic gauche qui ferme une boucle : DD ferme et finalise atomiquement
	avec sa Bézier, donc le call_deferred arriverait trop tard. On intercepte
	tout :
	  1. Consomme l'événement (DD ne le verra pas).
	  2. Retire B (anchor au point de fermeture, avec HasArcPoint) via
	     UndoPolyPoint, puis ajoute nos points d'arc.
	  3. Finalise via EndPath / EndWall / FinishShape selon l'outil.
	  4. Force loop=true sur le noeud résultant si DD ne l'a pas détecté.
	
	Le dernier point de notre arc coïncide avec polyline[0], ce qui devrait
	suffire à DD pour reconnaître le loop, mais on le force par sécurité."""
	var world_ui = _g.get("WorldUI")
	var tool = _get_active_drawing_tool()
	if world_ui == null or tool == null:
		_exit_mode()
		return true
	
	# On force l'arc à se terminer pile sur polyline[0] (et non sur
	# _arc_end_point) — sinon, avec Snap To Grid désactivé, B est légèrement
	# décalé du premier point, et la fermeture forcée par EndWall(true) /
	# set_loop ajoute un mini-segment parasite entre la fin de l'arc et P0.
	var polyline = world_ui.get("Polyline")
	if polyline == null or polyline.size() < 1:
		_exit_mode()
		return true
	var loop_end = _extract_arcvec_position(polyline[0])
	
	var params = _compute_arc_params(_arc_start_point, loop_end, _get_mouse_position())
	if not params.valid:
		# Souris trop proche de la corde : on ne sait pas quoi faire de l'arc.
		# On consomme le clic pour éviter une fermeture Bézier vanilla et on sort.
		_exit_mode()
		return true
	
	var arc_points = _calculate_arc_points(
		_arc_start_point, loop_end, params.direction, params.angle
	)
	
	var orientation = "gauche" if params.direction == 1 else "droite"
	print("[ArcDraw] Arc en fermeture de boucle (%.1f° %s)"
		% [rad2deg(params.angle), orientation])
	
	# Capture de la référence à la Pathway en cours avant finalisation
	# (PathTool expose ActivePath). WallTool n'expose pas d'équivalent, donc
	# pour les walls on s'appuie directement sur le paramètre loop d'EndWall.
	var active_path_before = null
	if "ActivePath" in tool:
		active_path_before = tool.get("ActivePath")
	
	_exit_mode()  # nettoie l'overlay et notre state avant d'agir
	
	# Retire B (qui porte le HasArcPoint Bézier).
	if world_ui.has_method("UndoPolyPoint"):
		world_ui.call("UndoPolyPoint")
	
	# Ajout des points d'arc avec règle différente selon l'outil :
	#
	# • path : on OMET le dernier point d'arc (qui coïncide avec polyline[0]).
	#   Le segment de fermeture sera fourni par _force_loop_path comme
	#   arc_{N-1} → polyline[0] — un vrai segment non dégénéré. Si on incluait
	#   arc_N, le cursor parasite ajouté par EndPath(false) tomberait sur
	#   polyline[0], donc _trim_path_cursor_point verrait dist ≈ 0 et ne
	#   supprimerait pas le doublon ⇒ cassure visible.
	#
	# • wall : on INCLUT tous les points. EndWall(true) interprète le polyline
	#   comme déjà fermé (last ≈ first) ; il drop le doublon final mais
	#   conserve le segment précédent. Si on omettait arc_N, EndWall(true)
	#   utiliserait arc_{N-2} comme dernier "vrai" point et créerait un
	#   segment de fermeture arc_{N-2}→polyline[0] de longueur double, rendu
	#   en droite.
	#
	# • pattern : on INCLUT tous les points. FinishShape attend un polyline
	#   fermé (polyline[last] ≈ polyline[0]) pour reconnaître la boucle ;
	#   les patterns étant des polygones intrinsèquement clos, le doublon
	#   final n'a aucune conséquence visuelle.
	var is_pattern = tool.has_method("FinishShape")
	var is_wall = (not is_pattern) and tool.has_method("EndWall")
	var include_last = is_pattern or is_wall
	var n_to_add = arc_points.size() if include_last else (arc_points.size() - 1)
	for i in range(n_to_add):
		world_ui.call("AddPolyPoint", arc_points[i])
	
	# Nettoie l'état mode-courbe natif au cas où il subsisterait (UndoPolyPoint
	# devrait suffire mais on s'assure que FinishShape/EndPath n'interprètent
	# pas un HasArcPoint résiduel sur le mauvais point).
	if "EditArcPoint" in world_ui:
		world_ui.EditArcPoint = false
	if "IndicateEditArcPoint" in world_ui:
		world_ui.IndicateEditArcPoint = 0
	
	if tool.has_method("UpdatePath"):
		tool.call("UpdatePath")
	
	# Finalisation selon l'outil.
	# PatternShapeTool hérite de ShapeTool qui expose FinishShape() —
	# "Takes the polyline from WorldUI and turns it into a shape.
	#  Automagically determines if it needs to loop or add new points."
	if tool.has_method("FinishShape"):
		tool.call("FinishShape")
	elif tool.has_method("EndPath"):
		var arc_end = _get_last_polyline_position(world_ui)
		tool.call("EndPath", false)
		_trim_path_cursor_point(active_path_before, arc_end)
		_force_loop_path(active_path_before)
	elif tool.has_method("EndWall"):
		# WallTool : EndWall(loop) prend un paramètre loop natif, on passe
		# true pour créer directement un wall en boucle (DD gère le segment
		# de fermeture en interne). WallTool n'expose pas d'ActiveWall (à
		# la différence de PathTool.ActivePath) donc impossible de
		# post-modifier le wall ; il faut le configurer dès la création.
		tool.call("EndWall", true)
	
	return true  # consomme le clic original


func _force_loop_path(path):
	"""Active le flag loop sur une Pathway et rafraîchit le rendu.
	Sans Smooth() / UpdateOccluder() après set_loop, le tracé reste
	rendu comme un chemin ouvert jusqu'à la prochaine édition manuelle
	des points (symptôme : cassure visible que "edit points" corrige)."""
	if path == null or not is_instance_valid(path):
		return
	if path.get("loop") != true:
		path.call("set_loop", true)
	if path.has_method("Smooth"):
		path.call("Smooth")
	if path.has_method("UpdateOccluder"):
		path.call("UpdateOccluder")




func _apply_pending_arc_injection():
	"""Appelé via call_deferred après que DD ait traité le clic (gauche ou
	droit). À ce stade, DD a committé sa courbe proprement (ligne jaune
	nettoyée). On remplace la courbe commitée par nos points d'arc droits,
	et si c'était un clic droit on finalise le tracé sans passer par
	Confirm() — qui ajoute automatiquement la position du curseur comme
	point final (cause du segment parasite traversant l'arc)."""
	if _pending_arc_points.empty(): return
	if _g == null: return
	var world_ui = _g.get("WorldUI")
	if world_ui == null:
		_pending_arc_points = []
		_pending_finish_trace = false
		return
	
	var finish_trace = _pending_finish_trace
	var arc_points = _pending_arc_points
	_pending_arc_points = []
	_pending_finish_trace = false
	
	# Cas 1 : DD a déjà finalisé le tracé (trace ended synchronously with
	# right-click). Le polyline est vide — rien à faire, c'est fichu.
	var tool = _get_active_drawing_tool()
	if tool == null:
		# Le tracé s'est terminé pendant l'événement. Pas d'injection possible,
		# mais au moins DD a géré son état interne proprement.
		return
	
	# Cas 2 : le tracé est toujours actif. On undo le point courbé commité par
	# DD puis on ajoute nos points d'arc.
	if world_ui.has_method("UndoPolyPoint"):
		world_ui.call("UndoPolyPoint")
	for point in arc_points:
		world_ui.call("AddPolyPoint", point)
	
	if tool.has_method("UpdatePath"):
		tool.call("UpdatePath")
	if world_ui.has_method("update"):
		world_ui.call("update")
	
	# Cas 2b : clic droit → on finalise maintenant. On évite Confirm() qui
	# ajoute "automagically" la position du curseur comme point final.
	if finish_trace:
		var editor = _g.get("Editor")
		var tools = editor.get("Tools")
		var pattern_tool = tools.get("PatternShapeTool") if tools != null else null
		
		if tool == pattern_tool:
			# Pour PatternShape, le clic droit ne termine pas le tracé en vanilla.
			return
		
		# Pour PathTool, EndPath(false) ajoute quand même la position courante
		# du curseur comme dernier point de la Pathway (contrairement à
		# EndWall(false)). On sauvegarde la référence à la Pathway avant
		# EndPath, puis on retire le dernier point après finalisation.
		var active_path_before = null
		if "ActivePath" in tool:
			active_path_before = tool.get("ActivePath")
		
		var arc_end = _get_last_polyline_position(world_ui)
		
		if tool.has_method("EndPath"):
			tool.call("EndPath", false)
			_trim_path_cursor_point(active_path_before, arc_end)
		elif tool.has_method("EndWall"):
			tool.call("EndWall", false)


func _get_last_polyline_position(world_ui) -> Vector2:
	"""Lit la position du dernier point du polyline courant (= fin d'arc B)."""
	var polyline = world_ui.get("Polyline")
	if polyline == null or polyline.size() == 0:
		return Vector2.ZERO
	var last = polyline[polyline.size() - 1]
	return _extract_arcvec_position(last)


func _trim_path_cursor_point(pathway, expected_end: Vector2):
	"""Après EndPath(false), la Pathway créée contient un point final parasite
	à la position du curseur (comportement intrinsèque de EndPath). On le
	retire via DeletePoint puis on régénère le rendu via Smooth().
	
	On ne retire le point que s'il diffère significativement de expected_end
	(= notre fin d'arc B) — pour ne pas mutiler une Pathway où le curseur
	coïnciderait déjà avec B."""
	if pathway == null or not is_instance_valid(pathway):
		return
	if not pathway.has_method("DeletePoint"):
		return
	
	var edit_points = pathway.get("EditPoints")
	if edit_points == null: return
	var n = edit_points.size()
	if n < 2: return  # pas assez de points pour retirer quoi que ce soit
	
	# La Pathway travaille en local space ; expected_end est en world space.
	# On convertit en soustrayant la position du noeud (GlobalRect ou position).
	var origin = pathway.get("global_position") if "global_position" in pathway else Vector2.ZERO
	if origin == null: origin = Vector2.ZERO
	var expected_local = expected_end - origin
	
	var last_point = edit_points[n - 1]
	var dist = last_point.distance_to(expected_local)
	
	# Si le dernier point est "loin" de notre B, c'est le curseur parasite.
	# Tolérance de 1 unité pour éviter de retirer B lui-même.
	if dist > 1.0:
		pathway.call("DeletePoint", n - 1)
		if pathway.has_method("Smooth"):
			pathway.call("Smooth")
		if pathway.has_method("UpdateOccluder"):
			pathway.call("UpdateOccluder")


# ══════════════════════════════════════════════════════════════════════════════
# États
# ══════════════════════════════════════════════════════════════════════════════

func _enter_draw_mode():
	if _state == State.DRAW_PREVIEW:
		return
	# Il faut au moins 2 points d'ancrage et le mode courbe natif actif.
	var anchors = _get_last_two_anchors()
	if anchors.size() < 2:
		return
	_arc_start_point = anchors[0]
	_arc_end_point = anchors[1]
	_state = State.DRAW_PREVIEW
	_create_overlay()


func _exit_mode():
	_remove_overlay()
	_state = State.INACTIVE
	_arc_start_point = Vector2.ZERO
	_arc_end_point = Vector2.ZERO
	_edit_path = null
	_edit_original_pts = []
	_edit_ai = -1
	_edit_bi = -1
	_active_curve_edit = null


# ══════════════════════════════════════════════════════════════════════════════
# Update
# ══════════════════════════════════════════════════════════════════════════════

func update(_delta):
	if _destroyed: return
	if _g == null: return
	
	var ctrl_pressed = Input.is_key_pressed(KEY_CONTROL)
	
	# ─── Mode CURVE OVERRIDE (quand un curve_edit est en mode preview) ───
	if _is_curve_edit_active():
		_update_curve_override_mode(ctrl_pressed)
		return
	
	# ─── Mode DRAW ───
	var draw_tool = _get_active_drawing_tool()
	if draw_tool != null and _get_polyline_count() >= 1:
		_update_draw_mode(ctrl_pressed)
		return
	
	# Aucun mode actif
	if _state != State.INACTIVE:
		_exit_mode()


func _update_draw_mode(ctrl_pressed: bool):
	# Le mode arc ne s'active qu'en mode courbe natif (Arc Point de DD).
	var curve_mode = _is_native_curve_mode()
	var arc_combo = ctrl_pressed and curve_mode
	
	if arc_combo and _state == State.INACTIVE:
		_enter_draw_mode()
		if _state == State.DRAW_PREVIEW:
			print("[ArcDraw] Mode arc activé (contrôle souris)")
	elif not arc_combo and _state == State.DRAW_PREVIEW:
		_exit_mode()
		return
	
	if _state == State.DRAW_PREVIEW:
		# Paramètres de l'arc calculés dynamiquement depuis la souris
		var params = _compute_arc_params_from_mouse()
		if not params.valid:
			# Souris trop proche de la corde : masquer la preview
			if _overlay_line != null:
				_overlay_line.visible = false
			return
		
		var arc_points = _calculate_arc_points(
			_arc_start_point, _arc_end_point, params.direction, params.angle
		)
		_update_overlay(_arc_start_point, arc_points)
		_apply_overlay_color(params)
		# Aligne la courbe native sur notre preview via ArcPoint = milieu de l'arc
		_sync_native_bezier_at(params.arc_mid)


func _update_curve_override_mode(ctrl_pressed: bool):
	"""Met à jour le mode override quand un curve_edit est en preview.
	La souris contrôle l'arc exactement comme en mode DRAW / EDIT POINTS."""
	var curve_edit = _get_active_curve_edit()
	if curve_edit == null:
		if _state == State.CURVE_OVERRIDE:
			_exit_mode()
		return
	
	if not ctrl_pressed:
		# Ctrl relâché - revenir au mode courbe normal (restaurer son overlay)
		if _state == State.CURVE_OVERRIDE:
			_set_curve_edit_overlay_visible(_active_curve_edit, true)
			_remove_overlay()
			_state = State.INACTIVE
			_active_curve_edit = null
		return
	
	# Entrer en mode CURVE_OVERRIDE si pas déjà
	if _state != State.CURVE_OVERRIDE:
		_state = State.CURVE_OVERRIDE
		_active_curve_edit = curve_edit
		_create_overlay()
		# Masque le tracé Bézier natif du curve_edit pendant qu'on affiche l'arc,
		# sinon on a deux lignes magenta empilées (confus visuellement).
		_set_curve_edit_overlay_visible(curve_edit, false)
		print("[ArcDraw] Mode arc sur courbe (contrôle souris)")
	
	# Récupérer les points du segment latché par le curve_edit
	var pts = curve_edit._original_pts
	var ai = curve_edit._anchor_a_idx
	var bi = curve_edit._anchor_b_idx
	if pts.size() == 0 or ai < 0 or bi < 0 or ai >= pts.size() or bi >= pts.size():
		return
	
	var start = pts[ai]
	var end = pts[bi]
	var params = _compute_arc_params(start, end, _get_mouse_position())
	
	if not params.valid:
		# Souris trop proche de la corde : indicateur straight line
		_update_overlay(start, [end])
		_apply_overlay_color(params)
		return
	
	var arc_points = _calculate_arc_points(start, end, params.direction, params.angle)
	_update_overlay(start, arc_points)
	_apply_overlay_color(params)


func _confirm_curve_override_arc():
	"""Confirme l'arc et remplace le segment dans le curve_edit."""
	if _active_curve_edit == null:
		_exit_mode()
		return
	
	var curve_edit = _active_curve_edit
	
	# pattern_curve_edit utilise _edit_shape, les autres utilisent _edit_path
	var edit_path = curve_edit.get("_edit_path")
	if edit_path == null:
		edit_path = curve_edit.get("_edit_shape")
	
	var pts = curve_edit._original_pts
	var ai = curve_edit._anchor_a_idx
	var bi = curve_edit._anchor_b_idx
	
	if edit_path == null or pts.size() == 0 or ai < 0 or bi < 0:
		_exit_mode()
		return
	
	var start = pts[ai]
	var end = pts[bi]
	var params = _compute_arc_params(start, end, _get_mouse_position())
	if not params.valid:
		_exit_mode()
		return
	
	var arc_points = _calculate_arc_points(start, end, params.direction, params.angle)
	
	# Sauvegarder temporairement pour _replace_segment_with_arc
	_edit_path = edit_path
	_edit_original_pts = pts
	_edit_ai = ai
	_edit_bi = bi
	
	_replace_segment_with_arc(arc_points)
	var after_pts = _read_node_pts(edit_path)
	_record_points_change(edit_path, pts, after_pts)
	
	var orientation = "gauche" if params.direction == 1 else "droite"
	print("[ArcDraw] Arc confirmé sur courbe (%.1f° %s)" % [rad2deg(params.angle), orientation])
	
	# Annuler le mode courbe du curve_edit
	curve_edit._remove_overlay()
	curve_edit._state = 0  # IDLE
	
	# Réinitialiser les variables selon le type de curve_edit
	if curve_edit.get("_edit_path") != null:
		curve_edit._edit_path = null
	if curve_edit.get("_edit_shape") != null:
		curve_edit._edit_shape = null
	
	curve_edit._original_pts = []
	curve_edit._anchor_a_idx = -1
	curve_edit._anchor_b_idx = -1
	
	_exit_mode()


# ══════════════════════════════════════════════════════════════════════════════
# Undo
# ══════════════════════════════════════════════════════════════════════════════
# Points-based custom record. Registered at arc confirmation on an existing
# node (edit mode, or curve-override mode on top of a curve_edit).
#
# Draw-mode arcs don't register a record here — during mid-draw, Ctrl+Z is
# handled directly by DD via UndoPolyPoint (polyline-level), which bypasses
# Editor.History entirely. Our 16 discretized arc points appear as 16 separate
# undo steps. We can't group them: a single point with HasArcPoint=true renders
# the arc as a Bézier curve (DD's native 3-point arc mechanism), which doesn't
# match our circular arc shape. So we keep the discretization and accept the
# N-undo cost.
#
# The record calls _write_pts(node, pts) on arc_draw. Since arc_draw works
# on three node types (path, wall, pattern), _write_pts here is a dispatcher
# that routes to the existing _write_path_pts / _write_wall_pts /
# _write_pattern_pts based on the node's API shape — mirroring how
# _replace_segment_with_arc already detects the type.


# Dispatcher used by points_history_record.undo/redo.
func _write_pts(node, pts: Array):
	if node == null or not is_instance_valid(node):
		return
	if node.get("GlobalEditPoints") != null:
		_write_path_pts(node, pts)
	elif node.has_method("get_Points"):
		_write_wall_pts(node, pts)
	elif node.get("GlobalPolygon") != null:
		_write_pattern_pts(node, pts)


var _PointsRecordScript = null


func _load_record_script() -> void:
	if _PointsRecordScript != null:
		return
	_PointsRecordScript = ResourceLoader.load(
		_g.Root + "library/points_history_record.gd", "GDScript", true)
	if _PointsRecordScript == null:
		print("[ArcDraw] WARN: library/points_history_record.gd not found; undo disabled")


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


# Read back the points of a node after a mutation, using the same
# parsers the rest of arc_draw uses (avoids PoolVector2Array conversion
# quirks).
func _read_node_pts(node) -> Array:
	if node == null or not is_instance_valid(node):
		return []
	if node.get("GlobalEditPoints") != null:
		return _read_path_pts(node)
	if node.has_method("get_Points"):
		return _read_wall_pts(node)
	if node.get("GlobalPolygon") != null:
		return _read_pattern_pts(node)
	return []
