# wall_tool_portal_fix.gd
# Corrige le bug "wall fou" (Set() non appelé lors de l'édition de points)
# et repositionne les portals après édition avec le WallTool.
#
# Dépendance optionnelle sur portal_reposition_ui :
#   ui != null et ui.reposition_enabled → repositionne les portals
#   ui == null ou reposition_enabled == false → vanilla (portals supprimés)

var _g
var ui        = null  # ref optionnelle vers portal_reposition_ui
var floor_mod = null  # ref optionnelle vers floor_shape_portal_fix

var _wall_tool  = null
var _wall_ep    = null
var _wall_panel = null
var _wall_last_panel_visible = true
var _reposition_btn = null

var _is_editing = false

var _portal_snapshots   = {}
var _orphaned_snapshots = []
var _modified_walls     = {}
var _point_hashes       = {}
var _wall_save_data     = {}
var _pending_reload     = null
var _pending_reload_tick = 0
var _node_id_counter    = -1

const CHECK_INTERVAL = 0.1
const DIR_TOLERANCE  = 0.02


# Helper : la feature Reposition Portals est active si on a une UI ref
# ET que reposition_enabled est true. Quand inactive, on revient au
# comportement vanilla DD : portals visibles normalement, puis supprimes
# par DD des qu'on bouge un point. Le wall-fou fix (Set() apres edit)
# reste actif dans tous les cas — c'est la raison principale du mod.
func _is_repo_active() -> bool:
	return ui != null and ui.reposition_enabled


func initialize():
	_wall_tool = _g.Editor.Tools["WallTool"]
	_wall_ep   = _wall_tool.get("EditPoints")
	if _wall_ep != null and _wall_ep.has_signal("toggled"):
		_wall_ep.connect("toggled", self, "_on_wall_edit_toggled")
	if _wall_ep != null:
		var align = _wall_ep.get_parent()
		if align != null:
			_wall_panel = align.get_parent()
	_wall_last_panel_visible = _wall_panel.visible if _wall_panel != null else true

	if ui != null:
		_reposition_btn = ui.create_button_for(_wall_ep)

	var timer = Timer.new()
	timer.wait_time = CHECK_INTERVAL
	timer.autostart = true
	timer.connect("timeout", self, "_tick")
	_g.Editor.add_child(timer)

	print("[WallPortalFix] initialized")


func _tick():
	# Rechargement différé (LoadWall après edit)
	if _pending_reload != null and _pending_reload.size() > 0:
		_pending_reload_tick -= 1
		if _pending_reload_tick <= 0:
			_deferred_reload_wall()

	# Surveillance du panel WallTool
	if _wall_panel != null:
		var pv = _wall_panel.visible
		if pv != _wall_last_panel_visible:
			if not pv and _is_editing:
				_enter_edit(false)
			elif pv and not _is_editing and _wall_ep != null and _wall_ep.pressed:
				_enter_edit(true)
			_wall_last_panel_visible = pv

	if _is_editing:
		_scan_and_rebuild()
		# Markers + overlay : reposition-only. En vanilla, on ne calcule
		# rien et on n'affiche aucun cercle colore.
		if _is_repo_active():
			_compute_markers()
			ui.refresh_overlay()


func _on_wall_edit_toggled(pressed):
	if pressed and not _is_editing:
		_enter_edit(true)
	elif not pressed and _is_editing:
		_enter_edit(false)


func _enter_edit(pressed):
	# Force la sortie du FloorShapeTool si en cours d'édition
	if pressed and floor_mod != null and floor_mod._is_editing:
		floor_mod._enter_edit(false)

	_is_editing = pressed
	if _reposition_btn != null:
		# Le bouton n'est visible qu'en mode Edit Points ET si la feature
		# Reposition Portals est activee dans Settings (ui.reposition_enabled).
		# Si OFF, le bouton reste cache meme en EP.
		var repo_allowed = ui != null and ui.reposition_enabled
		_reposition_btn.visible = pressed and repo_allowed

	if pressed:
		_modified_walls.clear()
		_point_hashes.clear()
		_orphaned_snapshots.clear()
		_wall_save_data.clear()
		_pending_reload = null
		_snapshot_portals()
		# Overlay = visualisation reposition-only. En vanilla on ne cree
		# meme pas l'overlay (pas de cercles colores possibles).
		if _is_repo_active():
			ui.create_overlay(_g.World.GetCurrentLevel())
			ui.set_marker_data([])
	else:
		if ui != null:
			ui.destroy_overlay()
		_final_restore()
		_modified_walls.clear()
		_point_hashes.clear()


