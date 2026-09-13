# transform_box_fix.gd
# Fixes DD's transform box capturing clicks on other assets inside it.
# When clicking on a highlighted asset that's different from the selected one,
# deselects current selection first so DD can pick up the new asset.

var _g
var select_tool
var ui_util
var path_fix
var input_listener: Node
# Suivi clic-vs-drag : on ne bascule vers l'asset survole QU'AU release et
# seulement si le geste etait un clic (aucun drag), pour ne JAMAIS voler un
# deplacement de l'asset deja selectionne.
var _left_pressed := false
var _press_pos := Vector2.ZERO
var _drag_passed := false
var _pending_switch = null
var _pending_release_thing = null

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[TransformBoxFix] Initialized")


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "TransformBoxFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _deferred_switch() -> void:\n\tif handler != null:\n\t\thandler._do_deferred_switch()\nfunc _process(_delta) -> void:\n\tif handler != null:\n\t\thandler._tbz_process()\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


# Mouse is on/near a transform box handle (corner resize) or in the rotation
# zone just outside a corner. Mirrors the pattern used in selection_resize.gd:
# trust DD's transformCorner when available, fall back to corner-distance with
# a zoom-scaled tolerance for cases where a bigger asset under the box steals
# hover before DD flags the corner.
func _is_over_transform_handle() -> bool:
	if select_tool == null:
		return false
	# Decision native de DD sur ce press (si son _Input est passe avant nous) :
	# Move(1)/Rotate(2)/Scale(3) signifient tous "transformer la selection
	# courante" -> ne pas deselectionner.
	var tm = select_tool.get("transformMode")
	if tm != null and int(tm) != 0:
		return true
	# transformCorner is updated by DD's hover detection in real time
	# (0=TL, 1=TR, 2=BR, 3=BL, -1=none).
	var dd_corner = select_tool.get("transformCorner")
	if dd_corner != null and int(dd_corner) >= 0 and int(dd_corner) <= 3:
		return true

	# Interroger DIRECTEMENT le widget de la box : memes tests que DD, synchrones
	# et independants de l'ordre des handlers. C'est la source fiable pour la
	# zone de rotation (transformMode n'est pas encore pose si notre listener
	# tourne avant celui de DD, et transformCorner ne couvre que les coins).
	var tbox = select_tool.get("transformBox")
	if tbox != null and is_instance_valid(tbox) and tbox.visible:
		if tbox.has_method("IsMouseOnCorner") and int(tbox.IsMouseOnCorner()) != -1:
			return true
		var in_rotate = tbox.has_method("IsMouseInRotateZone") and tbox.IsMouseInRotateZone()
		var inside = tbox.has_method("IsMouseInside") and tbox.IsMouseInside()
		# Anneau de rotation = dans la zone mais hors de la box. L'interieur
		# (Move) reste deselectable pour basculer sur un autre asset sous la box.
		if in_rotate and not inside:
			return true

	# Repli geometrique world-space si le widget n'est pas accessible.
	if not select_tool.has_method("GetSelectionRect"):
		return false
	var rect = select_tool.GetSelectionRect()
	if not (rect is Rect2):
		return false
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return false
	if _g.WorldUI == null:
		return false
	var mouse: Vector2 = _g.WorldUI.MousePosition

	# Screen-tolerance scaled to world units via camera zoom.
	var zoom = 1.0
	var cam = _g.Editor.get("Camera") if _g.Editor else null
	if cam and is_instance_valid(cam) and cam is Camera2D:
		zoom = max(cam.zoom.x, 0.001)

	# Zone de rotation : a l'exterieur de la box mais dans la marge de rotation.
	var rotate_margin = 64.0 * zoom
	if rect.grow(rotate_margin).has_point(mouse) and not rect.has_point(mouse):
		return true

	# Corner area fallback (resize) for cases DD hasn't flagged transformCorner.
	var tl: Vector2 = rect.position
	var br: Vector2 = rect.position + rect.size
	var corners = [tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)]
	# 35 px matches the constant used in selection_resize.gd for DD's hit zone.
	var minor = min(rect.size.x, rect.size.y)
	var tol = min(35.0 * zoom, max(minor * 0.4, 8.0 * zoom))

	for c in corners:
		if mouse.distance_to(c) <= tol:
			return true
	return false


