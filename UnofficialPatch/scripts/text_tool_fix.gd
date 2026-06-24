# text_drag.gd
# Sub-mod for BugFixes -- Drag text nodes while in the Text Tool and Select Tool

var _g
var _ui_util = null

var _text_toolbar_path   : NodePath
var _select_toolbar_path : NodePath
var _viewport_path       : NodePath
var _input_listener      : Node = null

# Text alignment mode: 0=left anchor, 1=center anchor, 2=right anchor
var _align_mode    := 0
var _align_buttons := []   # [btn_left, btn_center, btn_right]

# Anchor tracking: instance_id -> anchor_x in world coords
var _anchors       := {}
# Previous Texts child count to detect new text creation
var _prev_text_count := -1

# Focused text (TextTool)
var _focused_text : Node = null

# Drag state (shared)
var _dragging     : Node = null
var _drag_offset  := Vector2.ZERO
var _in_drag_zone := false
var _in_sel_zone  := false

# SelectTool hover
var _sel_hover_text : Node = null

# Cursor
var _cursor_active   := false
var _move_cursor_tex = null
var _texts_mouse_blocked := false
var _current_level       = null
var _clone_btn_connected := false
var _clone_snapshot    := []  # [{pos, mode}] of source texts before clone
var _restoring         := false  # suppress auto-registration during restore
var _map_file_path       := ""
var _save_btn_connected  := false
var _line_break_pending  := false  # suppress _apply_alignment during line break fixup
const MOD_DATA_KEY := "TextToolFix_Align"

# Font scroll
var _font_selector_path : NodePath
var _font_list          := []
var _current_font_idx   := -1
var _current_font_node  := 0


# ── Helpers (level-aware) ─────────────────────────────────────────────────────

func _get_current_texts() -> Node:
	if _g.World == null or not is_instance_valid(_g.World):
		return null
	var level = _g.World.GetCurrentLevel()
	if level == null or not is_instance_valid(level):
		return null
	var texts = level.Texts if level != null else null
	if texts != null and not is_instance_valid(texts):
		return null
	return texts


# ── Setup ─────────────────────────────────────────────────────────────────────

func initialize() -> void:
	print("[TextToolFix] Initialized")
	# Cleanup previous instance's listener if still alive (e.g. map reload without closing DD)
	if Engine.has_meta("_TextToolFixListener"):
		var old = Engine.get_meta("_TextToolFixListener")
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
		Engine.remove_meta("_TextToolFixListener")
	_try_setup(0)


func _try_setup(attempt: int) -> void:
	if attempt > 50:
		print("[TextToolFix] Setup failed after 50 attempts")
		return
	# Bail out if World was freed (map closed/reloaded during setup retries)
	if _g.World == null or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	# Navigate only from World — _g.Editor is unsafe in timer callbacks
	var tree = _g.World.get_tree()
	if tree == null:
		return
	var vp     = tree.root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	var anchor = tree.root.get_node_or_null("Master/Editor/VPartition/Panels/Tools/Anchor")
	if vp == null or anchor == null:
		var t = tree.create_timer(0.2)
		t.connect("timeout", self, "_try_setup", [attempt + 1])
		return
	# Wait for DD to finish loading texts (dataOnFocus must be set on at least one)
	var texts = _get_current_texts()
	if texts != null and texts.get_child_count() > 0:
		# Wait until rect_position AND rect_size are both valid
		# rect_size must be > 10 to ensure DD has fully laid out the text nodes
		var ready = false
		for tx in texts.get_children():
			if tx is Control and tx.rect_position.length() > 1.0 and tx.rect_size.x > 10.0:
				ready = true; break
		if not ready:
			var t = tree.create_timer(0.1)
			t.connect("timeout", self, "_try_setup", [attempt + 1])
			return
	_do_setup()