# ── Snapshot ──────────────────────────────────────────────────────────────────

func _snapshot_portals():
	_portal_snapshots.clear()
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		var wtype = wall.get("Type")
		if wtype == null or wtype != 1:
			continue
		var wid     = wall.get_instance_id()
		var portals = wall.Portals
		if portals == null or portals.size() == 0:
			continue
		var points  = wall.Points
		var is_loop = wall.Loop
		var infos   = []
		for portal in portals:
			var idx     = portal.WallPointIndex
			var seg     = _get_segment(points, is_loop, idx)
			var seg_vec = seg[1] - seg[0]
			var seg_len = seg_vec.length()
			var dfs     = 0.0
			var dfe     = 0.0
			if seg_len > 0.001:
				var sd = seg_vec / seg_len
				dfs = (portal.position - seg[0]).dot(sd)
				dfe = seg_len - dfs
			var save_data = null
			if portal.has_method("Save"):
				save_data = portal.Save(false)
			infos.append({
				"tex_object": portal.Texture,  "closed": portal.Closed,
				"direction":  portal.Direction, "radius": portal.Radius,
				"flip":       portal.Flip,      "wallDistance": portal.WallDistance,
				"wallPointIndex": portal.WallPointIndex,
				"position": portal.position, "rotation": portal.rotation,
				"scale":    portal.scale,
				"seg_start": seg[0], "seg_end": seg[1],
				"seg_direction":      _segment_direction(seg[0], seg[1]),
				"orig_seg_direction": _segment_direction(seg[0], seg[1]),
				"orig_position":   portal.position,
				"orig_seg_start":  seg[0], "orig_seg_end": seg[1],
				"dist_from_start": dfs,    "dist_from_end": dfe,
				"_save_data":    save_data,
				"_orig_node_id": portal.get_meta("node_id") if portal.has_meta("node_id") else -1
			})
		_portal_snapshots[wid] = infos
		if wall.has_method("Save") and not _wall_save_data.has(wid):
			_wall_save_data[wid] = wall.Save()
		# Masque les portals pendant l'édition (évite l'affichage fantôme)
		# UNIQUEMENT en mode reposition : on les remplace ensuite par les
		# cercles colores. En vanilla, on laisse les portals visibles —
		# DD les supprimera de lui-meme quand l'utilisateur bouge un point.
		if _is_repo_active():
			for portal in portals:
				if is_instance_valid(portal):
					portal.visible = false


func _snapshot_new_portals(wall, wid):
	"""Capture les portals ajoutés pendant l'édition (non encore dans le snapshot)."""
	var portals = wall.Portals
	if portals == null or portals.size() == 0:
		return
	var existing = _portal_snapshots.get(wid, [])
	var existing_positions = {}
	for info in existing:
		existing_positions[str(info.get("orig_position", info["position"]))] = true
	var points  = wall.Points
	var is_loop = wall.Loop
	var added   = 0
	for portal in portals:
		if existing_positions.has(str(portal.position)):
			continue
		var idx     = portal.WallPointIndex
		var seg     = _get_segment(points, is_loop, idx)
		var seg_vec = seg[1] - seg[0]
		var seg_len = seg_vec.length()
		var dfs     = 0.0
		var dfe     = 0.0
		if seg_len > 0.001:
			var sd = seg_vec / seg_len
			dfs = (portal.position - seg[0]).dot(sd)
			dfe = seg_len - dfs
		existing.append({
			"tex_object": portal.Texture,  "closed": portal.Closed,
			"direction":  portal.Direction, "radius": portal.Radius,
			"flip":       portal.Flip,      "wallDistance": portal.WallDistance,
			"wallPointIndex": portal.WallPointIndex,
			"position": portal.position, "rotation": portal.rotation,
			"scale":    portal.scale,
			"seg_start": seg[0], "seg_end": seg[1],
			"seg_direction":      _segment_direction(seg[0], seg[1]),
			"orig_seg_direction": _segment_direction(seg[0], seg[1]),
			"orig_position":  portal.position,
			"orig_seg_start": seg[0], "orig_seg_end": seg[1],
			"dist_from_start": dfs, "dist_from_end": dfe
		})
		added += 1
	if added > 0:
		_portal_snapshots[wid] = existing


