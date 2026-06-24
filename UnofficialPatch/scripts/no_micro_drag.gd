# no_micro_drag.gd
# Empêche un micro-drag accidentel sur le SelectTool.
#
# Comportement :
#   - Clic sur un asset NON sélectionné :
#       Le drag est bloqué jusqu'à ce que l'une de ces conditions soit remplie :
#         (A) mouvement single-frame ≥ FAST_FRAME_PX  → drag rapide, libération immédiate
#         (B) temps écoulé ≥ DRAG_THRESHOLD_MS et distance ≥ MIN_DRAG_PX → drag par durée
#         (C) distance cumulée ≥ DRAG_DISTANCE_PX     → drag par distance
#       Au démarrage du drag, les assets sont repositionnés pour compenser les
#       frames bloquées (voir RECENTER_ON_DRAG / CENTER_UNDER_MOUSE).
#       Si aucune condition n'est remplie au relâché → simple sélection, sans déplacement.
#   - Clic sur un asset DÉJÀ sélectionné :
#       protection désactivée, le drag part immédiatement (comportement natif DD).
#   - Sélection lockée :
#       protection désactivée, on laisse DD bloquer le déplacement nativement
#       (sinon notre override continu écraserait la protection).
#
# ── Détection rapide (FAST_FRAME_PX) ─────────────────────────────────────────
# Un jitter de souris accidentel ne produit jamais un mouvement de plusieurs
# pixels en une seule frame ; un drag intentionnel rapide oui. On libère donc
# le drag dès la première frame si event.relative.length() dépasse ce seuil,
# évitant toute phase bloquée pour les drags rapides.
#
# ── Recentrage ────────────────────────────────────────────────────────────────
# Notre listener est dans World, donc il reçoit les events AVANT DD. Conséquence : au mousedown, DD n'a pas encore traité le clic,
# Selected est vide. On ne peut donc pas mémoriser les positions des assets au
# mousedown.
#
# Solution : on mémorise au PREMIER motion bloqué. À ce moment, DD a déjà traité
# le mousedown et l'asset est bien dans Selected.
# On accumule ensuite tous les event.relative bloqués pour obtenir le delta total
# parcouru par la souris. Au déclenchement du drag, on applique ce delta (converti
# en coordonnées monde via la partie linéaire du canvas transform, sans la
# translation qui encoderait l'offset des panneaux UI) aux positions mémorisées.
#
# ── CENTER_UNDER_MOUSE (override continu) ───────────────────────────────────
# Quand actif, update() force à chaque frame la position de chaque asset en
# se basant uniquement sur des données stables : la position d'origine de
# chaque asset (_assets_pos_at_first_move), la position monde du clic
# (_click_world_pos), la position actuelle de la souris, et l'état de snap
# courant. Aucun offset n'est pré-calculé : tout est ré-évalué par frame,
# ce qui permet de réagir aux changements de mode de snap en cours de drag.
#
# Formule (mode snap actif) :
#   leader_target = snap(mouse_world + leader_orig - click_world)
#   delta         = leader_target - leader_orig
#   asset.pos     = asset_orig + delta   (pour chaque asset)
# → Le leader (asset cliqué, ou unique asset de la sélection) atterrit sur
#   un point de snap du mode courant. Tous les autres assets bougent du même
#   delta, ce qui préserve la structure relative (prefabs/groupes). Si on
#   bascule vanilla ↔ Custom Snap pendant le drag, snap() change de fonction
#   et l'asset est immédiatement repositionné sur un snap point du nouveau mode.
#
# Formule (snap inactif) :
#   delta     = mouse_world - click_world
#   asset.pos = asset_orig + delta
# → Pas de saut visuel : à la frame de drag start, mouse ≈ click, donc
#   delta ≈ 0 et l'asset reste où on l'a cliqué.
#
# ── Snap (grille native + Custom Snap) ──────────────────────────────────────
# IMPORTANT : Custom Snap nécessite que Snap to Grid soit aussi activé pour
# snapper. _snap_is_enabled() ne se fie donc qu'à l'heuristique DD native
# (WorldUI.SnappedPosition diverge de MousePosition > 1px ssi snap global ON),
# qui couvre les deux modes. _get_snapped_position() utilise Custom Snap
# (snappy_mod) quand il est chargé ET son flag custom_snap_enabled est vrai,
# sinon WorldUI.GetSnappedPosition.

