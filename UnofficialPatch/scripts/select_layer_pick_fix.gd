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
#
# Cas supplementaire (bug vanilla) : HighlightThingAtPoint teste les categories
# dans un ordre FIXE (Lights > Roofs > freestanding Portals > Objects > ...).
# Un freestanding portal gagne donc TOUJOURS le pick face a un asset, meme si
# l'asset est dessine au-dessus -> l'asset devient inselectionnable. On corrige
# aussi ce cas : si DD vise un PortalFree et qu'un objet opaque sous le curseur
# est dessine AU-DESSUS du portail (z effectif puis ordre d'arbre), on redirige
# vers l'objet. Si le portail est au-dessus, on ne touche a rien.
#
# Troisieme cas (clic vs drag sur la zone de la transform box) : quand un objet
# A est selectionne, sa transform box capture TOUT press dans sa zone (corners,
# interieur, anneau de rotation) via GetTransformMode() ; un objet B highlighte
# sous le curseur ne peut alors jamais etre selectionne au clic. On desambigue :
#   - press dans la zone avec B highlighte -> on retient le press (consomme) ;
#   - la souris bouge (> seuil) bouton enfonce -> DRAG : on rejoue le press vers
#     SelectTool._ContentInput -> comportement natif (handles/deplacement de A) ;
#   - relache sans mouvement -> CLIC : on selectionne B.

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

# ── Clic-vs-drag sur la zone de la transform box (hcs = handle click select) ──
# Seuil de drag en pixels ECRAN (independant du zoom).
const HCS_DRAG_THRESHOLD_PX := 5.0
var _hcs_pending := false        # press retenu, en attente clic-vs-drag
var _hcs_press_event = null      # copie du press consomme (rejoue si drag)
var _hcs_press_pos := Vector2.ZERO   # position ecran du press
var _hcs_target = null           # weakref vers la cible B highlightee au press
var _hcs_type := 4               # type Selectable de B (2 PortalFree, 3 PortalWall, 4 Object)
# Press rejoue vers _ContentInput : la relache reelle doit etre rejouee par le
# MEME canal (le routeur d'input de DD ne livre pas la relache d'un press qu'il
# n'a jamais vu) puis consommee.
var _hcs_forwarded := false
# Prop sur lequel ON a pose la box de highlight native (weakref), pour
# l'eteindre proprement quand la correction cesse.
var _hl_prop = null
# Watchdog "type statique selectionne" : tant qu'un PortalWall est la seule
# selection, un code tiers (reagissant au changement de selection) re-affiche
# la box -> rect 1x1. On la re-coupe a chaque frame tant que la selection est
# ce portail. weakref vers le portail surveille, null = watchdog inactif.
var _static_watch = null
var _static_watch_logged := false
# Portail fantome courant (highlighte par DD mais couvert par un asset opaque),
# publie dans ModMapData pour que transform_box_fix ignore les bascules vers lui.
var _phantom_logged := false


func initialize() -> void:
	_install_input_listener()
	print("[SelectLayerPickFix] initialized")


func cleanup() -> void:
	_destroyed = true
	_hcs_reset()
	_hcs_forwarded = false
	_set_native_highlight(null, null)
	_static_watch = null
	_publish_phantom(null)
	_publish_true_top(null)
	if _listener != null and is_instance_valid(_listener):
		_listener.handler = null
		_listener.queue_free()
	_listener = null


func update(_delta) -> void:
	if _g == null or _g.Editor == null or _g.WorldUI == null:
		_publish_true_top(null)
		return
	if _active_tool_name() != "SelectTool":
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
	# Le watchdog doit tourner CHAQUE frame (le re-affichage tiers ne depend
	# pas d'un mouvement souris), donc avant le cache de position.
	_static_box_watchdog(st)
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
	else:
		_clear_phantom_portal_highlight(st, mouse)
	# Box de highlight NATIVE sur la vraie cible : DD ne peut pas highlighter un
	# objet sans Selectable, mais Prop.Highlight(bool) est appelable directement.
	_set_native_highlight(corrected, st)


