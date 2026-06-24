# rotate_context.gd
# Right-click context menu provider: "Rotate 90°" for SelectTool object
# selections.
#
# Also neutralizes the third-party "RotateAndJiggle" (Jiggle.gd) mod's
# automatic right-click rotation, which otherwise fires at the same time as
# our context menu (annoying double-action). Jiggle binds its right-click
# rotation to a private InputMap action "new_right_mouse_click"; we strip
# that action's events so the rotation never triggers, while leaving
# Jiggle's wheel / trackpad rotation and its rotation slider fully intact.
# Our own menu is polled in right_click_util (not via that action), so it
# is unaffected.

var _g

const JIGGLE_RC_ACTION := "new_right_mouse_click"

var _icon = null
# Retry window (~2s @ 60fps) so the neutralization works regardless of
# whether Jiggle.gd loads before or after us.
var _disable_frames := 120


func initialize() -> void:
	var img = Image.new()
	if img.load(_g.Root + "icons/rotate.png") == OK:
		var tex = ImageTexture.new()
		tex.create_from_image(img, 0)
		_icon = tex
	print("[RotateContext] Initialized")


func update(_delta: float) -> void:
	if _disable_frames > 0:
		_disable_frames -= 1
		_neutralize_jiggle_right_click()


# Strip the events bound to Jiggle's right-click action. We leave the action
# itself registered (just empty): Jiggle's start() guard
# `if not InputMap.has_action(...)` stays satisfied so it won't re-add the
# event, and its `Input.is_action_just_pressed(...)` calls quietly return
# false (no error spam from querying a missing action).
func _neutralize_jiggle_right_click() -> void:
	if not InputMap.has_action(JIGGLE_RC_ACTION):
		return
	if InputMap.get_action_list(JIGGLE_RC_ACTION).size() > 0:
		InputMap.action_erase_events(JIGGLE_RC_ACTION)
		print("[RotateContext] Disabled Jiggle's right-click auto-rotation")


# ===== Provider interface (right_click_util) =====

func get_context_items(raw) -> Array:
	var items = []
	var select_tool = _get_select_tool()
	if select_tool == null:
		return items
	# Only offer the item when at least one Object (selectable type 4) is
	# selected -- rotating walls/portals/etc. by 90deg in place isn't useful.
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if select_tool.GetSelectableType(thing) == 4:
			items.append({label = "Rotate 90°", icon = _icon, action_id = "rotate_90"})
			break
	return items


func on_context_action(action_id: String, raw) -> void:
	if action_id != "rotate_90":
		return
	var select_tool = _get_select_tool()
	if select_tool == null:
		return

	# Collect the object nodes to rotate.
	var nodes = []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if select_tool.GetSelectableType(thing) == 4:
			nodes.append(thing)
	if nodes.size() == 0:
		return

	# Rotation is a Transform2D property, so wrap the mutation in undo_lib's
	# transform sandwich (records the currently-selected nodes' transforms
	# for Ctrl+Z). Caller-selected nodes ARE the current selection here.
	var undo = null
	if _g != null and _g.get("ModMapData") != null and (_g.ModMapData is Dictionary):
		undo = _g.ModMapData.get("_undo_lib")
	var undoing = undo != null and undo.has_method("begin_transform") and undo.begin_transform()

	for node in nodes:
		node.rotation = wrapf(node.rotation + PI / 2.0, 0.0, TAU)

	if undoing:
		undo.commit_transform()

	# Refresh the selection box so handles / rotation slider follow the new
	# orientation.
	if select_tool.has_method("OnFinishSelection"):
		select_tool.OnFinishSelection()


func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary):
		return null
	return tools.get("SelectTool")
