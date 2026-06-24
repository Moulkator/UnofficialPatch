# text_transform.gd — v3
# Multi-selection, group transform, drag-box, copy/paste in SelectTool.
# Handles: 0=TL 1=TC 2=TR 3=MR 4=BR 5=BC 6=BL 7=ML  8=ROT
# Single selection : rotated transform box, corners commit to font size
# Multi  selection : AABB box (no rotation), corners scale only

var _g
var _ui_util = null
var _mouse_over_ui = false
var _viewport_path       : NodePath
var _select_toolbar_path : NodePath
var _select_tool         = null   # DD SelectTool C# node
var _anchor_path         : NodePath  # stored during setup when _g.Editor is safe
var _overlay             : Node = null
var _input_listener      : Node = null

# ── Selection ──────────────────────────────────────────────────────────────────
var _selected_texts : Array = []
var _primary_text   : Node  = null   # snap anchor for group moves

# ── Handle drag ───────────────────────────────────────────────────────────────
const IDX_ROT    := 8
const CORNER_IDX := [0, 2, 4, 6]
const EDGE_IDX   := [1, 3, 5, 7]

var _active_handle  := -1
var _drag_start_pos := Vector2.ZERO
var _drag_states    : Array = []  # {node, pos, rot, sx, sy, font_size, font_name}
var _group_bbox     := Rect2()    # AABB at drag start (world space)

# ── Group move ────────────────────────────────────────────────────────────────
var _group_moving      := false
var _group_move_moved  := false
var _move_offsets  : Array = []   # {node, offset: Vector2}

# ── Font size tracking (single node) ─────────────────────────────────────────
var _last_font_size := 0
var _last_font_node := 0

# ── Passive drag-box (no event consumption) ──────────────────────────────────
var _pbox_active := false   # tracking active
var _pbox_moved  := false   # moved past threshold
var _pbox_start  := Vector2.ZERO
var _pbox_cur    := Vector2.ZERO

# ── Modifiers ─────────────────────────────────────────────────────────────────
var _mod_alt   := false
var _mod_shift := false

# ── Undo stack ────────────────────────────────────────────────────────────────
# Each entry: {type: "paste"|"delete", data: [...]}
var _undo_stack : Array = []

# ── Clipboard ─────────────────────────────────────────────────────────────────
var _clipboard : Array = []
# [{text, font_name, font_size, font_color, position, rotation, sx, sy, align_mode}]
# Vrai quand la copie incluait aussi des assets sélectionnés côté DD (sélection
# mixte). Sert à router le collage : si mixte, on ne consomme pas Ctrl+V afin que
# DD colle ses assets en parallèle de nos textes.
var _clipboard_mixed := false
# Template node kept for paste-when-map-has-no-text (e.g. after Ctrl+X that
# removed the only existing text). Duplicated from a selected text at cut time.
var _paste_template_node : Node = null

# ── Cursors ───────────────────────────────────────────────────────────────────
var _cursor_active     := false
var _current_cursor_key := ""   # caches current cursor identity to avoid
                                # re-calling Input.set_custom_mouse_cursor every
                                # frame (was a measurable cost in SelectTool)
var _cursors           := {}
var _move_cursor_tex   = null

# ── Overlay processing gate ──────────────────────────────────────────────────
# Tracks whether overlay's _process is currently enabled. We disable it when
# SelectTool is inactive — the overlay early-exits anyway, but skipping the
# whole _process → update() → _draw() chain is cheaper than running it empty.
var _overlay_processing := true

# ── Texts filter ──────────────────────────────────────────────────────────────
var _texts_filter_enabled := true
var _filter_popup        : Node = null
var _filter_item_idx     := -1

# ── Inline edit (double-click to edit text without leaving SelectTool) ────────
var _inline_edit_node : Node = null

# ── Alignment buttons in SelectTool ──────────────────────────────────────────
var _align_container : Node = null
var _align_buttons_st := []

# ── Custom rotation / scale persistence ──────────────────────────────────────
# DD's text save format only stores box_shape, font_color, font_name, font_size,
# node_id, position, text. Rotation and scale are NOT serialised by DD.
# We persist them ourselves via ModMapData (saved with every Ctrl+S, Save As,
# auto-backup) plus a sidecar JSON fallback. Pattern follows text_tool_fix.
const MOD_DATA_KEY := "TextTransform_Transforms"
var _transforms       : Dictionary = {}     # { node_id_str: {rot, sx, sy} }
var _last_world_id    : int        = -1
var _transforms_loaded             := false
var _save_btn_connected            := false


# ══ Helpers (level-aware) ═════════════════════════════════════════════════════

func _get_current_texts() -> Node:
	var level = _g.World.GetCurrentLevel() if _g.World else null
	return level.Texts if level != null else null


# ══ Setup ═════════════════════════════════════════════════════════════════════

func initialize() -> void:
	print("[TextTransform] Initialized")
	_try_setup(0)


func _try_setup(attempt: int) -> void:
	if attempt > 20:
		print("[TextTransform] Setup failed after 20 attempts")
		return
	# Check if key nodes are ready
	var vp = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if vp == null or anchor == null:
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_try_setup", [attempt + 1])
		return
	_do_setup()


func _do_setup() -> void:
	var vp = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	if vp == null:
		print("[TextTransform] Viewport not found"); return
	_viewport_path = vp.get_path()

	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor:
		_anchor_path = anchor.get_path()
		for child in anchor.get_children():
			if str(child.get("ForceTool")) == "SelectTool":
				_select_toolbar_path = child.get_path()
				break

	# Overlay lives in World so its draw coords == world space (same as rect_position)
	var ov_script = GDScript.new()
	ov_script.source_code = "extends Node2D\nvar handler = null\nfunc _process(_d):\n\tupdate()\nfunc _draw():\n\tif handler != null:\n\t\thandler._draw_overlay(self)\n"
	ov_script.reload()
	_overlay = Node2D.new()
	_overlay.name = "TextTransformOverlay"
	_overlay.set_script(ov_script)
	_overlay.handler = self
	_g.World.call_deferred("add_child", _overlay)

	var in_script = GDScript.new()
	in_script.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	in_script.reload()
	_input_listener = Node.new()
	_input_listener.name = "TextTransformListener"
	_input_listener.set_script(in_script)
	_input_listener.handler = self
	# Pas de move_child(0) : décalerait GridMesh (index 0) et casserait Snappy Grid,
	# qui appelle Global.World.get_child("GridMesh") -> se comporte comme get_child(0).
	# text_tool_fix utilise call_deferred pour son add_child, donc son listener est
	# ajouté APRÈS celui-ci dans l'arbre quoi qu'il arrive.
	_g.World.add_child(_input_listener)

	var uu = ResourceLoader.load(_g.Root + "scripts/ui_util.gd", "GDScript", true)
	if uu: _ui_util = uu.new()

	# Get DD's SelectTool
	var tools = _g.Editor.get("Tools")
	if tools != null and tools.has("SelectTool"):
		_select_tool = tools["SelectTool"]
		print("[TextTransform] SelectTool acquired")

	_g.ModMapData["_ttf_transform"] = self
	# Dump SelectTool toolbar children to find filter UI
	if not _select_toolbar_path.is_empty():
		var tb = _g.World.get_tree().root.get_node_or_null(_select_toolbar_path)
		if tb:
			print("[TextTransform] SelectTool toolbar: ", tb.name)
			_dump_children(tb, 0)
	_load_cursors()
	_load_move_cursor()
	print("[TextTransform] Ready")
	# Filter setup: retry until SelectToolPanel is populated
	_try_filter_setup(0)


func _try_filter_setup(attempt: int) -> void:
	if attempt > 20:
		print("[TextTransform] Filter setup failed after 20 attempts")
		return
	if not _input_listener or not is_instance_valid(_input_listener):
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_try_filter_setup", [attempt + 1])
		return
	var anchor = _input_listener.get_node_or_null(_anchor_path)
	if anchor == null:
		var t = _g.World.get_tree().create_timer(0.2)
		t.connect("timeout", self, "_try_filter_setup", [attempt + 1])
		return
	# Check if SelectToolPanel/Align is populated (has VBoxContainer children in align)
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
			if align != null and align.get_child_count() > 0:
				_setup_texts_filter_delayed()
				return
			break
	var t = _g.World.get_tree().create_timer(0.2)
	t.connect("timeout", self, "_try_filter_setup", [attempt + 1])


# ══ Cursors ═══════════════════════════════════════════════════════════════════

func _load_move_cursor() -> void:
	var img = Image.new()
	if img.load(_g.Root + "icons/drag-cursor-icon.png") != OK:
		print("[TextTransform] Move cursor not found"); return
	_move_cursor_tex = ImageTexture.new()
	_move_cursor_tex.create_from_image(img, 0)
	print("[TextTransform] Move cursor loaded")


func _load_cursors() -> void:
	var files = {
		"resize-nwse": [0, 4], "resize-nesw": [2, 6],
		"resize-ns":   [1, 5], "resize-ew":   [3, 7],
		"rotate":      [8],
	}
	for fname in files.keys():
		var img = Image.new()
		if img.load(_g.Root + "icons/" + fname + ".png") != OK: continue
		var tex = ImageTexture.new()
		tex.create_from_image(img, 0)
		for idx in files[fname]: _cursors[idx] = tex


func _set_cursor(handle_idx: int) -> void:
	if _cursors.has(handle_idx):
		var key = "h%d" % handle_idx
		if _cursor_active and _current_cursor_key == key:
			return
		var tex = _cursors[handle_idx]
		Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2)
		_cursor_active = true
		_current_cursor_key = key
	else:
		_do_reset_cursor()


func _set_move_cursor() -> void:
	if _move_cursor_tex:
		if _cursor_active and _current_cursor_key == "move":
			return
		var hs = _move_cursor_tex.get_size() / 2
		Input.set_custom_mouse_cursor(_move_cursor_tex, Input.CURSOR_ARROW, hs)
		_cursor_active = true
		_current_cursor_key = "move"
	else:
		_do_reset_cursor()