# Highlight FANTOME : le pick d'un portail est un simple Rect genereux, DD le
# highlighte donc meme quand un asset pixel-opaque le couvre entierement sous
# le curseur (hoverbox visible a travers l'asset). Ce `highlighted` mensonger
# est ensuite consomme par TOUT le monde : le press natif de DD (Select du
# portail invisible au re-clic sur l'asset selectionne), transform_box_fix
# (bascule au release + box 1x1 sur PortalWall), etc. On neutralise le pick a
# la source : hoverbox eteinte ET highlighted remis a null. DD re-pioche a
# chaque mouvement souris ; si le curseur atteint une zone ou le portail est
# reellement visible, le pick redevient legitime et on ne touche a rien.
# Eteint le highlighted courant si son Thing est invisible dans l'arbre
# (calque cache). Meme mecanique que la neutralisation des portails fantomes :
# Highlight(false) pour le visuel + highlighted=null pour que le press de DD
# ne voie plus rien (le clic retombe sur "espace vide" -> depart de dragbox).
func _clear_hidden_highlight() -> void:
	if _g == null or _g.Editor == null:
		return
	# Lecture LIVE de l'outil actif (on est en phase _input, avant _process).
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or not is_instance_valid(st):
		return
	var h = st.get("highlighted")
	if h == null or typeof(h) != TYPE_OBJECT or not is_instance_valid(h):
		return
	var thing = h.get("Thing")
	if thing == null or typeof(thing) != TYPE_OBJECT or not is_instance_valid(thing):
		return
	if not (thing is CanvasItem) or thing.is_visible_in_tree():
		return
	if st.has_method("Highlight"):
		st.Highlight(h, false)
	st.set("highlighted", null)


func _clear_phantom_portal_highlight(st, mouse) -> void:
	var h = st.get("highlighted")
	if h == null or typeof(h) != TYPE_OBJECT or not is_instance_valid(h):
		_publish_phantom(null)
		return
	var ht = int(h.get("Type"))
	if ht != 2 and ht != 3:
		_publish_phantom(null)
		return
	var portal = h.get("Thing")
	if portal == null or typeof(portal) != TYPE_OBJECT or not is_instance_valid(portal):
		return
	# Filtre Objects OFF : les objets ne sont pas selectionnables, piocher le
	# portail a travers l'asset est alors le comportement voulu -> ne pas gener.
	var filter = st.get("Filter")
	if typeof(filter) == TYPE_DICTIONARY and filter.has("Objects") and filter["Objects"] == false:
		_publish_phantom(null)
		return
	if _g.World == null or not is_instance_valid(_g.World):
		_publish_phantom(null)
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		_publish_phantom(null)
		return
	var top = _topmost_object_at(level, mouse, st)
	if top == null:
		_publish_phantom(null)
		return
	# Portail reellement visible au-dessus du sommet opaque -> pick legitime.
	if _renders_above(portal, top) and _portal_pixel_opaque_at(portal, mouse):
		_publish_phantom(null)
		return
	if st.has_method("Highlight"):
		st.Highlight(h, false)
	st.set("highlighted", null)
	_publish_phantom(portal)
	if not _phantom_logged:
		_phantom_logged = true
		print("[SLPF-DIAG] phantom portal neutralise: z_portal=", _effective_z(portal), " z_top=", _effective_z(top), " portal_above=", _renders_above(portal, top), " portal_opaque=", _portal_pixel_opaque_at(portal, mouse))


# Tant qu'un PortalWall selectionne via notre commit reste la seule selection,
# re-couper la box si un tiers l'a re-affichee (elle est degeneree en 1x1 pour
# ce type). Desarme des que la selection change. Cout : un test bool par frame
# quand arme ; lecture de Selected uniquement si la box est redevenue visible.
func _static_box_watchdog(st) -> void:
	if _static_watch == null:
		return
	var portal = _static_watch.get_ref()
	if portal == null or not is_instance_valid(portal):
		_static_watch = null
		return
	var tb = st.get("transformBox")
	if tb == null or typeof(tb) != TYPE_OBJECT or not is_instance_valid(tb):
		_static_watch = null
		return
	if not tb.visible:
		return
	# Box redevenue visible : la selection est-elle toujours ce portail seul ?
	var selected = st.get("Selected")
	if not (selected is Array) or selected.size() != 1 or selected[0] != portal:
		_static_watch = null
		return
	if not _static_watch_logged:
		_static_watch_logged = true
		print("[SLPF-DIAG] transform box re-affichee sur PortalWall selectionne -> re-coupee (watchdog)")
	if st.has_method("EnableTransformBox"):
		st.EnableTransformBox(false)


