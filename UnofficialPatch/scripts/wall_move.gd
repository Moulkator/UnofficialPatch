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
# Membres du prefab qui accompagnent le wall drague. Un drag instantane (clic
# direct sur un wall non selectionne) ne passe pas par la box de
# DragSelectWalls : sans ca le wall se detachait de son prefab au lieu de
# l'emmener avec lui, alors que le meme drag sur une selection existante
# deplace bien tout le groupe.
var _drag_group_walls := []   # [{wall, pts, portals, children}]
var _drag_group_nodes := {}   # {Node2D: position d'origine}

var _cursor_active  = false
var _move_cursor_tex = null

var _left_pressed        = false
var _drag_threshold_passed = false
var _left_press_pos      = Vector2.ZERO
# Wall survole au moment du clic. overlay_tool rafraichit _hover_wall depuis
# son propre _process : quand le seuil de drag est franchi, il a parfois deja
# ete vide (mouvement rapide, survol perdu entre le clic et la 1re motion).
# _try_start_drag sortait alors sans rien faire, et DD tracait un rectangle de
# selection a la place — d'ou les drags qui "ne se declenchent pas".
var _press_hover_wall    = null
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
	_drag_group_walls = []
	_drag_group_nodes = {}
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
			_press_hover_wall = null
			if overlay_tool != null and is_instance_valid(overlay_tool):
				_press_hover_wall = overlay_tool._hover_wall
			# Cliquer sur un wall overlayed le selectionne (parite avec les paths)
			_try_force_select_wall()
		else:
			_left_pressed = false
			_drag_threshold_passed = false
			_press_hover_wall = null
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
	# Respecter aussi le filtre de calques et la visibilite
	if _layer_pick_blocked(st, wall):
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
	_enable_dd_box_if_owned(st)
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
	# Meme cause que pour le drag : quand le hit-test de DD rate le wall (il
	# tolere 32 px depuis l'AXE, donc la moitie exterieure d'un mur epais ne
	# compte pas), il a demarre son rectangle de selection sur le press. Tant
	# qu'il tourne, SelectThingsInsideBox() ecrase notre selection a chaque
	# frame et le wall finit deselectionne au relachement — cliquer sur le
	# cote exterieur d'un mur ne le selectionnait plus. On coupe ici, apres
	# la passe d'input de DD, et on lui rend la selection.
	_cancel_dd_drag_select(wall)
	var raw = st.RawSelectables
	if raw:
		for s in raw:
			if s != null and s.get("Thing") == wall:
				return  # toujours selectionne, rien a faire
	# DD a vide la selection : on la restaure
	if not Input.is_key_pressed(KEY_SHIFT):
		st.DeselectAll()
	st.SelectThing(wall, true)
	_enable_dd_box_if_owned(st)
	_notify_wall_panel()


# La box de DD n'est utile que quand DragSelectWalls ne prend pas la main
# (wall simple et plat). Dans les autres cas — 2+ walls, ou walls + assets,
# donc un prefab — la rendre visible ici a un effet de bord majeur : DD voit
# transformBox.Visible sur le meme clic et LATCHE une de ses transformations
# (transformMode > 0). DSW passe alors en _transforming, ce qui desactive son
# watchdog de geometrie (`not _transforming`) pour toute la duree du drag :
# sa box restait figee en arriere. Elle declenchait en plus
# _update_group_transform(), qui reapplique sa propre transformation aux walls
# pendant que nous les deplacons deja.
func _enable_dd_box_if_owned(st) -> void:
	if st == null or not st.has_method("EnableTransformBox"):
		return
	# Appel DIFFERE. Nos listeners voient le clic dans la phase _input, donc
	# AVANT le _on_Content_gui_input de DD : rendre la box visible tout de
	# suite la lui montre sur ce meme clic, et il latche transformMode
	# (GetTransformMode() renvoie Move puisque la souris est dans la box qu'on
	# vient d'ajuster). DD deplace alors Thing.Position en parallele de notre
	# drag et desactive le watchdog de DragSelectWalls — la box restait figee
	# en arriere. call_deferred repousse l'activation apres la passe d'input :
	# la box apparait a la frame suivante, DD ne voit rien a latcher.
	call_deferred("_deferred_enable_dd_box")


