# path_fix.gd
# Fixes for flat (straight) Line2D paths in Dungeondraft:
# 1. Rotation snap: snaps near-exact rotations to 0/90/180/270 so DD's
#    IsMouseWithin detection works (requires GlobalRect dimension = exactly 0)
# 2. Move hijack: forces Move mode when dragging the middle of a flat path
#    (DD's transform box has zero height/width, making handles unusable)
# 3. Rotate at extremities: lets DD handle rotation at path ends, then
#    seamlessly takes over if DD drops the transform (mouse too far)
# 4. Snap support: compatible with Snappy mod and DD vanilla snap
# 5. Re-applies fixes on level change (reload, new map, switch level)

var _g
var select_tool
var ui_util
var input_listener: Node

var _is_flat_selected := false
var _flat_line = null
var _hijacking := false
var _hijack_mode := 0  # 0=none, 1=Move, 2=Rotate
var _drag_start := Vector2.ZERO
var _drag_origin := Vector2.ZERO
var _mouse_was_pressed := false
var _at_extremity := false
var _dd_was_rotating := false
var _rotate_center := Vector2.ZERO
var _rotate_last_angle := 0.0
var _force_drag_ready := false

var _snappy_ref = null
var _snappy_searched := false
var _initial_fix_done := false
var _initial_fix_delay := 30
var _left_pressed := false
var _drag_threshold_passed := false
var _left_press_pos := Vector2.ZERO
var _reselect_on_empty := false
var _hovered_path = null
var _pending_reselect = null
var _pending_drag_start := Vector2.ZERO
var _pending_drag_origin := Vector2.ZERO
# Override "selection a travers un trou" differe au release : si le press tombe
# dans la zone de deplacement (corps de la box d'un asset selectionne), on ne
# selectionne l'asset du dessous QUE si le geste est un clic (aucun drag), pour ne
# jamais voler un deplacement de l'asset selectionne.
var _pending_overlay_pat = null
var _pending_overlay_sel = null
# Idem pour un PATH clique dans le corps de la box d'un autre asset selectionne :
# selection differee au release, seulement si clic (pas de drag).
var _pending_overlay_path = null
var _pending_overlay_path_sel = null

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_create_highlight_material()
	_install_input_listener()
	print("[PathFix] Initialized")


func _do_deferred_panel_notify() -> void:
	if not _is_select_tool_active():
		return
	var line = _flat_line
	if line == null or not is_instance_valid(line):
		return
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var t = s.get("Thing")
		if t != null and is_instance_valid(t) and t == line:
			# Recalcule AreDeletable/HasCopyable/HasPrefab + rafraîchit les boutons
			# (Delete, Copy, Mirror, Lock, Make Prefab). Sans ça, ces flags
			# restent à false sur une sélection de path directe (sans sélection
			# préalable) et les boutons restent grisés.
			if select_tool.has_method("OnFinishSelection"):
				select_tool.OnFinishSelection()
			var sel_type = select_tool.GetSelectableType(line)
			var tool_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
			if tool_panel and tool_panel.has_method("OnSelect"):
				tool_panel.OnSelect(sel_type)
			return


func _normalize_pathway_position(line) -> void:
	# Fix vanilla DD bug: Edit Points moves local points but never updates
	# the node position. The transform box anchors on position, causing a
	# mismatch. Detect via points[0]: if it's drifted from (0,0), the node
	# origin needs shifting. After we fix it, points[0] becomes (0,0) so
	# re-selecting won't re-normalize.
	var pts = line.points
	if pts.size() < 2:
		return
	var offset = pts[0]
	if abs(offset.x) < 0.5 and abs(offset.y) < 0.5:
		return
	# Shift node position
	var xform = line.get_global_transform()
	var global_offset = xform.basis_xform(offset)
	line.global_position += global_offset
	# Shift all Line2D points so points[0] becomes (0,0)
	var new_pts = PoolVector2Array()
	for p in pts:
		new_pts.append(p - offset)
	line.points = new_pts
	# Shift EditPoints by the same offset so Path Tool Edit Points stays aligned
	var edit_pts = line.get("EditPoints")
	if edit_pts != null and edit_pts.size() > 0:
		var new_edit = PoolVector2Array()
		for ep in edit_pts:
			new_edit.append(ep - offset)
		line.set("EditPoints", new_edit)

func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "PathFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _process(delta) -> void:\n\tif handler != null:\n\t\thandler._on_process(delta)\nfunc _deferred_reselect() -> void:\n\tif handler != null:\n\t\thandler._do_deferred_reselect()\nfunc _deferred_overlay_select() -> void:\n\tif handler != null:\n\t\thandler._do_deferred_overlay_select()\nfunc _deferred_overlay_path_select() -> void:\n\tif handler != null:\n\t\thandler._do_deferred_overlay_path_select()\nfunc _deferred_panel_notify() -> void:\n\tif handler != null:\n\t\thandler._do_deferred_panel_notify()\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)
	_install_pattern_box()


func _install_pattern_box() -> void:
	# Noeud de dessin pour le contour pointille jaune du pattern survole au-dessus
	# d'un path (le widget de highlight des PatternShape n'est pas accessible).
	# Ajoute a WorldUI : meme espace que la box de selection de DD, donc aligne
	# avec les GlobalRect.
	_pattern_box_node = Node2D.new()
	_pattern_box_node.name = "PathFixPatternBox"
	var s = GDScript.new()
	s.source_code = "extends Node2D\nvar rect = null\nfunc _draw() -> void:\n\tif rect == null:\n\t\treturn\n\tvar col = Color(0.93, 1.0, 0.0, 0.6)\n\tvar step = 16.0\n\tvar dot = 5.0\n\tvar p = rect.position\n\tvar sz = rect.size\n\tvar x = p.x\n\twhile x <= p.x + sz.x:\n\t\tdraw_circle(Vector2(x, p.y), dot, col)\n\t\tdraw_circle(Vector2(x, p.y + sz.y), dot, col)\n\t\tx += step\n\tvar y = p.y\n\twhile y <= p.y + sz.y:\n\t\tdraw_circle(Vector2(p.x, y), dot, col)\n\t\tdraw_circle(Vector2(p.x + sz.x, y), dot, col)\n\t\ty += step\n"
	s.reload()
	_pattern_box_node.set_script(s)
	_pattern_box_node.set("z_as_relative", false)
	_pattern_box_node.z_index = 998
	var ui = _g.get("WorldUI")
	if ui != null and is_instance_valid(ui):
		ui.call_deferred("add_child", _pattern_box_node)
	elif _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _pattern_box_node)


# === SNAPPY MOD DETECTION ===

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
			print("[PathFix] Found Snappy via Global.API")
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
						print("[PathFix] Found Snappy via Toolbar '" + str(key) + "'")
						return found

	print("[PathFix] Snappy mod not found - using DD vanilla snap")
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


# === SNAP ===

func _get_snapped_position(pos: Vector2) -> Vector2:
	if not _g.Editor.IsSnapping:
		return pos

	var snappy = _get_snappy_mod()
	if snappy and snappy.has_method("get_snapped_position") and snappy.get("custom_snap_enabled"):
		return snappy.get_snapped_position(pos)

	var world_ui = _g.WorldUI
	if world_ui and world_ui.has_method("GetSnappedPosition"):
		return world_ui.GetSnappedPosition(pos)

	var cell_size = world_ui.CellSize
	if cell_size is Vector2:
		var snap = cell_size.x * 0.5
		if world_ui.get("UseHalfSnap"):
			snap = snap * 0.5
		return Vector2(stepify(pos.x, snap), stepify(pos.y, snap))
	return pos


# === DEFERRED RESELECT ===

func _do_deferred_reselect() -> void:
	var child = _pending_reselect
	_pending_reselect = null
	if child == null or not is_instance_valid(child):
		return

	# Only re-select if DD actually deselected
	var needs_select = true
	var cur_raw = select_tool.RawSelectables
	if cur_raw:
		for s in cur_raw:
			if s == null or not is_instance_valid(s):
				continue
			var t = s.get("Thing")
			if t != null and is_instance_valid(t) and t == child:
				needs_select = false
				break
	if needs_select:
		_normalize_pathway_position(child)
		select_tool.SelectThing(child, true)
		select_tool.EnableTransformBox(true)
		input_listener.call_deferred("_deferred_panel_notify")
	# Set up our drag — use CURRENT position, not stale
	_flat_line = child
	_is_flat_selected = _check_if_flat(child)
	_mouse_was_pressed = true
	_at_extremity = false
	_dd_was_rotating = false
	_hijacking = false
	_hijack_mode = 0
	_force_drag_ready = true
	_drag_start = _pending_drag_start
	_drag_origin = child.global_position
	select_tool.SavePreTransforms()


# === INPUT ===

# Vrai tant qu'un ColorPicker Godot est ouvert (popup visible) — couvre la
# pioche du picker natif DD comme celle des mods tiers (Colour and Modify
# Things). Un ColorPicker n'est visible_in_tree que lorsque son popup est
# ouvert, donc on ne touche pas a la selection pendant ce temps.
func _is_color_picking() -> bool:
	if input_listener == null or not is_instance_valid(input_listener):
		return false
	var tree = input_listener.get_tree()
	if tree == null or tree.root == null:
		return false
	# Un ColorPicker n'est visible que dans un popup ouvert. Si aucun popup n'est
	# visible (cas courant a chaque frame), on evite de parcourir tout l'arbre UI
	# -> sortie immediate. ui_util met ce test en cache par frame (partage entre
	# tous les appelants), donc c'est quasi gratuit.
	if ui_util != null and ui_util.has_method("_cached_has_visible_popup"):
		if not ui_util._cached_has_visible_popup(tree):
			return false
	return _find_visible_colorpicker(tree.root)