func _reset_cursor() -> void:
	_do_reset_cursor()


func _do_reset_cursor() -> void:
	if not _cursor_active:
		return
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	_cursor_active = false
	_current_cursor_key = ""


# ══ Update (from Core.gd every frame) ════════════════════════════════════════

func update(_delta: float) -> void:
	if _viewport_path.is_empty(): return
	# Détecte les changements de map et restaure les rotations/scales saved
	_check_world_change()
	var tree = _g.World.get_tree()
	if not _is_select_tool_active(tree):
		if _inline_edit_node != null:
			_end_inline_edit()
		_selected_texts.clear()
		_primary_text = null
		if _align_container != null and is_instance_valid(_align_container):
			_align_container.visible = false
		# Gate overlay's _process: when SelectTool is inactive, _draw_overlay
		# would early-return anyway, but skipping the whole _process →
		# update() → _draw() chain is cheaper than running it empty each frame.
		if _overlay_processing and _overlay != null and is_instance_valid(_overlay):
			_overlay.set_process(false)
			_overlay_processing = false
		return

	# Re-enable overlay processing when we enter SelectTool
	if not _overlay_processing and _overlay != null and is_instance_valid(_overlay):
		_overlay.set_process(true)
		_overlay_processing = true

	# Inline edit mode: skip all SelectTool logic, just manage the editing text
	if _inline_edit_node != null:
		if not is_instance_valid(_inline_edit_node):
			_end_inline_edit()
			return
		_inline_edit_node.mouse_filter = Control.MOUSE_FILTER_STOP
		if _align_container != null and is_instance_valid(_align_container):
			_align_container.visible = false
		return

	# Passive drag-box — read mouse state without consuming events
	var lmb_down = Input.is_mouse_button_pressed(BUTTON_LEFT)
	_mouse_over_ui = _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener)
	var vp_pb = tree.root.get_node_or_null(_viewport_path)
	if vp_pb != null and not _mouse_over_ui:
		var wp_pb = _mouse_world(vp_pb)
		if lmb_down and not _pbox_active and _active_handle < 0 and not _group_moving:
			var on_sel = false
			for t in _selected_texts:
				if is_instance_valid(t) and _text_aabb(t).has_point(wp_pb):
					on_sel = true; break
			if not on_sel and _hit_handle(wp_pb, vp_pb) < 0:
				_pbox_active = true
				_pbox_moved  = false
				_pbox_start  = wp_pb
				_pbox_cur    = wp_pb
		elif lmb_down and _pbox_active:
			_pbox_cur = wp_pb
			if _pbox_start.distance_to(wp_pb) > 4.0:
				_pbox_moved = true
		elif not lmb_down and _pbox_active:
			if _pbox_moved:
				_finish_pbox_select(vp_pb)
				print("[TextTransform] Box select done: %d texts" % _selected_texts.size())
			_pbox_active = false
			_pbox_moved  = false

	# Prune stale refs
	var i = 0
	while i < _selected_texts.size():
		if not is_instance_valid(_selected_texts[i]):
			_selected_texts.remove(i)
		else:
			i += 1
	# Poll FILTER popup checked state for Texts item
	if _filter_popup != null and is_instance_valid(_filter_popup) and _filter_item_idx >= 0:
		var checked = _filter_popup.is_item_checked(_filter_item_idx)
		if checked != _texts_filter_enabled:
			_texts_filter_enabled = checked
			if not checked:
				_selected_texts.clear()
				_primary_text = null


	# Cursor: resolved and written every frame so DD's IBeam never wins
	var vp_cur = tree.root.get_node_or_null(_viewport_path)
	if vp_cur != null and not _mouse_over_ui:
		var wp_cur = _mouse_world(vp_cur)
		if _active_handle >= 0:
			_set_cursor(_active_handle)
		elif _group_moving:
			_set_move_cursor()
		else:
			var resolved = false
			if _selected_texts.size() > 0:
				var hit = _hit_handle(wp_cur, vp_cur)
				if hit >= 0:
					_set_cursor(hit)
					resolved = true
				else:
					var inside = _selection_bbox().has_point(wp_cur) if _selected_texts.size() > 1 else \
						(is_instance_valid(_selected_texts[0]) and _text_aabb(_selected_texts[0]).has_point(wp_cur))
					if inside:
						_set_move_cursor()
						resolved = true
			if not resolved:
				_reset_cursor()
	elif _mouse_over_ui:
		_reset_cursor()

	_update_align_visibility()


# ══ Input ═════════════════════════════════════════════════════════════════════

func _on_input(event: InputEvent) -> void:
	if _viewport_path.is_empty(): return
	var tree = _g.World.get_tree()
	if not _is_select_tool_active(tree): return
	var vp = tree.root.get_node_or_null(_viewport_path)
	if vp == null: return

	# ── Inline edit mode: intercept everything ────────────────────────────────
	if _inline_edit_node != null and is_instance_valid(_inline_edit_node):
		# Enter or Escape → end editing
		if event is InputEventKey and event.pressed:
			if event.scancode == KEY_ENTER or event.scancode == KEY_KP_ENTER or event.scancode == KEY_ESCAPE:
				_end_inline_edit()
				tree.set_input_as_handled()
				return
			# Let all other keys go to the focused text (typing, arrows, backspace, etc.)
			return
		# LMB press outside the text → end editing
		if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
			var wp_ie = _mouse_world(vp)
			var r = Rect2(_inline_edit_node.rect_position, _inline_edit_node.rect_size * _inline_edit_node.rect_scale)
			if not r.has_point(wp_ie):
				_end_inline_edit()
				tree.set_input_as_handled()
				return
			# Click inside the text → let Godot handle caret positioning
			return
		# Ignore all other events during inline edit
		return

	# Track modifiers from any event
	if event is InputEventKey:
		_mod_alt   = event.alt
		_mod_shift = event.shift
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		_mod_alt   = event.alt
		_mod_shift = event.shift

	# Keyboard shortcuts
	if event is InputEventKey and event.pressed and not event.echo:
		if event.control and event.scancode == KEY_C:
			# Ne capturer Ctrl+C que si des textes sont sélectionnés. Sinon, vider
			# notre presse-papiers (pour router le prochain Ctrl+V vers DD) et laisser
			# l'évènement passer aux handlers natifs / mods tiers (ex. ColorAndModifyThings).
			if _selected_texts.size() > 0:
				_copy_selection()  # met aussi _clipboard_mixed à jour
				# Sélection mixte (textes + assets DD) : on NE consomme PAS l'évènement
				# afin que le copy natif de DD (et clipboard_fix / ColorAndModifyThings)
				# copie les assets en parallèle. Les textes ne sont jamais dans DD.Selected
				# (gérés indépendamment), donc aucun risque de double-copie.
				if _clipboard_mixed:
					return
				tree.set_input_as_handled(); return
			else:
				_clipboard.clear()
				_clipboard_mixed = false
				return
		if event.control and event.scancode == KEY_V:
			# Ne capturer Ctrl+V que si notre presse-papiers contient des textes.
			# Sinon, laisser DD coller ses assets et préserver leurs propriétés tierces.
			if not _clipboard.empty():
				_paste_selection(vp)
				# Si la copie était mixte, ne pas consommer : DD colle ses assets
				# (toujours dans son presse-papiers depuis la copie non consommée).
				if _clipboard_mixed:
					return
				tree.set_input_as_handled(); return
			else:
				return
		if event.control and event.scancode == KEY_Z:
			# Seulement si des textes sont sélectionnés — sinon DD gère son propre undo
			if _selected_texts.size() > 0:
				_undo_action(vp); tree.set_input_as_handled(); return
		if event.scancode in [KEY_DELETE, KEY_BACKSPACE] and _selected_texts.size() > 0:
			_delete_selection()
			tree.set_input_as_handled(); return
		# Enter on a single selected text → start inline edit
		if event.scancode == KEY_ENTER or event.scancode == KEY_KP_ENTER:
			if _selected_texts.size() == 1 and is_instance_valid(_selected_texts[0]):
				_start_inline_edit(_selected_texts[0])
				tree.set_input_as_handled(); return

	if _ui_util != null and _ui_util.is_mouse_over_ui(_input_listener):
		return

	var wp = _mouse_world(vp)

	# ── LMB press ─────────────────────────────────────────────────────────────
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		# 1. Handle drag on current selection
		if _selected_texts.size() > 0:
			var hit = _hit_handle(wp, vp)
			if hit >= 0:
				_start_handle_drag(hit, wp)
				tree.set_input_as_handled(); return

		# 2. Click inside selection bbox → group move (or double-click → inline edit)
		if _selected_texts.size() > 0:
			var inside_any = false
			var dbl_target = null
			if _selected_texts.size() == 1:
				if is_instance_valid(_selected_texts[0]) and _text_aabb(_selected_texts[0]).has_point(wp):
					inside_any = true
					dbl_target = _selected_texts[0]
			else:
				inside_any = _selection_bbox().has_point(wp)
				for t in _selected_texts:
					if is_instance_valid(t) and _text_aabb(t).has_point(wp):
						dbl_target = t; break
			if inside_any:
				if event.doubleclick and dbl_target != null:
					_start_inline_edit(dbl_target)
					tree.set_input_as_handled(); return
				_start_group_move(wp)
				tree.set_input_as_handled(); return

		# 3. Click on any text → select (if filter enabled)
		if not _texts_filter_enabled: return
		var texts = _get_current_texts()
		if texts:
			var hit_node = null
			var ch = texts.get_children()
			for k in range(ch.size() - 1, -1, -1):
				var nd = ch[k]
				if nd is Control and _text_aabb(nd).has_point(wp):
					hit_node = nd; break
			if hit_node != null:
				_ensure_text_sized(hit_node)
				if _mod_shift:
					var idx = _selected_texts.find(hit_node)
					if idx >= 0: _selected_texts.remove(idx)
					else:        _selected_texts.append(hit_node)
					_primary_text = hit_node
				else:
					_selected_texts = [hit_node]
					_primary_text   = hit_node
					# The previous asset's transform box is drawn by DD's SelectTool
					# via EnableTransformBox — independent of Selected[] / isSelected.
					# Hide it directly, then deselect. Consume event to block drag-box.
					if _select_tool != null:
						_select_tool.call("EnableTransformBox", false)
						_select_tool.call("DeselectAll")
					_start_group_move(wp)
					tree.set_input_as_handled(); return

		# 4. Empty space → clear selection (DD handles the rest)
		if not _mod_shift:
			_selected_texts.clear()
			_primary_text = null

	# ── LMB release ───────────────────────────────────────────────────────────
	elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		if _active_handle >= 0:
			_commit_handle_drag()
			_active_handle = -1
			tree.set_input_as_handled()
		elif _group_moving:
			_finish_group_move()
			tree.set_input_as_handled()
	# ── Mouse motion ──────────────────────────────────────────────────────────
	elif event is InputEventMouseMotion:
		if _active_handle >= 0:
			_update_handle_drag(wp, vp)
			tree.set_input_as_handled()
		elif _group_moving:
			_update_group_move(wp, vp)
			tree.set_input_as_handled()