# Le test de propriete est refait ICI, pas au moment de la planification :
# quand on force la selection d'un wall, la selection est encore vide a
# l'instant du clic, donc DragSelectWalls ne "possede" pas encore la box et on
# activait celle de DD pour rien. On voyait alors DEUX boxes de tailles
# differentes — celle de DD ajustee sur les seuls Points, la notre elargie de
# l'epaisseur du mur — puis un saut de taille quand DSW masquait celle de DD
# au premier frame de drag. Differer le test suffit : le wall est selectionne
# a ce moment-la, DSW possede la box, on ne touche pas a celle de DD.
func _deferred_enable_dd_box() -> void:
	if _destroyed:
		return
	var st = _get_select_tool()
	if st == null or not st.has_method("EnableTransformBox"):
		return
	if _dsw_owns_box():
		return
	st.EnableTransformBox(true)


# True quand l'overlay custom de DragSelectWalls prend la main sur la box.
func _dsw_owns_box() -> bool:
	if _g == null or not (_g.ModMapData is Dictionary):
		return false
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null or not is_instance_valid(dsw):
		return false
	# _selection_owns_box ignore isDrawing : quand DD transforme le clic en
	# drag-select (son hit-test rate le bord d'un mur epais), _is_custom_active
	# retombe a false et on reactivait sa box — deuxieme box a l'ecran.
	if dsw.has_method("_selection_owns_box"):
		return dsw._selection_owns_box()
	if not dsw.has_method("_is_custom_active"):
		return false
	return dsw._is_custom_active()


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
	# Priorite au wall latche au clic ; le survol courant n'est qu'un repli.
	var wall = _press_hover_wall
	if wall == null or not is_instance_valid(wall):
		wall = overlay_tool._hover_wall
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

	# DragSelectWalls' custom box owns the interaction while it is being
	# dragged (move / rotate / scale). Running our own translation on top
	# of it fights the box for the same Points.
	if _dsw_box_dragging():
		return

	# DD a deja latche son propre deplacement (instant drag sur un asset).
	# Ses movableThings incluent les walls du groupe, qu'il traine par
	# Thing.Position : si on translate AUSSI leurs Points ici, le wall
	# encaisse le deplacement deux fois et finit plus loin que le reste du
	# prefab. Cas frequent, il suffit que le prop clique chevauche un wall
	# pour que overlay_tool le donne comme survole.
	if _dd_manual_move_active():
		return
	# Bloquer les walls FloorShape (Type != 1)
	var wtype = wall.get("Type")
	if wtype != null and wtype != 1:
		return

	# Pas de drag d'un wall filtre par calque ou invisible
	var st_lf = _get_select_tool()
	if st_lf != null and _layer_pick_blocked(st_lf, wall):
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
	_drag_origin_children = _snapshot_wall_children(wall)
	_collect_prefab_companions(wall)
	
	# Pour l'undo : capturer un snapshot stable (node_ids + valeurs) qui
	# survivra à la disparition/recréation des nodes. Les Points, la
	# global_position et les positions de portals suffisent à
	# reconstruire tout le reste via RemakeLines().
	_undo_snapshot_before = _snapshot_group_state()

	_dragging = true
	_cancel_dd_drag_select(_drag_wall)
	_set_drag_cursor()


# Remet le wall (et les compagnons du prefab) a leur geometrie d'origine, puis
# abandonne le drag sans rien enregistrer : DD prend le relais.
func _cancel_drag_for_dd() -> void:
	if _drag_wall != null and is_instance_valid(_drag_wall):
		if _drag_origin_pts.size() > 0:
			_set_wall_points(_drag_wall, _drag_origin_pts)
		_move_children(Vector2.ZERO)
		for portal in _drag_origin_portals:
			if is_instance_valid(portal):
				portal.position = _drag_origin_portals[portal]
		if _drag_wall.has_method("RemakeLines"):
			_drag_wall.call("RemakeLines")
	_move_prefab_companions(Vector2.ZERO)
	_dragging = false
	_drag_wall = null
	_undo_snapshot_before = null
	_drag_origin_children = {}
	_drag_group_walls = []
	_drag_group_nodes = {}
	_reset_cursor()


# Vrai si le wall ne doit pas etre pickable : invisible dans l'arbre (calque
# cache par un mod tiers type Hide Layers) ou rejete par le filtre de CALQUES
# du SelectTool (IsObjectLayerFiltered, methode C# publique ; pour les walls
# c'est l'entree 9999 "Locked Layers"). Le pick natif de DD refuse ces walls
# (HighlightThingAtPoint), notre pick ameliore doit faire pareil.
func _layer_pick_blocked(st, thing) -> bool:
	if thing is CanvasItem and not thing.is_visible_in_tree():
		return true
	if st != null and st.has_method("IsObjectLayerFiltered") and st.IsObjectLayerFiltered(thing):
		return true
	return false