func _find_visible_colorpicker(node) -> bool:
	if node is ColorPicker and node.is_visible_in_tree():
		return true
	for child in node.get_children():
		# Elague la branche Node2D (carte/objets) : aucun ColorPicker n'y vit
		# et elle peut etre enorme.
		if child is Node2D:
			continue
		if _find_visible_colorpicker(child):
			return true
	return false


func _on_input(event) -> void:
	# Track left button for drag detection (before any early returns)
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_left_pressed = true
			_drag_threshold_passed = false
			_left_press_pos = event.position
		else:
			# Override "selection a travers un trou" differe : si le geste etait un
			# CLIC (aucun drag) dans le corps d'une box selectionnee, on selectionne
			# maintenant l'asset du dessous. Si un DRAG a eu lieu, on ne touche a
			# rien -> DD a deplace l'asset selectionne (comportement voulu).
			if _pending_overlay_pat != null:
				var pend = _pending_overlay_pat
				_pending_overlay_pat = null
				if not _drag_threshold_passed and is_instance_valid(pend):
					_pending_overlay_sel = pend
					input_listener.call_deferred("_deferred_overlay_select")
			# Idem pour un path clique dans le corps d'une box : selection au release
			# seulement si clic (pas de drag).
			if _pending_overlay_path != null:
				var pend_p = _pending_overlay_path
				_pending_overlay_path = null
				if not _drag_threshold_passed and is_instance_valid(pend_p):
					_pending_overlay_path_sel = pend_p
					input_listener.call_deferred("_deferred_overlay_path_select")
			_left_pressed = false
			_drag_threshold_passed = false
	if event is InputEventMouseMotion and _left_pressed and not _drag_threshold_passed:
		if event.position.distance_to(_left_press_pos) > 4:
			_drag_threshold_passed = true

	# On left click, try to force-select a path
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		if _is_select_tool_active() and not ui_util.is_mouse_over_ui(input_listener):
			# Poignee de redim/rotation de la box : toujours laisser DD transformer,
			# ne jamais hijacker au profit d'une selection a travers un trou.
			if _transform_box_on_handle():
				pass
			# Pattern ajoure au-dessus d'un autre pattern : selectionner celui que
			# l'overlay montre a travers le trou, AVANT que DD ne demarre un Move sur
			# le pattern du dessus s'il est deja selectionne. _select_overlay_pattern
			# s'auto-annule si le pattern survole est deja selectionne (vrai Move).
			elif _select_overlay_pattern():
				pass
			# Path clique dans le corps de la box d'un autre asset selectionne :
			# differe la selection au release (clic vs drag) au lieu de laisser DD
			# deplacer l'asset selectionne.
			elif _select_overlay_path():
				pass
			# DD a deja calcule son transformMode sur ce press (son _Input passe
			# avant notre listener) : si != None, il va transformer l'asset
			# selectionne (move/rotate/resize) -> ne pas detecter le path.
			# Les methodes de la box servent de repli si l'ordre des handlers varie.
			elif _dd_transform_mode() != 0 or _transform_box_wants_cursor():
				pass
			# Sur le trace central, DD pointe le path (priorite path > pattern).
			# Si un pattern est au-dessus, on selectionne le pattern a la place.
			elif _select_pattern_over_path():
				pass
			elif not _is_path_covered() and not _is_color_picking():
				_try_force_select()

	# Free Transform actif → laisser FT gérer les drags, ne pas hijacker
	if _g.ModMapData.get("_free_transform_active", false):
		_hijacking = false
		_hijack_mode = 0
		_mouse_was_pressed = false
		_force_drag_ready = false
		_at_extremity = false
		_dd_was_rotating = false
		_left_pressed = false
		_drag_threshold_passed = false
		return

	# Multi-selection: let DD handle everything
	var raw_check = select_tool.RawSelectables
	if raw_check != null and raw_check.size() > 1:
		return

	# Only handle flat path hijack when single path selected AND it's flat
	if not _is_flat_selected:
		if not _force_drag_ready:
			return

	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			if not _force_drag_ready:
				_mouse_was_pressed = true
				# Rotation seulement si on est a l'extremite ET pas sur un pixel du path
				var on_pixel = overlay_tool != null and is_instance_valid(overlay_tool) and overlay_tool._hover_path != null
				_at_extremity = _is_flat_selected and _is_mouse_near_extremity() and not on_pixel
				_dd_was_rotating = false
		else:
			_mouse_was_pressed = false
			_force_drag_ready = false
			var was_rotating = _at_extremity or _dd_was_rotating or _hijack_mode == 2
			var was_hijacking = _hijacking
			_at_extremity = false
			_dd_was_rotating = false
			if _hijacking:
				_hijacking = false
				_hijack_mode = 0
				_reset_cursor()
				_reselect_on_empty = false
				# Re-select if DD cleared selection during drag
				var end_raw = select_tool.RawSelectables
				if (end_raw == null or end_raw.size() == 0) and _flat_line and is_instance_valid(_flat_line):
					select_tool.SelectThing(_flat_line, true)
				select_tool.RecordTransforms()
				select_tool.EnableTransformBox(false)
				select_tool.EnableTransformBox(true)
			# Fix rotation after any rotate operation
			if was_rotating:
				_fix_near_exact_rotations()
			# Ne notifier le panneau (= le reconstruire via OnSelect) que si une
			# transformation a vraiment eu lieu. Sinon un simple clic sur un widget
			# du panneau de gauche (ex: dropdown de layer) reconstruit le panneau et
			# referme le popup immediatement.
			if (was_hijacking or was_rotating) and _flat_line and is_instance_valid(_flat_line):
				input_listener.call_deferred("_deferred_panel_notify")

	if event is InputEventMouseMotion and (_mouse_was_pressed or _force_drag_ready):
		var mode = select_tool.get("transformMode")

		if not _hijacking:
			if _force_drag_ready:
				if mode != null and mode != 0:
					_force_drag_ready = false
					if mode != 1 and _is_flat_selected:
						_hijacking = true
						_hijack_mode = 1
						_drag_start = _g.WorldUI.MousePosition
						_drag_origin = _flat_line.global_position
						select_tool.SavePreTransforms()
						select_tool.EnableTransformBox(false)
						_set_drag_cursor()
				else:
					var drag_dist = (_g.WorldUI.MousePosition - _drag_start).length()
					if drag_dist > 5:
						_hijacking = true
						_hijack_mode = 1
						_force_drag_ready = false
						select_tool.EnableTransformBox(false)
						_set_drag_cursor()
			elif _is_flat_selected and mode != null and mode != 0:
				if mode == 1:
					# DD set Move mode - let DD handle it natively
					pass
				elif _at_extremity:
					# Rotate/Scale at extremity - let DD handle, track for takeover
					_dd_was_rotating = true
				else:
					# Rotate/Scale in middle - hijack as Move
					_hijacking = true
					_hijack_mode = 1
					_drag_start = _g.WorldUI.MousePosition
					_drag_origin = _flat_line.global_position
					select_tool.SavePreTransforms()
					select_tool.EnableTransformBox(false)
					_set_drag_cursor()
			elif _dd_was_rotating and (mode == null or mode == 0):
				# DD just dropped the transform! Take over rotation seamlessly
				_hijacking = true
				_hijack_mode = 2
				_rotate_center = _get_path_center_world()
				var mouse = _g.WorldUI.MousePosition
				_rotate_last_angle = (mouse - _rotate_center).angle()
				# Don't call SavePreTransforms - DD already started, transforms are tracked

		if _hijacking:
			if _hijack_mode == 1:
				_do_move()
				_set_drag_cursor()
			elif _hijack_mode == 2:
				_do_rotate()
				_set_rotate_cursor()
			input_listener.get_tree().set_input_as_handled()


func _get_path_center_world() -> Vector2:
	var gr = _flat_line.get("GlobalRect")
	if gr and gr is Rect2 and gr.size.length() > 0.1:
		return gr.position + gr.size * 0.5
	return _flat_line.global_position


func _do_move() -> void:
	var current_mouse = _g.WorldUI.MousePosition
	var target = _drag_origin + (current_mouse - _drag_start)

	if _g.Editor.IsSnapping:
		target = _get_snapped_position(target)

	if not _flat_line or not is_instance_valid(_flat_line):
		return

	var actual_delta = target - _flat_line.global_position
	if actual_delta.length() < 0.01:
		return

	var raw = select_tool.RawSelectables
	if raw and raw.size() > 0:
		for s in raw:
			if s == null or not is_instance_valid(s):
				continue
			var thing = s.get("Thing")
			if thing != null and is_instance_valid(thing) and thing is Node2D:
				thing.position += actual_delta
	else:
		# DD cleared selection — move directly
		_flat_line.position += actual_delta


