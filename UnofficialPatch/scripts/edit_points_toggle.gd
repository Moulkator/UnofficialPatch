# edit_points_toggle.gd
# Fait du bouton Edit Points un vrai toggle dans le FloorShapeTool (Building Tool)
# et le PatternShapeTool (Pattern Tool).
#
# Comportement :
#   - 1er clic sur Edit Points  -> entre en mode Edit Points (vanilla)
#     et on memorise la shape precedemment active (Freehand / Rectangle /
#     Polygon / Paint Bucket / ...)
#   - 2e clic sur Edit Points   -> sort du mode Edit Points et restaure
#     la shape memorisee.
#
# Par defaut, cliquer sur un bouton deja presse dans un ButtonGroup Godot
# ne fait rien (le ButtonGroup empeche l'untoggle). Ce mod ajoute ce
# comportement de bascule en interceptant button_up sur EditPoints.
#
# Integration avec le Paint Bucket (PatternShapeTool) : le mod pattern_paint_bucket
# auto-desactive son bouton quand EP devient presse et restaure son _prev_mode,
# ce qui kidnapperait EditPoints. On neutralise ce comportement en interceptant
# EP.toggled(true) pour desactiver proprement le bucket (via son sentinel
# _prev_mode = -1 qui signifie "ne rien restaurer").

var script_class = "tool"
var _g

# Reference optionnelle vers le mod pattern_paint_bucket.
# Sert a coordonner la bascule EditPoints <-> Paint Bucket : sans ca, le mod
# paint_bucket auto-desactive son bouton quand EP est presse et restaure son
# _prev_mode (Rectangle), ce qui kidnappe EditPoints.
var pattern_paint_bucket = null

# Dernier bouton de shape presse avant d'entrer en Edit Points.
# Cle: nom du tool (String), Valeur: BaseButton
var _last_shape = {}

# Liste des boutons de shape (sans EditPoints) par tool.
var _shape_buttons = {}

# Etat de EditPoints capture au button_down, pour detecter au button_up
# si l'utilisateur a clique alors qu'EP etait deja presse.
# Cle: nom du tool (String), Valeur: bool
var _ep_was_pressed_at_down = {}

# Tools concernes (noms internes DD ; dans l'UI, FloorShapeTool = Building Tool)
const TOOL_NAMES = ["FloorShapeTool", "PatternShapeTool"]


# --- Lifecycle ---------------------------------------------------------------

func initialize():
	_last_shape = {}
	_shape_buttons = {}
	_ep_was_pressed_at_down = {}
	for tool_name in TOOL_NAMES:
		_install_for_tool(tool_name)
	print("[EditPointsToggle] initialized")


func _install_for_tool(tool_name: String) -> void:
	if _g == null: return
	var editor = _g.get("Editor")
	if editor == null: return
	var tools = editor.get("Tools")
	if tools == null: return
	var tool = tools.get(tool_name)
	if tool == null:
		print("[EditPointsToggle] %s not found" % tool_name)
		return

	var ep = tool.get("EditPoints")
	if ep == null or not is_instance_valid(ep):
		print("[EditPointsToggle] EditPoints button not found for %s" % tool_name)
		return

	# Collecte des boutons de shape frères de EditPoints (via le ButtonGroup,
	# avec repli sur les siblings du conteneur parent).
	var shape_buttons = _collect_shape_buttons(ep)

	# Ajout explicite du Paint Bucket pour le PatternShapeTool : il n'est ni
	# dans le ButtonGroup des shapes vanilla, ni sibling direct de EP (DD met
	# les shapes et EP dans des HBoxContainer distincts), donc ni la methode
	# ButtonGroup ni le sibling scan ne le captent. On le resout via la ref.
	if tool_name == "PatternShapeTool" and pattern_paint_bucket != null \
			and is_instance_valid(pattern_paint_bucket):
		var pb_btn = pattern_paint_bucket.get("_bucket_button")
		if pb_btn != null and is_instance_valid(pb_btn) and not pb_btn in shape_buttons:
			shape_buttons.append(pb_btn)
			print("[EditPointsToggle] Paint Bucket added to tracked shapes")

	if shape_buttons.empty():
		print("[EditPointsToggle] no shape buttons found for %s" % tool_name)
		return
	_shape_buttons[tool_name] = shape_buttons

	# Tracker la derniere shape pressee en se branchant sur leur signal toggled.
	for btn in shape_buttons:
		if btn == null or not is_instance_valid(btn): continue
		if btn.has_signal("toggled") and not btn.is_connected("toggled", self, "_on_shape_toggled"):
			btn.connect("toggled", self, "_on_shape_toggled", [tool_name, btn])

	# Initialisation: shape pressee actuellement sinon premier bouton.
	var initial = null
	for btn in shape_buttons:
		if is_instance_valid(btn) and btn.pressed:
			initial = btn
			break
	if initial == null:
		for btn in shape_buttons:
			if is_instance_valid(btn):
				initial = btn
				break
	if initial != null:
		_last_shape[tool_name] = initial

	# Intercepter le clic sur EditPoints pour detecter le "clic alors que deja presse".
	# On capture l'etat au button_down et on agit au button_up : a ce moment-la le
	# release a deja ete traite par BaseButton, donc changer l'etat est safe.
	if not ep.is_connected("button_down", self, "_on_edit_points_button_down"):
		ep.connect("button_down", self, "_on_edit_points_button_down", [tool_name])
	if not ep.is_connected("button_up", self, "_on_edit_points_button_up"):
		ep.connect("button_up", self, "_on_edit_points_button_up", [tool_name])

	# Pour le PatternShapeTool, on ecoute aussi toggled(true) de EP afin de
	# neutraliser proprement le Paint Bucket si besoin (cf. _on_ep_toggled_pattern).
	if tool_name == "PatternShapeTool":
		if not ep.is_connected("toggled", self, "_on_ep_toggled_pattern"):
			ep.connect("toggled", self, "_on_ep_toggled_pattern")

	print("[EditPointsToggle] installed for %s (%d shape buttons)" % [tool_name, shape_buttons.size()])