# ── Scan & rebuild (fix wall fou) ─────────────────────────────────────────────

func _scan_and_rebuild():
	"""Détecte les changements de points et appelle Set() pour corriger le wall fou."""
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	var current_ids = {}
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		var wtype = wall.get("Type")
		if wtype == null or wtype != 1:
			continue
		var wid = wall.get_instance_id()
		current_ids[wid] = true
		var h = _hash_points(wall.Points)
		if _point_hashes.has(wid):
			if _point_hashes[wid] != h:
				_point_hashes[wid] = h
				_modified_walls[wid] = true
				_snapshot_new_portals(wall, wid)
				wall.Set(wall.Points, wall.Texture, wall.Color, wall.Loop,
						 wall.HasShadow, wall.Type, wall.Joint, wall.NormalizeUV)
				# Re-cache les portals (Set() les recrée visibles → flash d'une frame)
				# UNIQUEMENT en mode reposition.
				if _is_repo_active():
					var portals_after = wall.Portals
					if portals_after != null:
						for portal in portals_after:
							if is_instance_valid(portal):
								portal.visible = false
				# Resync les positions : DD recalcule les positions des portals
				# après Set(). Si on ne met pas à jour notre snapshot, les portals
				# sur des segments non touchés semblent "disparaître" au tick suivant.
				_resync_portal_positions(wall, wid)
		else:
			_point_hashes[wid] = h
	var to_remove = []
	for wid in _point_hashes:
		if not current_ids.has(wid):
			to_remove.append(wid)
	for wid in to_remove:
		_point_hashes.erase(wid)
		_portal_snapshots.erase(wid)
		_modified_walls.erase(wid)


# ── Marqueurs overlay ─────────────────────────────────────────────────────────

func _resync_portal_positions(wall, wid):
	# Après Set(), DD recalcule les positions de tous les portals du wall.
	# On resynchronise notre snapshot avec ces nouvelles positions pour que
	# _validate_portal ne les perde pas au tick suivant.
	if not _portal_snapshots.has(wid):
		return
	var portals = wall.Portals
	if portals == null or portals.size() == 0:
		return
	var infos = _portal_snapshots[wid]
	for info in infos:
		var best_portal = null
		var best_dist   = 200.0
		for portal in portals:
			if not is_instance_valid(portal):
				continue
			var d = portal.position.distance_to(info["position"])
			if d < best_dist:
				best_dist   = d
				best_portal = portal
		if best_portal != null:
			info["position"]      = best_portal.position
			info["orig_position"] = best_portal.position