# SelectTool.manualAction : 0 None, 1 MoveThing, 2 MovePortal, 3 AttenuateLight.
# Champ prive cote C# mais lisible depuis GDScript, comme transformMode.
func _dd_manual_move_active() -> bool:
	if _g == null or _g.Editor == null:
		return false
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary) or not tools.has("SelectTool"):
		return false
	var st = tools["SelectTool"]
	if st == null or not is_instance_valid(st):
		return false
	var ma = st.get("manualAction")
	return ma != null and int(ma) == 1


# DD n'a pas toujours reconnu le wall sous la souris : son hit-test
# (Wall.IsMouseWithin) tolere 32 px depuis l'AXE, ce qui rate la pointe d'un
# angle aigu ou le bord d'un mur epais alors que le pixel clique est bien du
# mur. `highlighted` est alors null et DD demarre son rectangle de selection.
# Le laisser tourner a deux effets : il selectionne tout ce que le rectangle
# traverse pendant qu'on deplace le mur, et l'overlay de DragSelectWalls se
# cache tant que isDrawing est vrai — d'ou la box "restee derriere". On coupe
# donc le drag-select des que notre propre drag demarre, et on redonne la
# selection au wall.
func _cancel_dd_drag_select(wall = null) -> void:
	if wall == null:
		wall = _drag_wall
	var st = _get_select_tool()
	if st == null:
		return
	if st.get("isDrawing") != true:
		return
	st.set("isDrawing", false)
	if st.get("isDrawing") == true:
		# Champ non inscriptible depuis GDScript : on le signale une fois
		# plutot que de laisser le symptome sans explication.
		if not Engine.has_meta("_wm_isdrawing_checked"):
			Engine.set_meta("_wm_isdrawing_checked", true)
			printerr("[UnofficialPatch] SelectTool.isDrawing is not writable from GDScript; ")
			printerr("[UnofficialPatch] dragging a wall from a sharp corner will also drag-select.")
		return
	var box = st.get("selectionBox")
	if box != null and is_instance_valid(box) and box.has_method("SetRect"):
		box.SetRect(null)
	if wall == null or not is_instance_valid(wall):
		return
	if not Input.is_key_pressed(KEY_SHIFT):
		st.DeselectAll()
	st.SelectThing(wall, true)
	_notify_wall_panel()


# SelectTool.transformMode : 0 None, 1 Move, 2 Rotate, 3 Scale.
func _dd_transform_mode() -> int:
	var st = _get_select_tool()
	if st == null:
		return 0
	var tm = st.get("transformMode")
	if tm == null:
		return 0
	return int(tm)


func _get_select_tool():
	if _g == null or _g.Editor == null:
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary) or not tools.has("SelectTool"):
		return null
	var st = tools["SelectTool"]
	if st == null or not is_instance_valid(st):
		return null
	return st


# La geometrie d'un wall vit dans Points ; la position de son node doit rester
# a l'origine. On la remet a zero sur le wall drague et ses compagnons.
func _zero_wall_node_positions() -> void:
	if _drag_wall != null and is_instance_valid(_drag_wall) \
			and _drag_wall.position != Vector2.ZERO:
		_drag_wall.position = Vector2.ZERO
	for entry in _drag_group_walls:
		var w = entry["wall"]
		if is_instance_valid(w) and w.position != Vector2.ZERO:
			w.position = Vector2.ZERO


# True while DragSelectWalls is running one of its custom box drags.
func _dsw_box_dragging() -> bool:
	if _g == null or not (_g.ModMapData is Dictionary):
		return false
	var dsw = _g.ModMapData.get("_drag_select_walls")
	if dsw == null:
		return false
	var mode = dsw.get("_ci_mode")
	return mode != null and int(mode) > 0


# ── Wall.Points ↔ Wall.pointsClosed ────────────────────────────────────────
# DD keeps a second copy of a LOOPED wall's outline in the private
# `pointsClosed` array (Points + Points[0] appended). It is built only by
# Wall.Set() and shifted by Wall.Offset() — RemakeLines() does NOT rebuild
# it. PortalTool.FindBestLocation() → Wall.FindPortalSpot() reads
# `Loop ? pointsClosed : Points`, so once we write Points directly the
# PortalTool keeps snapping new portals onto the wall's OLD outline.
# Every direct Points write must go through this helper. Godot's Mono
# property bridge reaches private auto-properties, so we can write the
# cache back ourselves; non-looped walls need nothing.
func _set_wall_points(wall, pts) -> void:
	wall.set("Points", pts)
	if wall.get("Loop") != true:
		return
	if pts == null or pts.size() < 2:
		return
	var closed := PoolVector2Array()
	for p in pts:
		closed.append(p)
	closed.append(pts[0])
	wall.set("pointsClosed", closed)
	# One-shot sanity check: if the private property turns out to be
	# unreachable, say so once instead of silently leaving portals
	# snapping to stale geometry.
	if not Engine.has_meta("_up_pointsclosed_checked"):
		Engine.set_meta("_up_pointsclosed_checked", true)
		var back = wall.get("pointsClosed")
		if back == null or back.size() != closed.size():
			printerr("[UnofficialPatch] Wall.pointsClosed is not writable from GDScript; ")
			printerr("[UnofficialPatch] portals may snap to stale geometry on looped walls.")


