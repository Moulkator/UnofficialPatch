#########################################################################################################
##
## COLOR PICKER FIX MOD
## Fixes the eyedropper/pipette tool by temporarily offsetting the preview object far from
## the cursor so the picker can see the map underneath.
##
#########################################################################################################

var script_class = "tool"

var picking_mode = false
var connected_buttons = {}
var click_was_pressed = false
var scan_delay = 3.0
var eyedropper_cursor = null

# Outils qui suivent le curseur avec un Preview a deplacer (pioche DD native).
const PREVIEW_TOOLS = ["ObjectTool", "ScatterTool"]

var _input_listener = null

func start() -> void:
	eyedropper_cursor = _load_eyedropper_cursor()
	_install_input_listener()
	print("[ColorPickerFix] Mod loaded")

func _install_input_listener() -> void:
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_listener_input(e)\n"
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "ColorPickerFixListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	Global.World.add_child(_input_listener)

# Detecte la pioche native d'un ColorPicker Godot : quand elle est active,
# Godot ajoute un Control plein ecran (top-level) dont le signal "gui_input"
# est relie a la methode "_screen_input" du ColorPicker. Marche pour tout
# ColorPicker, y compris ceux des mods tiers (Colour and Modify Things).
func _color_pick_active() -> bool:
	var root = Global.World.get_tree().root
	for child in root.get_children():
		if child is Control and child.visible:
			for conn in child.get_signal_connection_list("gui_input"):
				if str(conn.get("method")) == "_screen_input":
					return true
	return false

# Pendant la pioche en SelectTool : consomme l'ENFONCEMENT du clic gauche (et
# le drag) pour empecher le SelectTool de changer la selection. On laisse
# passer le RELACHEMENT pour que le ColorPicker valide la couleur et se ferme.
func _on_listener_input(event) -> void:
	if str(Global.Editor.get("ActiveToolName")) != "SelectTool":
		return
	if not _color_pick_active():
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		Global.World.get_tree().set_input_as_handled()
	elif event is InputEventMouseMotion and (event.button_mask & BUTTON_MASK_LEFT):
		Global.World.get_tree().set_input_as_handled()

func _load_eyedropper_cursor() -> ImageTexture:
	var image = Image.new()
	var texture = ImageTexture.new()
	var path = Global.Root + "icons/eyedropper01.png"
	var err = image.load(path)
	if err != OK:
		print("[ColorPickerFix] Failed to load cursor icon: ", path)
		return null
	texture.create_from_image(image, 0)  # No flags = crisp pixels
	print("[ColorPickerFix] Loaded cursor icon: ", path, " (", image.get_width(), "x", image.get_height(), ")")
	return texture

func _force_eyedropper_cursor() -> void:
	if eyedropper_cursor != null:
		var hotspot = Vector2(eyedropper_cursor.get_width() / 2, eyedropper_cursor.get_height() / 2)
		Input.set_custom_mouse_cursor(eyedropper_cursor, Input.CURSOR_ARROW, hotspot)
		Input.set_custom_mouse_cursor(eyedropper_cursor, Input.CURSOR_POINTING_HAND, hotspot)
		Input.set_custom_mouse_cursor(eyedropper_cursor, Input.CURSOR_CROSS, hotspot)
		Input.set_custom_mouse_cursor(eyedropper_cursor, Input.CURSOR_CAN_DROP, hotspot)

func _restore_cursor() -> void:
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_POINTING_HAND)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_CROSS)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_CAN_DROP)

func _scan_for_pickers() -> void:
	for tool_name in PREVIEW_TOOLS:
		var panel = Global.Editor.Toolset.GetToolPanel(tool_name)
		if panel != null and is_instance_valid(panel):
			_find_and_connect_pickers(panel)
	print("[ColorPickerFix] Scan complete, connected ", connected_buttons.size(), " buttons")

func _find_and_connect_pickers(root) -> void:
	if root == null or not is_instance_valid(root):
		return
	if root is ColorPicker:
		_connect_screen_pick_button(root)
	if root.get("colorPicker") != null:
		var cp = root.colorPicker
		if cp != null and is_instance_valid(cp) and cp is ColorPicker:
			_connect_screen_pick_button(cp)
	if root is ColorPickerButton:
		var picker = root.get_picker()
		if picker != null and is_instance_valid(picker):
			_connect_screen_pick_button(picker)
	for i in range(root.get_child_count()):
		var child = root.get_child(i)
		if child != null and is_instance_valid(child):
			_find_and_connect_pickers(child)

func _connect_screen_pick_button(picker) -> void:
	if picker == null or not is_instance_valid(picker):
		return
	for i in range(picker.get_child_count()):
		var child = picker.get_child(i)
		if child != null and is_instance_valid(child):
			if child is ToolButton:
				var id = child.get_instance_id()
				if not connected_buttons.has(id):
					child.connect("pressed", self, "_on_screen_pick_pressed")
					connected_buttons[id] = true
			for j in range(child.get_child_count()):
				var grandchild = child.get_child(j)
				if grandchild != null and is_instance_valid(grandchild) and grandchild is ToolButton:
					var id2 = grandchild.get_instance_id()
					if not connected_buttons.has(id2):
						grandchild.connect("pressed", self, "_on_screen_pick_pressed")
						connected_buttons[id2] = true

func _on_screen_pick_pressed() -> void:
	var active = false
	for tool_name in PREVIEW_TOOLS:
		if Global.Editor.Toolset.ToolPanels.has(tool_name):
			if Global.Editor.Toolset.ToolPanels[tool_name].visible:
				active = true
				break
	if not active:
		return
	picking_mode = true
	click_was_pressed = false
	_offset_preview()
	_force_eyedropper_cursor()
	print("[ColorPickerFix] Eyedropper activated")

func update(delta: float) -> void:
	if scan_delay >= 0.0:
		scan_delay -= delta
		if scan_delay < 0.0:
			_scan_for_pickers()
		return
	if not picking_mode:
		return
	_force_eyedropper_cursor()
	var mouse_pressed = Input.is_mouse_button_pressed(BUTTON_LEFT)
	if mouse_pressed and not click_was_pressed:
		_offset_preview()
		click_was_pressed = true
		return
	if click_was_pressed and not mouse_pressed:
		picking_mode = false
		click_was_pressed = false
		_restore_cursor()
		print("[ColorPickerFix] Picking ended")
		return
	if Input.is_key_pressed(KEY_ESCAPE):
		picking_mode = false
		click_was_pressed = false
		_restore_cursor()
		print("[ColorPickerFix] Picking cancelled")
		return
	_offset_preview()

func _offset_preview() -> void:
	for tool_name in ["ObjectTool", "ScatterTool"]:
		var tool = Global.Editor.Tools[tool_name]
		if tool != null and is_instance_valid(tool):
			var preview = tool.get("Preview")
			if preview != null and is_instance_valid(preview):
				preview.global_position += Vector2(99999, 99999)