# Pose/retire la box de highlight native (Prop.Highlight) sur la cible corrigee.
# Ne retire PAS la box d'un prop que DD highlighte lui-meme a cet instant (cas :
# le curseur vient de passer de la zone corrigee a l'objet nu -> DD a repris la
# main sur le meme prop, l'eteindre tuerait sa box jusqu'au prochain mouvement).
func _set_native_highlight(target, st) -> void:
	# Mode overlay (teinte des objets active) : c'est la teinte qui sert de
	# highlight, ne jamais poser la box native (elle flashait une frame).
	if target != null and _g != null and _g.ModMapData is Dictionary \
			and _g.ModMapData.get("_ov_obj_hover_on", false):
		target = null
	var prev = null
	if _hl_prop != null:
		prev = _hl_prop.get_ref()
	if prev == target:
		return
	if prev != null and is_instance_valid(prev) and prev.has_method("Highlight"):
		var dd_owns = false
		if st != null:
			var h = st.get("highlighted")
			if h != null and typeof(h) == TYPE_OBJECT and is_instance_valid(h) and h.get("Thing") == prev:
				dd_owns = true
		if not dd_owns:
			prev.Highlight(false)
	_hl_prop = null
	if target != null and is_instance_valid(target) and target.has_method("Highlight"):
		target.Highlight(true)
		_hl_prop = weakref(target)


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
		if ht == 2:
			# DD vise un freestanding portal (PortalFree). Son pick est teste AVANT
			# les objets, donc il gagne meme quand un asset est dessine au-dessus
			# (bug vanilla). Regle "on pioche ce qu'on voit" : l'objet du sommet est
			# pixel-opaque sous le curseur ; on garde le portail SEULEMENT s'il est
			# rendu au-dessus ET reellement visible (pixel opaque) a cet endroit.
			# (Le pick du portail est un simple Rect genereux : il gagne souvent la
			# ou son sprite est transparent, voire hors sprite.)
			var portal = h.get("Thing")
			if portal == null or typeof(portal) != TYPE_OBJECT or not is_instance_valid(portal):
				return null
			if _renders_above(portal, top) and _portal_pixel_opaque_at(portal, mouse):
				return null
		elif ht != 4:
			# DD vise un autre non-objet (mur, portail sur mur, lumiere, pattern,
			# toit…) qui est prioritaire a cet endroit -> ne pas detourner.
			return null
		var cur = h.get("Thing")
		if cur == top:
			return null   # DD vise deja le bon objet
	# h == null (objet du dessous selectionne -> box, ou survol non encore pose),
	# ou DD vise un objet plus bas : on corrige vers le vrai sommet.
	return top


# Vrai si le sprite du portail est pixel-opaque a la position monde donnee.
# Sprite/texture absents ou point hors rect -> false (le portail n'y est pas
# visible, l'objet dessous doit gagner le pick).
func _portal_pixel_opaque_at(portal, mouse) -> bool:
	var spr = portal.get("Sprite")
	if spr == null or typeof(spr) != TYPE_OBJECT or not is_instance_valid(spr):
		return false
	if not spr.has_method("is_pixel_opaque"):
		return false
	if spr.get("texture") == null:
		return false
	var lp = spr.to_local(mouse)
	if spr.has_method("get_rect") and not spr.get_rect().has_point(lp):
		return false
	return spr.is_pixel_opaque(lp)


# Publie/efface le portail fantome courant pour les autres mods
# (transform_box_fix consulte _slpf_phantom_portal avant de basculer).
func _publish_phantom(portal) -> void:
	if _g == null or not (_g.ModMapData is Dictionary):
		return
	if portal == null:
		if _g.ModMapData.has("_slpf_phantom_portal"):
			_g.ModMapData.erase("_slpf_phantom_portal")
	else:
		_g.ModMapData["_slpf_phantom_portal"] = portal


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


