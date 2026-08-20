# select_highlight_fix.gd
# Bug vanilla : dans SelectTool, l'asset survolé reste "highlighted" lorsque
# le curseur quitte le canvas de la map (panneau latéral, menu du haut, popup
# dessiné par-dessus le canvas, ou une autre fenêtre de l'OS). DD ne met à jour
# le highlight que sur mouvement souris AU-DESSUS du canvas (via
# HighlightThingAtPoint), donc dès que le curseur passe sur l'UI le dernier
# highlight reste figé à l'écran.
#
# De plus, un asset qui dépasse hors des limites de la map peut être highlighté
# alors que le curseur est en dehors du rectangle de la map (mais encore sur le
# canvas, dans la zone grise autour). On veut aussi l'éteindre dans ce cas.
#
# Enfin, bug lié aux FILTRES : quand un type est désactivé dans le filtre du
# SelectTool (ex: "Objects" décoché), HighlightThingAtPoint ne pose plus de
# highlight sur ce type, MAIS un highlighted périmé du même type (posé avant que
# le filtre soit coupé) n'est pas nettoyé. Or DD sélectionne au clic le
# highlighted courant sans re-tester le filtre : on pouvait donc encore
# sélectionner un objet filtré. De plus, Highlight(h, false) n'efface QUE le
# visuel, pas la référence highlighted — donc même "éteint", le thing restait
# cliquable. On corrige les deux points.
#
# Fix (même principe que Preview Fix) :
#   - On écoute mouse_exited sur le Control du canvas
#     (Master/Editor/VPartition/Panels/HSplit/Content). Godot émet cet event
#     quand la souris passe sur n'importe quel Control au-dessus (panneau,
#     menu, popup) OU quand elle quitte la fenêtre — ce qui couvre ces cas.
#   - On surveille aussi la perte de focus fenêtre (Alt+Tab) en polling.
#   - Chaque frame, on vérifie si la souris (WorldUI.MousePosition) est en
#     dehors du rectangle de la map (World.WorldRect) ; si oui, on éteint le
#     highlight. (On n'utilise pas IsInsideBounds : il a un padding de 512
#     unités, trop large pour "strictement dans la map".)
#   - Chaque frame, on vérifie aussi si le highlighted courant est d'un type
#     (ou d'un calque) filtré, ou s'il est invisible dans l'arbre (calque
#     caché par un mod tiers type Hide Layers, ex. container Portals masqué —
#     le pick de DD ignore la visibilité) ; si oui, on l'éteint.
# Dans tous ces cas, si SelectTool est actif, on éteint le highlight de survol
# via SelectTool.Highlight(highlighted, false) PUIS on remet highlighted à null
# pour qu'il ne reste pas sélectionnable. DD le re-pose tout seul au prochain
# mouvement souris sur le canvas, dans les limites de la map et selon le filtre.

# SelectableTypes -> clé du dictionnaire Filter du SelectTool.
const TYPE_TO_FILTER := {
	1: "Walls",     # Wall
	2: "Portals",   # PortalFree
	3: "Portals",   # PortalWall
	4: "Objects",   # Object
	5: "Paths",     # Pathway
	6: "Lights",    # Light
	7: "Patterns",  # PatternShape
	8: "Roofs",     # Roof
}

var _g
var _content: Control = null
var _watcher = null
var _listener = null
var _was_focused := true
var _connected := false
# Vrai tant que le SelectTool etait en train de tracer une dragbox (isDrawing)
# a la derniere frame ou il etait actif. Sert a detecter un changement d'outil
# EN PLEIN drag (cf. _cleanup_interrupted_drag).
var _select_was_drawing := false
# Assets couverts par la dragbox a la derniere frame de drag. DD les met en
# highlight EN LIVE a chaque frame (SelectThingsInsideBox dans _Update). A
# l'interruption, Disable() les deselectionne mais NE retire PAS leur highlight,
# et comme `selected` est deja vide on ne peut plus les atteindre autrement ->
# on garde leur reference ici pour pouvoir eteindre leur highlight.
var _drag_things := []


