# select_cursor_fix.gd
# Bug vanilla : dans SelectTool, le cursor change sur survol d'un handle
# de la transform box (resize/move/rotate). Si on quitte le tool via
# raccourci clavier (X, Echap, etc.), le cursor reste bloqué partout
# sur le canvas jusqu'au reload de la map.
#
# Cause exacte (trouvée via scan du scene tree) :
#   DD modifie Content.mouse_default_cursor_shape — le Control principal
#   du canvas, à /root/Master/Editor/VPartition/Panels/HSplit/Content —
#   pendant le survol d'un handle (12=FDIAGSIZE, 11=BDIAGSIZE, 13=MOVE,
#   7=CAN_DROP selon la zone) mais ne le reset jamais lorsque le tool
#   change. Le shape stuck persiste sur tout le Content, d'où le cursor
#   bloqué sur tout le canvas. L'UI était également stuck dans les tests
#   initiaux à cause d'une texture custom resize que DD avait collée au
#   slot CURSOR_ARROW.
#
# Fix : au quit de SelectTool, on remet Content.mouse_default_cursor_shape
# à CURSOR_ARROW, et on clear la texture custom du slot CURSOR_ARROW.

var _g
var _last_tool := ""
var _content: Control = null


func initialize() -> void:
	pass


func start() -> void:
	if _g != null and _g.Editor != null:
		_last_tool = str(_g.Editor.ActiveToolName)


func update(_delta) -> void:
	if _g == null or _g.Editor == null:
		return
	var cur = str(_g.Editor.ActiveToolName)
	if cur == _last_tool:
		return
	if _last_tool == "SelectTool" and cur != "SelectTool":
		_reset_canvas_cursor()
	_last_tool = cur


func _reset_canvas_cursor() -> void:
	# Lazy resolve du node Content (le scene tree n'est pas forcément
	# prêt au moment de initialize()).
	if _content == null or not is_instance_valid(_content):
		var node = _g.World.get_tree().root.get_node_or_null(
			"Master/Editor/VPartition/Panels/HSplit/Content")
		if node != null and node is Control:
			_content = node
	if _content != null and is_instance_valid(_content):
		_content.mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Clear aussi le slot ARROW au cas où DD y aurait collé une texture
	# leftover (constaté dans les tests : cursor stuck aussi sur l'UI).
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	# Godot ne reconsulte mouse_default_cursor_shape qu'au prochain
	# mouse motion event. Sans bouger la souris, le cursor garderait son
	# ancienne forme. On force un mouse motion en warping la souris vers
	# sa propre position — visuellement no-op, mais ça déclenche le
	# refresh du cursor immédiatement.
	var vp = _g.World.get_viewport()
	if vp != null:
		Input.warp_mouse_position(vp.get_mouse_position())