# Vrai si `a` est dessine au-dessus de `b`. Regle de rendu Godot : z effectif
# d'abord, puis ordre d'arbre en profondeur (le plus tardif gagne). `a` et `b`
# vivent dans des conteneurs differents (Objects vs Portals) : on compare donc
# les chemins d'indices depuis la racine, pas seulement get_index().
func _renders_above(a, b) -> bool:
	var za = _effective_z(a)
	var zb = _effective_z(b)
	if za != zb:
		return za > zb
	var pa = _path_indices(a)
	var pb = _path_indices(b)
	var n = int(min(pa.size(), pb.size()))
	for i in range(n):
		if pa[i] != pb[i]:
			return pa[i] > pb[i]
	return pa.size() > pb.size()


func _path_indices(node) -> Array:
	var out = []
	var n = node
	while n != null and n.get_parent() != null:
		out.push_front(n.get_index())
		n = n.get_parent()
	return out


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
	# ── Neutralisation pre-press des things CACHES ─────────────────────────
	# DD pose highlighted meme sur un thing invisible (HighlightThingAtPoint
	# ignore la visibilite) et son press fait Select(highlighted) : un wall ou
	# un portail freestanding d'un calque cache par un mod tiers (Hide Layers,
	# container Walls/Portals invisible) restait donc cliquable, avec bascule
	# du panneau et transform box. On eteint ici, en phase _input (avant le
	# gui_input de DD), tout highlighted dont le Thing n'est pas visible dans
	# l'arbre. Couvre press ET release (ajout Shift a la relache). Alt est
	# laisse passer : retirer de la selection un thing cache reste legitime.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.alt:
		_clear_hidden_highlight()
	# Press rejoue vers _ContentInput : rejouer aussi la relache reelle par le
	# meme canal, sinon DD reste en mode transform (il faut re-cliquer pour
	# valider). On consomme l'originale pour ne pas la livrer deux fois.
	if _hcs_forwarded and event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		_hcs_forwarded = false
		if _g != null and _g.Editor != null and str(_g.Editor.ActiveToolName) == "SelectTool":
			var fst = _g.Editor.Tools.get("SelectTool")
			if fst != null and fst.has_method("_ContentInput"):
				fst.call("_ContentInput", event)
				if _listener != null and _listener.get_tree() != null:
					_listener.get_tree().set_input_as_handled()
		return
	# Press retenu : on attend de savoir si c'est un clic ou un drag.
	if _hcs_pending:
		if event is InputEventMouseMotion:
			_hcs_on_motion(event)
			return
		if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
			_hcs_on_release(event)
			return
		# Tout autre event (clavier, molette, autre bouton) passe tel quel.
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
	# IMPORTANT : lecture LIVE de l'outil actif, PAS le cache _active_tool_name().
	# Le cache n'est rafraichi qu'une fois par frame (Main.gd/_process) alors que
	# _input est delivre AVANT _process : au 1er clic suivant un changement d'outil,
	# le cache peut encore dire "SelectTool" alors qu'on est deja dans l'ObjectTool
	# -> on selectionnait un objet et on activait la transform box HORS SelectTool.
	# Un clic est un evenement rare : la lecture directe ne coute rien ici et doit
	# rester exacte. Ne pas "optimiser" ceci vers le cache.
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null:
		return
	var mouse = _g.WorldUI.get("MousePosition")
	if typeof(mouse) != TYPE_VECTOR2:
		return
	# Neutralisation du highlight fantome AU PRESS (phase input, avant le
	# _ContentInput de DD). Le clearing du survol tourne en _process : une
	# micro-motion dans la MEME frame que le press re-highlighte le portail
	# via DD (phase input) apres notre dernier clearing -> le press natif
	# selectionnait quand meme le portail invisible. Ici on re-nettoie juste
	# avant que DD ne traite le press.
	_clear_phantom_portal_highlight(st, mouse)
	var top = _compute_correction(st, mouse)
	if top != null and is_instance_valid(top):
		if not st.has_method("SelectThing"):
			return
		# On COMMIT la selection de B : ainsi DD le voit selectionne, avec sa
		# transform box sous le curseur. C'est necessaire car dans le cas du
		# round-trip de calque la pioche interne de DD est cassee (il re-pioche
		# l'objet du dessous au press et ignore highlighted) ; en revanche,
		# presser la box d'un objet DEJA selectionne le drague, quelle que soit
		# cette pioche.
		# Non-shift => on remplace la selection (comportement normal de DD).
		_commit_selection(st, top, 4, not event.shift)
		# On NE consomme PAS l'event : DD traite alors le press sur B
		# (selectionne, box sous le curseur) et peut demarrer un drag en un
		# seul geste.
		if CONSUME_CLICK and _listener != null and _listener.get_tree() != null:
			_listener.get_tree().set_input_as_handled()
		return
	# Pas de correction de pioche : tente l'interception clic-vs-drag sur la
	# zone de la transform box (press qui serait sinon avale par les handles).
	_hcs_try_intercept(event, st, mouse)


