# wall_move.gd
# Permet de deplacer les walls par drag dans le SelectTool.
# Deplace : Points C#, Line2D.points, Sprite end caps, et portals.

var _g
var overlay_tool
var ui_util
var _listener = null

var _dragging       = false
var _drag_wall      = null
var _drag_start     = Vector2.ZERO
var _drag_origin_pts = []
var _drag_origin_pos = Vector2.ZERO
var _drag_origin_portals = {}  # {portal: position_originale}
var _drag_origin_children = {}  # {node: data_originale}

var _cursor_active  = false
var _move_cursor_tex = null

var _left_pressed        = false
var _drag_threshold_passed = false
var _left_press_pos      = Vector2.ZERO
var _destroyed := false
var _pending_wall_reselect = null
const DRAG_THRESHOLD     = 5.0
const SELECTABLE_WALL    = 1  # DD SelectableType: Wall


func initialize():
	_install_listener()
	print("[WallMove] Initialized")


func cleanup() -> void:
	_destroyed = true
	if _listener != null and is_instance_valid(_listener):
		_listener.handler = null
		_listener.queue_free()
	_listener = null
	# Reset drag state if drag was in progress.
	_dragging = false
	_drag_wall = null
	_drag_origin_portals = {}
	_drag_origin_children = {}
	_left_pressed = false
	_drag_threshold_passed = false
	print("[WallMove] Cleaned up")


func _install_listener():
	_listener = Node.new()
	_listener.name = "WallMoveListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\nfunc _process(d):\n\tif handler != null:\n\t\thandler._on_process(d)\n"
	s.reload()
	_listener.set_script(s)
	_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _listener)


func _is_select_tool_active():
	return _g.Editor and _g.Editor.ActiveToolName == "SelectTool"


func _on_input(event):
	if _destroyed:
		return
	if not _is_select_tool_active():
		return

	# Block all wall move interaction when free transform is active on a portal
	if _is_ft_on_portal():
		return

	# Tracker le bouton gauche
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_left_pressed = true
			_drag_threshold_passed = false
			_left_press_pos = event.position
			# Cliquer sur un wall overlayed le selectionne (parite avec les paths)
			_try_force_select_wall()
		else:
			_left_pressed = false
			_drag_threshold_passed = false
			if _dragging:
				_end_drag()

	# Detecter le seuil de drag
	if event is InputEventMouseMotion and _left_pressed and not _drag_threshold_passed:
		if event.position.distance_to(_left_press_pos) > DRAG_THRESHOLD:
			_drag_threshold_passed = true
			_try_start_drag()

	# Drag en cours
	if event is InputEventMouseMotion and _dragging:
		_do_drag()
		_listener.get_tree().set_input_as_handled()


func _try_force_select_wall() -> void:
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return
	if not _is_select_tool_active():
		return
	if ui_util and ui_util.is_mouse_over_ui(_listener):
		return
	if _is_ft_on_portal():
		return
	var wall = overlay_tool._hover_wall
	if wall == null or not is_instance_valid(wall):
		return
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return
	# Respecter le filter Walls du SelectTool
	var filter = st.get("Filter")
	if filter is Dictionary and not bool(filter.get("Walls", true)):
		return
	# Pas de selection si la souris est sur un portal (meme logique que le drag)
	if _is_mouse_on_portal(wall):
		return
	# Bloquer les walls FloorShape (Type != 1)
	var wtype = wall.get("Type")
	if wtype != null and wtype != 1:
		return
	# Respecter la selection des assets au-dessus du wall (objet, light, portal,
	# roof, pattern) : si un element est rendu devant, laisser DD le selectionner.
	var path_fix = overlay_tool.path_fix
	if path_fix != null and is_instance_valid(path_fix) and path_fix.has_method("_is_wall_covered"):
		if path_fix._is_wall_covered(wall):
			return
	# Deja selectionne ? laisser DD / le drag gerer (pas de re-select)
	var cur_raw = st.RawSelectables
	if cur_raw:
		for s in cur_raw:
			if s != null and s.get("Thing") == wall:
				return
	if not Input.is_key_pressed(KEY_SHIFT):
		st.DeselectAll()
	st.SelectThing(wall, true)
	st.EnableTransformBox(true)
	# DD peut deselectionner sur le meme clic si son hit-test natif rate :
	# on replanifie une re-selection differee pour garantir l'etat final.
	_pending_wall_reselect = wall
	call_deferred("_do_deferred_wall_reselect")
	_notify_wall_panel()


