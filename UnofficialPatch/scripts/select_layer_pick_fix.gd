# select_layer_pick_fix.gd
# Bug vanilla : deux objets A et B sur le MEME calque qui se recouvrent (B dans
# l'emprise de A, ex: un livre sur une table). Apres avoir change le calque de A
# puis l'avoir rebascule sur son calque d'origine, B n'est plus jamais detecte
# au survol ni selectionnable : DD pioche toujours A, alors que B est dessine
# DEVANT (z egal, B est l'enfant le plus tardif).
#
# Cause (confirmee par diagnostic) : DD departage le pick via une liste interne
# (PAS RawSelectables, qui ne contient que la SELECTION). Le changement de calque
# y deplace A, qui se met a gagner le pick face a B. Cette liste n'est ni lisible
# ni reordonnable depuis un mod, et on ne peut pas obtenir le Selectable d'un
# objet non-selectionne pour rediriger highlighted.
#
# Fix : on recalcule nous-memes l'objet REELLEMENT au sommet sous le curseur
# (pixel-perfect, ordre de dessin = z effectif puis index d'enfant).
#  - Au survol : si DD a highlighte un objet plus bas, on eteint sa box trompeuse
#    et on publie le bon objet dans ModMapData["_slpf_true_top"] (overlay_tool le
#    teinte s'il est actif).
#  - Au clic gauche : on selectionne nous-memes le bon objet (en respectant Shift)
#    et on consomme l'event pour que DD ne selectionne pas celui du dessous.
# Intervention uniquement quand DD pointe deja un objet (rien de plus prioritaire
# au-dessus) et qu'un autre objet est dessine au-dessus : sinon no-op total.

var _g
var ui_util = null   # injecte par Main.gd ; garde "curseur au-dessus de l'UI"
var _listener = null
var _destroyed = false
var _last_mouse = Vector2.INF
var true_top = null   # objet correct sous le curseur (ou null) — expose

# Repli : false = ne pas consommer le clic (drag en un geste). Si le clic
# re-selectionne l'objet du dessous chez toi, passe a true (selection fiable,
# drag en deux temps).
const CONSUME_CLICK := false


func initialize() -> void:
	_install_input_listener()
	print("[SelectLayerPickFix] initialized")


func cleanup() -> void:
	_destroyed = true
	_publish_true_top(null)
	if _listener != null and is_instance_valid(_listener):
		_listener.handler = null
		_listener.queue_free()
	_listener = null


func update(_delta) -> void:
	if _g == null or _g.Editor == null or _g.WorldUI == null:
		_publish_true_top(null)
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		_publish_true_top(null)
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null:
		_publish_true_top(null)
		return
	var mouse = _g.WorldUI.get("MousePosition")
	if typeof(mouse) != TYPE_VECTOR2:
		_publish_true_top(null)
		return
	if mouse == _last_mouse:
		return
	_last_mouse = mouse

	# Curseur au-dessus de l'UI (panneaux, barre d'outils, popups) : l'objet
	# calcule serait sous un panneau -> ne rien corriger ni publier.
	if _is_over_ui():
		_publish_true_top(null)
		return

	var corrected = _compute_correction(st, mouse)
	_publish_true_top(corrected)
	# Eteint la box que DD a posee sur l'objet du dessous (sinon highlight trompeur
	# sur A). overlay_tool, s'il est actif, teintera _slpf_true_top a la place.
	if corrected != null:
		var h = st.get("highlighted")
		if h != null and typeof(h) == TYPE_OBJECT and is_instance_valid(h) and st.has_method("Highlight"):
			st.Highlight(h, false)


# Renvoie le vrai objet au sommet sous le curseur s'il faut le selectionner a la
# place de ce que DD viserait, sinon null. Independant de highlighted : gere
# aussi le cas ou un objet PLUS BAS est deja selectionne (DD montre alors sa
# transform box et ne highlight plus rien au survol de l'objet du dessus).
func _compute_correction(st, mouse):
	if bool(st.get("isDrawing")):
		return null
	# Filtre de TYPE : si "Objects" est decoche, ce mod (qui ne pioche que des
	# objets) ne doit ni corriger le survol ni selectionner au clic. Sans ce
	# garde, on contournait le filtre et on pouvait quand meme selectionner un
	# objet. (Le filtre de CALQUE est gere plus bas via IsObjectLayerFiltered.)
	var filter = st.get("Filter")
	if typeof(filter) == TYPE_DICTIONARY and filter.has("Objects") and filter["Objects"] == false:
		return null
	if _g.World == null or not is_instance_valid(_g.World):
		return null
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	var top = _topmost_object_at(level, mouse, st)
	if top == null:
		return null
	# Objet du sommet deja selectionne -> on laisse DD le manipuler (drag/resize
	# via sa transform box), pas de re-selection.
	var selected = st.get("Selected")
	if selected is Array and selected.has(top):
		return null
	# Ce que DD viserait via son survol.
	var h = st.get("highlighted")
	if h != null and typeof(h) == TYPE_OBJECT and is_instance_valid(h):
		var ht = int(h.get("Type"))
		if ht != 4:
			# DD vise un non-objet (mur, portail, lumiere, pattern, toit…) qui est
			# prioritaire a cet endroit -> ne pas detourner vers un objet.
			return null
		var cur = h.get("Thing")
		if cur == top:
			return null   # DD vise deja le bon objet
	# h == null (objet du dessous selectionne -> box, ou survol non encore pose),
	# ou DD vise un objet plus bas : on corrige vers le vrai sommet.
	return top