var _g
var overlay_tool = null
var wall_move = null

const DRAG_THRESHOLD_MS  := 100
const DRAG_DISTANCE_PX   := 50.0
const MIN_DRAG_PX        := 4.0
const FAST_FRAME_PX      := 12.0

# Délai après le DÉPART du drag avant que le snap ne s'active. Pendant ce
# laps, l'asset suit librement la souris (formule non snappée), comme DD natif,
# pour éviter les rollbacks de position au tout début du déplacement.
# N'a d'effet qu'en mode CENTER_UNDER_MOUSE et seulement sur sélection fraîche
# (clic sur asset non sélectionné), qui est le seul chemin passant par update().
const SNAP_DELAY_MS      := 250

# En dessous de ce déplacement monde entre deux frames, la souris est
# considérée immobile (pas de snap subi à l'arrêt après le délai).
const MOVE_EPS           := 0.01

# Mettre à false pour désactiver le recentrage par compensation des frames
# bloquées (l'asset reste à sa position d'origine quand le drag démarre).
const RECENTER_ON_DRAG   := true

# Si vrai, override continu pendant tout le drag (formule ci-dessus).
# Supersède RECENTER_ON_DRAG quand actif.
const CENTER_UNDER_MOUSE := true

var _input_listener           = null
var _mouse_down               := false
var _drag_started             := false
var _bypass                   := false
var _positions_stored         := false   # true dès que les positions ont été mémorisées
var _click_time_ms            := 0
# Horodatage du départ effectif du drag (release ou fast-path). Sert à gater
# l'activation du snap pendant SNAP_DELAY_MS.
var _drag_start_time_ms       := 0
# Position monde de la souris à la frame précédente d'update(). Sert à détecter
# si la souris bouge : passé SNAP_DELAY_MS, le snap ne s'applique QUE sur les
# frames en mouvement (sinon on garde la position courante, pas de snap subi à
# l'arrêt).
var _prev_mouse_world = null              # Vector2 ou null
var _distance_moved           := 0.0
var _injecting                := false
var _assets_pos_at_first_move := {}       # { Node2D: Vector2 } — positions d'origine
var _accumulated_screen_delta := Vector2.ZERO
# Position monde du curseur au mousedown — sert d'ancre dans la formule
# de centrage continu. Capturée une fois, jamais recalculée.
var _click_world_pos = null               # Vector2 ou null
# Flag : vrai quand update() doit overrider chaque frame la position des
# assets selon la formule de CENTER_UNDER_MOUSE. Activé par
# _center_assets_under_mouse(), désactivé par _reset().
var _center_active            := false
# Positions visibles au moment du mouseup, capturées pour la dernière
# frame d'override (post-mouseup de DD). En les restaurant telles quelles
# au lieu de recalculer via la formule, on évite qu'une dérive de la
# souris entre le mouseup et la frame suivante ne snappe l'asset sur un
# point adjacent. Voir update() pour le détail.
var _final_positions          := {}       # { Node2D: Vector2 }
var _destroyed                := false


func initialize() -> void:
	var il = GDScript.new()
	il.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler:\n\t\thandler._on_input(e)\n"
	il.reload()
	_input_listener = Node.new()
	_input_listener.name = "NoMicroDragListener"
	_input_listener.set_script(il)
	_input_listener.handler = self
	# Reste dans World (nettoyé au changement de map) mais PAS en position 0 :
	# move_child(0) décalait GridMesh et cassait Snappy Grid.
	_g.World.add_child(_input_listener)
	print("[NoMicroDrag] Initialized — threshold=", DRAG_THRESHOLD_MS,
		"ms / dist=", DRAG_DISTANCE_PX, "px / min=", MIN_DRAG_PX,
		"px / fast=", FAST_FRAME_PX, "px — recenter=", RECENTER_ON_DRAG,
		" / center_under_mouse=", CENTER_UNDER_MOUSE)