func _do_rotate() -> void:
	var current_mouse = _g.WorldUI.MousePosition
	var current_angle = (current_mouse - _rotate_center).angle()
	var delta_angle = current_angle - _rotate_last_angle

	# Avoid jumps at ±PI boundary
	if delta_angle > PI:
		delta_angle -= TAU
	elif delta_angle < -PI:
		delta_angle += TAU

	if abs(delta_angle) > 0.001:
		# Rotate all selectables around center - don't touch transform box
		var raw = select_tool.RawSelectables
		if raw:
			for s in raw:
				if s == null or not is_instance_valid(s):
					continue
				var thing = s.get("Thing")
				if thing != null and is_instance_valid(thing) and thing is Node2D:
					var offset = thing.global_position - _rotate_center
					thing.global_position = _rotate_center + offset.rotated(delta_angle)
					thing.rotation += delta_angle
		_rotate_last_angle = current_angle


func _is_mouse_near_extremity() -> bool:
	if _flat_line == null:
		return false
	var mouse_world = _g.WorldUI.MousePosition
	var local_pos = _flat_line.get_global_transform().affine_inverse().xform(mouse_world)
	var pts = _flat_line.points
	if pts.size() < 2:
		return false
	var start_pt = pts[0]
	var end_pt = pts[pts.size() - 1]
	var path_length = (end_pt - start_pt).length()
	var zone_size = 200.0
	var dist_to_start = (local_pos - start_pt).length()
	var dist_to_end = (local_pos - end_pt).length()
	return dist_to_start < zone_size or dist_to_end < zone_size


# === FORCE SELECT ===

func _is_object_under_mouse() -> bool:
	# NOTE: select_tool.Selectables (C# property) calls ToDictionary() internally,
	# which throws "An item with the same key has already been added" when a drag box
	# selects a prefab whose nodes appear more than once in RawSelectables.
	# Using RawSelectables directly avoids the crash entirely.
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return false
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing != null and is_instance_valid(thing) and not (thing is Line2D):
			return true
	return false


# Memo des scans de couverture (chacun parcourt toute la scene en pixel-perfect
# / IsMouseWithin). Cle : position souris + instance ciblee. Tant que la souris
# ne bouge pas, le resultat ne peut pas changer (scene statique pendant le
# survol) -> aucun rescann. Ces fonctions sont aussi appelees plusieurs fois par
# frame (path_fix + overlay_tool) : le memo collapse ces appels en un seul scan.
var _wcov_mouse := Vector2.INF
var _wcov_id := 0
var _wcov_val := false
var _pcov_mouse := Vector2.INF
var _pcov_id := 0
var _pcov_val := false


func _aabb_miss(node, mouse_world: Vector2, margin: float) -> bool:
	# Vrai uniquement si on peut PROUVER que le curseur est hors de la bbox
	# monde (+ marge) -> on saute le test exact (IsMouseWithin / is_pixel_opaque).
	# Si pas de GlobalRect fiable, on ne culle pas (resultat inchange).
	var r = node.get("GlobalRect")
	if r is Rect2 and (r.size.x > 0.0 or r.size.y > 0.0):
		return not r.grow(margin).has_point(mouse_world)
	return false


func _is_path_covered(path = null) -> bool:
	if path == null and overlay_tool != null and is_instance_valid(overlay_tool):
		path = overlay_tool._hover_path
	if path == null or not is_instance_valid(path) or not (path is CanvasItem):
		return false
	var mouse_world = _g.WorldUI.MousePosition
	var pid = path.get_instance_id()
	if _pcov_mouse == mouse_world and _pcov_id == pid:
		return _pcov_val
	_pcov_mouse = mouse_world
	_pcov_id = pid
	_pcov_val = _compute_path_covered(path, mouse_world)
	return _pcov_val


func _compute_path_covered(path, mouse_world: Vector2) -> bool:
	# Detection fidele a SelectTool.HighlightThingAtPoint (source DD) :
	#  - objects : test PIXEL-PERFECT (Sprite.is_pixel_opaque), pas la bbox
	#    (la bbox sur-detectait et masquait l'overlay un peu partout) ;
	#  - patterns : imbriques sous PatternShapes.Layers[key] ;
	#  - lights : via light.GetWidget().IsMouseWithin() (toujours au sommet) ;
	#  - roofs/portals : IsMouseWithin() ; walls : IsMouseWithin(mousePos).
	# Au-dessus/en-dessous : calque (= z_index, cf. prop.ZIndex = ActiveLayer)
	# puis rang de type a calque egal. Un element ne couvre que s'il est au-dessus.
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return false
	var pz = _effective_z(path)

	# Lights (toujours rendues au sommet) : GetWidget() n'est pas accessible
	# depuis GDScript -> detection par proximite de l'icone (petit rayon).
	var lights = level.get("Lights")
	if lights != null:
		for light in lights.get_children():
			if light == null or not is_instance_valid(light):
				continue
			if light.get("global_position") == null:
				continue
			if mouse_world.distance_to(light.global_position) <= 32.0:
				return true

	# Roofs
	var roofs = level.get("Roofs")
	if roofs != null:
		for roof in roofs.get_children():
			if roof == null or not is_instance_valid(roof) or not (roof is CanvasItem):
				continue
			if roof.has_method("IsMouseWithin") and roof.IsMouseWithin() and _is_above_z(roof, 8, pz):
				return true

	# Portals libres
	var portals = level.get("Portals")
	if portals != null:
		for portal in portals.get_children():
			if portal == null or not is_instance_valid(portal) or not (portal is CanvasItem):
				continue
			if portal.has_method("IsMouseWithin") and portal.IsMouseWithin() and _is_above_z(portal, 2, pz):
				return true

	# Objects : PIXEL-PERFECT
	var objs = level.get("Objects")
	if objs != null:
		for child in objs.get_children():
			if child == null or not is_instance_valid(child) or child == path:
				continue
			if _aabb_miss(child, mouse_world, 8.0):
				continue
			var spr = child.get("Sprite")
			if spr == null or not is_instance_valid(spr) or not spr.has_method("is_pixel_opaque"):
				continue
			if spr.is_pixel_opaque(spr.to_local(mouse_world)) and _is_above_z(child, 4, pz):
				return true

	# Walls
	var walls = level.get("Walls")
	if walls != null:
		for wall in walls.get_children():
			if wall == null or not is_instance_valid(wall) or not (wall is CanvasItem):
				continue
			if overlay_tool != null and is_instance_valid(overlay_tool) \
			and overlay_tool.has_method("_wall_aabb_miss") \
			and overlay_tool._wall_aabb_miss(wall, mouse_world, 96.0):
				continue
			if wall.has_method("IsMouseWithin") and wall.IsMouseWithin(mouse_world) and _is_above_z(wall, 1, pz):
				return true

	# PatternShapes : imbriques (PatternShapes.Layers[key] non accessible depuis
	# GDScript) -> on descend recursivement et on lit le calque via GetLayer().
	var ps = level.get("PatternShapes")
	if ps != null and _scan_patterns(ps, pz, 0):
		return true
	return false


func _is_wall_covered(wall) -> bool:
	if wall == null or not is_instance_valid(wall) or not (wall is CanvasItem):
		return false
	var mouse_world = _g.WorldUI.MousePosition
	var wid = wall.get_instance_id()
	if _wcov_mouse == mouse_world and _wcov_id == wid:
		return _wcov_val
	_wcov_mouse = mouse_world
	_wcov_id = wid
	_wcov_val = _compute_wall_covered(wall, mouse_world)
	return _wcov_val


func _compute_wall_covered(wall, mouse_world: Vector2) -> bool:
	# Equivalent de _compute_path_covered mais pour un wall : un asset ne le
	# couvre que s'il est rendu AU-DESSUS (calque dominant, puis rang de type a
	# calque egal, le rang du Wall etant 3). Sert a wall_move pour ne pas
	# force-select un wall quand un objet/light/portal/roof/pattern est devant.
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return false
	var wz = _effective_z(wall)
	var wall_rank = 3  # rang visuel du Wall

	# Lights (toujours au sommet)
	var lights = level.get("Lights")
	if lights != null:
		for light in lights.get_children():
			if light == null or not is_instance_valid(light):
				continue
			if light.get("global_position") == null:
				continue
			if mouse_world.distance_to(light.global_position) <= 32.0:
				return true

	# Roofs
	var roofs = level.get("Roofs")
	if roofs != null:
		for roof in roofs.get_children():
			if roof == null or not is_instance_valid(roof) or not (roof is CanvasItem):
				continue
			if roof.has_method("IsMouseWithin") and roof.IsMouseWithin() and _is_above_z(roof, 8, wz, wall_rank):
				return true

	# Portals libres
	var portals = level.get("Portals")
	if portals != null:
		for portal in portals.get_children():
			if portal == null or not is_instance_valid(portal) or not (portal is CanvasItem):
				continue
			if portal.has_method("IsMouseWithin") and portal.IsMouseWithin() and _is_above_z(portal, 2, wz, wall_rank):
				return true

	# Objects : PIXEL-PERFECT
	var objs = level.get("Objects")
	if objs != null:
		for child in objs.get_children():
			if child == null or not is_instance_valid(child):
				continue
			if _aabb_miss(child, mouse_world, 8.0):
				continue
			var spr = child.get("Sprite")
			if spr == null or not is_instance_valid(spr) or not spr.has_method("is_pixel_opaque"):
				continue
			if spr.is_pixel_opaque(spr.to_local(mouse_world)) and _is_above_z(child, 4, wz, wall_rank):
				return true

	# Autres walls au-dessus (calque dominant ; meme calque ne couvre pas)
	var walls = level.get("Walls")
	if walls != null:
		for w in walls.get_children():
			if w == null or not is_instance_valid(w) or w == wall or not (w is CanvasItem):
				continue
			if overlay_tool != null and is_instance_valid(overlay_tool) \
			and overlay_tool.has_method("_wall_aabb_miss") \
			and overlay_tool._wall_aabb_miss(w, mouse_world, 96.0):
				continue
			if w.has_method("IsMouseWithin") and w.IsMouseWithin(mouse_world) and _is_above_z(w, 1, wz, wall_rank):
				return true

	# Pathways : hit-test fiable via overlay_tool. Le wall est rendu au-dessus
	# des paths a calque egal -> un path ne couvre que sur un calque superieur.
	if overlay_tool != null and is_instance_valid(overlay_tool) \
	and overlay_tool.has_method("_is_mouse_on_path"):
		var pathways = level.get("Pathways")
		if pathways != null:
			for line in pathways.get_children():
				if line == null or not is_instance_valid(line) or not (line is Line2D):
					continue
				if _aabb_miss(line, mouse_world, 64.0):
					continue
				if overlay_tool._is_mouse_on_path(line, mouse_world) and _is_above_z(line, 5, wz, wall_rank):
					return true

	# PatternShapes (calque dominant uniquement, rang < Wall)
	var ps2 = level.get("PatternShapes")
	if ps2 != null and _scan_patterns(ps2, wz, 0, wall_rank):
		return true
	return false