func initialize() -> void:
	# Watcher pour le cas "souris hors de la fenêtre de l'OS" : on déclenche
	# aussi le clear sur NOTIFICATION_WM_MOUSE_EXIT par sécurité (certaines
	# configs ne propagent pas mouse_exited au Control dans ce cas précis).
	var script_src = """
extends Node

var owner_mod = null

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_MOUSE_EXIT:
		if owner_mod != null:
			owner_mod._on_window_mouse_exit()
"""
	var script = GDScript.new()
	script.source_code = script_src
	script.reload()
	_watcher = Node.new()
	_watcher.set_script(script)
	_watcher.owner_mod = self
	_watcher.name = "SelectHighlightFixWatcher"
	if _g != null and _g.Editor != null:
		_g.Editor.add_child(_watcher)
	# Listener d'input (phase _input, priorité haute, avant le
	# _on_Content_gui_input de DD) : éteint le highlighted filtré/caché au
	# moment exact du clic (voir _on_input). Complément du polling d'update(),
	# qui perd la course quand un motion et le press arrivent dans la même
	# frame : DD re-pose highlighted à CHAQUE motion pour les things cachés
	# (son HighlightThingAtPoint ignore la visibilité), et son press lit
	# highlighted avant que notre _process ait pu le nettoyer.
	_listener = Node.new()
	_listener.name = "SelectHighlightFixInput"
	var lscript = GDScript.new()
	lscript.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -250\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	lscript.reload()
	_listener.set_script(lscript)
	_listener.handler = self
	if _g != null and _g.World != null:
		_g.World.call_deferred("add_child", _listener)
	print("[SelectHighlightFix] initialized")


# Press/release gauche livrés en phase _input, AVANT le _ContentInput de DD :
# si le highlighted courant est filtré ou caché, on l'éteint ICI pour que le
# press de DD (Select(highlighted)) et l'ajout Shift à la release ne voient
# plus rien. On ne consomme pas l'événement : le clic retombe sur le
# comportement "espace vide" de DD (départ de dragbox), qui est le bon.
func _on_input(event) -> void:
	if not (event is InputEventMouseButton) or event.button_index != BUTTON_LEFT:
		return
	# Alt = alt_deselect : retirer un thing caché de la sélection reste
	# légitime, ne pas lui voler son highlighted.
	if event.alt:
		return
	if _g == null or _g.Editor == null:
		return
	# Lecture LIVE de l'outil actif : le cache _active_tool_name() n'est
	# rafraîchi qu'en _process, or _input est délivré avant (cf. slpf).
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	if _highlight_filtered():
		_clear_highlight()


func update(_delta) -> void:
	_cleanup_interrupted_drag()
	_ensure_content_connected()
	# Perte de focus fenêtre (Alt+Tab, clic sur une autre fenêtre sans
	# mouvement souris déclenchant mouse_exited).
	var focused = OS.is_window_focused()
	if _was_focused and not focused:
		_clear_highlight()
	_was_focused = focused
	if not focused:
		return
	# Curseur hors des limites de la map (ex: asset qui dépasse) : on éteint
	# le highlight même si le curseur est encore au-dessus du canvas.
	if _mouse_outside_map():
		_clear_highlight()
	# Highlighted d'un type/calque filtré : on l'éteint pour qu'il ne reste
	# pas sélectionnable malgré le filtre.
	elif _highlight_filtered():
		_clear_highlight()


# Bug vanilla : si on change d'outil (ex: raccourci clavier) PENDANT une dragbox
# de selection, avant de relacher le clic, DD appelle SelectTool.Disable() —
# lequel fait DeselectAll/Highlight(false)/EnableTransformBox(false)/isDrawing=
# false, MAIS jamais selectionBox.SetRect(null). Le rectangle bleu de drag reste
# donc dessine dans les autres outils (et selon l'enchainement, une selection
# fantome peut subsister). On detecte la transition "on quitte le SelectTool
# alors qu'un drag etait en cours" et on force un nettoyage complet.
func _cleanup_interrupted_drag() -> void:
	if _g == null or _g.Editor == null:
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null:
		_select_was_drawing = false
		return
	# Lecture LIVE (pas le cache _active_tool_name) : la detection doit etre
	# exacte a la frame pres. Avec le retard d'une frame du cache, Disable()
	# aurait deja remis isDrawing=false quand on lirait encore "SelectTool", et
	# on raterait l'interruption. Un test par frame ici est negligeable.
	var in_select = str(_g.Editor.ActiveToolName) == "SelectTool"
	if in_select:
		var drawing = bool(st.get("isDrawing"))
		_select_was_drawing = drawing
		if drawing:
			# Aperçu live : on memorise les assets actuellement dans la box (ils
			# sont highlightes par DD). Copie GDScript pour survivre au vidage de
			# `selected` par Disable().
			var sel = st.get("Selected")
			_drag_things = sel.duplicate() if sel is Array else []
		else:
			_drag_things = []
		return
	# On n'est plus dans le SelectTool : si un drag etait en cours quand on l'a
	# quitte, on nettoie (une seule fois).
	if _select_was_drawing:
		_select_was_drawing = false
		_force_clear_select_state(st)
		# Eteindre le highlight des assets de l'aperçu (Disable ne le fait pas).
		for thing in _drag_things:
			_dehighlight_thing(thing)
		_drag_things = []