func cleanup() -> void:
	_destroyed = true
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	_assets_pos_at_first_move = {}
	_final_positions = {}
	print("[NoMicroDrag] Cleaned up")


func _is_select_tool_active() -> bool:
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor == null:
		return false
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			return child.visible
	return false


# Convertit un déplacement écran en déplacement monde.
# On utilise uniquement la partie linéaire (basis) du canvas transform inverse :
# juste le zoom, sans la translation (qui encoderait l'offset des panneaux UI).
func _screen_delta_to_world(screen_delta: Vector2) -> Vector2:
	var inv = _g.World.get_canvas_transform().affine_inverse()
	return inv.basis_xform(screen_delta)


# ── Helpers Snap (DD natif + Custom Snap) ────────────────────────────────
# Pattern aligné sur clipboard_fix / DragSelectWalls / selection_resize.

# Récupère l'instance GDScript du mod snappy_mod (Custom Snap) si chargé
# et qu'il expose get_snapped_position, sinon null.
func _get_custom_snap_api():
	if _g == null:
		return null
	var editor = _g.Editor
	if editor == null or not ("Tools" in editor):
		return null
	var tools = editor.Tools
	if not tools.has("snappy_mod"):
		return null
	var snappy_tool = tools["snappy_mod"]
	if snappy_tool == null:
		return null
	if not snappy_tool.has_method("get_ScriptInstance"):
		return null
	var script_instance = snappy_tool.get_ScriptInstance()
	if script_instance == null:
		return null
	if not script_instance.has_method("get_snapped_position"):
		return null
	return script_instance


# Vrai ssi le snap est globalement actif (toggle « Snap to Grid »).
# Custom Snap requiert que ce toggle soit ON pour snapper, donc
# l'heuristique DD native suffit ici et couvre les deux modes :
# SnappedPosition diverge de MousePosition de >1px ssi le snap global est ON.
# (Si Custom Snap est activé seul, sans Snap to Grid, aucun snap ne s'applique
# et l'heuristique retourne correctement false.)
func _snap_is_enabled() -> bool:
	var wui = _g.get("WorldUI")
	if wui == null:
		return false
	var snap_pos = wui.get("SnappedPosition")
	var mouse_pos = wui.get("MousePosition")
	if snap_pos == null or mouse_pos == null:
		return false
	if not (snap_pos is Vector2) or not (mouse_pos is Vector2):
		return false
	return snap_pos.distance_to(mouse_pos) > 1.0


# Snappe une position monde via Custom Snap si activé, sinon DD natif.
# À appeler uniquement après _snap_is_enabled() == true (sinon WorldUI
# snappe quand même — ce n'est pas un no-op quand le toggle global est off,
# mais en pratique on ne passe ici qu'avec snap on, donc OK).
func _get_snapped_position(pos: Vector2) -> Vector2:
	var custom = _get_custom_snap_api()
	if custom != null and "custom_snap_enabled" in custom and custom.custom_snap_enabled:
		return custom.get_snapped_position(pos)
	var wui = _g.get("WorldUI")
	if wui != null and wui.has_method("GetSnappedPosition"):
		return wui.GetSnappedPosition(pos)
	return pos