# Vrai si le pattern compte comme COUVRANT le point souris : il faut que son
# rendu y soit opaque. Un pattern ajoure (grille...) transparent sous le curseur
# ne couvre donc plus le wall/path dessous. Delegue a overlay_tool._pattern_solid_at
# (echantillonnage fidele au shader Pattern.shader de DD : texture via l'uniform
# albedo + rotation autour de 0.5). Repli "couvre" si overlay_tool indisponible
# (aucune regression vs l'ancien comportement purement geometrique).
func _pattern_opaque_here(shape, mouse_world) -> bool:
	if overlay_tool != null and is_instance_valid(overlay_tool) \
	and overlay_tool.has_method("_pattern_solid_at"):
		return overlay_tool._pattern_solid_at(shape, mouse_world)
	return true


func _scan_patterns(node, pz: int, depth: int, self_rank: int = 2) -> bool:
	if depth > 5:
		return false
	var mouse_world = _g.WorldUI.MousePosition
	for child in node.get_children():
		if child == null or not is_instance_valid(child):
			continue
		if child is Polygon2D and child.has_method("IsMouseWithin") \
		and not _aabb_miss(child, mouse_world, 4.0) and child.IsMouseWithin() \
		and _pattern_opaque_here(child, mouse_world):
			var cl = child.GetLayer() if child.has_method("GetLayer") else _effective_z(child)
			if _covers_layer(int(cl), 7, pz, self_rank):
				return true
		elif child.get_child_count() > 0:
			if _scan_patterns(child, pz, depth + 1, self_rank):
				return true
	return false


func _is_above_z(node, type_code: int, pz: int, self_rank: int = 2) -> bool:
	return _covers_layer(_effective_z(node), type_code, pz, self_rank)


func _covers_layer(node_layer: int, type_code: int, pz: int, self_rank: int = 2) -> bool:
	# Calque dominant, puis rang de type a calque egal.
	if node_layer != pz:
		return node_layer > pz
	return _type_rank(type_code) > self_rank  # self_rank = rang de l'element teste


func _type_rank(t: int) -> int:
	# SelectableType : Wall1 PortalFree2 PortalWall3 Object4 Pathway5 Light6
	# PatternShape7 Roof8. Rang visuel (haut->bas) : Light Roof Portal Object
	# Wall Path Pattern.
	match t:
		6: return 7  # Light
		8: return 6  # Roof
		2, 3: return 5  # Portal
		4: return 4  # Object
		1: return 3  # Wall
		5: return 2  # Pathway
		7: return 1  # PatternShape
	return 0


func _fix_dd_highlight() -> void:
	# Corrige le highlight que DD pose au survol :
	#  - path devant un asset : DD surligne l'asset du dessous (il ne voit pas
	#    le flat path) -> on le masque ;
	#  - path couvert par un pattern : sur le trace central DD surligne le path
	#    (priorite path > pattern). On masque le trace et on surligne nous-meme
	#    le pattern (DD ne le touche pas, son highlighted reste le path) ;
	#  - path couvert par un asset legitime au-dessus (object, etc.) : DD le
	#    surligne correctement -> on NE touche PAS.
	# Defensif : si highlighted n'est pas lisible, no-op.
	# Si l'overlay du wall est actif sous le curseur, le wall est rendu au-dessus :
	# aucun highlight de path/pattern ici (gere par _fix_dd_wall_highlight).
	if overlay_tool != null and is_instance_valid(overlay_tool) \
	and overlay_tool.has_method("_effective_walls") and overlay_tool._effective_walls() \
	and overlay_tool._hover_wall != null and is_instance_valid(overlay_tool._hover_wall):
		_clear_pattern_highlight()
		_unforce_path_widget()
		return
	if _hovered_path == null or not is_instance_valid(_hovered_path):
		_clear_pattern_highlight()
		_unforce_path_widget()
		return
	var hl = select_tool.get("highlighted")
	if hl == null or not is_instance_valid(hl):
		_clear_pattern_highlight()
		_unforce_path_widget()
		return
	var t = hl.get("Thing")
	if t == null or not is_instance_valid(t):
		_clear_pattern_highlight()
		_unforce_path_widget()
		return
	var tp = hl.get("Type")
	var covered = _is_path_covered(_hovered_path)
	if tp == 5:
		_unforce_path_widget()
		if not covered:
			_clear_pattern_highlight()
			return  # path reellement au-dessus -> highlight legitime, on garde
		# Path couvert : sur le trace central c'est forcement par un pattern (un
		# type prioritaire aurait ete surligne a la place du path).
		_do_dehighlight(t, 5)  # masquer le trace central
		_set_pattern_highlight(_topmost_pattern_above(_hovered_path))
	else:
		_clear_pattern_highlight()
		if not covered:
			# DD a surligne un non-path sous le path (path devant) -> masquer.
			# _do_dehighlight passe par le widget de l'asset ; or un PatternShape
			# n'a ni Highlight() propre ni widget, donc son highlight natif
			# persisterait sous le path. On utilise SelectTool.Highlight(Selectable,
			# false) qui de-surligne tous les types (cf. _fix_dd_wall_highlight).
			if tp == 7 and select_tool.has_method("Highlight"):
				select_tool.call_deferred("Highlight", hl, false)
			else:
				_do_dehighlight(t, tp)
			# DD a surligne l'asset du dessous, jamais le path -> celui-ci n'a aucun
			# widget. Si l'overlay des paths est actif, c'est lui qui montre le
			# survol ; sinon on affiche nous-memes le widget natif du path (sans
			# quoi un path devant un objet n'a aucun indicateur en mode overlay OFF).
			if _paths_overlay_active():
				_unforce_path_widget()
			else:
				_force_path_widget(_hovered_path)
		else:
			_unforce_path_widget()


# Pattern actuellement surligne par nous (le highlight de DD ne le touche pas).
var _hl_pattern = null
var _pattern_box_node = null
# Widget de path qu'on force a afficher quand le path est devant un asset (DD a
# surligne l'asset, pas le path). DD ne le rallumera pas -> on le suit pour
# l'eteindre nous-memes.
var _forced_path_widget = null


func _set_pattern_highlight(pat) -> void:
	if pat == _hl_pattern:
		return
	_hl_pattern = pat
	if _pattern_box_node == null or not is_instance_valid(_pattern_box_node):
		return
	if pat != null and is_instance_valid(pat) and pat.get("GlobalRect") != null:
		_pattern_box_node.rect = pat.GlobalRect
	else:
		_pattern_box_node.rect = null
	_pattern_box_node.update()


func _clear_pattern_highlight() -> void:
	_hl_pattern = null
	if _pattern_box_node != null and is_instance_valid(_pattern_box_node):
		if _pattern_box_node.rect != null:
			_pattern_box_node.rect = null
			_pattern_box_node.update()


func _fix_dd_wall_highlight() -> void:
	# Quand un wall est survole (overlay affiche) et qu'il n'est PAS couvert par
	# un asset au-dessus, DD peut quand meme poser son highlight natif sur un
	# element situe EN DESSOUS du wall (path / pattern / calque inferieur) parce
	# que la zone de survol de l'overlay est plus large que le hit-test de DD.
	# On masque ce highlight parasite. Si DD surligne le wall lui-meme, on garde.
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return
	if overlay_tool.has_method("_effective_walls") and not overlay_tool._effective_walls():
		return
	var wall = overlay_tool._hover_wall
	if wall == null or not is_instance_valid(wall):
		return
	if _is_wall_covered(wall):
		return
	var hl = select_tool.get("highlighted")
	if hl == null or not is_instance_valid(hl):
		return
	var t = hl.get("Thing")
	if t == null or not is_instance_valid(t) or t == wall:
		return
	# API officielle : SelectTool.Highlight(Selectable, false) dé-surligne
	# n'importe quel type (y compris PatternShape, qui n'a pas de Highlight()
	# propre ni de widget). En call_deferred pour passer APRES le
	# HighlightThingAtPoint() que DD execute dans la frame.
	if select_tool.has_method("Highlight"):
		select_tool.call_deferred("Highlight", hl, false)