func _on_input(event) -> void:
	# Suivi du drag : des que la souris depasse le seuil apres un press gauche.
	if event is InputEventMouseMotion:
		if _left_pressed and not _drag_passed and event.position.distance_to(_press_pos) > 4:
			_drag_passed = true
		return
	if not (event is InputEventMouseButton and event.button_index == BUTTON_LEFT):
		return

	if event.pressed:
		_left_pressed = true
		_drag_passed = false
		_press_pos = event.position
		_pending_switch = null
		# Shift : laisser DD gerer (ajout a la selection), pas de basculement.
		if Input.is_key_pressed(KEY_SHIFT):
			return
		# Preparer un eventuel basculement vers l'asset survole DIFFERENT, mais NE
		# PAS deselectionner maintenant : DD arme son Move sur l'asset selectionne ;
		# on tranchera au release (clic vs drag).
		_pending_switch = _switch_target()
	else:
		var pend = _pending_switch
		_pending_switch = null
		_left_pressed = false
		var was_drag = _drag_passed
		_drag_passed = false
		# Clic (aucun drag) sur un autre asset dans la box -> basculer dessus au
		# release. Drag -> on ne touche a rien : DD a deplace l'asset selectionne.
		if pend != null and not was_drag and is_instance_valid(pend):
			_pending_release_thing = pend
			input_listener.call_deferred("_deferred_switch")


# Renvoie le Thing (noeud) survole par DD, DIFFERENT du/des selectionnes et
# eligible a un basculement, ou null si aucun basculement ne doit etre prepare.
# Regroupe toutes les conditions de l'ancien _on_input.
func _switch_target():
	# Clic sur un panneau/popup UI : ignorer (le listener est global).
	if ui_util != null and ui_util.is_mouse_over_ui(input_listener):
		return null
	# Seulement quand SelectTool est actif.
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if not (panel and panel is CanvasItem and panel.is_visible_in_tree()):
		return null
	# Seulement quand quelque chose est selectionne.
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return null
	# Sur une poignee (coin/redim) ou l'anneau de rotation : laisser DD transformer.
	if _is_over_transform_handle():
		return null
	# Un path non couvert est survole : c'est path_fix qui doit gerer la selection
	# (DD ne "voit" pas les paths plats et survolerait l'asset DESSOUS). Sans ce
	# garde-fou, on basculerait vers cet asset au release et on volerait la
	# selection du path que path_fix vient de poser.
	if path_fix != null and is_instance_valid(path_fix) \
	and path_fix.has_method("_has_selectable_path_hover") and path_fix._has_selectable_path_hover():
		return null
	# DD voit-il un asset sous la souris ?
	var highlighted = select_tool.get("highlighted")
	if highlighted == null:
		return null
	var hover_thing = null
	if typeof(highlighted) == TYPE_OBJECT and is_instance_valid(highlighted):
		hover_thing = highlighted.get("Thing")
	if hover_thing == null:
		return null
	# Portail fantome (highlighte par DD mais couvert par un asset opaque sous
	# le curseur, cf. select_layer_pick_fix) : ne JAMAIS basculer vers lui.
	if _g.ModMapData is Dictionary and _g.ModMapData.get("_slpf_phantom_portal") == hover_thing:
		return null
	if typeof(hover_thing) == TYPE_OBJECT and not is_instance_valid(hover_thing):
		return null
	# Deja selectionne -> laisser DD gerer normalement (deplacement).
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var t = s.get("Thing")
		if t != null and is_instance_valid(t) and t == hover_thing:
			return null
	return hover_thing


# Differe (idle) : bascule la selection vers l'asset survole apres que DD ait fini
# de traiter le release (evite tout conflit avec son RecordTransforms).
func _do_deferred_switch() -> void:
	var thing = _pending_release_thing
	_pending_release_thing = null
	if thing == null or not is_instance_valid(thing):
		return
	# Ceinture + bretelles : re-verifier le fantome au moment differe aussi.
	if _g.ModMapData is Dictionary and _g.ModMapData.get("_slpf_phantom_portal") == thing:
		return
	if select_tool == null:
		return
	# Re-verifier qu'il n'est pas devenu selectionne entre-temps.
	var raw = select_tool.RawSelectables
	if raw != null:
		for s in raw:
			if s == null or not is_instance_valid(s):
				continue
			var t = s.get("Thing")
			if t != null and is_instance_valid(t) and t == thing:
				return
	if not Input.is_key_pressed(KEY_SHIFT):
		select_tool.DeselectAll()
	select_tool.EnableTransformBox(false)
	if select_tool.has_method("SelectThing"):
		var made = select_tool.SelectThing(thing, true)
		if select_tool.has_method("EnableTransformBox"):
			select_tool.EnableTransformBox(true)
		if made != null:
			select_tool.set("highlighted", made)
	# Annule un eventuel Move residuel arme par DD sur l'ancien asset.
	if select_tool.get("transformMode") != null:
		select_tool.set("transformMode", 0)