func _store_asset_positions() -> void:
	# Appelé au premier motion bloqué : DD a déjà traité le mousedown,
	# Selected contient bien les assets concernés.
	_assets_pos_at_first_move.clear()
	var select_tool = _g.Editor.Tools["SelectTool"]
	if select_tool == null:
		return
	# Sélection lockée : DD interdit déjà le déplacement. On bypass pour
	# éviter que _center_assets_under_mouse + l'override continu de update()
	# n'écrasent la protection native (sinon un click+drag d'un seul geste
	# sur un asset locked déclencherait quand même le déplacement).
	if select_tool.has_method("IsSelectionLocked") and select_tool.IsSelectionLocked():
		_bypass = true
		return
	for thing in select_tool.Selected:
		_assets_pos_at_first_move[thing] = thing.global_position
	_positions_stored = true


func _recenter_assets() -> void:
	if not _positions_stored or _assets_pos_at_first_move.empty():
		return
	# Applique aux assets le delta monde équivalent au chemin parcouru par la
	# souris pendant le blocage. L'asset se retrouve là où il aurait été sans
	# le blocage, et DD calcule un grab-offset nul.
	var world_delta = _screen_delta_to_world(_accumulated_screen_delta)
	for thing in _assets_pos_at_first_move:
		thing.global_position = _assets_pos_at_first_move[thing] + world_delta


# Position monde de la souris via la valeur déjà calculée par DD (WorldUI.MousePosition).
func _get_mouse_world_pos():
	var wui = _g.get("WorldUI")
	if wui == null:
		return null
	return wui.get("MousePosition")


# Active le mode d'override continu. La formule effective est dans update(),
# qui recalcule tout chaque frame depuis _assets_pos_at_first_move et
# _click_world_pos — pas d'offset pré-calculé ici.
func _center_assets_under_mouse() -> void:
	if not _positions_stored or _assets_pos_at_first_move.empty():
		return
	if _click_world_pos == null:
		return  # impossible d'ancrer sans la position du clic
	_center_active = true


func _release_drag(event: InputEventMouseMotion) -> void:
	_drag_started = true
	_drag_start_time_ms = OS.get_ticks_msec()

	if CENTER_UNDER_MOUSE:
		_center_assets_under_mouse()
	elif RECENTER_ON_DRAG:
		_recenter_assets()

	# Injecter l'ancre après que l'override soit armé, pour que DD lise
	# les positions overridées au prochain frame.
	_inject_anchor_event(event)
	# L'event original n'est PAS marqué handled : DD le reçoit normalement.


func _reset() -> void:
	_mouse_down               = false
	_drag_started             = false
	_bypass                   = false
	_positions_stored         = false
	_distance_moved           = 0.0
	_accumulated_screen_delta = Vector2.ZERO
	_click_world_pos          = null
	_drag_start_time_ms       = 0
	_prev_mouse_world         = null
	_center_active            = false
	_assets_pos_at_first_move.clear()
	_final_positions.clear()