# ══ Geometry ══════════════════════════════════════════════════════════════════

func _mouse_world(vp: Node) -> Vector2:
	return vp.canvas_transform.affine_inverse().xform(vp.get_mouse_position())

# Axis-aligned bounding box of a text node (accounts for rotation)
# Returns the tight visual rect of a text node (trimmed to actual text content)
func _text_visual_rect(t: Control) -> Dictionary:
	# Returns {o: origin, w: width, h: height} accounting for alignment mode
	var w = t.rect_size.x * t.rect_scale.x
	var h = t.rect_size.y * t.rect_scale.y
	var o = t.rect_position

	# Try to measure the actual text width
	var text_str = t.get("text")
	var font_res = t.get_font("font") if t.has_method("get_font") else null
	if text_str != null and text_str != "" and font_res != null:
		var measured_w = font_res.get_string_size(text_str).x * t.rect_scale.x
		if measured_w > 5.0 and measured_w < w * 0.95:
			# There's extra space — trim based on alignment mode
			var mode = 0
			var ttf = _g.ModMapData.get("_ttf_handler")
			if ttf != null:
				var id = t.get_instance_id()
				if ttf._anchors.has(id):
					mode = ttf._anchors[id]["mode"]
				elif t.has_meta("td_align"):
					mode = int(t.get_meta("td_align"))
			elif t.has_meta("td_align"):
				mode = int(t.get_meta("td_align"))
			match mode:
				0: # Left aligned — trim from right
					w = measured_w
				1: # Center — trim both sides
					o = Vector2(o.x + (w - measured_w) * 0.5, o.y)
					w = measured_w
				2: # Right — trim from left
					o = Vector2(o.x + w - measured_w, o.y)
					w = measured_w
	return {"o": o, "w": w, "h": h}


func _text_aabb(t: Control) -> Rect2:
	var rot = deg2rad(t.rect_rotation)
	var vr = _text_visual_rect(t)
	var o = vr.o; var w = vr.w; var h = vr.h
	var corners = [
		o,
		o + Vector2(w, 0).rotated(rot),
		o + Vector2(w, h).rotated(rot),
		o + Vector2(0, h).rotated(rot),
	]
	var mn = corners[0]; var mx = corners[0]
	for c in corners:
		mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y)
		mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y)
	return Rect2(mn, mx - mn)

# Compute AABB of the whole selection
func _selection_bbox() -> Rect2:
	var mn = Vector2(INF, INF); var mx = Vector2(-INF, -INF)
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		var bb = _text_aabb(t)
		mn.x = min(mn.x, bb.position.x); mn.y = min(mn.y, bb.position.y)
		mx.x = max(mx.x, bb.end.x);      mx.y = max(mx.y, bb.end.y)
	if mn.x == INF: return Rect2()
	return Rect2(mn, mx - mn)

# Handle positions: rotated for single node, AABB-aligned for group
func _current_handle_positions(vp: Node) -> Array:
	if _selected_texts.size() == 0: return []
	if _selected_texts.size() == 1:
		return _single_handle_positions(_selected_texts[0])
	return _bbox_handle_positions(_selection_bbox())

func _single_handle_positions(t: Control) -> Array:
	var rot = deg2rad(t.rect_rotation)
	var vr = _text_visual_rect(t)
	var o = vr.o; var w = vr.w; var h = vr.h
	return [
		o,                                       # 0 TL
		o + Vector2(w * 0.5, 0).rotated(rot),   # 1 TC
		o + Vector2(w,       0).rotated(rot),   # 2 TR
		o + Vector2(w, h * 0.5).rotated(rot),   # 3 MR
		o + Vector2(w,       h).rotated(rot),   # 4 BR
		o + Vector2(w * 0.5, h).rotated(rot),   # 5 BC
		o + Vector2(0,       h).rotated(rot),   # 6 BL
		o + Vector2(0, h * 0.5).rotated(rot),   # 7 ML
	]

func _bbox_handle_positions(bb: Rect2) -> Array:
	var o = bb.position; var w = bb.size.x; var h = bb.size.y
	return [
		o,
		o + Vector2(w * 0.5, 0),
		o + Vector2(w,       0),
		o + Vector2(w, h * 0.5),
		o + Vector2(w,       h),
		o + Vector2(w * 0.5, h),
		o + Vector2(0,       h),
		o + Vector2(0, h * 0.5),
	]

func _rot_handle_world(handles: Array, vp: Node) -> Vector2:
	var zoom = vp.canvas_transform.get_scale().x
	# For single: rotate with the node; for multi: straight up
	if _selected_texts.size() == 1 and is_instance_valid(_selected_texts[0]):
		var rot = deg2rad(_selected_texts[0].rect_rotation)
		return handles[1] + Vector2(0, -36.0 / zoom).rotated(rot)
	return handles[1] + Vector2(0, -36.0 / zoom)

func _hit_handle(wp: Vector2, vp: Node) -> int:
	var hs = _current_handle_positions(vp)
	if hs.empty(): return -1
	var zoom = vp.canvas_transform.get_scale().x
	var thr  = 12.0 / zoom
	var rh   = _rot_handle_world(hs, vp)
	if wp.distance_to(rh) < thr: return IDX_ROT
	for k in range(hs.size()):
		if wp.distance_to(hs[k]) < thr: return k
	return -1

# Pivot world position for a given handle (using _group_bbox)
func _get_pivot(handle_idx: int) -> Vector2:
	var o  = _group_bbox.position
	var w  = _group_bbox.size.x
	var h  = _group_bbox.size.y
	var cx = o + Vector2(w * 0.5, h * 0.5)
	if _mod_alt or handle_idx == IDX_ROT: return cx
	# For single-node: rotated pivot using drag_start_rot
	if _selected_texts.size() == 1 and _drag_states.size() == 1:
		var rot = deg2rad(_drag_states[0].rot)
		match handle_idx:
			0: return o + Vector2(w, h).rotated(rot) + o - o  # corrected below
			_: pass
	# Use AABB pivot (no rotation) — works for both single and multi
	match handle_idx:
		0: return o + Vector2(w, h)
		2: return o + Vector2(0, h)
		4: return o
		6: return o + Vector2(w, 0)
		1: return o + Vector2(w * 0.5, h)
		5: return o + Vector2(w * 0.5, 0)
		3: return o + Vector2(0, h * 0.5)
		7: return o + Vector2(w, h * 0.5)
	return cx

# For single-node rotated pivot
func _get_pivot_single(handle_idx: int) -> Vector2:
	var st  = _drag_states[0]
	var rot = deg2rad(st.rot)
	var w   = _group_bbox.size.x
	var h   = _group_bbox.size.y
	var o   = _group_bbox.position
	var cx  = o + Vector2(w * 0.5, h * 0.5)
	if _mod_alt or handle_idx == IDX_ROT: return cx
	match handle_idx:
		0: return o + Vector2(w, h).rotated(rot) + (cx - cx.rotated(rot))  # wrong
		_: pass
	# Simpler: compute from actual node corners
	var nd  = _drag_states[0].node
	var nw  = nd.rect_size.x * st.sx
	var nh  = nd.rect_size.y * st.sy
	var nO  = st.pos
	match handle_idx:
		0: return nO + Vector2(nw, nh).rotated(rot)
		2: return nO + Vector2(0,  nh).rotated(rot)
		4: return nO
		6: return nO + Vector2(nw, 0).rotated(rot)
		1: return nO + Vector2(nw * 0.5, nh).rotated(rot)
		5: return nO + Vector2(nw * 0.5, 0).rotated(rot)
		3: return nO + Vector2(0, nh * 0.5).rotated(rot)
		7: return nO + Vector2(nw, nh * 0.5).rotated(rot)
	return cx

func _pivot_local_single(handle_idx: int, nw: float, nh: float) -> Vector2:
	if _mod_alt: return Vector2(nw * 0.5, nh * 0.5)
	match handle_idx:
		0: return Vector2(nw, nh)
		2: return Vector2(0,  nh)
		4: return Vector2(0,  0)
		6: return Vector2(nw, 0)
		1: return Vector2(nw * 0.5, nh)
		5: return Vector2(nw * 0.5, 0)
		3: return Vector2(0,        nh * 0.5)
		7: return Vector2(nw,       nh * 0.5)
	return Vector2(nw * 0.5, nh * 0.5)


# ══ Passive drag-box selection ════════════════════════════════════════════════