# ══════════════════════════════════════════════════════════════════════════
# TBZ : transform box native a taille ECRAN constante a fort zoom
#
# TransformBoxWidget dessine cadre et poignees via World.UI.TransformStyleBox /
# TransformCornerStyleBox dans des rects en unites MONDE (drawRadius 32 est
# readonly cote C#) : tres zoome, contours epais et poignees enormes. Au-dela
# de TBZ_ENGAGE_ZOOM :
#   - le dessin PROPRE du widget est masque via self_modulate alpha 0 (les
#     enfants ne sont pas affectes, contrairement a modulate). NB : muter les
#     styleboxes recuperes via WorldUI.get() ne masque PAS le dessin natif
#     (l'instance consommee par _Draw n'est pas celle exposee) ;
#   - un overlay enfant du widget redessine cadre + poignees avec des DUPLICATS
#     des memes styleboxes, a taille ecran constante (herite position/rotation
#     du widget, donc suit les transformations) ;
#   - grabRadius / rotateZoneSize (champs prives C#) sont reduits en proportion
#     pour garder zones de hit et visuel synchronises. Si set() etait sans
#     effet, les zones resteraient vanilla (plus larges que le visuel) : sans
#     danger.
# En dessous du seuil : desengagement complet, comportement vanilla intact.
# ══════════════════════════════════════════════════════════════════════════

const TBZ_ENGAGE_ZOOM := 0.5    # zoom ecran/monde au-dela duquel on compense
const TBZ_GRAB_RADIUS := 32.0   # grabRadius vanilla (unites monde, restauration)
const TBZ_ROTATE_ZONE := 64.0   # rotateZoneSize vanilla (unites monde, restauration)
# Cibles ECRAN une fois engage. On dessine cadre et poignees NOUS-MEMES
# (traits fins) plutot que de reutiliser les styleboxes DD, dont le contour
# epais fait partie de la texture et grossit avec la taille du rect :
const TBZ_HANDLE_SCREEN_PX := 44.0   # cote des poignees a l'ecran
const TBZ_GRAB_SCREEN_PX := 44.0     # rayon de grab : couvre la poignee (22 px
									 # de demi-cote, ~31 px en diagonale) + marge
const TBZ_ROTATE_SCREEN_PX := 64.0   # marge de l'anneau de rotation
const TBZ_LINE_SCREEN_PX := 6.0      # epaisseur des traits (cadre + poignees) —
									 # assez epais pour rester lisible sur des
									 # assets/textures superposes a fort zoom
# Transition douce depuis l'apparence vanilla AU POINT D'ENGAGEMENT vers les
# cibles ci-dessus, atteintes a TBZ_BLEND_END_ZOOM. Interpolation smoothstep
# sur le zoom. Les valeurs d'engagement correspondent au rendu vanilla au
# seuil (64 px monde x 0.5 = 32 px ecran, contour ~3.5 px) pour une bascule
# invisible.
const TBZ_BLEND_END_ZOOM := 1.8
const TBZ_HANDLE_ENGAGE_PX := 32.0   # taille vanilla des poignees au seuil (64 x 0.5)
const TBZ_LINE_ENGAGE_PX := 3.5      # approx du contour vanilla au seuil
const TBZ_GRAB_ENGAGE_PX := 44.0
const TBZ_ROTATE_ENGAGE_PX := 64.0

var _tbz_engaged := false
var _tbz_overlay = null       # Node2D enfant du widget (dessin compense)
var _tbz_saved_selfmod := Color(1, 1, 1, 1)   # self_modulate vanilla du widget


func _tbz_process() -> void:
	if _g == null or _g.Editor == null:
		return
	if select_tool == null or not is_instance_valid(select_tool):
		select_tool = _g.Editor.Tools.get("SelectTool")
		if select_tool == null:
			return
	var tb = select_tool.get("transformBox")
	if tb == null or typeof(tb) != TYPE_OBJECT or not is_instance_valid(tb):
		return
	var zoom = _tbz_zoom(tb)
	if zoom <= TBZ_ENGAGE_ZOOM:
		_tbz_disengage(tb)
		return
	if not _tbz_engaged:
		_tbz_engage(tb)
	if _tbz_engaged:
		_tbz_sync(tb, zoom)