func _do_deferred_wall_reselect() -> void:
	var wall = _pending_wall_reselect
	_pending_wall_reselect = null
	if wall == null or not is_instance_valid(wall):
		return
	if not _is_select_tool_active():
		return
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return
	var raw = st.RawSelectables
	if raw:
		for s in raw:
			if s != null and s.get("Thing") == wall:
				return  # toujours selectionne, rien a faire
	# DD a vide la selection : on la restaure
	if not Input.is_key_pressed(KEY_SHIFT):
		st.DeselectAll()
	st.SelectThing(wall, true)
	st.EnableTransformBox(true)
	_notify_wall_panel()


func _notify_wall_panel() -> void:
	# SelectThing() ne rafraichit pas le panneau du SelectTool : on appelle
	# OnSelect(Wall) nous-memes pour faire apparaitre les controles de wall,
	# mais seulement si la selection est exclusivement des walls.
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return
	var raw = st.RawSelectables
	if raw != null:
		for s in raw:
			if s != null and s.get("Type") != SELECTABLE_WALL:
				return
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel != null and panel.has_method("OnSelect"):
		panel.OnSelect(SELECTABLE_WALL)


func _try_start_drag():
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return
	var wall = overlay_tool._hover_wall
	if wall == null or not is_instance_valid(wall):
		return
	if ui_util and ui_util.is_mouse_over_ui(_listener):
		return

	# Don't drag the wall if the mouse is on a portal
	if _is_mouse_on_portal(wall):
		return

	# Don't drag walls when free transform is active on a portal
	if _is_ft_on_portal():
		return

	# Bloquer les walls FloorShape (Type != 1)
	var wtype = wall.get("Type")
	if wtype != null and wtype != 1:
		return

	# Sauvegarder l'etat initial
	_drag_wall = wall
	_drag_start = _g.WorldUI.MousePosition
	_drag_origin_pos = wall.global_position

	var pts = wall.get("Points")
	_drag_origin_pts = []
	if pts != null:
		for p in pts:
			_drag_origin_pts.append(p)

	# Sauvegarder positions initiales des portals
	_drag_origin_portals = {}
	var portals = wall.get("Portals")
	if portals != null:
		for portal in portals:
			if is_instance_valid(portal):
				_drag_origin_portals[portal] = portal.position
	# Sauvegarder positions initiales des enfants visuels
	_drag_origin_children = {}
	_snapshot_children(wall)
	
	# Pour l'undo : capturer un snapshot stable (node_ids + valeurs) qui
	# survivra à la disparition/recréation des nodes. Les Points, la
	# global_position et les positions de portals suffisent à
	# reconstruire tout le reste via RemakeLines().
	_undo_snapshot_before = _snapshot_wall_state(wall)

	_dragging = true
	_set_drag_cursor()


func _do_drag():
	if _drag_wall == null or not is_instance_valid(_drag_wall):
		_end_drag()
		return

	var mouse = _g.WorldUI.MousePosition
	var raw_delta = mouse - _drag_start

	# Snap
	var snapped_origin = _drag_origin_pos + raw_delta
	if _g.Editor.IsSnapping and _g.WorldUI.has_method("GetSnappedPosition"):
		snapped_origin = _g.WorldUI.GetSnappedPosition(snapped_origin)
	var delta = snapped_origin - _drag_origin_pos

	# 1. Points C# (sauvegarde DD)
	var new_pts = []
	for i in range(_drag_origin_pts.size()):
		new_pts.append(_drag_origin_pts[i] + delta)
	_drag_wall.set("Points", new_pts)

	# 2. Enfants visuels
	_move_children(delta)

	# 3. Portals
	for portal in _drag_origin_portals:
		if is_instance_valid(portal):
			portal.position = _drag_origin_portals[portal] + delta
	# 4. Rafraichir l'etat interne C# du wall
	if _drag_wall.has_method("RemakeLines"):
		_drag_wall.call("RemakeLines")
	elif _drag_wall.has_method("RemakeLinesWhenAllPortalsReady"):
		_drag_wall.call("RemakeLinesWhenAllPortalsReady")