func _do_drag():
	if _drag_wall == null or not is_instance_valid(_drag_wall):
		_end_drag()
		return

	# DD a latche son propre deplacement APRES qu'on ait demarre le notre : nos
	# listeners voient le clic avant son _ContentInput, donc le test au demarrage
	# arrive systematiquement trop tot (manualAction est encore None). On le
	# refait ici, a chaque frame. Si DD mene, on annule proprement : le wall
	# revient a sa geometrie d'origine (delta nul) et c'est DragSelectWalls qui
	# convertit la translation de DD. Sans ca les deux mods deplacent le meme
	# wall et il avance deux fois plus vite que le reste du prefab.
	if _dd_manual_move_active():
		if _dragging:
			print("[WM-DIAG] annulation : DD mene le deplacement")
		_cancel_drag_for_dd()
		return

	# Filet de securite. Si DD a tout de meme latche une de ses transformations
	# sur ce clic (transformMode > 0), il ecrit Thing.Position sur les walls
	# selectionnes a chaque frame. Or un Wall ne porte pas sa geometrie dans sa
	# position : cette ecriture se cumule a la notre et laisse le wall decale du
	# reste du prefab. On la neutralise.
	if _dd_transform_mode() > 0:
		_zero_wall_node_positions()

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
	_set_wall_points(_drag_wall, new_pts)

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

	# 5. Le reste du prefab suit le meme delta
	_move_prefab_companions(delta)

	# 6. La transform box de DD est calculee au moment de la selection et n'est
	# rafraichie que par SES propres drags : on ecrit les positions
	# directement, elle resterait donc en arriere. Une box decalee fausse
	# ensuite tout pivot/scale, qui se font par rapport a elle.
	_refresh_dd_transform_box()


func _snapshot_wall_children(wall) -> Dictionary:
	var out := {}
	for child in wall.get_children():
		if child is Line2D:
			var pts = []
			for p in child.points: pts.append(p)
			out[child] = {"points": pts}
			for sub in child.get_children():
				if sub is Node2D:
					out[sub] = {"position": sub.position}
		elif child is Node2D:
			for sub in child.get_children():
				if sub is Line2D:
					var pts = []
					for p in sub.points: pts.append(p)
					out[sub] = {"points": pts}
	return out


func _move_children(delta):
	_move_children_map(_drag_origin_children, delta)


func _move_children_map(map: Dictionary, delta) -> void:
	for node in map:
		if not is_instance_valid(node):
			continue
		var orig = map[node]
		if orig.has("points"):
			var lpts = PoolVector2Array()
			for p in orig["points"]:
				lpts.append(p + delta)
			node.points = lpts
		elif orig.has("position"):
			node.position = orig["position"] + delta


# Un wall expose RemakeLines ; ni un Prop ni un Portal ne l'ont, ce qui en
# fait un discriminant fiable sans dependre des valeurs de SelectableType.
func _is_wall_node(node) -> bool:
	return node != null and is_instance_valid(node) and node.has_method("RemakeLines")


func _collect_prefab_companions(main_wall) -> void:
	_drag_group_walls = []
	_drag_group_nodes = {}
	if main_wall == null or not main_wall.has_meta("prefab_id"):
		return
	var pid = str(main_wall.get_meta("prefab_id"))
	if pid == "":
		return
	if _g == null or _g.World == null:
		return
	var tree = _g.World.get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(pid):
		if node == null or not is_instance_valid(node) or node == main_wall:
			continue
		if not (node is Node2D):
			continue
		if _is_wall_node(node):
			var entry = {"wall": node, "pts": [], "portals": {}, "children": {}}
			var pts = node.get("Points")
			if pts != null:
				for p in pts:
					entry["pts"].append(p)
			var portals = node.get("Portals")
			if portals != null:
				for portal in portals:
					if is_instance_valid(portal):
						entry["portals"][portal] = portal.position
			entry["children"] = _snapshot_wall_children(node)
			_drag_group_walls.append(entry)
			continue
		# Les portals ancres suivent deja leur wall : ne pas les deplacer deux
		# fois. Seuls les assets libres du groupe sont pris ici.
		var parent = node.get_parent()
		if parent != null and _is_wall_node(parent):
			continue
		_drag_group_nodes[node] = node.position