func _force_clear_select_state(st) -> void:
	# Idempotent : reproduit le nettoyage de Disable() ET efface le rectangle de
	# drag que DD oublie (selectionBox.SetRect(null)).
	if st.has_method("DeselectAll"):
		st.DeselectAll()
	var h = st.get("highlighted")
	if h != null and typeof(h) == TYPE_OBJECT and is_instance_valid(h) and st.has_method("Highlight"):
		st.Highlight(h, false)
	st.set("highlighted", null)
	st.set("isDrawing", false)
	if st.has_method("EnableTransformBox"):
		st.EnableTransformBox(false)
	# Efface le rectangle bleu : SetRect(null) est la methode qu'utilise DD au
	# relachement (SelectTool.cs), donc sure.
	var sb = st.get("selectionBox")
	if sb != null and is_instance_valid(sb) and sb.has_method("SetRect"):
		sb.SetRect(null)


# Eteint le highlight (isHighlighted) d'un asset. Selon le type, DD porte le
# highlight a des endroits differents ; PatternShape (et Pathway) exposent un
# Highlight() direct qui NE touche PAS leur contour pointille — celui-ci est
# porte par un widget separe. On ne s'arrete donc PAS au premier chemin : on
# eteint TOUTES les voies possibles (idempotent) pour couvrir tous les types.
#   - Highlight() direct        : Prop / Portal / Roof
#   - GetWidget().Highlight()   : Wall / Light / PatternShape
#   - widget natif .Highlight() : propriete .Widget OU enfant Line2D (contour
#     pointille des patterns/paths), meme detection que overlay_tool.
func _dehighlight_thing(thing) -> void:
	if thing == null or not is_instance_valid(thing):
		return
	if thing.has_method("Highlight"):
		thing.Highlight(false)
	if thing.has_method("GetWidget"):
		var gw = thing.GetWidget()
		if gw != null and is_instance_valid(gw) and gw.has_method("Highlight"):
			gw.Highlight(false)
	var w = _native_widget_of(thing)
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		w.Highlight(false)


# Widget natif d'un Thing : propriete .Widget si presente, sinon l'enfant Line2D
# exposant Highlight() ET Select() (WallWidget/PathwayWidget/PatternShapeWidget).
# On ne suppose pas sa position (d'autres mods inserent des Line2D avant lui).
# Meme logique que overlay_tool._get_native_widget.
func _native_widget_of(node):
	if node == null or not is_instance_valid(node):
		return null
	var w = node.get("Widget")
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		return w
	for c in node.get_children():
		if c is Line2D and c.has_method("Highlight") and c.has_method("Select"):
			return c
	return null


func _ensure_content_connected() -> void:
	if _connected:
		return
	if _content == null or not is_instance_valid(_content):
		if _g == null or _g.World == null:
			return
		var node = _g.World.get_tree().root.get_node_or_null(
			"Master/Editor/VPartition/Panels/HSplit/Content")
		if node != null and node is Control:
			_content = node
	if _content != null and is_instance_valid(_content):
		if not _content.is_connected("mouse_exited", self, "_on_content_mouse_exited"):
			_content.connect("mouse_exited", self, "_on_content_mouse_exited")
		_connected = true


func _on_content_mouse_exited() -> void:
	_clear_highlight()