func _finish_pbox_select(vp: Node) -> void:
	if not _texts_filter_enabled: return
	var texts = _get_current_texts()
	if texts == null: return
	var box = Rect2(_pbox_start, _pbox_cur - _pbox_start).abs()
	if box.size.length() < 4.0: return
	var new_sel = []
	for t in texts.get_children():
		if not (t is Control): continue
		if box.intersects(_text_aabb(t)):
			new_sel.append(t)
	if _mod_shift:
		for t in new_sel:
			if not _selected_texts.has(t): _selected_texts.append(t)
	else:
		_selected_texts = new_sel
	for t in _selected_texts:
		_ensure_text_sized(t)
	if _selected_texts.size() > 0:
		_primary_text = _selected_texts[0]


# ══ Handle drag ═══════════════════════════════════════════════════════════════

func _start_handle_drag(handle_idx: int, wp: Vector2) -> void:
	_active_handle       = handle_idx
	_drag_start_pos      = wp
	_drag_states.clear()
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		# _read_node_font absorbs scale into fsize — we need real scale for snapshot
		# so we read font name/size separately without absorbing scale
		var fi = _read_node_font_no_absorb(t)
		_drag_states.append({
			"node":      t,
			"pos":       t.rect_position,
			"rot":       t.rect_rotation,
			"sx":        t.rect_scale.x,
			"sy":        t.rect_scale.y,
			"font_size": fi["font_size"],
			"font_name": fi["font_name"],
		})
	_group_bbox = _selection_bbox()


func _update_handle_drag(wp: Vector2, vp: Node) -> void:
	if _drag_states.empty(): return
	var is_single = _selected_texts.size() == 1

	var delta = wp - _drag_start_pos
	var fw    = _group_bbox.size.x
	var fh    = _group_bbox.size.y

	if _active_handle == IDX_ROT:
		var pivot = _get_pivot(IDX_ROT)
		var a0    = rad2deg(atan2(_drag_start_pos.y - pivot.y, _drag_start_pos.x - pivot.x))
		var a1    = rad2deg(atan2(wp.y              - pivot.y, wp.x              - pivot.x))
		var da    = a1 - a0
		if _mod_shift:
			# Snap total rotation to nearest 45° relative to drag-start angles
			var base_rot = _drag_states[0].rot if _drag_states.size() > 0 else 0.0
			var abs_rot  = base_rot + da
			abs_rot = round(abs_rot / 45.0) * 45.0
			da = abs_rot - base_rot
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			var offset = st.pos - pivot
			st.node.rect_position = pivot + offset.rotated(deg2rad(da))
			st.node.rect_rotation = st.rot + da
		return

	# ── Scale (corner or edge) ────────────────────────────────────────────────
	var rx := 1.0; var ry := 1.0

	if _active_handle in CORNER_IDX:
		var dx = delta.x; var dy = delta.y
		if _active_handle == 0 or _active_handle == 6: dx = -dx
		if _active_handle == 0 or _active_handle == 2: dy = -dy
		# For single rotated node, project onto local axes
		if is_single:
			var rot = deg2rad(_drag_states[0].rot)
			var ah  = Vector2(cos(rot), sin(rot))
			var av  = Vector2(-sin(rot), cos(rot))
			dx = delta.dot(ah); dy = delta.dot(av)
			if _active_handle == 0 or _active_handle == 6: dx = -dx
			if _active_handle == 0 or _active_handle == 2: dy = -dy
		var dw = fw * 0.5 if _mod_alt else fw
		var dh = fh * 0.5 if _mod_alt else fh
		if dw < 0.5 or dh < 0.5: return
		rx = max(0.1, 1.0 + dx / dw)
		ry = max(0.1, 1.0 + dy / dh)
		if not _mod_shift:
			var r = (rx + ry) * 0.5; rx = r; ry = r
	else:
		var is_vert = _active_handle == 1 or _active_handle == 5
		var proj    = delta.y if is_vert else delta.x
		if is_single:
			var rot = deg2rad(_drag_states[0].rot)
			proj = delta.dot(Vector2(-sin(rot), cos(rot))) if is_vert else delta.dot(Vector2(cos(rot), sin(rot)))
		var dir  = -1.0 if (_active_handle == 1 or _active_handle == 7) else 1.0
		var full = fh if is_vert else fw
		var div  = full * 0.5 if _mod_alt else full
		if div < 0.5: return
		var ratio = max(0.1, 1.0 + dir * proj / div)
		if _mod_shift:
			if is_vert: ry = ratio
			else:       rx = ratio
		else:
			rx = ratio; ry = ratio

	# ── Apply to each node ────────────────────────────────────────────────────
	if is_single:
		var st     = _drag_states[0]
		if not is_instance_valid(st.node): return
		var pivot  = _get_pivot_single(_active_handle)
		var rot    = deg2rad(st.rot)
		var new_sx = st.sx * rx; var new_sy = st.sy * ry
		var nw     = st.node.rect_size.x * new_sx
		var nh     = st.node.rect_size.y * new_sy
		st.node.rect_scale    = Vector2(new_sx, new_sy)
		st.node.rect_position = pivot - _pivot_local_single(_active_handle, nw, nh).rotated(rot)
	else:
		var pivot = _get_pivot(_active_handle)
		for st in _drag_states:
			if not is_instance_valid(st.node): continue
			var offset   = st.pos - pivot
			st.node.rect_position = pivot + Vector2(offset.x * rx, offset.y * ry)
			st.node.rect_scale    = Vector2(st.sx * rx, st.sy * ry)


func _commit_handle_drag() -> void:
	# Build undo snapshot from drag_states (captures pre-drag state)
	var undo_entries = []
	for st in _drag_states:
		if not is_instance_valid(st.node): continue
		undo_entries.append({
			"node":      st.node,
			"pos":       st.pos,
			"rot":       st.rot,
			"sx":        st.sx,
			"sy":        st.sy,
			"font_name": st.font_name,
			"font_size": st.font_size,
		})
	# Single-node corner → convert scale to font size
	if _selected_texts.size() == 1 and _active_handle in CORNER_IDX and _drag_states.size() == 1:
		var st        = _drag_states[0]
		if not is_instance_valid(st.node): return
		var sc        = st.node.rect_scale
		var saved_pos = st.node.rect_position
		var saved_rot = st.node.rect_rotation
		if _mod_shift:
			# ── Unlocked ratio (Shift still held at mouse release) ───────────
			# Font size is driven by the Y-axis scale change.
			# The X/Y distortion factor is preserved as rect_scale after SetFont.
			var ratio_y = sc.y / st.sy if st.sy != 0.0 else 1.0
			var ratio_x = sc.x / st.sx if st.sx != 0.0 else 1.0
			var new_size = int(clamp(st.font_size * ratio_y, 6, 256))
			_last_font_size = new_size
			_last_font_node = st.node.get_instance_id()
			# How much more X is stretched relative to Y (the distortion factor)
			var x_distortion = ratio_x / ratio_y if ratio_y != 0.0 else 1.0
			st.node.call("SetFont", st.font_name, new_size)
			# SetFont resets rect_scale internally; restore pre-drag Y scale
			# and apply the X distortion so the non-uniform stretch is preserved.
			st.node.rect_scale = Vector2(st.sx * x_distortion, st.sy)
		else:
			# ── Locked ratio (default) ───────────────────────────────────────
			var ratio = ((sc.x / st.sx) + (sc.y / st.sy)) * 0.5
			var new_size = int(clamp(st.font_size * ratio, 6, 256))
			_last_font_size = new_size
			_last_font_node = st.node.get_instance_id()
			st.node.call("SetFont", st.font_name, new_size)
			st.node.rect_scale = Vector2(st.sx, st.sy)
		var nd   = st.node
		var tmp  = _g.World.get_tree().create_timer(0.0)
		tmp.connect("timeout", self, "_restore_node", [nd, saved_pos, saved_rot])
	else:
		# Non single-corner cases (rotation, multi-corner, edges, group move):
		# rect_position / rect_rotation / rect_scale were modified live but
		# dataOnFocus still holds pre-drag state. DD reads dataOnFocus when
		# serialising → without this sync, transforms are lost on save/reload.
		for st2 in _drag_states:
			if is_instance_valid(st2.node):
				_refresh_dof(st2.node)
	# Persist rotation / scale via ModMapData (DD's save format omits them)
	_save_all_selected_transforms()
	# Push undo
	if not undo_entries.empty():
		var is_font_commit = (_selected_texts.size() == 1 and _active_handle in CORNER_IDX)
		_undo_stack.append({"type": "transform", "entries": undo_entries, "font_commit": is_font_commit})
		# NB : on n'appelle PAS _select_tool.RecordTransforms() ici. Ça plante avec
		# IndexOutOfRangeException car SelectTool.transformsBefore n'a pas été
		# rempli par un SavePreTransforms officiel (text_transform fait DeselectAll
		# côté SelectTool donc la sélection DD est vide).
	# Update anchors for all dragged nodes
	_call_ttf_anchor_update()


func _restore_node(nd: Node, pos: Vector2, rot: float) -> void:
	if not is_instance_valid(nd): return
	nd.rect_position = pos
	nd.rect_rotation = rot
	# Now that SetFont's deferred side effects have settled and we've put back
	# the correct position/rotation, snapshot the resulting state into
	# dataOnFocus so DD serialises the new font_size + scale on save.
	_refresh_dof(nd)
	# Et persiste rotation/scale via ModMapData
	_save_transform_for_node(nd)


# ── dataOnFocus sync helper ──────────────────────────────────────────────────
# DD's Text save format only contains: box_shape, font_color, font_name,
# font_size, node_id, position, text. Rotation and scale are NOT serialised.
# We still sync dataOnFocus with the canonical save dict so DD's undo system
# sees a consistent snapshot — but rotation/scale won't survive map reload
# regardless of what we do here. That's a DD API limitation.
func _refresh_dof(nd: Node) -> void:
	if not is_instance_valid(nd): return
	if not nd.has_method("Save"): return
	# Save() with no arg returns the canonical Dictionary; Save(false) returns
	# something weird (a Vector2) due to a GDScript<->C# conversion quirk.
	var d = nd.call("Save")
	if d != null and d is Dictionary:
		nd.set("dataOnFocus", d)