func _suppress_covered_wall_highlight() -> void:
	# Si DD surligne nativement un wall alors qu'un path ou un pattern (ou tout
	# asset) est rendu AU-DESSUS de lui sous le curseur, masquer ce highlight de
	# wall. Cas typique : un path plat est indetectable par DD, qui pioche alors
	# le wall en dessous et le surligne a tort. Symetrique de _fix_dd_wall_highlight.
	var hl = select_tool.get("highlighted")
	if hl == null or not is_instance_valid(hl):
		return
	if hl.get("Type") != 1:  # seulement un Wall surligne
		return
	var w = hl.get("Thing")
	if w == null or not is_instance_valid(w):
		return
	if not _is_wall_covered(w):
		return
	if select_tool.has_method("Highlight"):
		select_tool.call_deferred("Highlight", hl, false)
	# Le wall est couvert. Si c'est par un PATH, l'overlay des paths l'affiche
	# deja (rien a faire). Sinon, si un pattern est rendu au-dessus, recreer sa
	# hover box nous-memes : DD ne la montre pas (il surligne le wall a la place),
	# exactement comme pour les paths couverts par un pattern.
	var path_on_top = overlay_tool != null and is_instance_valid(overlay_tool) \
		and overlay_tool._hover_path != null and is_instance_valid(overlay_tool._hover_path)
	if path_on_top:
		return
	var pat = _topmost_pattern_above(w)
	if pat != null:
		_set_pattern_highlight(pat)


func _do_dehighlight(t, tp) -> void:
	# Highlight(false) selon le type (cf. source SelectTool.Highlight), en
	# call_deferred pour passer apres le highlight pose par DD dans la frame.
	if tp == 4 or tp == 2 or tp == 3 or tp == 8:  # Object / Portal / Roof
		if t.has_method("Highlight"):
			t.call_deferred("Highlight", false)
		return
	# Wall(1) / Light(6) / Pattern(7) / Pathway(5) : via widget
	var w = null
	if t.has_method("GetWidget"):
		w = t.GetWidget()
	elif t.get("Widget") != null:
		w = t.get("Widget")
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		w.call_deferred("Highlight", false)


func _paths_overlay_active() -> bool:
	return overlay_tool != null and is_instance_valid(overlay_tool) \
		and overlay_tool.has_method("_effective_paths") and overlay_tool._effective_paths()


func _path_widget(path):
	if path == null or not is_instance_valid(path):
		return null
	if path.has_method("GetWidget"):
		var gw = path.GetWidget()
		if gw != null and is_instance_valid(gw):
			return gw
	if path.get("Widget") != null:
		return path.get("Widget")
	# Fallback : 1er enfant Line2D exposant Highlight() (le PathwayWidget).
	for c in path.get_children():
		if c is Line2D and c.has_method("Highlight"):
			return c
	return null


# Affiche le widget natif d'un path devant un asset (idempotent : ne (re)Highlight
# que sur changement de cible -> rien ne l'eteint entre-temps en mode overlay OFF).
func _force_path_widget(path) -> void:
	var w = _path_widget(path)
	if w == null or not is_instance_valid(w) or not w.has_method("Highlight"):
		return
	if _forced_path_widget == w:
		return
	if _forced_path_widget != null and is_instance_valid(_forced_path_widget) \
	and _forced_path_widget.has_method("Highlight"):
		_forced_path_widget.call_deferred("Highlight", false)
	_forced_path_widget = w
	w.call_deferred("Highlight", true)


func _unforce_path_widget() -> void:
	if _forced_path_widget != null and is_instance_valid(_forced_path_widget) \
	and _forced_path_widget.has_method("Highlight"):
		_forced_path_widget.call_deferred("Highlight", false)
	_forced_path_widget = null



func _select_overlay_pattern() -> bool:
	# Au clic : DD selectionne le pattern le plus haut sous le curseur via son
	# IsMouseWithin geometrique (sans alpha). Quand un pattern ajoure (grille...)
	# est au-dessus, l'overlay surligne deja le pattern visible DESSOUS via son
	# trou : on force la selection de ce pattern-la plutot que celui du dessus.
	# Renvoie vrai si gere (au press) -- l'application peut etre differee au release.
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return false
	var pat = overlay_tool._hover_pattern
	if pat == null or not is_instance_valid(pat):
		return false
	if not select_tool.has_method("SelectThing"):
		return false
	# Ne PAS intervenir si l'overlay surligne un pattern DEJA selectionne : c'est
	# un deplacement/redim normal de ce pattern (curseur sur sa partie pleine),
	# pas une selection a travers un trou.
	if _is_thing_selected(pat):
		return false
	# Si le press tombe dans le CORPS de la box d'un asset selectionne, un drag de
	# cet asset est possible : on NE selectionne PAS au press (sinon on vole le
	# drag). On memorise le pattern et on tranchera au release : selection
	# seulement si c'etait un clic (aucun drag). DD arme son Move normalement.
	if _box_move_zone():
		_pending_overlay_pat = pat
		return true
	# Aucun asset deplaçable sous le curseur -> selection immediate (clic simple).
	_apply_overlay_pattern_selection(pat)
	return true


# Vrai si un Thing (noeud) est dans la selection courante.
func _is_thing_selected(thing) -> bool:
	var sel = select_tool.get("Selected")
	if sel is Array:
		for s in sel:
			if s == null or not is_instance_valid(s):
				continue
			if s == thing or s.get("Thing") == thing:
				return true
	return false


# Vrai si le curseur est dans le CORPS de la box de selection (zone Move), ou un
# drag de l'asset selectionne demarrerait. Exclut coins/anneau (poignees).
func _box_move_zone() -> bool:
	var tbox = select_tool.get("transformBox")
	if tbox == null or not is_instance_valid(tbox) or not tbox.visible:
		return false
	return tbox.has_method("IsMouseInside") and tbox.IsMouseInside()


# Applique reellement la selection du pattern survole (DeselectAll + SelectThing).
func _apply_overlay_pattern_selection(pat) -> void:
	if pat == null or not is_instance_valid(pat):
		return
	if not Input.is_key_pressed(KEY_SHIFT):
		select_tool.DeselectAll()
	var made = select_tool.SelectThing(pat, true)
	if select_tool.has_method("EnableTransformBox"):
		select_tool.EnableTransformBox(true)
	input_listener.call_deferred("_deferred_panel_notify")
	# highlighted = notre pattern, pour que le _ContentInput de DD selectionne le
	# meme objet (Select(highlighted)) au lieu du pattern du dessus.
	if made != null:
		select_tool.set("highlighted", made)
	# Annule un eventuel Move arme par DD sur l'ancien asset (transformMode != None
	# -> son _ContentInput deplace au lieu de selectionner).
	if select_tool.get("transformMode") != null:
		select_tool.set("transformMode", 0)


# Differe (idle) : applique l'override apres que DD ait fini de traiter le release.
func _do_deferred_overlay_select() -> void:
	var pat = _pending_overlay_sel
	_pending_overlay_sel = null
	_apply_overlay_pattern_selection(pat)


# Clic sur un PATH situe dans le corps de la box de selection d'un AUTRE asset :
# DD deplacerait l'asset selectionne (transformMode = Move), donc _try_force_select
# n'est jamais atteint. On differe au release : selection du path seulement si clic
# (aucun drag), sinon on laisse DD deplacer l'asset selectionne. Renvoie vrai si
# pris en charge (defere). Hors zone Move, on renvoie faux -> _try_force_select
# gere normalement au press.
# Vrai si un path SELECTIONNABLE (sous le curseur et NON couvert) est survole.
# Signal pour transform_box_fix : dans ce cas, c'est path_fix qui gere la selection.
func _has_selectable_path_hover() -> bool:
	return overlay_tool != null and is_instance_valid(overlay_tool) \
	and overlay_tool._hover_path != null and is_instance_valid(overlay_tool._hover_path)


func _select_overlay_path() -> bool:
	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return false
	var p = overlay_tool._hover_path
	if p == null or not is_instance_valid(p):
		return false
	# Respecter le filtre Paths du SelectTool.
	var filter = select_tool.get("Filter")
	if filter is Dictionary and not bool(filter.get("Paths", true)):
		return false
	# Deja selectionne -> laisser DD/drag gerer.
	if _is_thing_selected(p):
		return false
	# Seulement si le press tombe dans le corps d'une box (drag possible) : sinon
	# _try_force_select s'en charge au press, plus reactif.
	if not _box_move_zone():
		return false
	_pending_overlay_path = p
	return true


# Differe (idle) : selectionne le path apres le release.
func _do_deferred_overlay_path_select() -> void:
	var p = _pending_overlay_path_sel
	_pending_overlay_path_sel = null
	_apply_path_selection(p)


