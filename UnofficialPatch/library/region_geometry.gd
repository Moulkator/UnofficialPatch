# region_geometry.gd  (library/)
#
# Moteur de géométrie partagé : calcule la région fermée (bornée par murs, paths
# et bords de map) contenant un point donné. Extrait du pattern_paint_bucket pour
# être réutilisé par le terrain bucket.
#
# Utilisation :
#   var geo = ResourceLoader.load(g.Root + "library/region_geometry.gd", "GDScript", true).new()
#   geo._g = g
#   var region = geo.compute_region(mouse_world, include_patterns)
#   # region.outer : polygone simple (trous encodés via bridge-cuts, testables en
#   #                even-odd avec point_in_polygon). [] si clic hors région / sur un mur.
#
# La région renvoyée est un polygone "ponté" : les trous internes sont reliés à
# l'extérieur par des fentes de largeur nulle, donc un test point-in-polygon
# even-odd exclut correctement les trous. Pratique pour rasteriser (terrain) ou
# créer une PatternShape (pattern).

var _g

# px de chaque côté de la polyline. Doit être suffisant pour que deux barrières
# perpendiculaires se chevauchent de façon robuste au croisement.
const BARRIER_THICKNESS = 2.0
const EDGE_SNAP_THRESHOLD = 16.0   # endpoint à <N px d'un bord → snappé sur le bord
const EDGE_OVERSHOOT = 2.0         # quand on snappe, on dépasse de N px pour bien couper


# ── API publique ─────────────────────────────────────────────────────────────

func compute_region(mouse_world: Vector2, include_patterns: bool) -> Dictionary:
	var map_rect = _get_map_bounds_polygon()
	if map_rect.size() < 3:
		return {"outer": [], "holes": []}

	var b = _build_barriers(include_patterns)
	b.closed_pairs.sort_custom(self, "_sort_closed_pairs_by_outer_area_desc")

	var regions = [map_rect]

	for pair in b.closed_pairs:
		regions = _subtract_and_combine(regions, pair.outer)
		if regions.size() == 0: break
		if pair.inner != null:
			regions.append(pair.inner)

	for s in b.subs_last:
		regions = _subtract_and_combine(regions, s)
		if regions.size() == 0: break

	var outer = []
	var outer_area = INF
	for r in regions:
		if r.size() < 3: continue
		if not _point_in_polygon(mouse_world, r): continue
		var a = _polygon_area(r)
		if a < outer_area:
			outer_area = a
			outer = r

	return {"outer": outer, "holes": []}


# Test even-odd : le point est-il dans l'aire remplie du polygone ponté ?
func point_in_region(point: Vector2, region_outer: Array) -> bool:
	return _point_in_polygon(point, region_outer)


func get_map_bounds_polygon() -> Array:
	return _get_map_bounds_polygon()


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


func _get_path_polyline(path_node) -> Array:
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


# ── Géométrie de base ────────────────────────────────────────────────────────

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
	if dmin == dl: return Vector2(-EDGE_OVERSHOOT, p.y)
	if dmin == dr: return Vector2(w + EDGE_OVERSHOOT, p.y)
	if dmin == dt: return Vector2(p.x, -EDGE_OVERSHOOT)
	if dmin == db: return Vector2(p.x, h + EDGE_OVERSHOOT)
	return p


# ── Construction des barriers ────────────────────────────────────────────────

func _build_barriers(include_patterns: bool) -> Dictionary:
	var result = {"closed_pairs": [], "subs_last": []}
	var level = _get_current_level()
	if level == null: return result

	var walls_node = level.get("Walls")
	if walls_node != null:
		for child in walls_node.get_children():
			if not is_instance_valid(child): continue
			var pts_raw = child.get("Points")
			if pts_raw == null or pts_raw.size() < 2: continue
			# Les Points d'un Wall sont en espace LOCAL au nœud : on applique son
			# transform global (no-op si identité). Sans ça, un mur déplacé/tourné
			# via l'outil Select donne une région décalée.
			var xform = child.get_global_transform()
			var pts = []
			for p in pts_raw:
				pts.append(xform.xform(p))
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	var paths_node = level.get("Pathways")
	if paths_node != null:
		for child in paths_node.get_children():
			if not is_instance_valid(child): continue
			var pts = _get_path_polyline(child)
			if pts.size() < 2: continue
			var loop = bool(child.get("Loop"))
			_classify_polyline_barrier(pts, loop, result)

	if include_patterns:
		for shape in _get_all_pattern_shapes():
			var pts = _get_pattern_polygon(shape)
			if pts.size() >= 3:
				result.subs_last.append(pts)

	return result


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