func _move_prefab_companions(delta) -> void:
	for entry in _drag_group_walls:
		var w = entry["wall"]
		if not is_instance_valid(w):
			continue
		var np = []
		for p in entry["pts"]:
			np.append(p + delta)
		_set_wall_points(w, np)
		_move_children_map(entry["children"], delta)
		for portal in entry["portals"]:
			if is_instance_valid(portal):
				portal.position = entry["portals"][portal] + delta
		if w.has_method("RemakeLines"):
			w.call("RemakeLines")
	for node in _drag_group_nodes:
		if is_instance_valid(node):
			node.position = _drag_group_nodes[node] + delta


func _end_drag():
	# Avant de tout nettoyer : si un vrai déplacement a eu lieu, capturer
	# l'état final et créer un record pour Ctrl+Z.
	if _drag_wall != null and is_instance_valid(_drag_wall) and _undo_snapshot_before != null:
		_record_group_move(_undo_snapshot_before, _snapshot_group_state())
	_undo_snapshot_before = null
	_refresh_dd_transform_box()
	
	_dragging = false
	_drag_wall = null
	_drag_origin_pts = []
	_drag_origin_portals = {}
	_drag_origin_children = {}
	_drag_group_walls = []
	_drag_group_nodes = {}
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


# Etat complet du drag : le wall traine, les walls compagnons du prefab, puis
# les assets libres du groupe. Un seul record pour l'ensemble, donc un seul
# Ctrl+Z.
# EnableTransformBox(true) reconstruit la box depuis GetSelectionRect(), donc
# depuis la selection courante — walls inclus, DD gere SelectableType.Wall dans
# ce calcul. Sans selection on ne touche a rien : GetSelectionRect() renvoie un
# Rect2 nul et la box irait se poser a l'origine.
#
# IMPERATIF : ne rien faire quand l'overlay de DragSelectWalls possede la
# selection (2+ walls, ou walls + assets = le cas d'un prefab mixte). DSW
# masque alors la box de DD a chaque frame ; la re-activer ici en parallele
# faisait apparaitre DEUX boxes, puis laissait celle de DD echouee a la
# position d'avant le drag. Dans ce cas c'est la box de DSW qui doit suivre,
# et son watchdog de geometrie (_walls_geo_signature) s'en charge deja
# puisque nos ecritures de Points ne passent pas par son API.
func _refresh_dd_transform_box() -> void:
	if _g == null or _g.Editor == null:
		return
	if _dsw_owns_box():
		return
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary) or not tools.has("SelectTool"):
		return
	var st = tools["SelectTool"]
	if st == null or not is_instance_valid(st):
		return
	if not st.has_method("EnableTransformBox"):
		return
	var raw = st.RawSelectables
	if raw == null or raw.size() == 0:
		return
	st.EnableTransformBox(true)


func _snapshot_group_state() -> Array:
	var states := []
	if _drag_wall != null and is_instance_valid(_drag_wall):
		states.append(_snapshot_wall_state(_drag_wall))
	for entry in _drag_group_walls:
		var w = entry["wall"]
		if is_instance_valid(w):
			states.append(_snapshot_wall_state(w))
	for node in _drag_group_nodes:
		if is_instance_valid(node) and node.has_meta("node_id"):
			states.append({"node_id": node.get_meta("node_id"), "position": node.position})
	return states


func _record_group_move(before: Array, after: Array) -> void:
	if before.size() == 0 or before.size() != after.size():
		return
	# Rien n'a bouge (clic sans franchir DRAG_THRESHOLD) : pas de record.
	if before[0].get("global_position") == after[0].get("global_position") \
			and before[0].get("points") == after[0].get("points"):
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_group_state", [before],
		self, "_restore_group_state", [after])


func _restore_group_state(states: Array) -> void:
	for state in states:
		if state.has("points"):
			_restore_wall_state(state)
			continue
		var nid = state.get("node_id", -1)
		if nid < 0:
			continue
		var node = _find_node_by_id(nid)
		if node != null and is_instance_valid(node) and node is Node2D:
			node.position = state.get("position", node.position)


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
	_set_wall_points(wall, new_pts)
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