func _compute_markers():
	if ui == null:
		return
	var marker_data = []
	var level = _g.World.GetCurrentLevel()
	if level == null:
		ui.set_marker_data(marker_data)
		return
	var walls_node = level.Walls
	if walls_node == null:
		ui.set_marker_data(marker_data)
		return

	var current_wall_ids = {}
	var walls_by_id      = {}
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		var wtype = wall.get("Type")
		if wtype == null or wtype != 1:
			continue
		var wid = wall.get_instance_id()
		current_wall_ids[wid] = true
		walls_by_id[wid]      = wall

	# Gestion des orphelins (murs supprimés pendant l'édition)
	var orphaned_keys = []
	for wid in _portal_snapshots:
		if not current_wall_ids.has(wid):
			orphaned_keys.append(wid)
	for wid in orphaned_keys:
		for info in _portal_snapshots[wid]:
			_orphaned_snapshots.append(info)
		_portal_snapshots.erase(wid)
	if _orphaned_snapshots.size() > 0 and walls_by_id.size() > 0:
		var remaining = []
		for info in _orphaned_snapshots:
			var orig_pos  = info.get("orig_position", info["position"])
			var best_wid  = -1
			var best_dist = INF
			for wid in walls_by_id:
				var wall    = walls_by_id[wid]
				var closest = _find_closest_segment(wall.Points, wall.Loop, orig_pos)
				if closest["distance"] < best_dist:
					best_dist = closest["distance"]
					best_wid  = wid
			if best_wid >= 0 and best_dist < 500.0:
				if not _portal_snapshots.has(best_wid):
					_portal_snapshots[best_wid] = []
				_portal_snapshots[best_wid].append(info)
				_modified_walls[best_wid] = true
			else:
				remaining.append(info)
		_orphaned_snapshots = remaining

	var reposition_on = ui.reposition_enabled
	for wid in _portal_snapshots:
		if not walls_by_id.has(wid):
			continue
		var wall  = walls_by_id[wid]
		var infos = _portal_snapshots[wid]
		var np    = wall.Points
		var il    = wall.Loop
		for info in infos:
			var valid_si = _validate_portal(np, il, info)
			if valid_si >= 0:
				info["_last_state"]   = "valid"
				# wallPointIndex toujours à jour → _reposition_portal part du bon segment
				info["wallPointIndex"] = valid_si
				marker_data.append({
					"draw_position": info["position"],
					"draw_rotation": info["rotation"],
					"scale": info["scale"], "tex_object": info["tex_object"],
					"radius": info["radius"], "color": ui.COLOR_KEPT
				})
			elif reposition_on:
				var result = _reposition_portal(np, il, info)
				if result != null:
					info["_last_state"] = "repositioned"
					info["_last_proj"]  = result
					marker_data.append({
						"draw_position": result["position"],
						"draw_rotation": result["draw_rotation"],
						"scale": info["scale"], "tex_object": info["tex_object"],
						"radius": info["radius"], "color": ui.COLOR_REPOSITIONED
					})
				else:
					info["_last_state"] = "dropped"
					marker_data.append({
						"draw_position": info["position"],
						"draw_rotation": info["rotation"],
						"scale": info["scale"], "tex_object": info["tex_object"],
						"radius": info["radius"], "color": ui.COLOR_DROPPED
					})
			else:
				info["_last_state"] = "dropped"
				marker_data.append({
					"draw_position": info["position"],
					"draw_rotation": info["rotation"],
					"scale": info["scale"], "tex_object": info["tex_object"],
					"radius": info["radius"], "color": ui.COLOR_DROPPED
				})
	for info in _orphaned_snapshots:
		marker_data.append({
			"draw_position": info["position"], "draw_rotation": info["rotation"],
			"scale": info["scale"], "tex_object": info["tex_object"],
			"radius": info["radius"], "color": ui.COLOR_DROPPED
		})
	ui.set_marker_data(marker_data)


# ── Restauration finale ───────────────────────────────────────────────────────

func _final_restore():
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return

	var do_reposition = (ui != null and ui.reposition_enabled)

	# Vanilla ou aucune modification : rétablir juste la visibilité des portals
	if not do_reposition or _modified_walls.empty():
		for wid in _portal_snapshots:
			for i in range(walls_node.get_child_count()):
				var w = walls_node.get_child(i)
				if is_instance_valid(w) and w.get_instance_id() == wid:
					var portals = w.Portals
					if portals != null:
						for p in portals:
							if is_instance_valid(p):
								p.visible = true
					break
		_portal_snapshots.clear()
		_orphaned_snapshots.clear()
		_wall_save_data.clear()
		return

	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		var wtype = wall.get("Type")
		if wtype == null or wtype != 1:
			continue
		var wid = wall.get_instance_id()
		if not _modified_walls.has(wid):
			var portals = wall.Portals
			if portals != null:
				for p in portals:
					if is_instance_valid(p):
						p.visible = true
			continue
		if not _portal_snapshots.has(wid):
			continue
		_restore_wall_portals(wall, _portal_snapshots[wid])

	_portal_snapshots.clear()
	_orphaned_snapshots.clear()
	_wall_save_data.clear()