func _polyline_self_intersects(pts: Array, closed: bool) -> bool:
	var n = pts.size()
	if n < 4: return false
	var seg_count = n if closed else n - 1
	for i in range(seg_count):
		var a1 = pts[i]
		var a2 = pts[(i + 1) % n]
		for j in range(i + 1, seg_count):
			if j == i + 1:
				continue
			if closed and i == 0 and j == seg_count - 1:
				continue
			var b1 = pts[j]
			var b2 = pts[(j + 1) % n]
			if Geometry.segment_intersects_segment_2d(a1, a2, b1, b2) != null:
				return true
	return false


func _classify_polyline_barrier(pts: Array, loop: bool, out: Dictionary):
	if pts.size() < 2: return

	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) < 2.0:
		pts.pop_back()
		loop = true
	if pts.size() < 2: return

	if not loop:
		pts[0] = _snap_endpoint_to_map_edge(pts[0], EDGE_SNAP_THRESHOLD)
		pts[pts.size() - 1] = _snap_endpoint_to_map_edge(pts[pts.size() - 1], EDGE_SNAP_THRESHOLD)
		_append_segment_quads(pts, false, out)
		return

	if _polyline_self_intersects(pts, true):
		_append_segment_quads(pts, true, out)
		return

	var offset_result = Geometry.offset_polyline_2d(pts, BARRIER_THICKNESS, Geometry.JOIN_MITER, Geometry.END_JOINED)
	var polys = []
	for b in offset_result:
		if b.size() >= 3:
			polys.append(_to_array(b))
	if polys.size() == 0:
		return
	if polys.size() == 1:
		out.closed_pairs.append({"outer": polys[0], "inner": null})
		return
	var i_big := 0
	var i_small := 1
	if _polygon_area(polys[1]) > _polygon_area(polys[0]):
		i_big = 1; i_small = 0
	out.closed_pairs.append({"outer": polys[i_big], "inner": polys[i_small]})
	for i in range(polys.size()):
		if i == i_big or i == i_small: continue
		out.closed_pairs.append({"outer": polys[i], "inner": null})


# ── Pipeline de soustraction + recombinaison ─────────────────────────────────

func _sort_closed_pairs_by_outer_area_desc(a, b) -> bool:
	return _polygon_area(a.outer) > _polygon_area(b.outer)


func _subtract_and_combine(regions: Array, barrier: Array) -> Array:
	var new_regions = []
	for r in regions:
		var clipped = Geometry.clip_polygons_2d(r, barrier)
		var combined = _combine_outer_holes(clipped)
		for c in combined:
			if c.size() >= 3:
				new_regions.append(_to_array(c))
	return new_regions


func _combine_outer_holes(polygons_pool: Array) -> Array:
	var polys = []
	for p in polygons_pool:
		if p.size() >= 3:
			polys.append(_to_array(p))
	if polys.size() <= 1:
		return polys

	var parents = []
	for i in range(polys.size()):
		parents.append(_find_immediate_parent_idx(i, polys))

	var depths = []
	for i in range(polys.size()):
		var d = 0
		var p_idx = parents[i]
		while p_idx >= 0:
			d += 1
			p_idx = parents[p_idx]
		depths.append(d)

	var result = []
	for i in range(polys.size()):
		if depths[i] % 2 != 0: continue
		var outer = polys[i]
		var outer_holes = []
		for j in range(polys.size()):
			if depths[j] % 2 == 0: continue
			if parents[j] == i:
				outer_holes.append(polys[j])
		if outer_holes.size() == 0:
			result.append(outer)
		else:
			result.append(_eliminate_holes(outer, outer_holes))
	return result


func _find_immediate_parent_idx(p_idx: int, polygons: Array) -> int:
	var p_area = _polygon_area(polygons[p_idx])
	var min_parent_area = INF
	var min_parent_idx = -1
	for q_idx in range(polygons.size()):
		if q_idx == p_idx: continue
		var q_area = _polygon_area(polygons[q_idx])
		if q_area <= p_area: continue
		if not _polygon_inside_polygon(polygons[p_idx], polygons[q_idx]): continue
		if q_area < min_parent_area:
			min_parent_area = q_area
			min_parent_idx = q_idx
	return min_parent_idx


# ── Élimination de trous robuste (earcut) ────────────────────────────────────

func _eliminate_holes(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = _flip_y(outer_in)
	if _ring_signed_area(outer) < 0.0:
		outer.invert()
	var prepared = []
	for h in holes_in:
		var hp = _flip_y(h)
		if _ring_signed_area(hp) > 0.0:
			hp.invert()
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
		var bd = INF
		bi = 0
		for i in range(outer.size()):
			var d = outer[i].distance_squared_to(hole[hi])
			if d < bd:
				bd = d; bi = i
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


func _find_hole_bridge(outer: Array, hole: Array, hi: int) -> int:
	var hx = hole[hi].x
	var hy = hole[hi].y
	var qx = -INF
	var m = -1
	var n = outer.size()
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