# ══ Custom rotation / scale persistence ═══════════════════════════════════════

func _get_node_id_str(t: Node):
	# DD stocke node_id dans __meta__ (pareil que text_tool_fix._get_node_id)
	var meta = t.get("__meta__")
	if meta is Dictionary and meta.has("node_id"):
		return str(meta["node_id"])
	return null


func _get_map_transforms_path() -> String:
	# Sidecar JSON path (fallback si ModMapData ne survit pas)
	var candidates = ["CurrentMapFile", "MapFile", "currentFile", "CurrentFile"]
	var map_name = ""
	for c in candidates:
		var v = _g.Editor.get(c)
		if v != null and typeof(v) == TYPE_STRING and v != "":
			map_name = v.get_file().get_basename()
			break
	if map_name == "":
		return ""
	var dir = Directory.new()
	var folder = "user://UnofficialPatch/TextTransform"
	if not dir.dir_exists(folder):
		dir.make_dir_recursive(folder)
	return folder + "/" + map_name + ".json"


func _save_transforms_to_modmapdata() -> void:
	# Écrit l'état mémoire dans ModMapData. DD copie ModMapData dans le fichier
	# de save à chaque save (Ctrl+S, Save As, auto-backup).
	if _g.ModMapData == null:
		return
	# Filtrer les entrées identité (rot=0 et scale=(1,1)) — pas la peine de les saver
	var filtered = {}
	for nid in _transforms:
		var d = _transforms[nid]
		if abs(d.get("rot", 0.0)) > 0.01 \
		or abs(d.get("sx", 1.0) - 1.0) > 0.001 \
		or abs(d.get("sy", 1.0) - 1.0) > 0.001:
			filtered[nid] = d
	_g.ModMapData[MOD_DATA_KEY] = filtered
	# Sidecar JSON en fallback
	var path = _get_map_transforms_path()
	if path != "":
		var f = File.new()
		if f.open(path, File.WRITE) == OK:
			f.store_string(JSON.print(filtered))
			f.close()


func _load_transforms_from_modmapdata() -> Dictionary:
	# Priorité 1 : ModMapData (intégré au fichier de save DD)
	if _g.ModMapData != null and _g.ModMapData.has(MOD_DATA_KEY):
		var d = _g.ModMapData[MOD_DATA_KEY]
		if d is Dictionary:
			return d.duplicate()
	# Priorité 2 : sidecar JSON
	var path = _get_map_transforms_path()
	if path == "":
		return {}
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return {}
	var txt = f.get_as_text()
	f.close()
	var result = JSON.parse(txt)
	if result.error != OK or not (result.result is Dictionary):
		return {}
	return result.result


func _save_transform_for_node(nd: Node) -> void:
	# Capture rotation et scale courants pour ce node, met à jour mémoire + ModMapData
	if not is_instance_valid(nd): return
	var nid = _get_node_id_str(nd)
	if nid == null: return
	_transforms[nid] = {
		"rot": float(nd.rect_rotation),
		"sx":  float(nd.rect_scale.x),
		"sy":  float(nd.rect_scale.y),
	}
	_save_transforms_to_modmapdata()


func _save_all_selected_transforms() -> void:
	# Helper pour fin de drag : sauvegarde tous les texts qui ont été draggés
	for st in _drag_states:
		if is_instance_valid(st.node):
			_save_transform_for_node(st.node)


func _restore_existing_texts_transforms() -> void:
	# Appelé après un changement de map (détecté via update). Réapplique
	# rotation et scale stockés sur les texts dont le node_id matche.
	var texts = _get_current_texts()
	if texts == null:
		return
	var saved = _load_transforms_from_modmapdata()
	_transforms = saved.duplicate()
	if saved.empty():
		print("[TextTransform] Restore: no saved transforms")
		return
	var restored = 0
	for t in texts.get_children():
		if not is_instance_valid(t) or not (t is Control):
			continue
		var nid = _get_node_id_str(t)
		if nid == null or not saved.has(nid):
			continue
		var d = saved[nid]
		if d is Dictionary:
			# JSON ne distingue pas float/int : on cast explicitement
			t.rect_rotation = float(d.get("rot", 0.0))
			t.rect_scale    = Vector2(float(d.get("sx", 1.0)), float(d.get("sy", 1.0)))
			restored += 1
	print("[TextTransform] Restored %d/%d transforms from ModMapData" % [restored, saved.size()])


func _on_save_button_pressed() -> void:
	# Hook sur le bouton Save de DD : on flushe avant que DD écrive le fichier.
	_save_transforms_to_modmapdata()


func _connect_save_button() -> void:
	if _save_btn_connected:
		return
	var editor_node = _g.World.get_tree().root.get_node_or_null("Master/Editor")
	if editor_node == null:
		return
	var save_btn = editor_node.get("saveButton")
	if save_btn == null:
		return
	if not save_btn.is_connected("pressed", self, "_on_save_button_pressed"):
		save_btn.connect("pressed", self, "_on_save_button_pressed")
	_save_btn_connected = true


var _last_level_id    : int        = -1


func _check_world_change() -> void:
	# Appelé chaque frame depuis update(). Détecte changement de map
	# (instance_id du World) ET changement de level → relance la restauration.
	if _g.World == null or not is_instance_valid(_g.World):
		return
	var current_world_id = _g.World.get_instance_id()
	var current_level_id = _g.World.get("CurrentLevelId")
	if current_level_id == null: current_level_id = -1
	if current_world_id != _last_world_id:
		_last_world_id = current_world_id
		_last_level_id = -1
		_transforms_loaded = false
		_transforms.clear()
	if current_level_id != _last_level_id:
		_last_level_id = current_level_id
		_transforms_loaded = false
	if not _transforms_loaded:
		# Attend que les texts du level courant soient accessibles
		var texts = _get_current_texts()
		if texts != null:
			_transforms_loaded = true
			_restore_existing_texts_transforms()
			_connect_save_button()


func _undo_restore_pos(nd: Node, pos: Vector2) -> void:
	if not is_instance_valid(nd): return
	nd.rect_position = pos
	# Update anchor so _apply_alignment uses the restored x
	var ttf = _g.ModMapData.get("_ttf_handler")
	if ttf != null: ttf.update_anchor_after_move(nd)


# ══ Group move ════════════════════════════════════════════════════════════════

func _start_group_move(wp: Vector2) -> void:
	if _select_tool != null: _select_tool.call("SavePreTransforms")
	_group_moving      = true
	_group_move_moved  = false
	_drag_start_pos    = wp
	_move_offsets.clear()
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		_move_offsets.append({"node": t, "offset": t.rect_position - wp})


func _update_group_move(wp: Vector2, vp: Node) -> void:
	if _drag_start_pos.distance_to(wp) > 3.0:
		_group_move_moved = true
	if not _group_move_moved:
		return
	# Snap the primary node, compute the snapped delta, apply delta to all
	var primary_entry = _move_offsets[0] if _move_offsets.size() > 0 else null
	for entry in _move_offsets:
		if is_instance_valid(entry.node) and (entry.node == _primary_text or _primary_text == null):
			primary_entry = entry
			break
	var snap_delta = Vector2.ZERO
	if primary_entry != null and is_instance_valid(primary_entry.node):
		var raw = wp + primary_entry.offset
		var snapped = _snap_pos(primary_entry.node, raw)
		snap_delta = snapped - raw
	for entry in _move_offsets:
		if not is_instance_valid(entry.node): continue
		entry.node.rect_position = wp + entry.offset + snap_delta


func _finish_group_move() -> void:
	# Capture le flag AVANT de le reset, sinon le check plus bas est toujours faux
	# et RecordTransforms n'est jamais appelé → DD ne sait pas qu'on a bougé.
	var did_move = _group_move_moved
	_group_moving     = false
	_group_move_moved = false
	for entry in _move_offsets:
		if is_instance_valid(entry.node):
			entry.offset = entry.node.rect_position - _drag_start_pos
	_call_ttf_anchor_update()
	if did_move:
		# Sync dataOnFocus avec la nouvelle position pour chaque texte déplacé
		for entry in _move_offsets:
			if is_instance_valid(entry.node):
				_refresh_dof(entry.node)
		# NB : pas de RecordTransforms ici non plus (cf. _commit_handle_drag).
	_move_offsets.clear()


func _snap_pos(t: Control, pos: Vector2) -> Vector2:
	if not _g.Editor.IsSnapping: return pos
	var wu = _g.WorldUI
	if wu and wu.has_method("GetSnappedPosition"):
		return wu.GetSnappedPosition(pos)
	var cell = wu.CellSize if wu else null
	if cell is Vector2:
		var snap = cell.x * 0.5
		if wu.get("UseHalfSnap"): snap *= 0.5
		return Vector2(stepify(pos.x, snap), stepify(pos.y, snap))
	return pos


# ══ Delete ════════════════════════════════════════════════════════════════════

func _delete_selection() -> void:
	var ttf = _g.ModMapData.get("_ttf_handler")
	# Snapshot for undo
	var snap = []
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		var fi  = _read_node_font(t)
		var am  = 0
		if ttf:
			var id2 = t.get_instance_id()
			if ttf._anchors.has(id2): am = ttf._anchors[id2]["mode"]
		snap.append({"text": t.text if t.get("text") != null else "",
			"font_name": fi["font_name"], "font_size": fi["font_size"],
			"font_color": fi["font_color"], "position": t.rect_position,
			"rotation": t.rect_rotation, "sx": fi["sx"], "sy": fi["sy"], "align_mode": am})
		if ttf: ttf._anchors.erase(t.get_instance_id())
		t.queue_free()
	_selected_texts.clear()
	_primary_text = null
	# Register undo action via DD's history if possible
	if _select_tool != null:
		_select_tool.call("RecordTransforms")
	_undo_stack.append({"type": "delete", "data": snap})
	print("[TextTransform] Deleted %d texts (undo saved)" % snap.size())