# Commit d'une selection d'objet cote DD : selection + highlighted + transform
# box. Utilise UNIQUEMENT par la correction de pioche au press (objets, type 4) :
# DD traite ensuite le press lui-meme (box sous le curseur -> drag possible) et
# son propre epilogue de release invoque OnSelect (panneau, boutons, hooks).
func _commit_selection(st, thing, sel_type: int, replace: bool) -> void:
	if not st.has_method("SelectThing"):
		return
	if replace and st.has_method("DeselectAll"):
		st.DeselectAll()
	var sel = st.SelectThing(thing, true)
	if sel != null and is_instance_valid(sel):
		st.set("highlighted", sel)
	if sel_type != 3 and st.has_method("EnableTransformBox"):
		st.EnableTransformBox(true)


# ── Clic-vs-drag sur la zone de la transform box ────────────────────────────
# Press eligible : SelectTool, box visible, souris dans la zone de la box
# (corner / interieur / anneau de rotation), un objet B highlighte par DD et
# non selectionne. On consomme le press et on tranche au premier mouvement ou
# a la relache. Shift est exclu (drag-box additif natif de DD).

func _hcs_try_intercept(event, st, mouse) -> void:
	if event.shift:
		return
	var h = st.get("highlighted")
	if h == null or typeof(h) != TYPE_OBJECT or not is_instance_valid(h):
		return
	# Objets, portails, paths et patterns : DD les highlighte aussi dans la
	# zone de la box, et leur clic etait avale de la meme facon par les
	# handles. (2 = PortalFree, 3 = PortalWall, 4 = Object, 5 = Pathway,
	# 7 = PatternShape ; les autres types gardent le comportement vanilla.)
	var htype = int(h.get("Type"))
	if htype != 2 and htype != 3 and htype != 4 and htype != 5 and htype != 7:
		return
	var thing = h.get("Thing")
	if thing == null or typeof(thing) != TYPE_OBJECT or not is_instance_valid(thing):
		return
	var selected = st.get("Selected")
	if not (selected is Array) or selected.empty():
		return
	if selected.has(thing):
		return
	var tb = st.get("transformBox")
	if tb == null or typeof(tb) != TYPE_OBJECT or not is_instance_valid(tb):
		return
	if not tb.visible:
		return
	# Hors de la zone de la box, DD selectionne deja B nativement au press :
	# ne rien intercepter (repli sur, exactement, le comportement vanilla).
	if not _hcs_in_transform_zone(tb):
		return
	# Regle "on pioche ce qu'on voit", cote interception : si un objet
	# pixel-opaque sous le curseur couvre la cible (cas typique : re-clic sur
	# l'asset SELECTIONNE pose au-dessus d'un freestanding portal -> DD
	# highlighte le portail invisible dessous), ne pas basculer la selection.
	# Le clic reste un no-op de box et la selection courante est conservee.
	if _g.World != null and is_instance_valid(_g.World):
		var level = _g.World.GetCurrentLevel()
		if level != null:
			var top = _topmost_object_at(level, mouse, st)
			if top != null and top != thing:
				var visible_above = false
				if htype == 2 or htype == 3:
					# Portail : visible seulement s'il est rendu au-dessus ET
					# pixel-opaque a cet endroit (meme regle que la correction).
					visible_above = _renders_above(thing, top) and _portal_pixel_opaque_at(thing, mouse)
				elif htype == 4:
					# Objet : s'il n'est pas le sommet opaque, il est couvert
					# (ou transparent a ce pixel) -> on voit `top`, pas lui.
					visible_above = false
				else:
					# Path / pattern (pas de test pixel fiable) : visibles
					# seulement s'ils sont rendus au-dessus du sommet opaque.
					visible_above = _renders_above(thing, top)
				if not visible_above:
					return
	_hcs_pending = true
	_hcs_press_event = event.duplicate()
	_hcs_press_pos = event.position
	_hcs_target = weakref(thing)
	_hcs_type = htype
	# DD ne voit pas le press : GetTransformMode() ne s'engage pas.
	if _listener != null and _listener.get_tree() != null:
		_listener.get_tree().set_input_as_handled()