func _restore_wall_portals(wall, infos):
	var walls_node = wall.get_parent()
	if walls_node == null:
		return
	var wid = wall.get_instance_id()

	if not _wall_save_data.has(wid):
		wall.Set(wall.Points, wall.Texture, wall.Color, wall.Loop,
				 wall.HasShadow, wall.Type, wall.Joint, wall.NormalizeUV)
		wall.RemakeLinesWhenAllPortalsReady()
		return

	var current_points = wall.Points
	var wall_save      = _wall_save_data[wid].duplicate()
	wall_save["points"] = var2str(current_points)

	var orig_portal_array = _wall_save_data[wid].get("portals", [])
	var new_portal_array  = []

	for pi in range(infos.size()):
		var info  = infos[pi]
		var state = info.get("_last_state", "")
		if state == "dropped":
			continue
		if pi >= orig_portal_array.size():
			continue
		var pe      = orig_portal_array[pi].duplicate()
		var pos     = info["position"]
		var seg_idx = info.get("wallPointIndex", 0)
		if state == "repositioned" and info.has("_last_proj"):
			pos     = info["_last_proj"]["position"]
			seg_idx = info["_last_proj"]["seg_index"]
		else:
			seg_idx = _find_closest_segment(current_points, wall.Loop, pos)["index"]
		var seg     = _get_segment(current_points, wall.Loop, seg_idx)
		var sdv     = (seg[1] - seg[0]).normalized()
		var rot     = atan2(sdv.y, sdv.x)
		var seg_len = seg[0].distance_to(seg[1])
		var frac    = 0.5
		if seg_len > 0.001:
			frac = (pos - seg[0]).dot(sdv) / seg_len
		frac = clamp(frac, 0.01, 0.99)
		pe["position"]      = var2str(pos)
		pe["direction"]     = var2str(sdv)
		pe["point_index"]   = seg_idx
		pe["rotation"]      = rot
		pe["wall_distance"] = float(seg_idx) + frac
		for key in pe.keys():
			if pe[key] is Vector2:
				pe[key] = var2str(pe[key])
		new_portal_array.append(pe)

	wall_save["portals"] = new_portal_array
	for pe in new_portal_array:
		pe.erase("node_id")
		pe.erase("wall_id")

	if _pending_reload == null:
		_pending_reload = []
	_pending_reload.append({
		"save_data":  wall_save,
		"walls_node": walls_node,
		"old_wall":   wall
	})
	_pending_reload_tick = 1


func _deferred_reload_wall():
	var reloads      = _pending_reload
	_pending_reload  = null
	for entry in reloads:
		var save_data  = entry["save_data"]
		var walls_node = entry["walls_node"]
		var old_wall   = entry["old_wall"]
		if not is_instance_valid(walls_node):
			continue
		if is_instance_valid(old_wall):
			if old_wall.get_parent() != null:
				old_wall.get_parent().remove_child(old_wall)
			old_wall.free()
		walls_node.LoadWall(save_data)
		var new_wall = walls_node.get_child(walls_node.get_child_count() - 1)
		if is_instance_valid(new_wall) and new_wall.has_method("Set"):
			new_wall.RemakeLinesWhenAllPortalsReady()


# ── Utilitaires géométriques ──────────────────────────────────────────────────

func _validate_portal(np, il, info):
	# Retourne l'index du segment valide, ou -1.
	var pos      = info.get("orig_position", info["position"])
	var radius   = info["radius"]
	var orig_dir = info.get("orig_seg_direction", info["seg_direction"])
	var num_segs = np.size() if il else max(np.size() - 1, 0)
	for si in range(num_segs):
		var seg = _get_segment(np, il, si)
		var sv  = seg[1] - seg[0]
		var sl  = sv.length()
		if sl < 0.001:
			continue
		var sd = sv / sl
		if not _directions_match(orig_dir, sd):
			continue
		var r    = _psi(pos, seg[0], seg[1])
		if r["perp_distance"] > 5.0:
			continue
		var proj = (pos - seg[0]).dot(sd)
		if proj - radius < -5.0 or proj + radius > sl + 5.0:
			continue
		return si
	return -1