# Echelle de rendu REELLE du widget (local -> ecran). Mesuree sur le widget
# lui-meme via get_global_transform_with_canvas : fiable quel que soit
# l'arrangement camera/canvas, y compris aux zooms etendus de zoom_unlock
# (canvas_transform du viewport ne refletait pas le facteur reel a ~6000%).
func _tbz_zoom(tb) -> float:
	if tb == null or not is_instance_valid(tb):
		return 1.0
	return max(tb.get_global_transform_with_canvas().get_scale().x, 0.001)


func _tbz_engage(tb) -> void:
	_tbz_saved_selfmod = tb.self_modulate
	_tbz_make_overlay(tb)
	_tbz_engaged = true


func _tbz_disengage(tb) -> void:
	if not _tbz_engaged:
		return
	_tbz_engaged = false
	# Zones de hit vanilla + dessin natif retabli.
	if tb != null and typeof(tb) == TYPE_OBJECT and is_instance_valid(tb):
		tb.set("grabRadius", TBZ_GRAB_RADIUS)
		tb.set("rotateZoneSize", TBZ_ROTATE_ZONE)
		tb.self_modulate = _tbz_saved_selfmod
	if _tbz_overlay != null and is_instance_valid(_tbz_overlay):
		_tbz_overlay.queue_free()
	_tbz_overlay = null


