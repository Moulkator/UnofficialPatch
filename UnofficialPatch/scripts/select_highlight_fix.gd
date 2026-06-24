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
#     (ou d'un calque) filtré ; si oui, on l'éteint.
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
var _was_focused := true
var _connected := false


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
	print("[SelectHighlightFix] initialized")


func update(_delta) -> void:
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
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return false
	var rect = _g.World.WorldRect
	if typeof(rect) != TYPE_RECT2:
		return false
	var pos = _g.WorldUI.MousePosition
	return not rect.has_point(pos)


func _highlight_filtered() -> bool:
	if _g == null or _g.Editor == null:
		return false
	if str(_g.Editor.ActiveToolName) != "SelectTool":
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
	# Filtre par calque (objets seulement).
	var thing = h.get("Thing")
	if thing != null and is_instance_valid(thing) and st.has_method("IsObjectLayerFiltered"):
		if st.IsObjectLayerFiltered(thing):
			return true
	return false


func _clear_highlight() -> void:
	if _g == null or _g.Editor == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
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