# Meme zone que SelectTool.GetTransformMode() : corner (scale), interieur
# (move), anneau de rotation. has_method partout : si l'API du widget change,
# repli sur "pas dans la zone" -> pas d'interception (vanilla).
func _hcs_in_transform_zone(tb) -> bool:
	if tb.has_method("IsMouseOnCorner") and int(tb.IsMouseOnCorner()) != -1:
		return true
	if tb.has_method("IsMouseInside") and bool(tb.IsMouseInside()):
		return true
	if tb.has_method("IsMouseInRotateZone") and bool(tb.IsMouseInRotateZone()):
		return true
	return false


func _hcs_on_motion(event) -> void:
	if event.position.distance_to(_hcs_press_pos) <= HCS_DRAG_THRESHOLD_PX:
		return
	# DRAG : on rejoue le press retenu vers SelectTool._ContentInput -> DD
	# engage son mode transform (GetTransformMode lit la souris LIVE, pas
	# event.position : rejouer un press "en retard" est donc sans effet de
	# bord). La relache reelle suivra normalement (non consommee).
	var press = _hcs_press_event
	_hcs_reset()
	if press == null:
		return
	if _g == null or _g.Editor == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or not st.has_method("_ContentInput"):
		return
	st.call("_ContentInput", press)
	_hcs_forwarded = true


func _hcs_on_release(event) -> void:
	# CLIC : selectionner B, puis FORWARDER la relache reelle dans
	# _ContentInput pour que DD deroule son propre epilogue de release :
	# OnFinishSelection (box pour les types non statiques, rien pour
	# PortalWall) + invocation de l'evenement OnSelect (panneau, boutons,
	# hooks des autres mods). Sans cet epilogue, le panneau n'affichait pas
	# les controles et les mods en aval reagissaient a un flux anormal.
	# transformMode est reste None (le press a ete consomme), la relache
	# forwardee prend donc bien la branche OnFinishSelection.
	var target = null
	if _hcs_target != null:
		target = _hcs_target.get_ref()
	var sel_type = _hcs_type
	_hcs_reset()
	# On consomme l'originale : c'est nous qui la livrons a DD.
	if _listener != null and _listener.get_tree() != null:
		_listener.get_tree().set_input_as_handled()
	if target == null or not is_instance_valid(target):
		return
	if _g == null or _g.Editor == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or not st.has_method("SelectThing"):
		return
	if st.has_method("DeselectAll"):
		st.DeselectAll()
	var sel = st.SelectThing(target, true)
	if sel != null and is_instance_valid(sel):
		st.set("highlighted", sel)
	if sel_type == 3:
		# Type statique : couper la box residuelle de l'ancienne selection
		# AVANT l'epilogue (OnFinishSelection ne la re-affichera pas pour un
		# PortalWall, et GetSelectionRect ne sait pas la fitter -> rect 1x1).
		if st.has_method("EnableTransformBox"):
			st.EnableTransformBox(false)
		_static_watch = weakref(target)
		_static_watch_logged = false
		call_deferred("_hide_static_box_deferred")
	if st.has_method("_ContentInput"):
		st.call("_ContentInput", event)


# Coupe la box a l'idle si la selection courante est toujours un type statique
# (PortalWall). No-op sinon : ne jamais tuer la box d'une selection legitime.
func _hide_static_box_deferred() -> void:
	if _destroyed or _g == null or _g.Editor == null:
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		return
	var st = _g.Editor.Tools.get("SelectTool")
	if st == null or not st.has_method("EnableTransformBox"):
		return
	var selected = st.get("Selected")
	if not (selected is Array) or selected.size() != 1:
		return
	var thing = selected[0]
	if thing == null or not is_instance_valid(thing):
		return
	if not st.has_method("GetSelectableType"):
		return
	if int(st.GetSelectableType(thing)) != 3:
		return
	st.EnableTransformBox(false)


func _hcs_reset() -> void:
	_hcs_pending = false
	_hcs_press_event = null
	_hcs_target = null
	_hcs_type = 4


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