func _select_pattern_over_path() -> bool:
	# Au clic : si DD pointe un path (trace central) avec un pattern au-dessus,
	# on selectionne le pattern via SelectThing (qui cree le Selectable du bon
	# type) au lieu de laisser DD selectionner le path. Renvoie vrai si gere.
	var hl = select_tool.get("highlighted")
	if hl == null or not is_instance_valid(hl):
		return false
	if hl.get("Type") != 5:  # pas un Pathway
		return false
	var p = hl.get("Thing")
	if p == null or not is_instance_valid(p):
		return false
	var pat = _topmost_pattern_above(p)
	if pat == null:
		return false
	if not select_tool.has_method("SelectThing"):
		return false
	if not Input.is_key_pressed(KEY_SHIFT):
		select_tool.DeselectAll()
	var sel = select_tool.SelectThing(pat, true)
	if select_tool.has_method("EnableTransformBox"):
		select_tool.EnableTransformBox(true)
	input_listener.call_deferred("_deferred_panel_notify")
	# highlighted = le pattern, pour que le _ContentInput de DD selectionne le
	# meme objet (Select(highlighted)) au lieu du path.
	if sel != null:
		select_tool.set("highlighted", sel)
	return true


func _topmost_pattern_above(path):
	# Renvoie le PatternShape (Polygon2D) le plus haut dessine au-dessus du path
	# sous le curseur, ou null.
	if path == null or not is_instance_valid(path) or not (path is CanvasItem):
		return null
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	var ps = level.get("PatternShapes")
	if ps == null:
		return null
	return _find_pattern_above(ps, _effective_z(path), 0)


func _find_pattern_above(node, pz, depth):
	if depth > 5:
		return null
	var mouse_world = _g.WorldUI.MousePosition
	var found = null
	for child in node.get_children():
		if child == null or not is_instance_valid(child):
			continue
		if child is Polygon2D and child.has_method("IsMouseWithin") and child.IsMouseWithin() \
		and _pattern_opaque_here(child, mouse_world):
			var cl = child.GetLayer() if child.has_method("GetLayer") else _effective_z(child)
			if _covers_layer(int(cl), 7, pz):
				found = child
		elif child.get_child_count() > 0:
			var f = _find_pattern_above(child, pz, depth + 1)
			if f != null:
				found = f
	return found


func _sprite_over(world_pos, node) -> bool:
	if node.get("texture") != null and node.texture != null:
		return _sprite_bounds(world_pos, node, node.texture)
	for c in node.get_children():
		if c.get("texture") != null and c.texture != null:
			if _sprite_bounds(world_pos, c, c.texture):
				return true
	if node.get("global_position") != null:
		return world_pos.distance_to(node.global_position) <= 96.0
	return false


func _sprite_bounds(world_pos, sprite_node, texture) -> bool:
	var lp = sprite_node.global_transform.affine_inverse().xform(world_pos)
	var ts = texture.get_size()
	var hx = ts.x / 2.0
	var hy = ts.y / 2.0
	if sprite_node.get("offset") != null:
		lp = lp - sprite_node.offset
	if sprite_node.get("centered") != null and not sprite_node.centered:
		lp.x = lp.x - hx
		lp.y = lp.y - hy
	return lp.x >= -hx and lp.x <= hx and lp.y >= -hy and lp.y <= hy


func _point_in_polygon(point, polygon) -> bool:
	var inside = false
	var j = polygon.size() - 1
	var i = 0
	while i < polygon.size():
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
		i += 1
	return inside


func _effective_z(ci) -> int:
	# z effectif d'un CanvasItem : somme des z_index le long de la chaine
	# parente tant que z_as_relative est vrai (modele DD : sous-conteneurs
	# z_as_relative=true qui heritent du z de la couche).
	var z = 0
	var n = ci
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z


func _draws_above(a, b) -> bool:
	# Depart en cas d'egalite de z : le noeud le plus tardif dans le parcours
	# de l'arbre dessine au-dessus. Compare via l'ancetre commun le plus bas.
	var chain_a = []
	var n = a
	while n != null:
		chain_a.append(n)
		n = n.get_parent()
	chain_a.invert()
	var chain_b = []
	n = b
	while n != null:
		chain_b.append(n)
		n = n.get_parent()
	chain_b.invert()
	var i = 0
	while i < chain_a.size() and i < chain_b.size() and chain_a[i] == chain_b[i]:
		i += 1
	if i == 0:
		return false  # pas d'ancetre commun (ne devrait pas arriver)
	if i >= chain_a.size():
		return false  # a ancetre de b -> b (enfant) au-dessus
	if i >= chain_b.size():
		return true   # b ancetre de a -> a au-dessus
	return chain_a[i].get_index() > chain_b[i].get_index()


func _check_if_flat(line: Line2D) -> bool:
	# Check GlobalRect first — this is what DD uses internally to decide
	# transform mode. If one dimension is small, DD will enter Rotate mode.
	#
	# Threshold is line.width * 0.5, NOT a fixed pixel value like 1.0.
	# A path can appear flat in world space even with non-zero local Y spread,
	# when the node rotation nearly cancels the angle of the local points
	# (e.g. local pts (0,0)→(1024,-384) + rotation 0.3557 rad → world direction
	# ≈ (1, -0.002), GlobalRect.size.y ≈ 2.5px — real but invisible to the user).
	# Using width*0.5 as threshold catches these near-flat paths correctly while
	# leaving genuinely diagonal paths (where size >> width) unaffected.
	var gr = line.get("GlobalRect")
	if gr != null and gr is Rect2:
		if gr.size.x < line.width * 0.5 or gr.size.y < line.width * 0.5:
			return true
	# Fallback: check actual point spread in local space
	var pts = line.points
	var min_y = INF
	var max_y = -INF
	var min_x = INF
	var max_x = -INF
	for p in pts:
		if p.x < min_x: min_x = p.x
		if p.x > max_x: max_x = p.x
		if p.y < min_y: min_y = p.y
		if p.y > max_y: max_y = p.y
	var height = max_y - min_y
	var width_span = max_x - min_x
	return height < line.width * 0.5 or width_span < line.width * 0.5


func _try_force_select() -> void:
	# Respecter le filter du SelectTool : si Paths est decoche, ne pas force-select
	var filter = select_tool.get("Filter")
	if filter is Dictionary and not bool(filter.get("Paths", true)):
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var pathways = level.get("Pathways")
	if pathways == null:
		return

	var mouse_world = _g.WorldUI.MousePosition

	if overlay_tool == null or not is_instance_valid(overlay_tool):
		return
	var child = overlay_tool._hover_path
	if child == null or not is_instance_valid(child):
		return

	# Si le path appartient à un groupe custom, laisser DD gérer la sélection groupée
	if child.has_meta("prefab_id"):
		var pid = child.get_meta("prefab_id")
		if pid is int and pid >= 10000:
			return

	var already_selected = false
	var cur_raw = select_tool.RawSelectables
	if cur_raw:
		for s in cur_raw:
			if s == null or not is_instance_valid(s):
				continue
			var t = s.get("Thing")
			if t != null and is_instance_valid(t) and t == child:
				already_selected = true
				break

	if already_selected:
		var dd_detects = child.has_method("IsMouseWithin") and child.IsMouseWithin(mouse_world)
		if dd_detects and not _check_if_flat(child):
			return
		if dd_detects and _check_if_flat(child):
			var is_extremity = false
			var local_pos = child.get_global_transform().affine_inverse().xform(mouse_world)
			var pts = child.points
			if pts.size() >= 2:
				var zone_size = 200.0
				is_extremity = (local_pos - pts[0]).length() < zone_size or (local_pos - pts[pts.size() - 1]).length() < zone_size
			if is_extremity:
				return
		_pending_reselect = child
		_pending_drag_start = mouse_world
		_pending_drag_origin = child.global_position
		input_listener.call_deferred("_deferred_reselect")
		return

	_apply_path_selection(child)

	_flat_line = child
	_is_flat_selected = _check_if_flat(child)
	_mouse_was_pressed = true
	_at_extremity = _is_flat_selected and _is_mouse_near_extremity()
	_dd_was_rotating = false
	_hijacking = false
	_hijack_mode = 0
	_force_drag_ready = true
	_drag_start = mouse_world
	_drag_origin = child.global_position
	select_tool.SavePreTransforms()


# Selection d'un path (sans la mise en place du drag) : reutilisable par
# _try_force_select (au press) et par la selection differee (clic dans la box
# active d'un autre asset, applique au release).
func _apply_path_selection(child) -> void:
	if child == null or not is_instance_valid(child):
		return
	if not Input.is_key_pressed(KEY_SHIFT):
		select_tool.DeselectAll()
	_normalize_pathway_position(child)
	select_tool.SelectThing(child, true)
	select_tool.EnableTransformBox(true)
	input_listener.call_deferred("_deferred_panel_notify")
	var raw = select_tool.RawSelectables
	if raw:
		for s in raw:
			if s == null or not is_instance_valid(s):
				continue
			var t = s.get("Thing")
			if t != null and is_instance_valid(t) and t == child:
				select_tool.set("highlighted", s)
				break
	# Annule un eventuel Move arme par DD sur l'ancien asset (sinon son _ContentInput
	# deplace au lieu de selectionner notre path).
	if select_tool.get("transformMode") != null:
		select_tool.set("transformMode", 0)
func _distance_to_line(line: Line2D, world_pos: Vector2) -> float:
	var local_pos = line.get_global_transform().affine_inverse().xform(world_pos)
	var pts = line.points
	if pts.size() < 2:
		return INF
	var min_dist = INF
	for i in range(pts.size() - 1):
		var a = pts[i]
		var b = pts[i + 1]
		var ab = b - a
		var len_sq = ab.length_squared()
		var t = 0.0
		if len_sq > 0.001:
			t = clamp((local_pos - a).dot(ab) / len_sq, 0.0, 1.0)
		var proj = a + ab * t
		var d = (local_pos - proj).length()
		if d < min_dist:
			min_dist = d
	return min_dist