func _publish_true_top(v) -> void:
	true_top = v
	if _g != null and _g.ModMapData is Dictionary:
		if v == null:
			if _g.ModMapData.has("_slpf_true_top"):
				_g.ModMapData.erase("_slpf_true_top")
		else:
			_g.ModMapData["_slpf_true_top"] = v


func _topmost_object_at(level, mouse, st):
	var objs = level.get("Objects")
	if objs == null:
		return null
	var best = null
	var best_z = -2147483648
	var best_idx = -1
	for child in objs.get_children():
		if child == null or not is_instance_valid(child) or not (child is CanvasItem):
			continue
		if st.has_method("IsObjectLayerFiltered") and st.IsObjectLayerFiltered(child):
			continue
		var spr = child.get("Sprite")
		if spr == null or not is_instance_valid(spr) or not spr.has_method("is_pixel_opaque"):
			continue
		var lp = spr.to_local(mouse)
		if spr.has_method("get_rect") and not spr.get_rect().has_point(lp):
			continue
		if not spr.is_pixel_opaque(lp):
			continue
		var z = _effective_z(child)
		var idx = child.get_index()
		if z > best_z or (z == best_z and idx > best_idx):
			best = child
			best_z = z
			best_idx = idx
	return best


func _effective_z(ci) -> int:
	var z = 0
	var n = ci
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z


# ── Clic : selectionne nous-memes le bon objet ────────────────────────────

func _install_input_listener() -> void:
	_listener = Node.new()
	_listener.name = "SelectLayerPickFixInput"
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -250\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_listener.set_script(script)
	_listener.handler = self
	if _g != null and _g.World != null:
		_g.World.call_deferred("add_child", _listener)


func _on_input(event) -> void:
	if _destroyed:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_LEFT):
		return
	# On laisse passer Alt (alt_deselect) et Ctrl pour ne pas voler ces gestes.
	if event.alt or event.control:
		return
	# Ne pas voler le clic quand le curseur est au-dessus de l'UI : panneaux
	# (barre d'outils, panneau gauche, bibliotheque droite, floatbar, menu) ET
	# popups/dialogues. Sinon un clic sur un item d'UI retombe, en coordonnees-
	# monde, sur l'asset situe dessous -> on rebasculait la selection dessus.
	if _is_over_ui():
		return
	if _g == null or _g.Editor == null or _g.WorldUI == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null:
		return
	var mouse = _g.WorldUI.get("MousePosition")
	if typeof(mouse) != TYPE_VECTOR2:
		return
	var top = _compute_correction(st, mouse)
	if top == null or not is_instance_valid(top):
		return
	if not st.has_method("SelectThing"):
		return
	# On COMMIT la selection de B : ainsi DD le voit selectionne, avec sa transform
	# box sous le curseur. C'est necessaire car dans le cas du round-trip de calque
	# la pioche interne de DD est cassee (il re-pioche l'objet du dessous au press
	# et ignore highlighted) ; en revanche, presser la box d'un objet DEJA
	# selectionne le drague, quelle que soit cette pioche.
	# Non-shift => on remplace la selection (comportement normal de DD).
	if not event.shift and st.has_method("DeselectAll"):
		st.DeselectAll()
	var sel = st.SelectThing(top, true)
	if sel != null and is_instance_valid(sel):
		st.set("highlighted", sel)
	if st.has_method("EnableTransformBox"):
		st.EnableTransformBox(true)
	# Affiche les controles de l'objet dans le panneau SelectTool.
	var toolset = _g.Editor.get("Toolset")
	if toolset != null and toolset.has_method("GetToolPanel"):
		var tp = toolset.GetToolPanel("SelectTool")
		if tp != null and tp.has_method("OnSelect"):
			tp.OnSelect(4)   # 4 = Object
	# On NE consomme PAS l'event : DD traite alors le press sur B (selectionne, box
	# sous le curseur) et peut demarrer un drag en un seul geste.
	if CONSUME_CLICK and _listener != null and _listener.get_tree() != null:
		_listener.get_tree().set_input_as_handled()


# Vrai si le curseur est au-dessus de l'UI (panneaux + popups). Utilise le garde
# partagé ui_util quand il est injecté (detecte aussi les panneaux), sinon repli
# sur la detection des popups uniquement.
func _is_over_ui() -> bool:
	if ui_util != null and _listener != null and is_instance_valid(_listener):
		return ui_util.is_mouse_over_ui(_listener)
	return _any_popup_open()


# Vrai si un popup/menu (PopupMenu, WindowDialog…) est actuellement visible.
# Recherche bornée en profondeur depuis la racine (pas cher, appelé seulement
# sur un appui clic gauche).
func _any_popup_open() -> bool:
	if _listener == null or not is_instance_valid(_listener):
		return false
	var tree = _listener.get_tree()
	if tree == null or tree.root == null:
		return false
	return _has_visible_popup(tree.root, 0)


func _has_visible_popup(node: Node, depth: int) -> bool:
	if depth > 6 or not is_instance_valid(node):
		return false
	if (node is Popup or node is WindowDialog) and node.visible and node.is_visible_in_tree():
		return true
	for child in node.get_children():
		if _has_visible_popup(child, depth + 1):
			return true
	return false
