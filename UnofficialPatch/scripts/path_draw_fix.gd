# path_draw_fix.gd
# Keeps path/wall/pattern/roof preview following the mouse
# even when the cursor leaves the viewport during drawing.

var script_class = "tool"
var _g
var input_listener: Node

var _watched_tools = ["PathTool", "WallTool", "PatternShapeTool", "RoofTool", "FloorShapeTool"]

# Pour chaque tool, le nom de la methode "Update<Thing>" qui force un
# refresh du draw en cours en fonction de MousePosition (mis a jour par
# nous). Une seule de ces methodes existe par tool. On tente chacune
# (has_method) pour ne pas dependre d'un nommage particulier.
var _update_methods = ["UpdatePath", "UpdateWall", "UpdateShape", "UpdatePattern", "UpdateRoof", "UpdateFloor"]

const _META_KEY = "PathDrawFixListener"


func initialize():
	_cleanup_old_listener()
	_install_input_listener()
	print("[PathDrawFix] initialized")


func _cleanup_old_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
		Engine.set_meta(_META_KEY, null)
	if is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null


func _install_input_listener():
	input_listener = Node.new()
	input_listener.name = "PathDrawFixListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(event):\n\tif handler == null:\n\t\treturn\n\thandler._on_input(event)\n"
	s.reload()
	input_listener.set_script(s)
	input_listener.handler = self
	Engine.set_meta(_META_KEY, input_listener)
	_g.Editor.get_tree().get_root().call_deferred("add_child", input_listener)


# Retourne le tool actif s'il est dans _watched_tools, sinon null.
# On ne tente plus de detecter "draw en cours" via ActivePath : c'etait
# specifique a PathTool, et bloquait le fix pour les autres outils. Il
# suffit de pousser MousePosition + appeler la methode Update* du tool ;
# le tool sait lui-meme s'il est en plein draw.
func _get_active_drawing_tool():
	if _g == null:
		return null
	var editor = _g.get("Editor")
	if editor == null or not is_instance_valid(editor):
		return null
	var atn = editor.get("ActiveToolName")
	if atn == null or not (atn in _watched_tools):
		return null
	var tools = editor.get("Tools")
	if tools == null:
		return null
	var tool = tools.get(atn)
	if tool == null or not is_instance_valid(tool):
		return null
	return tool


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	if _g == null:
		return screen_pos
	var world_ui = _g.get("WorldUI")
	if world_ui == null or not is_instance_valid(world_ui):
		return screen_pos
	var canvas_xform = world_ui.get_viewport().get_canvas_transform()
	return canvas_xform.affine_inverse().xform(screen_pos)


func _on_input(event):
	if not (event is InputEventMouseMotion):
		return
	_update_preview(event.position)


func _update_preview(screen_pos: Vector2):
	if _g == null:
		return
	var world_ui = _g.get("WorldUI")
	if world_ui == null or not is_instance_valid(world_ui):
		return
	var tool = _get_active_drawing_tool()
	if tool == null:
		return
	var world_pos = _screen_to_world(screen_pos)
	world_ui.set("MousePosition", world_pos)
	world_ui.set("IsMouseMoving", true)
	# Tente la bonne methode Update* du tool. On essaie chaque candidat ;
	# une seule existera par tool. Sans ca, certains tools (Wall, Pattern,
	# etc.) ne recalculaient pas leur preview avec la nouvelle position.
	for m in _update_methods:
		if tool.has_method(m):
			tool.call(m)
			return


func update(_delta):
	pass


# Appele par Main.gd lors d'un hot-toggle off (Draw Over UI = false).
# Detache l'input listener globalement pour ne plus tracker la souris
# hors viewport.
func cleanup():
	_cleanup_old_listener()