func _on_window_mouse_exit() -> void:
	_clear_highlight()


func _mouse_outside_map() -> bool:
	if _g == null or _g.Editor == null or _g.World == null or _g.WorldUI == null:
		return false
	if _active_tool_name() != "SelectTool":
		return false
	var rect = _g.World.WorldRect
	if typeof(rect) != TYPE_RECT2:
		return false
	var pos = _g.WorldUI.MousePosition
	return not rect.has_point(pos)


func _highlight_filtered() -> bool:
	if _g == null or _g.Editor == null:
		return false
	if _active_tool_name() != "SelectTool":
		return false
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return false
	var h = st.get("highlighted")
	if h == null:
		return false
	if typeof(h) == TYPE_OBJECT and not is_instance_valid(h):
		return false
	# Filtre par type.
	var t = h.get("Type")
	if typeof(t) == TYPE_INT and TYPE_TO_FILTER.has(t):
		var filter = st.get("Filter")
		if typeof(filter) == TYPE_DICTIONARY:
			var key = TYPE_TO_FILTER[t]
			if filter.has(key) and filter[key] == false:
				return true
	var thing = h.get("Thing")
	if thing != null and is_instance_valid(thing):
		# Visibilité : un thing caché (calque masqué par un mod tiers type
		# Hide Layers) ne doit pas rester cliquable via le highlighted que
		# DD pose quand même (son pick ignore la visibilité).
		if thing is CanvasItem and not thing.is_visible_in_tree():
			return true
		# Filtre par calque.
		if st.has_method("IsObjectLayerFiltered") and st.IsObjectLayerFiltered(thing):
			return true
	return false


func _clear_highlight() -> void:
	if _g == null or _g.Editor == null:
		return
	if _active_tool_name() != "SelectTool":
		return
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return
	# highlighted peut crasher sur certains types (lights) : on passe par get()
	# qui retourne juste la référence sans toucher aux propriétés à risque.
	var h = st.get("highlighted")
	if h == null:
		return
	if typeof(h) == TYPE_OBJECT and not is_instance_valid(h):
		# Référence morte : on remet à null par sécurité.
		st.set("highlighted", null)
		return
	if st.has_method("Highlight"):
		st.Highlight(h, false)
	# Highlight(h, false) n'efface que le visuel : tant que highlighted pointe
	# sur le thing, un clic le sélectionne (même filtré). On force donc null ;
	# DD le re-pose au prochain mouvement souris si le filtre l'autorise.
	st.set("highlighted", null)


# ── Per-frame cached editor state (published by Main.gd, Engine metadata) ──
# Reading native/C# editor properties marshals a fresh GDScript object across
# the interop boundary on EVERY access; with dozens of submods polling every
# frame this is a steady allocation stream (background commit-charge growth).
# Main.gd reads ActiveToolName once per frame and publishes it; we read the
# shared copy here. THREE rules, each learned from a measured failure:
#   1. PRECONDITION: never serve a cached name when this mod's _g.Editor is
#      unreachable — callers would reach into editor objects that are unsafe
#      to touch (native access violation c0000005 on tool switch / map churn).
#   2. MEMOIZATION: the _g.Editor null-check itself marshals a wrapper per
#      access; doing it per call cost as much as the problem this cache
#      solves (+0.037 MB/s, +12% main CPU over 600 s). One read per mod per
#      process tick keeps the safety signal at ~1/10th the volume.
#   3. FORCED COPY: never hand out a COW reference to the String stored in
#      the shared Dictionary — hence "%s" % v.
var _uu_ed_frame := -1
var _uu_ed_ok := false


func _active_tool_name() -> String:
	if not _uu_editor_reachable():
		return ""
	if Engine.has_meta("_uu_editor_state"):
		var s = Engine.get_meta("_uu_editor_state")
		if s is Dictionary:
			var v = s.get("active_tool_name")
			if v is String:
				return "%s" % v
	return str(_g.Editor.ActiveToolName)


func _uu_editor_reachable() -> bool:
	var f = Engine.get_idle_frames()
	if f == _uu_ed_frame:
		return _uu_ed_ok
	_uu_ed_frame = f
	_uu_ed_ok = _g != null and _g.Editor != null
	return _uu_ed_ok