func _snapshot_children(wall):
	for child in wall.get_children():
		if child is Line2D:
			var pts = []
			for p in child.points: pts.append(p)
			_drag_origin_children[child] = {"points": pts}
			for sub in child.get_children():
				if sub is Node2D:
					_drag_origin_children[sub] = {"position": sub.position}
		elif child is Node2D:
			for sub in child.get_children():
				if sub is Line2D:
					var pts = []
					for p in sub.points: pts.append(p)
					_drag_origin_children[sub] = {"points": pts}


func _move_children(delta):
	for node in _drag_origin_children:
		if not is_instance_valid(node):
			continue
		var orig = _drag_origin_children[node]
		if orig.has("points"):
			var lpts = PoolVector2Array()
			for p in orig["points"]:
				lpts.append(p + delta)
			node.points = lpts
		elif orig.has("position"):
			node.position = orig["position"] + delta


func _end_drag():
	# Avant de tout nettoyer : si un vrai déplacement a eu lieu, capturer
	# l'état final et créer un record pour Ctrl+Z.
	if _drag_wall != null and is_instance_valid(_drag_wall) and _undo_snapshot_before != null:
		var after_snapshot = _snapshot_wall_state(_drag_wall)
		_record_wall_move(_undo_snapshot_before, after_snapshot)
	_undo_snapshot_before = null
	
	_dragging = false
	_drag_wall = null
	_drag_origin_pts = []
	_drag_origin_portals = {}
	_drag_origin_children = {}
	_reset_cursor()
	# Invalider hover pour que la re-detection se fasse depuis la nouvelle position
	if overlay_tool != null and is_instance_valid(overlay_tool):
		overlay_tool.invalidate_wall_hover()


# ──────────────────── UNDO SUPPORT ────────────────────

var _undo_snapshot_before = null


func _snapshot_wall_state(wall) -> Dictionary:
	# Capture everything needed to rebuild the wall's geometry after a
	# drag: its world position, its Points (C# side), and each attached
	# portal's local position. Identified by node_id so the snapshot is
	# stable across undo/redo cycles that may recreate wall nodes.
	var wall_nid = -1
	if wall.has_meta("node_id"):
		wall_nid = wall.get_meta("node_id")
	var pts: Array = []
	var raw_pts = wall.get("Points")
	if raw_pts != null:
		for p in raw_pts:
			pts.append(p)
	var portals_state: Array = []
	var raw_portals = wall.get("Portals")
	if raw_portals != null:
		for portal in raw_portals:
			if not is_instance_valid(portal):
				continue
			var pnid = -1
			if portal.has_meta("node_id"):
				pnid = portal.get_meta("node_id")
			portals_state.append({
				"node_id": pnid,
				"position": portal.position,
			})
	return {
		"wall_node_id": wall_nid,
		"global_position": wall.global_position,
		"points": pts,
		"portals": portals_state,
	}


func _record_wall_move(before: Dictionary, after: Dictionary) -> void:
	# Skip if nothing actually changed (e.g. user clicked then released
	# without moving enough to cross DRAG_THRESHOLD, though _end_drag
	# shouldn't fire in that case — guard anyway).
	if before.get("global_position") == after.get("global_position") \
			and before.get("points") == after.get("points"):
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_wall_state", [before],
		self, "_restore_wall_state", [after])


func _restore_wall_state(state: Dictionary) -> void:
	# Called on undo/redo. Re-locate the wall by node_id, apply Points
	# and global_position, restore each portal's local position, then
	# trigger DD's RemakeLines() so child Line2D / end-cap visuals
	# rebuild from the new Points.
	var wall_nid = state.get("wall_node_id", -1)
	if wall_nid < 0:
		return
	var wall = _find_node_by_id(wall_nid)
	if wall == null or not is_instance_valid(wall):
		return
	
	# Apply points + global position.
	var new_pts = PoolVector2Array()
	for p in state.get("points", []):
		new_pts.append(p)
	wall.set("Points", new_pts)
	wall.global_position = state.get("global_position", wall.global_position)
	
	# Apply each portal's local position by node_id.
	for entry in state.get("portals", []):
		var pnid = entry.get("node_id", -1)
		if pnid < 0:
			continue
		var portal = _find_node_by_id(pnid)
		if portal != null and is_instance_valid(portal):
			portal.position = entry.get("position", portal.position)
	
	# Rebuild the wall's visual children from its new Points.
	if wall.has_method("RemakeLines"):
		wall.call("RemakeLines")
	elif wall.has_method("RemakeLinesWhenAllPortalsReady"):
		wall.call("RemakeLinesWhenAllPortalsReady")


