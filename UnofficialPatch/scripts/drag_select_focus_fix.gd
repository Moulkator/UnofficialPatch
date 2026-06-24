# drag_select_focus_fix.gd
# Bug vanilla : un box-select (rubber-band) du SelectTool reste figé si la
# fenêtre perd le focus pendant le drag.
#
# Répro :
#   - Tracer une dragbox autour d'assets (clic maintenu sur zone vide).
#   - Alt+Tab SANS relâcher le clic.
#   - Alt+Tab pour revenir sur DD, puis relâcher le clic.
#   → Rien ne se passe. Au clic suivant, le widget jaune de survol s'affiche
#     sur tous les assets de la dragbox au lieu de les sélectionner.
#
# Cause :
#   Le box-select est piloté par le flag privé SelectTool.isDrawing. Comme le
#   relâché part pendant que la fenêtre n'a pas le focus, Godot ne délivre
#   jamais le mouseup au _ContentInput de DD. isDrawing reste donc à true :
#   DD continue de dessiner la box et de highlighter les candidats, et le
#   prochain clic est mal interprété.
#
# Fix (option A — finaliser le mouseup manquant) :
#   Chaque frame, si SelectTool est actif, la fenêtre a le focus, isDrawing est
#   à true ET le bouton gauche n'est plus enfoncé, on appelle DIRECTEMENT le
#   _ContentInput du SelectTool avec un InputEventMouseButton LEFT
#   (Pressed=false). DD termine alors sa box-select par son propre code
#   (boxEnd = mouse, selectionBox.SetRect(null), isDrawing = false,
#   OnFinishSelection()) → la sélection est committée proprement.
#
#   NB : get_tree().input_event() n'atteint PAS le dispatch custom de DD pour
#   les events boutons (testé : isDrawing restait true, box figée, réinjection
#   en boucle). L'appel direct de _ContentInput est déterministe et indépendant
#   du routage d'input. Le handler lit mouseButton.Pressed (flag de l'event),
#   pas l'état global d'Input, donc ça marche même si l'état souris de Godot
#   reste « collé » après l'Alt+Tab.
#
# Pourquoi ce gate distingue bug et drag normal :
#   - Drag normal : pendant tout le geste le bouton est enfoncé → on n'injecte
#     pas. Au relâché (fenêtre focus), DD reçoit le vrai mouseup et met
#     isDrawing à false lui-même avant notre update → pas d'injection.
#   - Retour d'Alt+Tab en gardant le clic : bouton encore enfoncé → on
#     n'injecte pas, l'utilisateur dessine toujours sa box.
#   - Bug (relâché pendant perte de focus) : isDrawing reste true alors que le
#     bouton est relâché → on injecte une fois, recovery propre.
#
# Le débounce (REQUIRED_FRAMES) couvre la frame de transition d'un drag normal
# où le bouton vient de remonter mais où le mouseup de DD n'aurait pas encore
# été traité (par sécurité — en pratique l'input passe avant _process).

var _g

var _select_tool = null
# Compteur de frames consécutives où la condition « isDrawing && bouton relâché »
# est vraie. On n'injecte qu'au-delà de REQUIRED_FRAMES pour éviter toute course
# avec le mouseup natif d'un drag normal.
var _stuck_frames := 0
# Cooldown post-injection : évite de réinjecter tant que l'état n'est pas
# clairement retombé (sécurité si l'injection n'était pas synchrone).
var _cooldown := 0

const REQUIRED_FRAMES := 2
const COOLDOWN_FRAMES  := 5


func initialize() -> void:
	if _g != null and _g.Editor != null and _g.Editor.Tools.has("SelectTool"):
		_select_tool = _g.Editor.Tools["SelectTool"]
	print("[DragSelectFocusFix] initialized")


func update(_delta) -> void:
	if _cooldown > 0:
		_cooldown -= 1
		return

	if _g == null or _g.Editor == null:
		return

	# SelectTool doit être l'outil actif.
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		_stuck_frames = 0
		return

	# On n'agit que fenêtre focus : sans focus on ne peut pas injecter
	# utilement, et le retour de focus est justement le moment où corriger.
	if not OS.is_window_focused():
		_stuck_frames = 0
		return

	if _select_tool == null or not is_instance_valid(_select_tool):
		if _g.Editor.Tools.has("SelectTool"):
			_select_tool = _g.Editor.Tools["SelectTool"]
		if _select_tool == null:
			return

	# Flag privé C# lu via get() (le seul accesseur fiable pour un champ C#).
	var is_drawing = _select_tool.get("isDrawing")
	if typeof(is_drawing) != TYPE_BOOL or not is_drawing:
		_stuck_frames = 0
		return

	# Bouton gauche encore enfoncé → drag en cours, rien à corriger.
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		_stuck_frames = 0
		return

	# isDrawing true + bouton relâché + focus : box-select orpheline.
	_stuck_frames += 1
	if _stuck_frames < REQUIRED_FRAMES:
		return

	_inject_release()
	_stuck_frames = 0
	_cooldown = COOLDOWN_FRAMES


# Finalise la box-select orpheline. On appelle DIRECTEMENT le _ContentInput du
# SelectTool avec un relâché synthétique : c'est déterministe et indépendant du
# routage d'input (get_tree().input_event() n'atteint PAS le dispatch custom de
# DD pour les events boutons). DD exécute alors sa branche mouseup
# (boxEnd = mouse, selectionBox.SetRect(null), isDrawing = false,
# OnFinishSelection()) → recovery propre. Le boxEnd est lu depuis
# World.UI.MousePosition par DD, donc la position de l'event n'a pas d'importance.
# Fallback : Input.parse_input_event() (primitive d'injection fiable utilisée
# ailleurs dans le projet), au cas où _ContentInput ne serait pas appelable.
func _inject_release() -> void:
	var ev = InputEventMouseButton.new()
	ev.button_index    = BUTTON_LEFT
	ev.pressed         = false
	# Pas de Shift/Control : finalisation simple de la box.
	ev.shift   = false
	ev.control = false

	if _select_tool != null and is_instance_valid(_select_tool) \
			and _select_tool.has_method("_ContentInput"):
		_select_tool.call("_ContentInput", ev)
		print("[DragSelectFocusFix] orphaned box-select finalized (direct _ContentInput)")
		return

	# Fallback.
	Input.parse_input_event(ev)
	print("[DragSelectFocusFix] orphaned box-select finalized (parse_input_event fallback)")