func _tbz_sync(tb, zoom) -> void:
	# Overlay perdu (rechargement de map : widget et enfants liberes) ?
	if _tbz_overlay == null or not is_instance_valid(_tbz_overlay):
		_tbz_make_overlay(tb)
		if _tbz_overlay == null:
			return
	elif _tbz_overlay.get_parent() != tb:
		# Nouveau widget (nouvelle map) : re-parenter proprement.
		_tbz_overlay.queue_free()
		_tbz_make_overlay(tb)
		if _tbz_overlay == null:
			return
	# Transition douce : t = 0 au point d'engagement (apparence ~vanilla de
	# zoom 1), t = 1 a TBZ_BLEND_END_ZOOM (cibles fines). Smoothstep.
	var t = clamp((zoom - TBZ_ENGAGE_ZOOM) / (TBZ_BLEND_END_ZOOM - TBZ_ENGAGE_ZOOM), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	var handle_px = lerp(TBZ_HANDLE_ENGAGE_PX, TBZ_HANDLE_SCREEN_PX, t)
	var line_px = lerp(TBZ_LINE_ENGAGE_PX, TBZ_LINE_SCREEN_PX, t)
	# EMPIRIQUE (logs utilisateur) : IsMouseOnCorner / IsMouseInRotateZone
	# comparent leur rayon a des distances qui se comportent en PIXELS ECRAN
	# (GetScaledLocalMousePosition), pas en unites monde — en vanilla le grab
	# reste ~32 px ecran a tout zoom pendant que le visuel gonfle (d'ou des
	# poignees enormes mais dures a attraper). Rayons ECRAN, sans division.
	tb.set("grabRadius", lerp(TBZ_GRAB_ENGAGE_PX, TBZ_GRAB_SCREEN_PX, t))
	tb.set("rotateZoneSize", lerp(TBZ_ROTATE_ENGAGE_PX, TBZ_ROTATE_SCREEN_PX, t))
	# Chaque frame : le dessin natif reste masque meme si le widget a ete
	# recree (nouvelle map) — self_modulate ne touche pas l'overlay enfant.
	tb.self_modulate = Color(1, 1, 1, 0)
	# Rect LOCAL du widget. La propriete C# `Rect` peut ne pas repondre au
	# get() Godot (le code UP existant contourne deja les proprietes du widget
	# par des methodes) : repli sur GetSelectionRect() (taille monde, box
	# centree a l'origine locale, grow(1) comme SetPositionAndSize).
	var lrect = null
	var pr = tb.get("Rect")
	if typeof(pr) == TYPE_RECT2 and pr.size != Vector2.ZERO:
		lrect = pr
	elif select_tool.has_method("GetSelectionRect"):
		var sr = select_tool.GetSelectionRect()
		if sr is Rect2 and sr.size != Vector2.ZERO:
			lrect = Rect2(sr.size * -0.5, sr.size).grow(1.0)
	if lrect == null:
		return
	# Couleurs LIVE des styleboxes : suit la couleur de groupe (group_assets
	# teinte transformStyleBox / transformCornerStyleBox, mauve par defaut) et
	# les changements du color picker en direct.
	var frame_color = Color(0.13, 0.68, 0.94, 0.95)
	var handle_color = Color(1, 1, 1, 1)
	if _g.WorldUI != null:
		frame_color = _tbz_style_color(_g.WorldUI.get("transformStyleBox"), frame_color)
		handle_color = _tbz_style_color(_g.WorldUI.get("transformCornerStyleBox"), handle_color)
	_tbz_overlay.set_params(lrect, handle_px, line_px, frame_color, handle_color)


# Couleur representative d'un stylebox (border puis bg), alpha du repli
# conserve. Repli tel quel si le stylebox est absent ou d'un type inconnu.
func _tbz_style_color(sb, fallback: Color) -> Color:
	if sb == null or typeof(sb) != TYPE_OBJECT or not is_instance_valid(sb):
		return fallback
	var c = sb.get("border_color")
	if c == null:
		c = sb.get("bg_color")
	if c == null:
		c = sb.get("modulate_color")
	if c == null or not (c is Color):
		return fallback
	# Keep the stylebox alpha: light_fix hides the lights' box by swapping in
	# a fully transparent StyleBoxFlat — the overlay must stay invisible too
	# (it used to redraw it opaque black above the engage zoom).
	return Color(c.r, c.g, c.b, fallback.a * c.a)


func _tbz_make_overlay(tb) -> void:
	_tbz_overlay = null
	if tb == null or not is_instance_valid(tb):
		return
	var script = GDScript.new()
	script.source_code = "extends Node2D\n" \
		+ "var rect := Rect2()\n" \
		+ "var handle_px := 44.0\n" \
		+ "var line_px := 2.5\n" \
		+ "var frame_color := Color(0.13, 0.68, 0.94, 0.95)\n" \
		+ "var handle_color := Color(1, 1, 1, 1)\n" \
		+ "func _process(_d) -> void:\n" \
		+ "\tupdate()\n" \
		+ "func _draw() -> void:\n" \
		+ "\tvar p = get_parent()\n" \
		+ "\tif p == null or not p.visible:\n" \
		+ "\t\treturn\n" \
		+ "\tif rect.size.x <= 0.0 or rect.size.y <= 0.0:\n" \
		+ "\t\treturn\n" \
		+ "\t# Echelle de rendu reelle de CE node : tailles ecran garanties.\n" \
		+ "\tvar s = max(get_global_transform_with_canvas().get_scale().x, 0.001)\n" \
		+ "\tvar hr = handle_px * 0.5 / s\n" \
		+ "\tvar lw = line_px / s\n" \
		+ "\tif frame_color.a <= 0.001 and handle_color.a <= 0.001:\n" \
		+ "\t\treturn\n" \
		+ "\t_stroke_rect(rect, frame_color, lw)\n" \
		+ "\tvar pts = [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]\n" \
		+ "\tfor c in pts:\n" \
		+ "\t\tvar hrect = Rect2(c - Vector2(hr, hr), Vector2(hr * 2.0, hr * 2.0))\n" \
		+ "\t\t# Fond legerement assombri pour detacher la poignee du decor.\n" \
		+ "\t\tdraw_rect(hrect, Color(0, 0, 0, 0.25 * handle_color.a), true)\n" \
		+ "\t\t_stroke_rect(hrect, handle_color, lw)\n" \
		+ "# Contour trace en 4 rects REMPLIS : draw_rect non rempli avec une\n" \
		+ "# largeur < 1.0 locale bascule sur des lignes GL de 1 px device\n" \
		+ "# (hairline), quel que soit le zoom — invisible tres zoome.\n" \
		+ "func _stroke_rect(r: Rect2, color: Color, w: float) -> void:\n" \
		+ "\tw = min(w, min(r.size.x, r.size.y) * 0.5)\n" \
		+ "\tdraw_rect(Rect2(r.position, Vector2(r.size.x, w)), color)\n" \
		+ "\tdraw_rect(Rect2(Vector2(r.position.x, r.end.y - w), Vector2(r.size.x, w)), color)\n" \
		+ "\tdraw_rect(Rect2(Vector2(r.position.x, r.position.y + w), Vector2(w, r.size.y - 2.0 * w)), color)\n" \
		+ "\tdraw_rect(Rect2(Vector2(r.end.x - w, r.position.y + w), Vector2(w, r.size.y - 2.0 * w)), color)\n" \
		+ "func set_params(r, hpx, lpx, fc, hc) -> void:\n" \
		+ "\trect = r\n" \
		+ "\thandle_px = hpx\n" \
		+ "\tline_px = lpx\n" \
		+ "\tframe_color = fc\n" \
		+ "\thandle_color = hc\n" \
		+ "\tupdate()\n"
	script.reload()
	var node = Node2D.new()
	node.name = "TBZOverlay"
	node.set_script(script)
	tb.add_child(node)
	_tbz_overlay = node