func _find_node_by_id(nid: int):
	if _g == null or _g.get("World") == null:
		return null
	var world = _g.World
	if not world.has_method("HasNodeID") or not world.HasNodeID(nid):
		return null
	return world.GetNodeByID(nid)


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")


func _on_process(_delta):
	if _destroyed:
		return
	if not _is_select_tool_active():
		if _dragging:
			_end_drag()
		return
	# Curseur drag quand hover wall (pas en drag, pas sur un portal, pas en ft sur portal)
	if not _dragging:
		if not _is_ft_on_portal() and overlay_tool != null and is_instance_valid(overlay_tool) and overlay_tool._hover_wall != null:
			if not _is_mouse_on_portal(overlay_tool._hover_wall):
				_set_drag_cursor()
			else:
				_reset_cursor()
		else:
			_reset_cursor()


func _is_mouse_on_portal(wall) -> bool:
	var portals = wall.get("Portals")
	if portals == null:
		return false
	# Marge d'exclusion = demi-epaisseur du mur (au lieu d'une tuile entiere),
	# pour ne couper le move cursor que sur l'ouverture du portal.
	var half_w = 40.0
	for child in wall.get_children():
		if child is Line2D and child.points.size() >= 2:
			if child.width * 0.5 > half_w or half_w == 40.0:
				half_w = child.width * 0.5
	var mouse = _g.WorldUI.MousePosition
	for portal in portals:
		if not is_instance_valid(portal):
			continue
		var rect = _get_portal_world_rect(portal, half_w)
		if rect.has_point(mouse):
			return true
	return false


func _get_portal_world_rect(portal, margin: float = 24.0) -> Rect2:
	var rect = Rect2()
	var found = false
	for child in portal.get_children():
		if child is Sprite and child.texture != null:
			var tex_size = child.texture.get_size()
			var s = child.global_scale.abs()
			var world_size = tex_size * s
			var child_rect = Rect2(child.global_position - world_size * 0.5, world_size)
			if not found:
				rect = child_rect
				found = true
			else:
				rect = rect.merge(child_rect)
	if not found:
		rect = Rect2(portal.global_position - Vector2(40, 40), Vector2(80, 80))
	return rect.grow(margin)


func _is_ft_on_portal() -> bool:
	if _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return false
	var ft = _g.ModMapData.get("_free_transform_active")
	if ft == null or not bool(ft):
		return false
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return false
	var wall = overlay_tool._hover_wall
	if wall == null or not is_instance_valid(wall):
		# Also check all walls — hover may be cleared when ft is active
		var level = _g.World.GetCurrentLevel() if _g.World != null else null
		if level == null:
			return false
		var walls = level.get("Walls")
		if walls == null:
			return false
		var mouse = _g.WorldUI.MousePosition
		for w in walls.get_children():
			if _is_mouse_on_portal(w):
				return true
		return false
	return _is_mouse_on_portal(wall)


func _is_mouse_near_portal(wall, radius_mult: float = 1.0) -> bool:
	var portals = wall.get("Portals")
	if portals == null:
		return false
	var mouse = _g.WorldUI.MousePosition
	for portal in portals:
		if not is_instance_valid(portal):
			continue
		var portal_pos = portal.global_position
		var hit_radius = 30.0
		for child in portal.get_children():
			if child is Sprite and child.texture != null:
				var tex_size = child.texture.get_size() * child.scale
				hit_radius = max(tex_size.x, tex_size.y) * 0.5
				break
		if mouse.distance_to(portal_pos) < hit_radius * radius_mult:
			return true
	return false


func _load_cursor_texture():
	var path = _g.Root + "icons/drag-cursor-icon.png"
	var img = Image.new()
	if img.load(path) != OK:
		return
	_move_cursor_tex = ImageTexture.new()
	_move_cursor_tex.create_from_image(img, 0)


func _set_drag_cursor():
	if _move_cursor_tex == null:
		_load_cursor_texture()
	if _move_cursor_tex:
		Input.set_custom_mouse_cursor(_move_cursor_tex, Input.CURSOR_ARROW,
			_move_cursor_tex.get_size() / 2)
		_cursor_active = true


func _reset_cursor():
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false