# --- Collecte des boutons de shape ------------------------------------------

func _collect_shape_buttons(ep) -> Array:
	var result = []

	# Methode 1 : via le ButtonGroup (boutons de shape vanilla)
	var group = ep.get("group")
	if group != null and group.has_method("get_buttons"):
		for b in group.get_buttons():
			if is_instance_valid(b) and b != ep:
				result.append(b)

	# Methode 2 : inclure aussi les siblings toggle (meme parent) qui ne sont
	# PAS dans le ButtonGroup. C'est le cas du Paint Bucket du mod
	# pattern_paint_bucket : il est toggle_mode mais injecte hors du group.
	var parent = ep.get_parent()
	if parent != null:
		for child in parent.get_children():
			if not is_instance_valid(child): continue
			if child == ep: continue
			if child in result: continue
			if child is BaseButton and child.toggle_mode:
				result.append(child)
	return result


# --- Signaux ----------------------------------------------------------------

func _on_shape_toggled(pressed: bool, tool_name: String, btn) -> void:
	# On ne garde que l'evenement "devient presse".
	if pressed and is_instance_valid(btn):
		_last_shape[tool_name] = btn


func _on_edit_points_button_down(tool_name: String) -> void:
	# Au mouse down on note juste si EP etait deja presse a cet instant.
	# On n'agit pas ici : changer l'etat tant que le release n'est pas traite
	# provoque un rebond de BaseButton qui retoggle EP a la fin du clic.
	if _g == null: return
	var editor = _g.get("Editor")
	if editor == null: return
	var tools = editor.get("Tools")
	if tools == null: return
	var tool = tools.get(tool_name)
	if tool == null: return
	var ep = tool.get("EditPoints")
	if ep == null or not is_instance_valid(ep): return
	_ep_was_pressed_at_down[tool_name] = ep.pressed


func _on_edit_points_button_up(tool_name: String) -> void:
	# button_up est emis apres que BaseButton ait fini de traiter le release.
	# Si EP etait deja presse au down, le ButtonGroup a conserve son etat
	# (clic sur un bouton deja presse d'un group = no-op). On peut maintenant
	# basculer proprement sur la derniere shape.
	var was_pressed = _ep_was_pressed_at_down.get(tool_name, false)
	_ep_was_pressed_at_down.erase(tool_name)
	if not was_pressed:
		return
	# On differe malgre tout, par precaution (certains signaux toggled/pressed
	# peuvent etre emis juste apres button_up dans la meme frame).
	call_deferred("_restore_last_shape", tool_name)


func _restore_last_shape(tool_name: String) -> void:
	if _g == null: return
	var editor = _g.get("Editor")
	if editor == null: return
	var tools = editor.get("Tools")
	if tools == null: return
	var tool = tools.get(tool_name)
	if tool == null: return
	var ep = tool.get("EditPoints")
	if ep == null or not is_instance_valid(ep): return
	# Si EditPoints n'est plus presse (un autre evenement est passe entre
	# temps), inutile d'intervenir.
	if not ep.pressed: return

	var last = _last_shape.get(tool_name)
	if last == null or not is_instance_valid(last):
		# Fallback : premier bouton de shape encore valide.
		var btns = _shape_buttons.get(tool_name, [])
		for b in btns:
			if is_instance_valid(b):
				last = b
				break

	if last == null or not is_instance_valid(last) or last.pressed:
		return

	# set pressed=true declenche automatiquement :
	#   - le swap du ButtonGroup (EditPoints passe a false) pour les shapes vanilla
	#   - pour le Paint Bucket : _on_bucket_toggled(true) qui un-press EP explicitement
	#   - l'emission du signal toggled(true) sur la shape
	# ce qui suffit a faire basculer le tool dans son nouveau mode.
	last.pressed = true
	print("[EditPointsToggle] %s : restored shape '%s'" % [tool_name, str(last.name)])


# --- Coordination avec le Paint Bucket (PatternShapeTool) -------------------

func _on_ep_toggled_pattern(pressed: bool) -> void:
	# Quand EditPoints vient d'etre active et que le Paint Bucket etait en cours,
	# le mod paint_bucket aurait auto-desactive son bouton la frame suivante et
	# restaure son _prev_mode (la shape precedente), kidnappant EditPoints.
	# On previent ca en desactivant le bucket des maintenant, avec le sentinel
	# _prev_mode = -1 (deja utilise par paint_bucket lui-meme pour signifier
	# "ne rien restaurer" -- cf. son _on_shape_button_pressed).
	if not pressed:
		return
	if pattern_paint_bucket == null or not is_instance_valid(pattern_paint_bucket):
		return
	var pb_active = pattern_paint_bucket.get("_bucket_active")
	if pb_active != true:
		return
	var pb_btn = pattern_paint_bucket.get("_bucket_button")
	if pb_btn == null or not is_instance_valid(pb_btn) or not pb_btn.pressed:
		return
	pattern_paint_bucket.set("_prev_mode", -1)
	pb_btn.pressed = false
	print("[EditPointsToggle] paint bucket neutralized (EP just activated)")