func _do_setup() -> void:
	var root = _g.World.get_tree().root
	var viewport = root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	if viewport == null:
		print("[TextToolFix] Viewport2D not found")
		return
	_viewport_path = viewport.get_path()

	var anchor_node = root.get_node_or_null("Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor_node == null:
		print("[TextToolFix] Anchor not found")
		return

	for child in anchor_node.get_children():
		var ft = str(child.get("ForceTool"))
		if ft == "TextTool":
			_text_toolbar_path = child.get_path()
		elif ft == "SelectTool":
			_select_toolbar_path = child.get_path()

	if _text_toolbar_path.is_empty():
		print("[TextToolFix] TextTool toolbar not found")
		return

	var ls = GDScript.new()
	ls.source_code = """extends Node
var handler = null
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	ls.reload()
	_input_listener = Node.new()
	_input_listener.name = "TextDragListener"
	_input_listener.set_script(ls)
	_input_listener.handler = self
	Engine.set_meta("_TextToolFixListener", _input_listener)
	_g.World.call_deferred("add_child", _input_listener)

	var ui_util_script = ResourceLoader.load(_g.Root + "scripts/ui_util.gd", "GDScript", true)
	if ui_util_script:
		_ui_util = ui_util_script.new()

	_setup_panel()
	_restore_existing_texts()
	# Connect save button
	var save_btn = _g.World.get_tree().root.get_node_or_null("Master/Editor").get("saveButton") if _g.World.get_tree().root.get_node_or_null("Master/Editor") else null
	if save_btn and not _save_btn_connected:
		save_btn.connect("pressed", self, "_on_save_pressed")
		_save_btn_connected = true
	# Connect clone level button
	if not _clone_btn_connected:
		_connect_clone_button()
	_g.ModMapData["_ttf_handler"] = self
	print("[TextToolFix] Ready")


func _connect_clone_button() -> void:
	var windows_node = _g.World.get_tree().root.get_node_or_null("Master/Editor/Windows")
	if windows_node == null:
		return
	var newlevelwindow = null
	for win in windows_node.get_children():
		for sub_win in win.get_children():
			if sub_win.name == "Margins":
				for thing in sub_win.get_child(0).get_children():
					if thing.name == "CloneLevel":
						newlevelwindow = sub_win
						break
			if newlevelwindow != null:
				break
		if newlevelwindow != null:
			break
	if newlevelwindow == null:
		print("[TextToolFix] Could not find Create Level window")
		return
	var ok_btn = newlevelwindow.get_node_or_null("VAlign/Buttons/OkayButton")
	if ok_btn == null:
		return
	ok_btn.connect("pressed", self, "_on_create_level_pressed", [newlevelwindow])
	_clone_btn_connected = true
	print("[TextToolFix] Connected to Create Level button")


func _on_create_level_pressed(newlevelwindow: Node) -> void:
	var valign = newlevelwindow.get_node_or_null("VAlign")
	if valign == null:
		return
	var clone_option = valign.get_node_or_null("CloneLevel/CloneLevelOptionButton")
	if clone_option == null or clone_option.selected <= 0:
		return
	# Snapshot source instance IDs and modes BEFORE clone
	_clone_snapshot = []
	if not _viewport_path.is_empty():
		var vp = _g.World.get_tree().root.get_node_or_null(_viewport_path)
		if vp != null:
			var texts = _get_current_texts()
			if texts != null:
				for t in texts.get_children():
					if t is Control:
						var id = t.get_instance_id()
						var mode = _anchors[id]["mode"] if _anchors.has(id) else 0
						_clone_snapshot.append({"src_id": id, "mode": mode})
	print("[TextToolFix] Clone level detected, snapshot=%d texts" % _clone_snapshot.size())
	# Wait for clone to complete by polling for new texts
	_wait_for_clone(0)


func _wait_for_clone(attempt: int) -> void:
	if attempt > 30:
		print("[TextToolFix] Clone wait timed out, restoring anyway")
		_do_clone_restore()
		return
	if _g.World == null or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	if _viewport_path.is_empty():
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_wait_for_clone", [attempt + 1])
		return
	var vp = _g.World.get_tree().root.get_node_or_null(_viewport_path)
	if vp == null:
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_wait_for_clone", [attempt + 1])
		return
	var texts = _get_current_texts()
	# Wait until text count has increased (clone added new texts)
	var current_count = texts.get_child_count() if texts else 0
	var snapshot_count = _clone_snapshot.size()
	if snapshot_count > 0 and current_count <= snapshot_count and attempt < 25:
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_wait_for_clone", [attempt + 1])
		return
	_do_clone_restore()


func _do_clone_restore() -> void:
	print("[TextToolFix] Restoring alignment after clone")
	_anchors.clear()
	_focused_text = null
	_prev_text_count = -1
	_restore_existing_texts()


func _get_node_id(t: Node):
	var meta = t.get("__meta__")
	if meta is Dictionary and meta.has("node_id"):
		return str(meta["node_id"])
	return null


func _get_map_align_path() -> String:
	# Find current map file name to use as key
	var candidates = ["CurrentMapFile", "MapFile", "currentFile", "CurrentFile"]
	var map_name = ""
	for c in candidates:
		var v = _g.Editor.get(c)
		if v != null and typeof(v) == TYPE_STRING and v != "":
			map_name = v.get_file().get_basename()
			break
		v = _g.get(c)
		if v != null and typeof(v) == TYPE_STRING and v != "":
			map_name = v.get_file().get_basename()
			break
	if map_name == "":
		return ""
	# Ensure directory exists
	var dir = Directory.new()
	var folder = "user://UnofficialPatch/TextTool"
	if not dir.dir_exists(folder):
		dir.make_dir_recursive(folder)
	return folder + "/" + map_name + ".json"


func _save_align_data() -> void:
	if _g.World == null or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var viewport = _g.World.get_tree().root.get_node_or_null(_viewport_path)
	if viewport == null:
		return
	var texts = _get_current_texts()
	if texts == null:
		return
	var data = {}
	for t in texts.get_children():
		if not (t is Control):
			continue
		var nid = _get_node_id(t)
		if nid == null:
			continue
		var id = t.get_instance_id()
		if _anchors.has(id):
			data[nid] = _anchors[id]["mode"]
	# Write into ModMapData — saved with every DD save (Ctrl+S, Save As, auto-backup)
	_g.ModMapData[MOD_DATA_KEY] = data
	print("[TextToolFix] Saved align data to ModMapData (%d entries)" % data.size())
	# Also write sidecar JSON as fallback
	var path = _get_map_align_path()
	if path != "":
		var f = File.new()
		if f.open(path, File.WRITE) == OK:
			f.store_string(JSON.print(data))
			f.close()


func _load_align_data() -> Dictionary:
	# Primary: ModMapData (survives all save types)
	if _g.ModMapData.has(MOD_DATA_KEY):
		var d = _g.ModMapData[MOD_DATA_KEY]
		if d is Dictionary and d.size() > 0:
			print("[TextToolFix] Loaded align data from ModMapData (%d entries)" % d.size())
			return d
	# Fallback: sidecar JSON
	var path = _get_map_align_path()
	if path == "":
		return {}
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return {}
	var text = f.get_as_text()
	f.close()
	var result = JSON.parse(text)
	if result.error != OK:
		return {}
	print("[TextToolFix] Loaded align data from sidecar JSON (%d entries)" % result.result.size())
	return result.result


func _on_save_pressed() -> void:
	# Write to ModMapData immediately (before DD saves the file)
	_save_align_data()


func _restore_existing_texts() -> void:
	_restoring = true
	var viewport = _g.World.get_tree().root.get_node_or_null(_viewport_path)
	if viewport == null:
		_restoring = false
		return
	var texts = _get_current_texts()
	if texts == null or not is_instance_valid(texts):
		_restoring = false
		return
	var saved = _load_align_data()
	var restored = 0
	for t in texts.get_children():
		if not is_instance_valid(t) or not (t is Control):
			continue
		var nid = _get_node_id(t)
		var mode = 0
		if nid != null and saved.has(nid):
			mode = int(saved[nid])
		# Compute anchor_x from DD's loaded position + rect_size (both correct after SetFont resize)
		var id = t.get_instance_id()
		var w = t.rect_size.x * t.rect_scale.x
		var ax: float
		match mode:
			0: ax = t.rect_position.x
			1: ax = t.rect_position.x + w * 0.5
			2: ax = t.rect_position.x + w
			_: ax = t.rect_position.x
		# Populate _anchors directly — NO _register_anchor, NO call_deferred("set", "align")
		# DD already has the correct align property from the saved file.
		_anchors[id] = {"x": ax, "mode": mode}
		t.set_meta("td_align", mode)
		if not t.is_connected("focus_entered", self, "_on_text_focus_entered"):
			t.connect("focus_entered", self, "_on_text_focus_entered", [t])
		if mode != 0:
			restored += 1
	if restored > 0:
		print("[TextToolFix] Restored alignment for %d texts" % restored)
	_restoring = false


func _setup_panel() -> void:
	var anchor_node = _g.World.get_tree().root.get_node_or_null("Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor_node == null:
		return
	var panel = null
	for child in anchor_node.get_children():
		if str(child.get("ForceTool")) == "TextTool":
			panel = child.get_node_or_null("Divider/TextToolPanel/Align")
			break
	if panel == null:
		print("[TextToolFix] TextToolPanel Align not found")
		return

	# Hide EDIT/MOVE container
	for child in panel.get_children():
		if child is HBoxContainer:
			for sub in child.get_children():
				if sub.has_method("get_text") and sub.get_text() in ["EDIT", "MOVE"]:
					child.visible = false
					print("[TextToolFix] Hidden EDIT/MOVE container")
					break

	# Add alignment buttons at the top of the panel
	# Wrap hbox in a centering container
	var center = CenterContainer.new()
	center.name = "TextAlignCenter"
	var hbox = HBoxContainer.new()
	hbox.name = "TextAlignButtons"
	hbox.add_constant_override("separation", 4)

	var icons_names = ["text-left.png", "text-center.png", "text-right.png"]
	var tooltips = ["Left anchor (text grows right)", "Center anchor (text grows both sides)", "Right anchor (text grows left)"]
	_align_buttons = []

	for i in range(3):
		var btn = Button.new()
		btn.hint_tooltip = tooltips[i]
		btn.toggle_mode = true
		btn.pressed = (i == 0)
		btn.focus_mode = 0  # FOCUS_NONE
		btn.size_flags_horizontal = 3
		btn.expand_icon = true
		btn.rect_min_size = Vector2(48, 48)
		# Load icon
		var img = Image.new()
		var icon_path = _g.Root + "icons/" + icons_names[i]
		if img.load(icon_path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img, 0)
			btn.icon = tex
		var idx = i
		btn.connect("pressed", self, "_on_align_button", [idx])
		hbox.add_child(btn)
		_align_buttons.append(btn)

	center.add_child(hbox)
	panel.add_child_below_node(panel.get_child(0), center)
	panel.move_child(center, 0)
	print("[TextToolFix] Alignment buttons added")

	# Find font selector control in TextTool toolbar (may be empty at this point)
	var text_toolbar = null
	for child in anchor_node.get_children():
		if str(child.get("ForceTool")) == "TextTool":
			text_toolbar = child
			break
	if text_toolbar != null:
		var font_ctrl = _find_font_control(text_toolbar)
		if font_ctrl != null:
			_font_selector_path = font_ctrl.get_path()
			print("[TextToolFix] Font selector found: %s (list loads on first use)" % font_ctrl.get_class())
		else:
			print("[TextToolFix] Font selector not found")


func _find_font_control(root: Node) -> Node:
	var queue = [root]
	var best  : Node = null
	while queue.size() > 0:
		var n = queue.pop_front()
		if n.name in ["TextAlignCenter", "TextAlignButtons"]:
			continue
		if n is ItemList:    return n
		if n is OptionButton and best == null: best = n
		for ch in n.get_children(): queue.append(ch)
	return best


func _build_font_list(ctrl: Node) -> void:
	_font_list.clear()
	if ctrl is ItemList:
		for i in range(ctrl.get_item_count()): _font_list.append(ctrl.get_item_text(i))
	elif ctrl is OptionButton:
		for i in range(ctrl.get_item_count()): _font_list.append(ctrl.get_item_text(i))


func _scroll_font(direction: int) -> void:
	if _focused_text == null or not is_instance_valid(_focused_text):
		return
	if _font_list.size() < 2 and not _font_selector_path.is_empty():
		var ctrl = _g.World.get_tree().root.get_node_or_null(_font_selector_path)
		if ctrl != null:
			_build_font_list(ctrl)
			print("[TextToolFix] Font list built: %d fonts" % _font_list.size())
	if _font_list.size() == 0:
		return
	# Read current font info — prefer direct properties over dataOnFocus
	var current_size = 48
	var current_name = ""
	var direct_size = _focused_text.get("fontSize")
	var direct_name = _focused_text.get("fontName")
	if direct_size != null and int(direct_size) > 0:
		current_size = int(direct_size)
	if direct_name != null and str(direct_name) != "":
		current_name = str(direct_name)
	if current_size <= 0 or current_name == "":
		var base = _focused_text.get("dataOnFocus")
		if base == null: return
		if current_size <= 0 and base.has("font_size"):
			current_size = int(base["font_size"])
		if current_name == "" and base.has("font_name"):
			current_name = str(base["font_name"])
	var node_id = _focused_text.get_instance_id()
	var idx: int
	if _current_font_node == node_id and _current_font_idx >= 0:
		idx = _current_font_idx
	else:
		idx = _font_list.find(current_name)
		if idx == -1: idx = 0
	idx = (idx + direction + _font_list.size()) % _font_list.size()
	_current_font_idx  = idx
	_current_font_node = node_id
	var new_font = _font_list[idx]
	var old_pos  = _focused_text.rect_position
	_focused_text.call("SetFont", new_font, current_size)
	var t = _g.World.get_tree().create_timer(0.0)
	t.connect("timeout", _focused_text, "set", ["rect_position", old_pos])
	if not _font_selector_path.is_empty():
		var ctrl = _g.World.get_tree().root.get_node_or_null(_font_selector_path)
		if ctrl is ItemList:
			ctrl.select(idx); ctrl.ensure_current_is_visible()
		elif ctrl is OptionButton:
			ctrl.select(idx)
	print("[TextToolFix] Font -> %s" % new_font)


func _on_align_button(idx: int) -> void:
	_align_mode = idx
	for i in range(_align_buttons.size()):
		if is_instance_valid(_align_buttons[i]):
			_align_buttons[i].pressed = (i == idx)
	# Find the active text — _focused_text may be null for newly created empty texts
	var target = _focused_text if (_focused_text != null and is_instance_valid(_focused_text)) else null
	if target == null and not _viewport_path.is_empty():
		var vp = _g.World.get_tree().root.get_node_or_null(_viewport_path)
		if vp:
			var texts = _get_current_texts()
			if texts:
				for tx in texts.get_children():
					if tx is Control and tx.has_focus():
						target = tx; break
	if target != null:
		var id = target.get_instance_id()
		var new_anchor_x = _anchor_x_from_rect_mode(target, idx)
		_anchors[id] = {"x": new_anchor_x, "mode": idx}
		target.call_deferred("set", "align", idx)
		target.set_meta("td_align", idx)
		_focused_text = target
		var tid = target.get_instance_id()
		if _anchors.has(tid):
			# Recompute anchor_x for new mode from current position
			_anchors[tid]["x"] = _anchor_x_from_rect_mode(target, idx)
			_anchors[tid]["mode"] = idx
		else:
			_register_anchor(target, _rect_anchor_world(target))
			_anchors[tid]["mode"] = idx
		# Apply now and again next frame (rect_size may still be 0 for empty texts)
		_apply_alignment(target)
		var tgt = target
		var t2 = _g.World.get_tree().create_timer(0.05)
		t2.connect("timeout", self, "_deferred_apply_alignment", [tgt])
	print("[TextToolFix] Align mode: %d" % idx)


func _deferred_apply_alignment(t: Node) -> void:
	if is_instance_valid(t) and t is Control:
		_apply_alignment(t)


func _anchor_x_from_rect_mode(t: Control, mode: int) -> float:
	var w = t.rect_size.x * t.rect_scale.x
	match mode:
		0: return t.rect_position.x
		1: return t.rect_position.x + w * 0.5
		2: return t.rect_position.x + w
	return t.rect_position.x


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event: InputEvent) -> void:
	if _viewport_path.is_empty():
		return
	if _g.World == null or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return

	var tree     = _g.World.get_tree()
	if tree == null:
		return
	var viewport = tree.root.get_node_or_null(_viewport_path)
	if viewport == null:
		return

	var in_text_tool   = _is_text_tool_active(tree)
	var in_select_tool = _is_select_tool_active(tree)

	if not in_text_tool and not in_select_tool and _dragging == null:
		return

	# Font scroll: wheel over font selector while text is focused
	if in_text_tool and event is InputEventMouseButton and event.pressed and 			event.button_index in [BUTTON_WHEEL_UP, BUTTON_WHEEL_DOWN] and 			not _font_selector_path.is_empty():
		var font_ctrl = tree.root.get_node_or_null(_font_selector_path)
		if font_ctrl != null and font_ctrl.get_global_rect().has_point(event.position):
			_scroll_font(-1 if event.button_index == BUTTON_WHEEL_UP else 1)
			tree.set_input_as_handled()
			return

	var over_ui_input = _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener)
	if over_ui_input and _dragging == null:
		return

	# Inline edit mode: block drag and newline — text_transform handles exit
	var _is_inline_input = _g.ModMapData.get("_ttf_inline_edit")
	if _is_inline_input != null and bool(_is_inline_input):
		return

	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			# SelectTool drag is handled by text_transform — TextTool drag only here
			if in_text_tool and _in_drag_zone and _dragging == null:
				var over_ui = _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener)
				if not over_ui:
					var world_pos = _to_world(viewport)
					if _focused_text != null and is_instance_valid(_focused_text):
						_dragging = _focused_text
						_drag_offset = _focused_text.rect_position - world_pos
						print("[TextToolFix] Drag start")
						tree.set_input_as_handled()
		elif not event.pressed and _dragging != null:
			_dragging = null
			_reset_cursor()
			tree.set_input_as_handled()

	elif event is InputEventKey and event.pressed and event.scancode == KEY_ENTER:
		if in_text_tool and _focused_text != null and is_instance_valid(_focused_text):
			var pos         = _focused_text.caret_position
			var old_text    = _focused_text.text
			var text_before = old_text.left(pos)
			var text_after  = old_text.right(pos)
			var base        = _focused_text.get("dataOnFocus")
			var src         = _focused_text
			# Read font info — prefer direct properties
			var src_font_name = ""
			var src_font_size = 48
			var dn = src.get("fontName")
			var ds = src.get("fontSize")
			if dn != null and str(dn) != "": src_font_name = str(dn)
			if ds != null and int(ds) > 0:   src_font_size = int(ds)
			if src_font_name == "" and base != null and base.has("font_name"):
				src_font_name = str(base["font_name"])
			if src_font_size <= 0 and base != null and base.has("font_size"):
				src_font_size = int(base["font_size"])
			var orig_pos    = src.rect_position
			var line_height = src.rect_size.y * src.rect_scale.y
			var new_y    = orig_pos.y + line_height
			var src_id   = src.get_instance_id()
			# If not registered yet, register now from current rect
			if not _anchors.has(src_id):
				_anchors[src_id] = {"x": _anchor_x_from_rect(src), "mode": _align_mode}
			var anchor_x = _anchors[src_id]["x"]
			var src_mode = _anchors[src_id]["mode"]
			# Compute new node x from anchor so it aligns correctly
			var new_x    = anchor_x  # will be corrected by _apply_alignment each frame
			# Read src width BEFORE any text changes
			var w_src = src.rect_size.x * src.rect_scale.x
			var new_node = src.duplicate()
			# Pre-register BEFORE add_child so _prev_text_count detection doesn't overwrite with mouse pos
			_anchors[new_node.get_instance_id()] = {"x": anchor_x, "mode": src_mode}
			src.get_parent().add_child(new_node)
			_assign_unique_node_id(new_node)
			# Set text content FIRST
			new_node.text = text_after if text_after != "" else ""
			src.text = text_before if text_before != "" else " "
			# Call SetFont on BOTH to force DD to recalculate rect_size
			new_node.call("SetFont", src_font_name, src_font_size)
			new_node.call("SetFontColor", src.get("fontColor"))
			src.call("SetFont", src_font_name, src_font_size)
			# After SetFont + text change, DD will recalculate rect_size via deferred calls.
			# Position both nodes after DD has finished, using the new rect_sizes.
			_line_break_pending = true
			var timer = tree.create_timer(0.05)
			timer.connect("timeout", self, "_fixup_line_break", [src, new_node, anchor_x, orig_pos.y, new_y, src_mode])
			new_node.grab_focus()
			new_node.caret_position = 0
			_focused_text = new_node
			_save_align_data()
			print("[TextToolFix] Simulated newline")
			tree.set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging != null:
		var world_pos  = _to_world(viewport)
		var target_pos = world_pos + _drag_offset
		if in_select_tool:
			var drag_id = _dragging.get_instance_id()
			if _anchors.has(drag_id):
				# Snap the alignment anchor point
				var mode     = _anchors[drag_id]["mode"]
				var w        = _dragging.rect_size.x * _dragging.rect_scale.x
				var anchor_x_offset: float
				match mode:
					0: anchor_x_offset = 0.0
					1: anchor_x_offset = w * 0.5
					2: anchor_x_offset = w
					_: anchor_x_offset = 0.0
				var h            = _dragging.rect_size.y * _dragging.rect_scale.y
				var anchor_world = Vector2(target_pos.x + anchor_x_offset, target_pos.y + h * 0.5)
				var snapped      = _get_snapped(anchor_world)
				target_pos = Vector2(snapped.x - anchor_x_offset, snapped.y - h * 0.5)
			else:
				var half = _dragging.rect_size * _dragging.rect_scale * 0.5
				var anchor_world = target_pos + half
				var snapped = _get_snapped(anchor_world)
				target_pos = snapped - half
		_dragging.rect_position = target_pos
		# Update anchor when dragging
		var drag_id = _dragging.get_instance_id()
		if _anchors.has(drag_id):
			_anchors[drag_id]["x"] = _anchor_x_from_rect(_dragging)
		tree.set_input_as_handled()


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta: float) -> void:
	if _viewport_path.is_empty():
		return
	if _g.World == null or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return

	var tree     = _g.World.get_tree()
	if tree == null:
		return
	var viewport = tree.root.get_node_or_null(_viewport_path)
	if viewport == null:
		return

	var in_text_tool   = _is_text_tool_active(tree)
	var in_select_tool = _is_select_tool_active(tree)

	if not in_text_tool and not in_select_tool:
		# Early-exit BEFORE calling is_mouse_over_ui — when neither tool is
		# active, the rest of this function does nothing useful, so skip the
		# tree walk that is_mouse_over_ui performs.
		_dragging = null
		_focused_text = null
		_sel_hover_text = null
		_in_drag_zone = false
		_in_sel_zone = false
		_reset_cursor()
		return

	var over_ui        = _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener)

	# In SelectTool, texts must be IGNORE so DD's drag box receives all events.
	var want_ignore = in_select_tool or over_ui
	if want_ignore and not _texts_mouse_blocked:
		_texts_mouse_blocked = true
		var tx = _get_current_texts()
		if tx:
			for t in tx.get_children():
				if t is Control:
					t.mouse_filter = 2  # IGNORE
	elif not want_ignore and _texts_mouse_blocked:
		_texts_mouse_blocked = false
		var tx = _get_current_texts()
		if tx:
			for t in tx.get_children():
				if t is Control:
					t.mouse_filter = 0  # STOP

	# Skip _get_current_texts() and the alignment loop when in SelectTool —
	# only the text-tool path below uses `texts`. text_transform handles
	# SelectTool concerns.
	if in_select_tool:
		_in_drag_zone  = false
		_in_sel_zone   = false
		_focused_text  = null
		_sel_hover_text = null
		return

	var texts = _get_current_texts()
	# Apply alignment even when mouse is over UI (alignment buttons)
	if in_text_tool and _dragging == null and texts != null:
		for t in texts.get_children():
			if t is Control:
				_apply_alignment(t)

	if over_ui:
		_in_drag_zone = false
		_in_sel_zone = false
		_reset_cursor()
		return

	var world_pos = _to_world(viewport)



	# ── Detect new text creation ──────────────────────────────────────────────
	if in_text_tool and texts != null:
		var count = texts.get_child_count()
		if _prev_text_count >= 0 and count > _prev_text_count and not _restoring:
			# A new text was just created — register its anchor
			var new_t = texts.get_child(count - 1)
			if new_t is Control and not _anchors.has(new_t.get_instance_id()):
				_register_anchor(new_t, world_pos)
				_apply_alignment(new_t)
		_prev_text_count = count

	# ── Text Tool mode ────────────────────────────────────────────────────────
	if in_text_tool:
		_in_sel_zone = false
		_sel_hover_text = null

		# Inline edit mode: only track focus, no drag zone or custom cursors
		var _is_inline = _g.ModMapData.get("_ttf_inline_edit")
		var _inline_active = _is_inline != null and bool(_is_inline)

		if texts != null:
			for t in texts.get_children():
				if t is Control and t.has_focus():
					if _focused_text != t:
						# Text just gained focus — register anchor if not already set
						if not _anchors.has(t.get_instance_id()):
							_register_anchor(t, _rect_anchor_world(t))
					_focused_text = t
					break

		if _focused_text != null and not is_instance_valid(_focused_text):
			_focused_text = null

		if _inline_active:
			_in_drag_zone = false
			_reset_cursor()
		else:
			var cursor_over_any = false
			if texts != null:
				for t in texts.get_children():
					if t is Control and _rect_of(t).has_point(world_pos):
						cursor_over_any = true
						break

			_in_drag_zone = false
			if not cursor_over_any and _focused_text != null and is_instance_valid(_focused_text):
				var inner = _rect_of(_focused_text)
				var outer = _text_tool_zone(_focused_text)
				_in_drag_zone = outer.has_point(world_pos) and not inner.has_point(world_pos)

			if _in_drag_zone and _dragging == null:
				_set_drag_cursor()
			elif _dragging == null:
				_reset_cursor()

	# ── Select Tool mode: handled by text_transform ────────────────────────────
	elif in_select_tool:
		_in_drag_zone  = false
		_in_sel_zone   = false
		_focused_text  = null
		_sel_hover_text = null


# ── Alignment helpers ─────────────────────────────────────────────────────────

func _register_anchor(t: Control, world_pos: Vector2) -> void:
	if not is_instance_valid(t):
		return
	_anchors[t.get_instance_id()] = {"x": world_pos.x, "mode": _align_mode}
	t.call_deferred("set", "align", _align_mode)
	t.set_meta("td_align", _align_mode)  # survives clone level
	# Connect focus signal to sync buttons when user clicks this text
	if not t.is_connected("focus_entered", self, "_on_text_focus_entered"):
		t.connect("focus_entered", self, "_on_text_focus_entered", [t])
	print("[TextToolFix] Registered anchor x=%.1f mode=%d for %s" % [world_pos.x, _align_mode, t.name])


func _on_text_focus_entered(t: Node) -> void:
	if not is_instance_valid(t):
		return
	if t.get_instance_id() != _current_font_node:
		_current_font_idx  = -1
		_current_font_node = 0
	var id = t.get_instance_id()
	if not _anchors.has(id):
		# Try to restore from saved metadata first
		var saved_mode = _align_mode
		if t.has_meta("td_align"):
			saved_mode = int(t.get_meta("td_align"))
		var old_mode = _align_mode
		_align_mode = saved_mode
		_register_anchor(t, _rect_anchor_world(t))
		_align_mode = old_mode
		_anchors[id]["mode"] = saved_mode
	var mode = _anchors[id]["mode"]
	_align_mode = mode
	for i in range(_align_buttons.size()):
		if is_instance_valid(_align_buttons[i]):
			_align_buttons[i].pressed = (i == mode)
	_focused_text = t
	print("[TextToolFix] Focus -> %s mode=%d" % [t.name, mode])


func register_anchor_external(t: Control, pos: Vector2, align_mode: int) -> void:
	# Called from text_transform after paste
	var id = t.get_instance_id()
	var w = t.rect_size.x * t.rect_scale.x
	var ax: float
	match align_mode:
		0: ax = pos.x
		1: ax = pos.x + w * 0.5
		2: ax = pos.x + w
		_: ax = pos.x
	_anchors[id] = {"x": ax, "mode": align_mode}
	t.call_deferred("set", "align", align_mode)
	t.set_meta("td_align", align_mode)
	if not t.is_connected("focus_entered", self, "_on_text_focus_entered"):
		t.connect("focus_entered", self, "_on_text_focus_entered", [t])
	print("[TextToolFix] Registered pasted text mode=%d ax=%.1f" % [align_mode, ax])


func update_anchor_after_move(t: Control) -> void:
	# Called from text_transform after group move
	if not is_instance_valid(t): return
	var id = t.get_instance_id()
	if _anchors.has(id):
		_anchors[id]["x"] = _anchor_x_from_rect(t)


func _apply_alignment(t: Control) -> void:
	if _line_break_pending:
		return
	var id = t.get_instance_id()
	if not _anchors.has(id):
		return
	var data     = _anchors[id]
	var anchor_x = data["x"]
	var mode     = data["mode"]
	var w        = t.rect_size.x * t.rect_scale.x
	var new_x: float
	match mode:
		0: new_x = anchor_x
		1: new_x = anchor_x - w * 0.5
		2: new_x = anchor_x - w
		_: new_x = anchor_x
	if abs(t.rect_position.x - new_x) > 0.5:
		var dof = t.get("dataOnFocus")
		if dof != null:
			dof["position"] = Vector2(new_x, t.rect_position.y)
			t.set("dataOnFocus", dof)
		t.rect_position = Vector2(new_x, t.rect_position.y)


func _anchor_x_from_rect(t: Control) -> float:
	var id   = t.get_instance_id()
	var mode = _align_mode
	if _anchors.has(id):
		mode = _anchors[id]["mode"]
	var w = t.rect_size.x * t.rect_scale.x
	match mode:
		0: return t.rect_position.x
		1: return t.rect_position.x + w * 0.5
		2: return t.rect_position.x + w
	return t.rect_position.x


# ── Helpers ───────────────────────────────────────────────────────────────────

func _fixup_line_break(src: Control, new_node: Control, anchor_x: float, src_y: float, new_y: float, mode: int) -> void:
	_line_break_pending = false
	# Called after DD's deferred rect_size recalculation.
	# Position both texts using their now-correct rect_size and the shared anchor_x.
	for info in [{"node": src, "y": src_y}, {"node": new_node, "y": new_y}]:
		var t = info.node
		if not is_instance_valid(t):
			continue
		var w = t.rect_size.x * t.rect_scale.x
		var new_x: float
		match mode:
			0: new_x = anchor_x
			1: new_x = anchor_x - w * 0.5
			2: new_x = anchor_x - w
			_: new_x = anchor_x
		t.rect_position = Vector2(new_x, info.y)
		# Update dataOnFocus so DD knows about the new position
		var dof = t.get("dataOnFocus")
		if dof != null:
			dof["position"] = t.rect_position
			t.set("dataOnFocus", dof)
		# Update anchor
		_anchors[t.get_instance_id()] = {"x": anchor_x, "mode": mode}
	_save_align_data()
	print("[TextToolFix] Line break fixup done: anchor_x=%.1f mode=%d" % [anchor_x, mode])


func _assign_unique_node_id(node: Node) -> void:
	var max_id = 0
	var texts = _get_current_texts()
	if texts != null:
		for t in texts.get_children():
			if t == node: continue
			var nid = _get_node_id(t)
			if nid != null:
				var nid_int = int(nid)
				if nid_int > max_id:
					max_id = nid_int
	var new_id = max_id + 1
	var meta = node.get("__meta__")
	if meta is Dictionary:
		meta["node_id"] = new_id
		node.set("__meta__", meta)
	print("[TextToolFix] Assigned node_id %d" % new_id)


func _rect_anchor_world(t: Control) -> Vector2:
	# Returns the anchor point as a world position based on current align mode
	var r = _rect_of(t)
	match _align_mode:
		0: return Vector2(r.position.x, r.position.y)
		1: return Vector2(r.position.x + r.size.x * 0.5, r.position.y)
		2: return Vector2(r.position.x + r.size.x, r.position.y)
	return r.position


func _is_text_tool_active(tree) -> bool:
	if _text_toolbar_path.is_empty():
		return false
	var tb = tree.root.get_node_or_null(_text_toolbar_path)
	return tb != null and tb.visible

func _is_select_tool_active(tree) -> bool:
	if _select_toolbar_path.is_empty():
		return false
	var tb = tree.root.get_node_or_null(_select_toolbar_path)
	return tb != null and tb.visible

func _to_world(viewport) -> Vector2:
	return viewport.canvas_transform.affine_inverse().xform(viewport.get_mouse_position())

func _rect_of(t: Control) -> Rect2:
	return Rect2(t.rect_position, t.rect_size * t.rect_scale)

func _text_tool_zone(t: Control) -> Rect2:
	var r = _rect_of(t)
	var m = Vector2(r.size.y * 2.0, r.size.y * 2.0)
	return Rect2(r.position - m, r.size + m * 2.0)

func _select_tool_zone(t: Control) -> Rect2:
	var r = _rect_of(t)
	var m = Vector2(r.size.y * 0.1, r.size.y * 0.1)
	return Rect2(r.position - m, r.size + m * 2.0)


# ── Snap ──────────────────────────────────────────────────────────────────────

func _get_snapped(pos: Vector2) -> Vector2:
	if not _g.Editor.IsSnapping:
		return pos
	var world_ui = _g.WorldUI
	if world_ui and world_ui.has_method("GetSnappedPosition"):
		return world_ui.GetSnappedPosition(pos)
	var cell_size = world_ui.CellSize
	if cell_size is Vector2:
		var snap = cell_size.x * 0.5
		if world_ui.get("UseHalfSnap"):
			snap *= 0.5
		return Vector2(stepify(pos.x, snap), stepify(pos.y, snap))
	return pos


# ── Cursor ────────────────────────────────────────────────────────────────────

func _load_cursor_texture() -> void:
	var path = _g.Root + "icons/drag-cursor-icon.png"
	var img = Image.new()
	if img.load(path) != OK:
		print("[TextToolFix] Failed to load cursor: " + path)
		return
	_move_cursor_tex = ImageTexture.new()
	_move_cursor_tex.create_from_image(img, 0)
	print("[TextToolFix] Loaded cursor: " + path)

func _set_drag_cursor() -> void:
	if _move_cursor_tex == null:
		_load_cursor_texture()
	if _move_cursor_tex:
		var hotspot = _move_cursor_tex.get_size() / 2
		Input.set_custom_mouse_cursor(_move_cursor_tex, Input.CURSOR_ARROW, hotspot)
		_cursor_active = true

func _reset_cursor() -> void:
	if _cursor_active:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_cursor_active = false