func _on_input(event: InputEvent) -> void:
	if _destroyed:
		return
	if _injecting:
		return
	if not _is_select_tool_active():
		return

	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_reset()
			_mouse_down    = true
			_click_time_ms = OS.get_ticks_msec()
			# Capture de la position monde du clic — ancre la formule de
			# centrage. Capturée UNE FOIS, jamais recalculée.
			_click_world_pos = _get_mouse_world_pos()
			# Si un asset est déjà sélectionné au moment du clic, on bypasse :
			# notre listener étant avant DD, Selected reflète l'état AVANT ce clic,
			# ce qui est exactement ce qu'on veut tester ici.
			var select_tool = _g.Editor.Tools["SelectTool"]
			_bypass = select_tool != null and select_tool.Selected.size() > 0
			# Les walls n'ont pas de transform box, bypasser no_micro_drag pour eux
			if overlay_tool != null and is_instance_valid(overlay_tool):
				var level = _g.World.GetCurrentLevel() if _g.World else null
				var mp = _g.get("WorldUI")
				if mp: mp = mp.get("MousePosition")
				if level and mp != null:
					var walls = level.get("Walls")
					if walls:
						for child in walls.get_children():
							if overlay_tool._is_mouse_on_wall(child, mp):
								_bypass = true
								break
		else:
			# Mouseup : si on est en mode centrage actif, on ne reset PAS
			# immédiatement. On capture les positions visibles courantes
			# (= celles posées par l'update() de la frame précédente, car
			# l'ordre Godot est input → update → render) et on laisse
			# update() les restaurer APRÈS le handler mouseup de DD.
			# C'est nécessaire car DD repositionnerait sinon l'asset à sa
			# position interne ; et on restaure plutôt que de recalculer
			# via la formule pour éviter qu'une micro-dérive de la souris
			# entre maintenant et la prochaine frame ne snappe l'asset
			# sur un point de snap adjacent. Le reset complet sera
			# effectué par update() après la restauration.
			if _drag_started and _center_active:
				_mouse_down = false
				_final_positions.clear()
				for thing in _assets_pos_at_first_move:
					if is_instance_valid(thing):
						_final_positions[thing] = thing.global_position
			else:
				_reset()

	elif event is InputEventMouseMotion and _mouse_down and not _drag_started and not _bypass:
		var frame_len := event.relative.length()

		# Drag rapide détecté dès la première frame : on libère immédiatement
		# AVANT toute mémorisation/accumulation. Le mousedown a déjà été
		# traité par DD, donc on laisse passer l'event sans rien intercepter.
		if frame_len >= FAST_FRAME_PX:
			_drag_started = true
			_drag_start_time_ms = OS.get_ticks_msec()
			if CENTER_UNDER_MOUSE:
				# Pas encore mémorisé : on le fait maintenant pour pouvoir centrer.
				_store_asset_positions()
				_center_assets_under_mouse()
				_inject_anchor_event(event)
			# Sinon : pas de recentrage nécessaire, rien n'a été bloqué,
			# l'asset est au bon endroit et DD applique event.relative normalement.
			return

		# Premier motion bloqué : mémoriser les positions maintenant que DD
		# a traité le mousedown et mis l'asset dans Selected.
		if not _positions_stored:
			_store_asset_positions()
			# _store_asset_positions a pu activer _bypass (sélection lockée) :
			# dans ce cas on stoppe net pour ne pas intercepter ce motion.
			if _bypass:
				return

		_distance_moved           += frame_len
		_accumulated_screen_delta += event.relative

		var elapsed       := OS.get_ticks_msec() - _click_time_ms
		# over_time est gaté par MIN_DRAG_PX : au-delà du seuil temporel, il
		# faut quand même un mouvement minimal pour considérer un drag,
		# sinon un simple clic long (sans bouger ou presque) en déclencherait un.
		var over_time     := elapsed >= DRAG_THRESHOLD_MS and _distance_moved >= MIN_DRAG_PX
		var over_distance := _distance_moved >= DRAG_DISTANCE_PX

		if not over_time and not over_distance:
			var wall_dragging = wall_move != null and is_instance_valid(wall_move) and wall_move._dragging
			if not wall_dragging:
				_g.World.get_tree().set_input_as_handled()
		else:
			_release_drag(event)


func _inject_anchor_event(ref_event: InputEventMouseMotion) -> void:
	var anchor_ev             = InputEventMouseMotion.new()
	anchor_ev.position        = ref_event.position
	anchor_ev.global_position = ref_event.global_position
	anchor_ev.relative        = Vector2.ZERO
	anchor_ev.speed           = Vector2.ZERO

	_injecting = true
	_g.World.get_tree().input_event(anchor_ev)
	_injecting = false