func _undo_action(vp: Node) -> void:
	if _undo_stack.empty(): return
	var action = _undo_stack.back()
	_undo_stack.pop_back()
	if action["type"] == "paste":
		# Undo paste: delete the pasted nodes
		var ttf = _g.ModMapData.get("_ttf_handler")
		for nd2 in action["nodes"]:
			if not is_instance_valid(nd2): continue
			if ttf: ttf._anchors.erase(nd2.get_instance_id())
			nd2.queue_free()
		_selected_texts.clear(); _primary_text = null
		print("[TextTransform] Undo paste: removed %d texts" % action["nodes"].size())
	elif action["type"] == "transform":
		var tree2 = _g.World.get_tree()
		var is_font_commit = action.get("font_commit", false)
		for entry in action["entries"]:
			if not is_instance_valid(entry["node"]): continue
			var nd3 = entry["node"]
			var pos3 = entry["pos"]
			# Pre-set dataOnFocus position so C# resets land correctly
			var dof3 = nd3.get("dataOnFocus")
			if dof3 != null: dof3["position"] = pos3; nd3.set("dataOnFocus", dof3)
			if is_font_commit:
				nd3.call("SetFont", entry["font_name"], entry["font_size"])
				nd3.rect_scale = Vector2(entry["sx"], entry["sy"])
				if nd3.get_instance_id() == _last_font_node:
					_last_font_size = entry["font_size"]
			else:
				nd3.rect_scale    = Vector2(entry["sx"], entry["sy"])
				nd3.rect_rotation = entry["rot"]
			# Deferred restore: sets position then updates anchor in sequence
			var tmp3 = tree2.create_timer(0.0)
			tmp3.connect("timeout", self, "_undo_restore_pos", [nd3, pos3])
		print("[TextTransform] Undo transform: restored %d nodes" % action["entries"].size())
	elif action["type"] == "delete":
		# Undo delete: restore nodes from snapshot
		var snap = action["data"]
		var texts = _get_current_texts()
		if texts == null: return
		var template : Node = null
		for t in texts.get_children():
			if t is Control: template = t; break
		if template == null: return
		var ttf = _g.ModMapData.get("_ttf_handler")
		var tree = _g.World.get_tree()
		var restored = []
		for item in snap:
			var nd = template.duplicate()
			texts.add_child(nd)
			var fc = item["font_color"]; if fc == null: fc = Color.white
			var dof2 = nd.get("dataOnFocus")
			if dof2 != null: dof2["position"] = item["position"]; nd.set("dataOnFocus", dof2)
			nd.call("SetFont", item["font_name"], item["font_size"])
			nd.call("SetFontColor", fc)
			nd.text = item["text"]
			nd.rect_rotation = item["rotation"]
			var pos = item["position"]; var sx = item["sx"]; var sy = item["sy"]
			var tmp1 = tree.create_timer(0.0)
			tmp1.connect("timeout", nd, "set", ["rect_scale",    Vector2(sx, sy)])
			var tmp2 = tree.create_timer(0.0)
			tmp2.connect("timeout", nd, "set", ["rect_position", pos])
			if ttf: ttf.register_anchor_external(nd, pos, item["align_mode"])
			restored.append(nd)
		_selected_texts = restored
		_primary_text   = restored[0] if restored.size() > 0 else null
		print("[TextTransform] Undo delete: restored %d texts" % restored.size())


# ══ Copy / Paste ══════════════════════════════════════════════════════════════

func _dd_has_selection() -> bool:
	# Vrai si SelectTool a des assets sélectionnés côté DD (objets/paths/patterns...).
	# Les textes sont gérés séparément (_selected_texts) et n'apparaissent pas ici.
	if _select_tool == null or not is_instance_valid(_select_tool):
		return false
	var sel = _select_tool.get("Selected")
	return sel != null and sel.size() > 0


func _copy_selection() -> void:
	_clipboard.clear()
	# Mémorise si la copie est mixte (textes + assets DD) pour router le collage.
	_clipboard_mixed = _dd_has_selection()
	var ttf = _g.ModMapData.get("_ttf_handler")
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		# Use no_absorb to get real font size; store real sx/sy to preserve unlocked ratio
		var fi = _read_node_font_no_absorb(t)
		var fc = t.get("fontColor"); if fc == null: fc = Color.white
		var align_mode = 0
		if ttf:
			var id = t.get_instance_id()
			if ttf._anchors.has(id): align_mode = ttf._anchors[id]["mode"]
		print("[TextTransform] Copy: font=", fi["font_name"], " size=", fi["font_size"], " scale=", t.rect_scale)
		_clipboard.append({
			"text":       t.text if t.get("text") != null else "",
			"font_name":  fi["font_name"],
			"font_size":  fi["font_size"],
			"font_color": fc,
			"position":   t.rect_position,
			"rotation":   t.rect_rotation,
			"sx":         t.rect_scale.x,
			"sy":         t.rect_scale.y,
			"align_mode": align_mode,
		})
	print("[TextTransform] Copied %d texts" % _clipboard.size())
	# Save a detached duplicate of the first selected text as a paste template.
	# This allows _paste_selection() to succeed even if cut empties the map.
	if _paste_template_node != null and is_instance_valid(_paste_template_node):
		_paste_template_node.queue_free()
	_paste_template_node = null
	for t in _selected_texts:
		if is_instance_valid(t):
			_paste_template_node = t.duplicate()
			# Not added to any tree — just used as a blueprint for _paste_selection.
			break



func _paste_selection_btn() -> void:
	var tree = _g.World.get_tree()
	var vp   = tree.root.get_node_or_null(_viewport_path)
	if vp: _paste_selection(vp)


func _paste_selection(vp: Node) -> void:
	if _clipboard.empty(): return
	var texts = _get_current_texts()
	if texts == null: return
	var template: Node = null
	for t in texts.get_children():
		if t is Control: template = t; break
	if template == null:
		# No existing text on the map (e.g. cut removed all of them).
		# Fall back to the detached template saved at copy time.
		if _paste_template_node != null and is_instance_valid(_paste_template_node):
			template = _paste_template_node
		else:
			print("[TextTransform] Paste: no template text found"); return
	var ttf     = _g.ModMapData.get("_ttf_handler")
	var tree    = _g.World.get_tree()
	var offset  = Vector2(30, 30)
	var new_sel = []
	for item in _clipboard:
		var nd = template.duplicate()
		texts.add_child(nd)
		var new_pos = item["position"] + offset
		var sx = item["sx"]; var sy = item["sy"]
		# Pre-set dataOnFocus["position"] so SetFont/text= reset to the right place
		var dof = nd.get("dataOnFocus")
		if dof != null:
			dof["position"] = new_pos
			nd.set("dataOnFocus", dof)
		# font_color may be null for old-map texts — guard against crash
		var fc = item["font_color"]
		if fc == null: fc = Color.white
		nd.call("SetFont", item["font_name"], item["font_size"])
		nd.call("SetFontColor", fc)
		nd.text          = item["text"]
		nd.rect_rotation = item["rotation"]
		# Restore scale and position after C# resets — separate timers (same signal target crashes)
		var tmp1 = tree.create_timer(0.0)
		tmp1.connect("timeout", nd, "set", ["rect_scale",    Vector2(sx, sy)])
		var tmp2 = tree.create_timer(0.0)
		tmp2.connect("timeout", nd, "set", ["rect_position", new_pos])
		if ttf: ttf.register_anchor_external(nd, new_pos, item["align_mode"])
		new_sel.append(nd)
	_selected_texts = new_sel
	_primary_text   = new_sel[0] if new_sel.size() > 0 else null
	# Store pasted nodes for undo
	var paste_snap = []
	for nd2 in new_sel:
		paste_snap.append(nd2)
	_undo_stack.append({"type": "paste", "nodes": paste_snap})
	print("[TextTransform] Pasted %d texts (undo saved)" % new_sel.size())


# ══ Anchor update callback ═════════════════════════════════════════════════════



func _call_ttf_anchor_update() -> void:
	var ttf = _g.ModMapData.get("_ttf_handler")
	if ttf == null: return
	for t in _selected_texts:
		if is_instance_valid(t): ttf.update_anchor_after_move(t)


# ══ Drawing ═══════════════════════════════════════════════════════════════════