func _suppress_dd_highlight() -> void:
	# Disabled: accessing select_tool.get("highlighted") crashes when lights
	# exist on the map. The path_fix hover highlight replaces DD's anyway.
	pass


func _is_select_tool_active() -> bool:
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel and panel is CanvasItem:
		return panel.is_visible_in_tree()
	return false


func _is_dragging() -> bool:
	if _hijacking:
		return true
	if _left_pressed and _drag_threshold_passed:
		return true
	return false


func _update_cursor_only() -> void:
	if not _is_select_tool_active() or ui_util.is_mouse_over_ui(input_listener):
		_reset_cursor()
		return
	if _is_dragging():
		# Pendant le drag, path_fix gere le curseur via _on_input
		return
	# overlay_tool tient _hover_path a jour (path selectionne ou non).
	# Source unique de verite pour eviter le flicker entre les deux modules.
	if overlay_tool != null and is_instance_valid(overlay_tool) and overlay_tool._hover_path != null:
		# Si la box de transformation d'un asset selectionne reclame le curseur
		# (move/rotate/resize), on ne detecte pas le path : DD garde la main sur
		# le curseur ET sur le clic (cf. _try_force_select).
		if _transform_box_wants_cursor():
			_reset_cursor()
			return
		_set_drag_cursor()
		return
	_reset_cursor()


func _dd_transform_mode() -> int:
	# Mode de transformation calcule par DD lui-meme (0=None, 1=Move, 2=Rotate,
	# 3=Scale). DD le met a jour dans son _Input sur le press (si la box est
	# visible) et le remet a None au relachement. C'est sa decision native, donc
	# fiable contrairement a un appel externe a GetTransformMode().
	var m = select_tool.get("transformMode")
	if m == null:
		return 0
	return int(m)


func _transform_box_wants_cursor() -> bool:
	# Vrai si la box de transformation est visible et que la souris est sur un
	# de ses curseurs. On interroge directement les memes methodes que DD
	# (IsMouseOnCorner / IsMouseInside / IsMouseInRotateZone) : passer par
	# GetTransformMode() donnait un faux negatif sur la zone de rotation.
	var tbox = select_tool.get("transformBox")
	if tbox == null or not is_instance_valid(tbox) or not tbox.visible:
		return false
	if tbox.has_method("IsMouseOnCorner") and tbox.IsMouseOnCorner() != -1:
		return true
	if tbox.has_method("IsMouseInside") and tbox.IsMouseInside():
		return true
	if tbox.has_method("IsMouseInRotateZone") and tbox.IsMouseInRotateZone():
		return true
	return false


# Vrai UNIQUEMENT si le curseur est sur une POIGNEE de la box (coin = redim, ou
# anneau de rotation MAIS hors de la box), pas sur son interieur (deplacement).
# IsMouseInRotateZone() = Rect.Grow(64).HasPoint -> vrai aussi a l'interieur, donc
# il faut explicitement exclure IsMouseInside(), sinon un clic dans un trou au sein
# de la box serait pris pour une poignee et bloquerait la selection a travers.
# Sert a ne jamais hijacker un redim/rotation au profit d'une selection a travers
# un trou, tout en laissant l'override agir quand le clic tombe dans le corps.
func _transform_box_on_handle() -> bool:
	var tbox = select_tool.get("transformBox")
	if tbox == null or not is_instance_valid(tbox) or not tbox.visible:
		return false
	if tbox.has_method("IsMouseOnCorner") and tbox.IsMouseOnCorner() != -1:
		return true
	var inside = tbox.has_method("IsMouseInside") and tbox.IsMouseInside()
	if not inside and tbox.has_method("IsMouseInRotateZone") and tbox.IsMouseInRotateZone():
		return true
	return false


func _update_hover_highlight() -> void:
	if not _is_select_tool_active() or ui_util.is_mouse_over_ui(input_listener):
		_clear_hover_highlight()
		return

	# Don't highlight (or call Selectables/RawSelectables) during a drag box:
	# DD may have duplicates in RawSelectables mid-selection which caused spam crashes.
	if _left_pressed and _drag_threshold_passed and not _hijacking and not _force_drag_ready:
		_clear_hover_highlight()
		return

	# Don't highlight during drag
	if _is_dragging():
		# Keep cursor during our own drag
		if not _hijacking:
			_clear_hover_highlight()
		else:
			# Clear highlight visuals but keep cursor
			if _hover_path != null and is_instance_valid(_hover_path):
				_hover_path.material = _hover_original_material
			_hover_path = null
			_hover_original_material = null
		return

	var level = _g.World.GetCurrentLevel()
	if level == null:
		_clear_hover_highlight()
		return
	var pathways = level.get("Pathways")
	if pathways == null:
		_clear_hover_highlight()
		return

	if _is_object_under_mouse():
		_clear_hover_highlight()
		return

	var mouse_world = _g.WorldUI.MousePosition
	var best = null

	var children = pathways.get_children()
	for i in range(children.size() - 1, -1, -1):
		var child = children[i]
		if not (child is Line2D):
			continue
		if _is_mouse_on_visible_pixel(child, mouse_world):
			best = child
			break

	if best != null:
		if best != _hover_path:
			_clear_hover_highlight()
			_hover_path = best
			_create_overlay(best)
		_update_cursor(best, mouse_world)
	else:
		_clear_hover_highlight()


func _create_overlay(source: Line2D) -> void:
	_hover_original_material = source.material
	source.material = _highlight_material


func _clear_hover_highlight() -> void:
	if _hover_path != null and is_instance_valid(_hover_path):
		_hover_path.material = _hover_original_material
	_hover_path = null
	_hover_original_material = null
	_reset_cursor()


var _cursor_active := false
var _move_cursor_tex = null
var _rotate_cursor_tex = null

func _load_cursor_texture() -> void:
	var img = Image.new()
	var path = _g.Root + "icons/drag-cursor-icon.png"
	if img.load(path) == OK:
		_move_cursor_tex = ImageTexture.new()
		_move_cursor_tex.create_from_image(img, 0)
		print("[PathFix] Loaded cursor: " + path)
	var img2 = Image.new()
	var path2 = _g.Root + "icons/rotate.png"
	if img2.load(path2) == OK:
		_rotate_cursor_tex = ImageTexture.new()
		_rotate_cursor_tex.create_from_image(img2, 0)
		print("[PathFix] Loaded rotate cursor: " + path2)


func _update_cursor(line: Line2D, mouse_world: Vector2) -> void:
	_set_drag_cursor()


func _set_drag_cursor() -> void:
	if _move_cursor_tex == null:
		_load_cursor_texture()
	if _move_cursor_tex:
		var hotspot = _move_cursor_tex.get_size() / 2
		Input.set_custom_mouse_cursor(_move_cursor_tex, Input.CURSOR_ARROW, hotspot)
		_cursor_active = true


func _set_rotate_cursor() -> void:
	if _rotate_cursor_tex == null:
		_load_cursor_texture()
	if _rotate_cursor_tex:
		var hotspot = _rotate_cursor_tex.get_size() / 2
		Input.set_custom_mouse_cursor(_rotate_cursor_tex, Input.CURSOR_ARROW, hotspot)
		_cursor_active = true


func _reset_cursor() -> void:
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false


# === ROTATION FIX FOR DETECTION ===

func _fix_near_exact_rotations() -> void:
	# Fix on all levels, not just current
	var levels = _g.World.get("levels")
	if levels:
		for level in levels:
			_fix_level_paths(level)
	else:
		var level = _g.World.GetCurrentLevel()
		if level:
			_fix_level_paths(level)


func _fix_level_paths(level) -> void:
	var pathways = level.get("Pathways")
	if pathways == null:
		return
	var fixed = 0
	for child in pathways.get_children():
		if child is Line2D:
			if _snap_rotation_to_exact(child):
				fixed += 1
	if fixed > 0:
		print("[PathFix] Snapped rotation of " + str(fixed) + " path(s) on " + str(level.name))


func _snap_rotation_to_exact(line: Line2D) -> bool:
	# Snap near-exact angles to exact (e.g. 89.999 -> 90, 180.001 -> 180)
	# This fixes IsMouseWithin for some paths (GlobalRect needs dimension = exactly 0)
	var rot = fmod(line.rotation_degrees, 360.0)
	if rot < 0:
		rot += 360.0

	var snap_angles = [0.0, 90.0, 180.0, 270.0]
	var threshold = 0.1

	for angle in snap_angles:
		var diff = abs(rot - angle)
		if diff < threshold and diff > 0.0:
			var current = line.rotation_degrees
			var target_diff = angle - rot
			line.rotation_degrees = current + target_diff
			return true
	return false


# === PROCESS ===

var _hover_path = null
var overlay_tool = null
var _hover_original_material = null
var _highlight_material = null
var _texture_image_cache := {}  # Texture -> Image (locked)