# Récupère la position monde d'origine du « leader » de la sélection.
# Le leader est l'asset utilisé comme référence pour le calcul du snap : sa
# position cible doit tomber sur un snap point du mode courant, et tous les
# autres assets suivent avec le même delta (préserve la structure relative
# des prefabs/groupes).
#
# En pratique, _bypass est forcé true au mousedown quand Selected est déjà
# non vide, donc on n'arrive ici que sur sélection fraîche créée par ce clic.
# Cela signifie typiquement un seul asset (ou un prefab, traité comme une
# entité unique par le SelectTool). Si plusieurs entrées existent quand même,
# on prend celle la plus proche du point de clic (l'asset effectivement cliqué).
func _pick_leader_orig():
	if _assets_pos_at_first_move.empty():
		return null
	if _click_world_pos == null:
		# Sans point de clic on prend juste le premier
		for thing in _assets_pos_at_first_move:
			return _assets_pos_at_first_move[thing]
		return null
	var best
	var best_dist = INF
	for thing in _assets_pos_at_first_move:
		var p = _assets_pos_at_first_move[thing]
		var d = p.distance_squared_to(_click_world_pos)
		if d < best_dist:
			best_dist = d
			best = p
	return best


func update(_delta: float) -> void:
	if _destroyed:
		return
	# Override continu pour CENTER_UNDER_MOUSE : à chaque frame tant que le
	# drag est actif, on recalcule la position de chaque asset depuis les
	# données stables (originals + click point) et l'état de snap courant.
	# Écrase ce que DD fait via son grab_offset interne.
	if not _drag_started or not _center_active:
		return

	# Post-mouseup : on restaure les positions visibles capturées au moment
	# du relâchement plutôt que de recalculer la formule. C'est ce dernier
	# override qui contre le repositionnement par le handler mouseup de DD.
	# On ne recalcule PAS via la formule ici, sinon une micro-dérive de la
	# souris entre le mouseup et cette frame pourrait franchir une frontière
	# de snap et repositionner l'asset sur un point adjacent.
	if not _mouse_down:
		for thing in _final_positions:
			if is_instance_valid(thing):
				thing.global_position = _final_positions[thing]
		_reset()
		return

	# Drag actif : formule normale.
	if _assets_pos_at_first_move.empty() or _click_world_pos == null:
		return

	var mouse_world = _get_mouse_world_pos()
	if mouse_world != null:
		var leader_orig = _pick_leader_orig()
		if leader_orig != null:
			var delta = Vector2.ZERO
			# Snap actif seulement passé SNAP_DELAY_MS depuis le départ du drag :
			# avant ce délai, suivi libre (comme la branche snap-off), ce qui
			# évite les rollbacks de position au tout début du déplacement.
			var snap_ready = OS.get_ticks_msec() - _drag_start_time_ms >= SNAP_DELAY_MS
			# Mouvement de la souris depuis la frame d'update() précédente.
			var is_moving = _prev_mouse_world == null or mouse_world.distance_to(_prev_mouse_world) > MOVE_EPS
			_prev_mouse_world = mouse_world
			if _snap_is_enabled() and snap_ready:
				# Souris immobile après le délai : on ne snappe pas, on garde la
				# position courante (libre si jamais snappée, sinon le dernier
				# point de grille déjà posé). Évite un snap subi à l'arrêt du curseur.
				if not is_moving:
					return
				# Le leader doit atterrir sur un snap point du mode courant :
				#   pos_leader = snap(mouse + leader_orig - click)
				# Le snap est ré-évalué chaque frame, donc basculer vanilla ↔
				# Custom Snap pendant le drag repositionne immédiatement
				# l'asset sur un point de snap du nouveau mode.
				#
				# Tous les autres assets suivent du même delta — la structure
				# relative est préservée (prefabs/groupes). Un snap per-asset
				# enverrait chaque membre vers son propre point de grille le
				# plus proche et casserait la mise en page du prefab.
				var leader_target = _get_snapped_position(mouse_world + leader_orig - _click_world_pos)
				delta = leader_target - leader_orig
			else:
				# Snap off : suivi direct de la souris. À la frame de drag
				# start mouse ≈ click → delta ≈ 0, aucun saut visuel.
				delta = mouse_world - _click_world_pos
			for thing in _assets_pos_at_first_move:
				if is_instance_valid(thing):
					thing.global_position = _assets_pos_at_first_move[thing] + delta