func _draw_overlay(overlay: Node2D) -> void:
	if not _is_select_tool_active(_g.World.get_tree()): return
	var vp = _g.World.get_tree().root.get_node_or_null(_viewport_path)
	if vp == null: return

	# Fast-path: nothing selected, no drag-box active, and either no texts on
	# the map or hover-highlight disabled → nothing this function would draw.
	# Skip all the zoom/colors/array work below.
	if _selected_texts.size() == 0 and not _pbox_active:
		if not _texts_filter_enabled:
			return
		var level_fp = _g.World.GetCurrentLevel() if _g.World else null
		var texts_fp = level_fp.Texts if level_fp != null else null
		if texts_fp == null or texts_fp.get_child_count() == 0:
			return
		if _mouse_over_ui:
			return

	var zoom     = vp.canvas_transform.get_scale().x
	var lw       = 1.5 / zoom
	var hw       = 10.0 / zoom
	var box_col  = Color(0.25, 0.65, 1.0, 0.9)
	var fill_col = Color(1.0,  1.0,  1.0, 0.85)
	var sel_col  = Color(0.25, 0.65, 1.0, 0.25)

	# Draw selection highlight per text
	for t in _selected_texts:
		if not is_instance_valid(t): continue
		var rot = deg2rad(t.rect_rotation)
		var vr  = _text_visual_rect(t)
		var o   = vr.o; var w = vr.w; var h = vr.h
		var tl  = o; var tr = o + Vector2(w, 0).rotated(rot)
		var br  = o + Vector2(w, h).rotated(rot)
		var bl  = o + Vector2(0, h).rotated(rot)
		overlay.draw_colored_polygon(PoolVector2Array([tl, tr, br, bl]), sel_col)
		overlay.draw_line(tl, tr, box_col, lw)
		overlay.draw_line(tr, br, box_col, lw)
		overlay.draw_line(br, bl, box_col, lw)
		overlay.draw_line(bl, tl, box_col, lw)

	# Draw AABB outline for multi-selection
	if _selected_texts.size() > 1:
		var bb  = _selection_bbox()
		var o2  = bb.position
		var w2  = bb.size.x; var h2 = bb.size.y
		var out_col = Color(0.25, 0.65, 1.0, 0.5)
		overlay.draw_line(o2,                         o2 + Vector2(w2, 0),  out_col, lw)
		overlay.draw_line(o2 + Vector2(w2, 0),        o2 + Vector2(w2, h2), out_col, lw)
		overlay.draw_line(o2 + Vector2(w2, h2),       o2 + Vector2(0,  h2), out_col, lw)
		overlay.draw_line(o2 + Vector2(0,  h2),       o2,                   out_col, lw)

	# Draw transform handles
	if _selected_texts.size() > 0:
		var hs = _current_handle_positions(vp)
		for k in range(hs.size()):
			var hp = hs[k]
			if k in CORNER_IDX:
				overlay.draw_rect(Rect2(hp - Vector2(hw, hw) * 0.5, Vector2(hw, hw)), fill_col)
				overlay.draw_rect(Rect2(hp - Vector2(hw, hw) * 0.5, Vector2(hw, hw)), box_col, false, lw)
			else:
				overlay.draw_circle(hp, hw * 0.5, fill_col)
				_draw_circle_outline(overlay, hp, hw * 0.5, box_col, lw, 12)
		var rh = _rot_handle_world(hs, vp)
		overlay.draw_line(hs[1], rh, box_col, lw)
		overlay.draw_circle(rh, hw * 0.65, fill_col)
		_draw_circle_outline(overlay, rh, hw * 0.65, box_col, lw, 16)




	# Hover highlight: text under cursor when not dragging
	if not _mouse_over_ui and not _pbox_active and not _group_moving and _active_handle < 0 and _texts_filter_enabled:
		var wp_h = _mouse_world(vp)
		var texts_h = _get_current_texts()
		if texts_h:
			for t in texts_h.get_children():
				if not (t is Control): continue
				if _selected_texts.has(t): continue
				if _text_aabb(t).has_point(wp_h):
					var rot = deg2rad(t.rect_rotation)
					var vr  = _text_visual_rect(t)
					var o   = vr.o; var w = vr.w; var h = vr.h
					var tl2 = o; var tr2 = o + Vector2(w, 0).rotated(rot)
					var br2 = o + Vector2(w, h).rotated(rot)
					var bl2 = o + Vector2(0, h).rotated(rot)
					overlay.draw_colored_polygon(PoolVector2Array([tl2, tr2, br2, bl2]), Color(1, 1, 1, 0.08))
					overlay.draw_line(tl2, tr2, Color(0.25, 0.65, 1.0, 0.5), lw)
					overlay.draw_line(tr2, br2, Color(0.25, 0.65, 1.0, 0.5), lw)
					overlay.draw_line(br2, bl2, Color(0.25, 0.65, 1.0, 0.5), lw)
					overlay.draw_line(bl2, tl2, Color(0.25, 0.65, 1.0, 0.5), lw)
					break  # only highlight topmost

	# Highlight texts inside the active drag box (before release)
	if _pbox_active and _pbox_moved and _texts_filter_enabled:
		var box      = Rect2(_pbox_start, _pbox_cur - _pbox_start).abs()
		var hover_col = Color(0.25, 0.65, 1.0, 0.18)
		var texts = _get_current_texts()
		if texts:
			for t in texts.get_children():
				if not (t is Control): continue
				if _selected_texts.has(t): continue  # already highlighted above
				if box.intersects(_text_aabb(t)):
					var rot = deg2rad(t.rect_rotation)
					var vr  = _text_visual_rect(t)
					var o   = vr.o; var w = vr.w; var h = vr.h
					var tl  = o; var tr = o + Vector2(w, 0).rotated(rot)
					var br  = o + Vector2(w, h).rotated(rot)
					var bl  = o + Vector2(0, h).rotated(rot)
					overlay.draw_colored_polygon(PoolVector2Array([tl, tr, br, bl]), hover_col)
					overlay.draw_line(tl, tr, box_col, lw)
					overlay.draw_line(tr, br, box_col, lw)
					overlay.draw_line(br, bl, box_col, lw)
					overlay.draw_line(bl, tl, box_col, lw)


func _draw_circle_outline(overlay: Node2D, center: Vector2, radius: float, color: Color, lw: float, steps: int) -> void:
	for s in range(steps):
		var a0 = (s / float(steps)) * TAU
		var a1 = ((s + 1) / float(steps)) * TAU
		overlay.draw_line(
			center + Vector2(cos(a0), sin(a0)) * radius,
			center + Vector2(cos(a1), sin(a1)) * radius,
			color, lw)


# ══ Misc ══════════════════════════════════════════════════════════════════════


func _ensure_text_sized(_t: Control) -> void:
	# No-op: we no longer modify DD's rect. The visual bounding box is computed
	# on-the-fly by _text_visual_rect() using font measurement.
	pass


func _read_node_font_no_absorb(t: Control) -> Dictionary:
	# Like _read_node_font but does NOT absorb rect_scale into font size
	var fname = ""
	var fsize = 12
	# Priority 1: direct C# properties (always up-to-date)
	var direct_name = t.get("fontName")
	var direct_size = t.get("fontSize")
	if direct_name != null and str(direct_name) != "":
		fname = str(direct_name)
	if direct_size != null and int(direct_size) > 0:
		fsize = int(direct_size)
	# Priority 2: dataOnFocus (snapshot — may be stale)
	if fname == "" or fsize <= 12:
		var base = t.get("dataOnFocus")
		if base != null and base is Dictionary:
			if fname == "" and base.has("font_name") and str(base["font_name"]) != "":
				fname = str(base["font_name"])
			if fsize <= 12 and base.has("font_size") and int(base["font_size"]) > 12:
				fsize = int(base["font_size"])
	if _last_font_node == t.get_instance_id() and _last_font_size > 0:
		fsize = _last_font_size
	# Priority 3: DynamicFont resource (fallback)
	if fname == "" or fsize <= 12:
		var font_res = t.get_font("font") if t.has_method("get_font") else null
		if font_res != null:
			if font_res.get("size") != null and fsize <= 12: fsize = int(font_res.get("size"))
			if fname == "":
				var fd = font_res.get("font_data")
				if fd != null:
					fname = _resolve_font_name(str(fd.resource_path))
	return {"font_name": fname, "font_size": fsize}


func _read_node_font(t: Control) -> Dictionary:
	var fname = ""
	var fsize = 12
	var copy_sx = t.rect_scale.x
	var copy_sy = t.rect_scale.y
	# Priority 1: direct C# properties (always up-to-date)
	var direct_name = t.get("fontName")
	var direct_size = t.get("fontSize")
	if direct_name != null and str(direct_name) != "":
		fname = str(direct_name)
	if direct_size != null and int(direct_size) > 0:
		fsize = int(direct_size)
	# Priority 2: dataOnFocus (snapshot — may be stale)
	if fname == "" or fsize <= 12:
		var base = t.get("dataOnFocus")
		if base != null and base is Dictionary:
			if fname == "" and base.has("font_name") and str(base["font_name"]) != "":
				fname = str(base["font_name"])
			if fsize <= 12 and base.has("font_size") and int(base["font_size"]) > 12:
				fsize = int(base["font_size"])
	if _last_font_node == t.get_instance_id() and _last_font_size > 0:
		fsize = _last_font_size
	# Priority 3: DynamicFont resource (fallback)
	if fname == "" or fsize <= 12:
		var font_res = t.get_font("font") if t.has_method("get_font") else null
		if font_res != null:
			if font_res.get("size") != null and fsize <= 12:
				fsize = int(font_res.get("size"))
			if fname == "":
				var fd = font_res.get("font_data")
				if fd != null:
					fname = _resolve_font_name(str(fd.resource_path))
	# Absorb scale into font size
	if copy_sx != 1.0 or copy_sy != 1.0:
		var avg = (copy_sx + copy_sy) * 0.5
		fsize = int(clamp(fsize * avg, 6, 512))
		copy_sx = 1.0; copy_sy = 1.0
	var fc = t.get("fontColor")
	if fc == null: fc = Color.white
	return {"font_name": fname, "font_size": fsize, "font_color": fc, "sx": copy_sx, "sy": copy_sy}


func _resolve_font_name(resource_path: String) -> String:
	# Convert "res://fonts/LibreBaskerville-Regular.ttf" → DD font list name
	var base = resource_path.get_file().get_basename()  # e.g. "LibreBaskerville-Regular"
	# Split on dash to separate variant
	var parts = base.split("-")
	var stem  = parts[0]  # e.g. "LibreBaskerville"
	var variant = parts[1] if parts.size() > 1 else "Regular"
	# Convert CamelCase stem to spaced: "LibreBaskerville" → "Libre Baskerville"
	var spaced = ""
	for i in range(stem.length()):
		var ch = stem[i]
		if i > 0 and ch == ch.to_upper() and ch != ch.to_lower():
			spaced += " "
		spaced += ch
	# Build candidate with variant (skip "Regular")
	var candidate = spaced
	if variant != "Regular" and variant != "":
		candidate += " " + variant
	# Match against DD font list (exact, then prefix, then substring)
	var ttf2 = _g.ModMapData.get("_ttf_handler")
	var fl : Array = []
	if ttf2 != null:
		fl = ttf2._font_list
		if fl.size() < 2 and not ttf2._font_selector_path.is_empty():
			var ctrl = _g.World.get_tree().root.get_node_or_null(ttf2._font_selector_path)
			if ctrl != null: ttf2._build_font_list(ctrl); fl = ttf2._font_list
	# 1. Exact
	for fn in fl:
		if fn == candidate: return fn
	# 2. Case-insensitive exact
	for fn in fl:
		if fn.to_lower() == candidate.to_lower(): return fn
	# 3. Spaced stem prefix (without variant)
	for fn in fl:
		if fn.to_lower().begins_with(spaced.to_lower()): return fn
	# 4. Any font that contains the stem words
	for fn in fl:
		if spaced.to_lower() in fn.to_lower(): return fn
	# Fallback
	return candidate