func _create_highlight_material() -> void:
	var shader = Shader.new()
	shader.code = """shader_type canvas_item;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (tex.a > 0.01) {
		vec3 tint = vec3(1.0, 1.0, 0.2);
		COLOR = vec4(mix(tex.rgb, tint, 0.35), min(tex.a + 0.5, 1.0));
	} else {
		COLOR = tex;
	}
}
"""
	_highlight_material = ShaderMaterial.new()
	_highlight_material.shader = shader


func _get_texture_image(tex: Texture) -> Image:
	if _texture_image_cache.has(tex):
		return _texture_image_cache[tex]
	var img = tex.get_data()
	if img:
		img.lock()
		_texture_image_cache[tex] = img
	return img


# Cache: for each texture, the visible UV range across the width [min_uv, max_uv]
var _visible_range_cache := {}

func _get_visible_range(tex: Texture, img: Image) -> Array:
	if _visible_range_cache.has(tex):
		return _visible_range_cache[tex]
	var tex_h = img.get_height()
	var tex_w = img.get_width()
	var min_uv = 1.0
	var max_uv = 0.0
	var step_x = max(tex_w / 64, 1)
	for y in range(tex_h):
		var opaque_count = 0
		var sample_count = 0
		for x in range(0, tex_w, step_x):
			sample_count += 1
			if img.get_pixel(x, y).a > 0.1:
				opaque_count += 1
		# Row counts as visible if at least 5% of samples are opaque
		if opaque_count > sample_count * 0.05:
			var uv = float(y) / float(tex_h)
			if uv < min_uv:
				min_uv = uv
			if uv > max_uv:
				max_uv = uv
	if min_uv > max_uv:
		min_uv = 0.0
		max_uv = 1.0
	# Add tiny margin for interpolation
	min_uv = max(min_uv - 0.01, 0.0)
	max_uv = min(max_uv + 0.01, 1.0)
	_visible_range_cache[tex] = [min_uv, max_uv]
	return [min_uv, max_uv]


func _is_mouse_on_visible_pixel(line: Line2D, world_pos: Vector2) -> bool:
	var local_pos = line.get_global_transform().affine_inverse().xform(world_pos)
	var pts = line.points
	if pts.size() < 2:
		return false

	# Longueur cumulee le long de la polyligne pour mapper a la coord texture U
	var cum = [0.0]
	var total_len = 0.0
	for i in range(pts.size() - 1):
		total_len += (pts[i + 1] - pts[i]).length()
		cum.append(total_len)

	# Trouver le segment le plus proche + distance perpendiculaire signee +
	# debordement au-dela des extremites (positif si curseur depasse)
	var best_score = INF
	var best_seg = 0
	var best_t = 0.0
	var best_perp = 0.0
	var best_along_past_start = 0.0
	var best_along_past_end = 0.0
	var best_arc = 0.0

	for i in range(pts.size() - 1):
		var pa = pts[i]
		var pb = pts[i + 1]
		var ab = pb - pa
		var seg_len = ab.length()
		if seg_len < 0.001:
			continue
		var dir = ab / seg_len
		var perp_n = Vector2(-dir.y, dir.x)
		var rel = local_pos - pa
		var along = rel.dot(dir)
		var perp_d = rel.dot(perp_n)
		var t = clamp(along / seg_len, 0.0, 1.0)
		var proj = pa + dir * (t * seg_len)
		var dist = (local_pos - proj).length()
		if dist < best_score:
			best_score = dist
			best_seg = i
			best_t = t
			best_perp = perp_d
			best_along_past_start = max(0.0, -along)
			best_along_past_end = max(0.0, along - seg_len)
			best_arc = cum[i] + t * seg_len

	var half_w = line.width * 0.5

	# Reject perpendiculaire : vraie distance perpendiculaire (pas euclidienne)
	if abs(best_perp) > half_w:
		return false

	# Reject extremite, dependant du cap_mode
	# LINE_CAP_NONE=0 : pas d'extension, tolerance minime
	# LINE_CAP_BOX=1 / LINE_CAP_ROUND=2 : cap qui s'etend de half_w au-dela
	if best_t <= 0.001 and best_seg == 0:
		var bcm = line.begin_cap_mode
		var max_past = 0.5 if bcm == 0 else half_w
		if best_along_past_start > max_past:
			return false
		if bcm == 2:  # ROUND : limite circulaire
			if best_along_past_start * best_along_past_start + best_perp * best_perp > half_w * half_w:
				return false
	if best_t >= 0.999 and best_seg == pts.size() - 2:
		var ecm = line.end_cap_mode
		var max_past2 = 0.5 if ecm == 0 else half_w
		if best_along_past_end > max_past2:
			return false
		if ecm == 2:
			if best_along_past_end * best_along_past_end + best_perp * best_perp > half_w * half_w:
				return false

	# V (perpendiculaire) en UV: 0 a un bord, 1 a l'autre
	var v_uv = best_perp / line.width + 0.5

	var tex = line.texture
	if tex == null:
		return v_uv >= 0.0 and v_uv <= 1.0
	var img = _get_texture_image(tex)
	if img == null:
		return v_uv >= 0.0 and v_uv <= 1.0

	var tex_w = img.get_width()
	var tex_h = img.get_height()

	# U (longitudinal) en UV dans l'espace texture, depend du texture_mode
	var u_uv = 0.0
	var tmode = line.texture_mode
	if tmode == Line2D.LINE_TEXTURE_TILE:
		# Une tuile = line.width * (tex_w / tex_h) unites monde
		var tile_len = line.width * (float(tex_w) / float(tex_h))
		if tile_len < 0.001:
			return v_uv >= 0.0 and v_uv <= 1.0
		u_uv = fmod(best_arc / tile_len, 1.0)
		if u_uv < 0.0:
			u_uv += 1.0
	elif tmode == Line2D.LINE_TEXTURE_STRETCH:
		if total_len < 0.001:
			return v_uv >= 0.0 and v_uv <= 1.0
		u_uv = best_arc / total_len
	else:
		# LINE_TEXTURE_NONE
		return v_uv >= 0.0 and v_uv <= 1.0

	# Echantillonner le pixel reel de la texture sous le curseur
	var px = int(clamp(u_uv * tex_w, 0, tex_w - 1))
	var py = int(clamp(v_uv * tex_h, 0, tex_h - 1))
	return img.get_pixel(px, py).a > 0.1

func _on_process(_delta) -> void:
	# Fix near-exact rotations once at startup
	if not _initial_fix_done:
		if _initial_fix_delay > 0:
			_initial_fix_delay -= 1
		else:
			_initial_fix_done = true
			_fix_near_exact_rotations()

	# Only interact with SelectTool internals when it's actually active
	if not _is_select_tool_active():
		if _hover_path != null:
			_clear_hover_highlight()
		_unforce_path_widget()
		_is_flat_selected = false
		_flat_line = null
		_hijacking = false
		_hijack_mode = 0
		_mouse_was_pressed = false
		_at_extremity = false
		_dd_was_rotating = false
		_force_drag_ready = false
		_reselect_on_empty = false
		_hovered_path = null
		return

	# Suppress DD's native dotted hover on all paths
	_suppress_dd_highlight()
	# Corriger le highlight parasite de DD (asset du dessous quand le path est
	# devant, ou trace central du path quand il est couvert par un pattern).
	_fix_dd_highlight()
	# Idem pour un wall survole : masquer le highlight natif de l'asset du dessous.
	_fix_dd_wall_highlight()
	# Symetrique : si DD surligne nativement un wall alors qu'un path/pattern est
	# rendu au-dessus, masquer ce highlight de wall (l'asset du dessus prime).
	_suppress_covered_wall_highlight()
	# Highlight visuel gere par overlay_tool, mais on gere le curseur ici
	_update_cursor_only()

	# Pioche couleur active (mod Colour and Modify Things, etc.) → ne pas
	# toucher a la selection : sinon le path survole serait reselectionne.
	if _is_color_picking():
		return

	# Free Transform actif → laisser FT gérer, ne pas interférer
	if _g.ModMapData.get("_free_transform_active", false):
		_is_flat_selected = false
		_flat_line = null
		_hijacking = false
		_hijack_mode = 0
		return

	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		if (_hijacking or _force_drag_ready) and _flat_line and is_instance_valid(_flat_line):
			# DD cleared selection during our drag — don't reset, keep dragging
			return
		_is_flat_selected = false
		_flat_line = null
		_hijacking = false
		_hijack_mode = 0
		_mouse_was_pressed = false
		_at_extremity = false
		_dd_was_rotating = false
		_force_drag_ready = false
		_reselect_on_empty = false
		return

	# Count non-path items in selection
	var line = null
	var non_path_count = 0
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if thing is Line2D:
			if line == null:
				line = thing
		else:
			non_path_count += 1

	# Don't hijack transforms in multi-selection with non-path assets
	if non_path_count > 0:
		_is_flat_selected = false
		_flat_line = null
		return

	# Multi-path selection: let DD handle everything
	if raw.size() > 1:
		_is_flat_selected = false
		_flat_line = null
		return

	if line == null:
		_is_flat_selected = false
		_flat_line = null
		return

	if _flat_line == line:
		_is_flat_selected = _check_if_flat(line)
		return

	_flat_line = line
	_is_flat_selected = _check_if_flat(line)
	_normalize_pathway_position(line)
	select_tool.DeselectAll()
	select_tool.SelectThing(line, true)
	select_tool.EnableTransformBox(true)
	input_listener.call_deferred("_deferred_panel_notify")