func _reposition_portal(np, il, info):
	# Cherche tous les segments non-perpendiculaires dont le point
	# le plus proche d'orig_pos est dans un rayon MAX_PHYS_DIST.
	# Critère purement géométrique — insensible aux décalages d'index
	# causés par les insertions de points.

	var orig_pos = info.get("orig_position", info["position"])
	var orig_sd  = info.get("orig_seg_direction", info["seg_direction"])
	var radius   = info["radius"]
	var orig_dir = info.get("direction", Vector2.RIGHT)
	var num_segs = np.size() if il else max(np.size() - 1, 0)

	# Rayon physique : on n'accepte un segment que si son point le plus proche
	# d'orig_pos est dans ce rayon. Assez grand pour couvrir un déplacement
	# normal de point, assez petit pour ne pas sauter sur un segment lointain.
	var MAX_PHYS_DIST = 800.0

	var best_result = null
	var best_dist   = INF

	for si in range(num_segs):
		var seg = _get_segment(np, il, si)
		var sv  = seg[1] - seg[0]
		var sl  = sv.length()
		if sl < 0.001:
			continue
		var sd = sv / sl

		# Exclut les segments quasi-perpendiculaires
		if abs(orig_sd.dot(sd)) < 0.1:
			continue

		# Filtre physique : distance du point le plus proche du segment à orig_pos
		var r = _psi(orig_pos, seg[0], seg[1])
		if r["distance"] > MAX_PHYS_DIST:
			continue

		# Projection axiale
		var denom = sd.dot(orig_sd)
		if abs(denom) < 0.001:
			continue
		var t = (orig_pos - seg[0]).dot(orig_sd) / denom
		if t - radius < -5.0 or t + radius > sl + 5.0:
			continue

		var clamped = clamp(t, radius, sl - radius)
		var new_pos = seg[0] + sd * clamped
		var dist    = new_pos.distance_to(orig_pos)
		if dist < best_dist:
			best_dist   = dist
			var nd      = sd if orig_dir.dot(sd) >= 0.0 else -sd
			best_result = {
				"seg_index":     si,
				"new_seg_start": seg[0],
				"new_seg_end":   seg[1],
				"position":      new_pos,
				"direction":     nd,
				"draw_rotation": nd.angle()
			}

	return best_result


func _find_closest_segment(points, is_loop, pos):
	var n  = points.size()
	var ns = n if is_loop else max(n - 1, 0)
	var bi = 0
	var bd = INF
	var bp = INF
	for si in range(ns):
		var seg = _get_segment(points, is_loop, si)
		var r   = _psi(pos, seg[0], seg[1])
		if r["distance"] < bd:
			bd = r["distance"]
			bp = r["perp_distance"]
			bi = si
	return {"index": bi, "distance": bd, "perp_distance": bp}


func _psi(point, a, b):
	var v = b - a
	var l = v.length()
	if l < 0.001:
		var d = point.distance_to(a)
		return {"distance": d, "perp_distance": d}
	var d  = v / l
	var t  = point - a
	var pp = abs(t.x * d.y - t.y * d.x)
	var cp = clamp(t.dot(d), 0.0, l)
	return {"distance": point.distance_to(a + d * cp), "perp_distance": pp}


func _get_segment(points, is_loop, idx):
	var n = points.size()
	if n < 2:
		return [Vector2.ZERO, Vector2.ZERO]
	return [points[idx % n], points[((idx + 1) % n) if is_loop else min(idx + 1, n - 1)]]


func _segment_direction(a, b):
	var d = b - a
	return d.normalized() if d.length() > 0.001 else Vector2.ZERO


func _directions_match(d1, d2):
	if d1.length() < 0.001 or d2.length() < 0.001:
		return false
	return abs(abs(d1.dot(d2)) - 1.0) < DIR_TOLERANCE


func _hash_points(points):
	if points == null:
		return ""
	var p = PoolStringArray()
	for pt in points:
		p.append(str(pt.x) + "," + str(pt.y))
	return p.join("|")


func _next_node_id():
	if _node_id_counter < 0:
		_node_id_counter = 0
		var level = _g.World.GetCurrentLevel()
		if level != null:
			var walls_node = level.Walls
			if walls_node != null:
				for i in range(walls_node.get_child_count()):
					var wall = walls_node.get_child(i)
					if is_instance_valid(wall) and wall.has_meta("node_id"):
						var nid = wall.get_meta("node_id")
						if nid is int and nid > _node_id_counter:
							_node_id_counter = nid
					if is_instance_valid(wall) and wall.has_method("Set"):
						var portals = wall.get("Portals")
						if portals != null:
							for portal in portals:
								if is_instance_valid(portal) and portal.has_meta("node_id"):
									var pid = portal.get_meta("node_id")
									if pid is int and pid > _node_id_counter:
										_node_id_counter = pid
	_node_id_counter += 1
	return _node_id_counter