func _setup_texts_filter_delayed() -> void:
	print("[TextTransform] Filter: setup starting")
	if _anchor_path.is_empty():
		print("[TextTransform] Filter: no anchor path"); return
	if _input_listener == null or not is_instance_valid(_input_listener):
		print("[TextTransform] Filter: listener invalid"); return
	# Use _input_listener (a real Node) to navigate absolute path
	var anchor = _input_listener.get_node_or_null(_anchor_path)
	print("[TextTransform] Filter: anchor=", anchor)
	if anchor == null:
		print("[TextTransform] Filter: anchor not found")
		return
	_do_add_filter(anchor)


func _do_add_filter(anchor: Node) -> void:
	for child in anchor.get_children():
		if str(child.get("ForceTool")) != "SelectTool":
			continue
		var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
		if align == null:
			print("[TextTransform] Filter: Align not found")
			return
		if align.get_node_or_null("TextsFilterGroup") != null:
			return
		_setup_texts_filter(align)
		_setup_align_buttons(align)
		return


func _setup_texts_filter(align: Node) -> void:
	# Find the FILTER MenuButton and add "Texts" to its PopupMenu
	var filter_btn : Node = null
	for ch in align.get_children():
		if ch is MenuButton and str(ch.get("text")) == "FILTER":
			filter_btn = ch
			break
	if filter_btn == null:
		print("[TextTransform] FILTER MenuButton not found")
		return
	var popup = filter_btn.get_popup()
	if popup == null:
		print("[TextTransform] FILTER popup not found")
		return
	# Check not already added
	for i in range(popup.get_item_count()):
		if popup.get_item_text(i) == "Texts":
			return
	# Add checkable item at end
	var idx = popup.get_item_count()
	popup.add_check_item("Texts", idx)
	popup.set_item_checked(idx, true)
	# Store refs for polling in update() — avoids conflict with DD's id_pressed handler
	_filter_popup    = popup
	_filter_item_idx = idx
	print("[TextTransform] Texts added to FILTER popup at index ", idx)





func _is_select_tool_active(tree) -> bool:
	if _select_toolbar_path.is_empty(): return true
	var tb = tree.root.get_node_or_null(_select_toolbar_path)
	return tb != null and tb.visible


func _start_inline_edit(target: Control) -> void:
	if target == null or not is_instance_valid(target):
		return
	_inline_edit_node = target
	_selected_texts.clear()
	_primary_text = null
	# Clear any active custom cursor (move/resize) from before the double-click
	_do_reset_cursor()
	# Deselect DD's selection and hide transform box
	if _select_tool != null:
		_select_tool.call("EnableTransformBox", false)
		_select_tool.call("DeselectAll")
	# Allow mouse events on this text so it shows IBeam and accepts clicks for caret
	target.mouse_filter = Control.MOUSE_FILTER_STOP
	target.grab_focus()
	if "caret_position" in target:
		target.caret_position = target.text.length() if target.text != null else 0
	# Publish state for other mods (e.g. compare_fix) that need to know
	# whether keyboard input should be treated as text entry.
	Engine.set_meta("_inline_text_editing", true)
	print("[TextTransform] Inline edit started: %s" % target.name)


func _end_inline_edit() -> void:
	if _inline_edit_node != null and is_instance_valid(_inline_edit_node):
		_inline_edit_node.release_focus()
		_inline_edit_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inline_edit_node = null
	_do_reset_cursor()
	Engine.set_meta("_inline_text_editing", false)
	print("[TextTransform] Inline edit ended")


# ── Alignment buttons in SelectTool ──────────────────────────────────────────

func _setup_align_buttons(panel_align: Node) -> void:
	if panel_align.get_node_or_null("TextAlignSelectTool") != null:
		return

	_align_container = VBoxContainer.new()
	_align_container.name = "TextAlignSelectTool"
	_align_container.visible = false

	var label = Label.new()
	label.text = "Text Align"
	label.align = Label.ALIGN_CENTER
	_align_container.add_child(label)

	var center = CenterContainer.new()
	var hbox = HBoxContainer.new()
	hbox.add_constant_override("separation", 4)

	var icons_names = ["text-left.png", "text-center.png", "text-right.png"]
	var tooltips = [
		"Single: left anchor | Multi: align left edges",
		"Single: center anchor | Multi: align centers",
		"Single: right anchor | Multi: align right edges",
	]
	_align_buttons_st = []

	for i in range(3):
		var btn = Button.new()
		btn.hint_tooltip = tooltips[i]
		btn.toggle_mode = true
		btn.pressed = (i == 0)
		btn.focus_mode = 0
		btn.size_flags_horizontal = 3
		btn.expand_icon = true
		btn.rect_min_size = Vector2(48, 48)
		var img = Image.new()
		if img.load(_g.Root + "icons/" + icons_names[i]) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img, 0)
			btn.icon = tex
		btn.connect("pressed", self, "_on_align_st_pressed", [i])
		hbox.add_child(btn)
		_align_buttons_st.append(btn)

	center.add_child(hbox)
	_align_container.add_child(center)
	panel_align.add_child(_align_container)
	print("[TextTransform] Alignment buttons added to SelectTool")


func _update_align_visibility() -> void:
	if _align_container == null or not is_instance_valid(_align_container):
		return
	var should_show = _selected_texts.size() > 0 and _inline_edit_node == null
	if _align_container.visible != should_show:
		_align_container.visible = should_show
	# Sync button state from first selected text's alignment mode (single select only)
	if should_show and _selected_texts.size() == 1:
		var ttf = _g.ModMapData.get("_ttf_handler")
		if ttf != null:
			var first = _selected_texts[0]
			if is_instance_valid(first):
				var id = first.get_instance_id()
				var mode = 0
				if ttf._anchors.has(id):
					mode = ttf._anchors[id]["mode"]
				elif first.has_meta("td_align"):
					mode = int(first.get_meta("td_align"))
				for i in range(_align_buttons_st.size()):
					if is_instance_valid(_align_buttons_st[i]):
						_align_buttons_st[i].pressed = (i == mode)
	elif should_show and _selected_texts.size() > 1:
		# Multi-select: no toggle state — buttons act as one-shot actions
		for i in range(_align_buttons_st.size()):
			if is_instance_valid(_align_buttons_st[i]):
				_align_buttons_st[i].pressed = false


func _on_align_st_pressed(mode: int) -> void:
	if _selected_texts.size() == 1:
		_align_single(mode)
	elif _selected_texts.size() > 1:
		_align_multi(mode)


func _align_single(mode: int) -> void:
	# Change text alignment mode (anchor) for a single selected text
	for i in range(_align_buttons_st.size()):
		if is_instance_valid(_align_buttons_st[i]):
			_align_buttons_st[i].pressed = (i == mode)

	var ttf = _g.ModMapData.get("_ttf_handler")
	if ttf == null:
		return

	var t = _selected_texts[0]
	if not is_instance_valid(t):
		return
	var id = t.get_instance_id()
	var vr = _text_visual_rect(t)
	var w = vr.w

	# Compute new anchor_x from visual position and new mode
	var new_anchor_x: float
	match mode:
		0: new_anchor_x = vr.o.x
		1: new_anchor_x = vr.o.x + w * 0.5
		2: new_anchor_x = vr.o.x + w
		_: new_anchor_x = vr.o.x

	ttf._anchors[id] = {"x": new_anchor_x, "mode": mode}
	t.call_deferred("set", "align", mode)
	t.set_meta("td_align", mode)
	if not t.is_connected("focus_entered", ttf, "_on_text_focus_entered"):
		t.connect("focus_entered", ttf, "_on_text_focus_entered", [t])
	ttf._save_align_data()
	print("[TextTransform] Single align mode set to %d" % mode)


func _align_multi(mode: int) -> void:
	# Position-align multiple texts relative to the selection bounding box
	var ttf = _g.ModMapData.get("_ttf_handler")
	var bbox = _selection_bbox()
	if bbox.size.x < 1.0:
		return

	for t in _selected_texts:
		if not is_instance_valid(t):
			continue
		var vr = _text_visual_rect(t)
		var visual_w = vr.w
		var delta_x: float

		match mode:
			0: # Left: align visual left edge to bbox left
				delta_x = bbox.position.x - vr.o.x
			1: # Center: align visual center to bbox center
				var bbox_center = bbox.position.x + bbox.size.x * 0.5
				var text_center = vr.o.x + visual_w * 0.5
				delta_x = bbox_center - text_center
			2: # Right: align visual right edge to bbox right
				var bbox_right = bbox.position.x + bbox.size.x
				var text_right = vr.o.x + visual_w
				delta_x = bbox_right - text_right
			_:
				delta_x = 0.0

		if abs(delta_x) > 0.5:
			t.rect_position = Vector2(t.rect_position.x + delta_x, t.rect_position.y)
			# Update dataOnFocus
			var dof = t.get("dataOnFocus")
			if dof != null:
				dof["position"] = t.rect_position
				t.set("dataOnFocus", dof)
			# Update anchor in text_tool_fix
			if ttf != null:
				var id = t.get_instance_id()
				if ttf._anchors.has(id):
					ttf._anchors[id]["x"] = ttf._anchor_x_from_rect(t)

	if ttf != null:
		ttf._save_align_data()
	print("[TextTransform] Multi align (mode %d) applied to %d texts" % [mode, _selected_texts.size()])
