# text_style_extra.gd
# Sub-mod for BugFixes -- Adds "Letter Spacing" and "Curvature" sliders to the
# Text Tool panel and to the "Text Style" section (text_select_style) of the
# Select Tool panel.
#
# - Letter spacing: sets DynamicFont.extra_spacing_char on the text's font.
#   DD recreates the font on every SetFont(), so a per-frame watcher reapplies
#   the spacing whenever it is lost. During export DD multiplies the font size
#   by 4; the watcher scales the spacing by the same factor.
# - Curvature: the native LineEdit cannot bend text, so a child Node2D overlay
#   redraws the characters along a circular arc (draw_char) and the native
#   glyphs are hidden (font_color alpha 0) while the text is not focused.
#   While the text is focused (edit mode), the flat text is shown for editing.
# - Persistence: per-text values are stored in ModMapData keyed by node_id
#   (same mechanism as text_tool_fix alignment data).
# - Undo/redo: integrated in DD history via undo_lib.record_callback.

var _g
var text_transform = null      # set by Main.gd (may be null)
var text_select_style = null   # set by Main.gd (may be null)

const MOD_DATA_KEY := "TextStyleExtra"
const OVERLAY_NAME := "UPCurveOverlay"
const MAX_ANGLE := PI          # slider at 100 == half circle

# instance_id -> {"spacing": int, "curve": float}
var _styles := {}
# instance_id -> Array signature for overlay redraw change-detection
var _draw_sig := {}
# instance ids already seen (new-text detection)
var _known := {}

# Tool-level defaults applied to newly created texts (mirrors native panel behavior)
var _default_spacing := 0
var _default_curve := 0.0

# UI -- Text Tool panel
var _tt_setup_done := false
var _tt_spacing = null
var _tt_curve = null
var _tt_synced_iid := 0

# UI -- Select Tool panel (inside text_select_style's section)
var _st_setup_done := false
var _st_rows := []
var _st_spacing = null
var _st_curve = null
var _st_synced_sig := ""

var _syncing := false
var _drag_snapshot = null      # [[nid, iid, spacing, curve], ...] at drag start
var _save_btn_connected := false


func initialize():
	_try_setup_text_panel(0)


# ── Panel injection ──────────────────────────────────────────────────────────

func _try_setup_text_panel(attempt):
	if attempt > 30 or _tt_setup_done:
		return
	var root = _g.World.get_tree().root
	var anchor = root.get_node_or_null("Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor == null:
		_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_setup_text_panel", [attempt + 1])
		return
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "TextTool":
			var align = child.get_node_or_null("Divider/TextToolPanel/Align")
			if align != null and align.get_child_count() > 0:
				_build_text_panel_ui(align)
				return
	_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_setup_text_panel", [attempt + 1])


func _build_text_panel_ui(align):
	# Insert right after the FONT_SIZE row (the HBox containing a SpinBox)
	var insert_idx = -1
	for i in range(align.get_child_count()):
		var c = align.get_child(i)
		if c is HBoxContainer:
			for sub in c.get_children():
				if sub is SpinBox:
					insert_idx = i + 1
					break
		if insert_idx >= 0:
			break
	var row1 = _make_slider_row("Spacing", -10, 40, 1)
	var row2 = _make_slider_row("Curve", -100, 100, 1)
	_tt_spacing = row1[1]
	_tt_curve = row2[1]
	align.add_child(row1[0])
	align.add_child(row2[0])
	if insert_idx >= 0:
		align.move_child(row1[0], insert_idx)
		align.move_child(row2[0], insert_idx + 1)
	_tt_spacing.connect("value_changed", self, "_on_slider_changed", ["tt"])
	_tt_curve.connect("value_changed", self, "_on_slider_changed", ["tt"])
	_tt_spacing.connect("drag_ended", self, "_on_drag_ended")
	_tt_curve.connect("drag_ended", self, "_on_drag_ended")
	_tt_setup_done = true
	print("[TextStyleExtra] Text Tool panel UI injected")


func _try_setup_select_panel():
	if _st_setup_done:
		return
	if text_select_style == null or not text_select_style._setup_done:
		return
	var color_row = text_select_style._color_row
	if color_row == null or not is_instance_valid(color_row):
		return
	var parent = color_row.get_parent()
	if parent == null:
		return
	var row1 = _make_slider_row("Spacing", -10, 40, 1)
	var row2 = _make_slider_row("Curve", -100, 100, 1)
	_st_spacing = row1[1]
	_st_curve = row2[1]
	parent.add_child(row1[0])
	parent.add_child(row2[0])
	parent.move_child(row1[0], color_row.get_index() + 1)
	parent.move_child(row2[0], color_row.get_index() + 2)
	_st_rows = [row1[0], row2[0]]
	_st_spacing.connect("value_changed", self, "_on_slider_changed", ["st"])
	_st_curve.connect("value_changed", self, "_on_slider_changed", ["st"])
	_st_spacing.connect("drag_ended", self, "_on_drag_ended")
	_st_curve.connect("drag_ended", self, "_on_drag_ended")
	_st_setup_done = true
	print("[TextStyleExtra] Select Tool panel UI injected")


func _make_slider_row(label_text: String, vmin: float, vmax: float, step: float) -> Array:
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(55, 0)
	row.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = step
	slider.value = 0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE  # never steal focus from the LineEdit
	row.add_child(slider)
	return [row, slider]


# ── Target resolution ────────────────────────────────────────────────────────

func _get_current_texts() -> Node:
	if _g.World == null or not is_instance_valid(_g.World):
		return null
	var level = _g.World.GetCurrentLevel()
	if level == null or not is_instance_valid(level):
		return null
	var texts = level.get("Texts")
	if texts == null or not is_instance_valid(texts):
		return null
	return texts


func _get_target_texts() -> Array:
	if _g.Editor == null:
		return []
	var tool_name = str(_g.Editor.get("ActiveToolName"))
	if tool_name == "TextTool":
		var t = null
		var tool = _g.Editor.get("ActiveTool")
		if tool != null:
			t = tool.get("focus")
		if (t == null or not is_instance_valid(t)) and _get_current_texts() != null:
			for c in _get_current_texts().get_children():
				if c is Control and c.has_focus():
					t = c
					break
		if t != null and is_instance_valid(t):
			return [t]
		return []
	elif tool_name == "SelectTool" and text_transform != null:
		var out := []
		for t2 in text_transform._selected_texts:
			if t2 != null and is_instance_valid(t2):
				out.append(t2)
		return out
	return []


func _get_node_id(t: Node):
	var meta = t.get("__meta__")
	if meta is Dictionary and meta.has("node_id"):
		return str(meta["node_id"])
	return null


func _get_style(iid: int) -> Dictionary:
	if _styles.has(iid):
		return _styles[iid]
	return {"spacing": 0, "curve": 0.0}


# ── Slider handlers ──────────────────────────────────────────────────────────

func _on_slider_changed(_value, which: String):
	if _syncing:
		return
	var targets = _get_target_texts()
	if _drag_snapshot == null and targets.size() > 0:
		# Capture pre-drag state once per drag for the undo record
		_drag_snapshot = []
		for t in targets:
			var st = _get_style(t.get_instance_id())
			_drag_snapshot.append([_get_node_id(t), t.get_instance_id(), st["spacing"], st["curve"]])
	var spacing = int((_tt_spacing if which == "tt" else _st_spacing).value)
	var curve = float((_tt_curve if which == "tt" else _st_curve).value)
	if which == "tt":
		_default_spacing = spacing
		_default_curve = curve
	for t in targets:
		_styles[t.get_instance_id()] = {"spacing": spacing, "curve": curve}
	# Mirror the other panel's sliders
	_syncing = true
	if which == "tt" and _st_setup_done:
		_st_spacing.value = spacing
		_st_curve.value = curve
	elif which == "st" and _tt_setup_done:
		_tt_spacing.value = spacing
		_tt_curve.value = curve
	_syncing = false


func _on_drag_ended(value_changed: bool):
	if not value_changed or _drag_snapshot == null:
		_drag_snapshot = null
		return
	var before = _drag_snapshot
	_drag_snapshot = null
	var after := []
	for e in before:
		var st = null
		if instance_from_id(e[1]) != null:
			st = _get_style(e[1])
		if st == null:
			continue
		after.append([e[0], e[1], st["spacing"], st["curve"]])
	var undo = _g.ModMapData.get("_undo_lib") if _g.ModMapData is Dictionary else null
	if undo != null and after.size() > 0:
		undo.record_callback(self, "_undo_apply", [before], self, "_undo_apply", [after])
	_write_mod_map_data()


func _undo_apply(entries: Array) -> void:
	for e in entries:
		var t = _resolve_text(e[0], e[1])
		if t == null:
			continue
		_styles[t.get_instance_id()] = {"spacing": int(e[2]), "curve": float(e[3])}
	_write_mod_map_data()


func _resolve_text(nid, iid: int):
	var obj = instance_from_id(iid)
	if obj != null and is_instance_valid(obj):
		return obj
	if nid == null:
		return null
	var texts = _get_current_texts()
	if texts == null:
		return null
	for t in texts.get_children():
		if _get_node_id(t) == nid:
			return t
	return null


# ── Persistence (ModMapData, keyed by node_id) ───────────────────────────────

func _write_mod_map_data() -> void:
	if not (_g.ModMapData is Dictionary):
		return
	var data = {}
	if _g.ModMapData.has(MOD_DATA_KEY) and _g.ModMapData[MOD_DATA_KEY] is Dictionary:
		# Keep entries from other levels / not currently instanced
		for k in _g.ModMapData[MOD_DATA_KEY]:
			data[k] = _g.ModMapData[MOD_DATA_KEY][k]
	if _g.World != null and is_instance_valid(_g.World):
		for level in _g.World.get_children():
			var texts = level.get("Texts") if level != null else null
			if texts == null or not is_instance_valid(texts):
				continue
			for t in texts.get_children():
				var nid = _get_node_id(t)
				if nid == null:
					continue
				var iid = t.get_instance_id()
				if _styles.has(iid):
					var st = _styles[iid]
					if int(st["spacing"]) == 0 and float(st["curve"]) == 0.0:
						data.erase(nid)
					else:
						data[nid] = [int(st["spacing"]), float(st["curve"])]
	_g.ModMapData[MOD_DATA_KEY] = data


func _adopt_saved_styles(texts: Node) -> void:
	if not (_g.ModMapData is Dictionary) or not _g.ModMapData.has(MOD_DATA_KEY):
		return
	var data = _g.ModMapData[MOD_DATA_KEY]
	if not (data is Dictionary):
		return
	for t in texts.get_children():
		var iid = t.get_instance_id()
		if _styles.has(iid):
			continue
		var nid = _get_node_id(t)
		if nid != null and data.has(nid):
			var e = data[nid]
			if e is Array and e.size() >= 2:
				_styles[iid] = {"spacing": int(e[0]), "curve": float(e[1])}


func _on_save_pressed() -> void:
	_write_mod_map_data()


# ── Per-frame watcher ────────────────────────────────────────────────────────

func update(_delta):
	if _g.Editor == null or _g.World == null or not is_instance_valid(_g.World):
		return
	_try_setup_select_panel()
	_connect_save_button()
	if _g.ModMapData is Dictionary:
		_g.ModMapData["_tse_handler"] = self

	var texts = _get_current_texts()
	if texts == null:
		return
	_adopt_saved_styles(texts)
	_watch_new_texts(texts)

	for t in texts.get_children():
		var iid = t.get_instance_id()
		if _styles.has(iid):
			_enforce_style(t, _styles[iid])
		elif t.get_node_or_null(OVERLAY_NAME) != null:
			# Orphan overlay from duplicate(): free it and restore font_color
			_enforce_style(t, {"spacing": 0, "curve": 0.0})

	_cleanup_dead()
	_sync_sliders()
	_sync_select_rows_visibility()


func _watch_new_texts(texts: Node) -> void:
	# Newly created texts inherit the Text Tool defaults (like native settings)
	var in_text_tool = str(_g.Editor.get("ActiveToolName")) == "TextTool"
	for t in texts.get_children():
		var iid = t.get_instance_id()
		if _known.has(iid):
			continue
		_known[iid] = true
		if in_text_tool and t is Control and t.has_focus() and not _styles.has(iid):
			if _default_spacing != 0 or _default_curve != 0.0:
				_styles[iid] = {"spacing": _default_spacing, "curve": _default_curve}


func _enforce_style(t: Node, st: Dictionary) -> void:
	var font = t.get("custom_fonts/font")
	if font == null or not (font is DynamicFont):
		return
	# Export scaling: DD sets font.Size = fontSize * 4 during export
	var base_size = 0
	var bs = t.get("fontSize")
	if bs != null:
		base_size = int(bs)
	var factor := 1.0
	if base_size > 0 and font.size >= base_size * 3:
		factor = float(font.size) / float(base_size)
	var want_spacing = int(round(int(st["spacing"]) * factor))
	if font.extra_spacing_char != want_spacing:
		font.extra_spacing_char = want_spacing
		t.text = t.text
		t.rect_size = Vector2.ZERO

	var curve = float(st["curve"])
	var ov = t.get_node_or_null(OVERLAY_NAME)
	var fc = t.get("fontColor")
	if fc == null or not (fc is Color):
		fc = Color.black
	if curve != 0.0:
		if ov == null:
			ov = _make_overlay(t)
		ov.curve = curve
		# Hide the native flat glyphs; the overlay renders the curved text,
		# including while editing (the caret stays visible: its color is a
		# separate theme item, independent from font_color)
		var cur = t.get("custom_colors/font_color")
		if cur == null or not (cur is Color) or cur.a != 0.0:
			t.set("custom_colors/font_color", Color(fc.r, fc.g, fc.b, 0.0))
		ov.visible = true
		var sig = [t.get("text"), font.size, font.extra_spacing_char, fc, curve, t.rect_size]
		if not _draw_sig.has(t.get_instance_id()) or not _sig_equal(_draw_sig[t.get_instance_id()], sig):
			_draw_sig[t.get_instance_id()] = sig
			ov.update()
	else:
		if ov != null:
			ov.queue_free()
		var cur2 = t.get("custom_colors/font_color")
		if cur2 == null or not (cur2 is Color) or cur2.a == 0.0:
			t.set("custom_colors/font_color", fc)


func _sig_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


func _make_overlay(t: Node) -> Node2D:
	var ov = CurveOverlay.new()
	ov.name = OVERLAY_NAME
	ov.use_parent_material = true  # inherit the FontSDF sharpening material
	t.add_child(ov)
	return ov


func _cleanup_dead() -> void:
	var dead := []
	for iid in _styles:
		if instance_from_id(iid) == null:
			dead.append(iid)
	for iid in dead:
		_styles.erase(iid)
		_draw_sig.erase(iid)
		_known.erase(iid)


func _connect_save_button() -> void:
	if _save_btn_connected:
		return
	var editor = _g.World.get_tree().root.get_node_or_null("Master/Editor")
	if editor == null:
		return
	var save_btn = editor.get("saveButton")
	if save_btn != null and not save_btn.is_connected("pressed", self, "_on_save_pressed"):
		save_btn.connect("pressed", self, "_on_save_pressed")
		_save_btn_connected = true


# ── Slider <-> selection sync ────────────────────────────────────────────────

func _sync_sliders() -> void:
	if _drag_snapshot != null:
		return  # user is dragging
	var targets = _get_target_texts()
	if targets.size() == 0:
		_tt_synced_iid = 0
		_st_synced_sig = ""
		return
	var primary = targets[0]
	var iid = primary.get_instance_id()
	var st = _get_style(iid)
	var tool_name = str(_g.Editor.get("ActiveToolName"))
	if tool_name == "TextTool" and _tt_setup_done:
		if _tt_synced_iid != iid:
			_tt_synced_iid = iid
			_syncing = true
			_tt_spacing.value = int(st["spacing"])
			_tt_curve.value = float(st["curve"])
			_syncing = false
			# Mirror native behavior: selecting a text updates the tool defaults
			_default_spacing = int(st["spacing"])
			_default_curve = float(st["curve"])
	elif tool_name == "SelectTool" and _st_setup_done:
		var sig = ""
		for t in targets:
			sig += str(t.get_instance_id()) + ";"
		if _st_synced_sig != sig:
			_st_synced_sig = sig
			_syncing = true
			_st_spacing.value = int(st["spacing"])
			_st_curve.value = float(st["curve"])
			_syncing = false


func _sync_select_rows_visibility() -> void:
	if not _st_setup_done or text_select_style == null:
		return
	var title = text_select_style._title
	if title == null or not is_instance_valid(title):
		return
	for row in _st_rows:
		if is_instance_valid(row):
			row.visible = title.visible


# ── Public API (used by text_transform for copy/paste) ───────────────────────

# Returns [spacing, curve] for clipboard serialization ([0, 0.0] when unstyled)
func get_style_for_copy(t: Node) -> Array:
	if t == null or not is_instance_valid(t):
		return [0, 0.0]
	var st = _styles.get(t.get_instance_id())
	if st == null:
		return [0, 0.0]
	return [int(st["spacing"]), float(st["curve"])]


# Called from text_transform after paste. Always stores the entry (even zeros)
# so the watcher normalizes duplicated nodes: template.duplicate() copies the
# curve overlay child and the alpha-0 font_color of a curved source, which
# must be cleaned up when the pasted style is flat.
func register_style_external(t: Node, spacing: int, curve: float) -> void:
	if t == null or not is_instance_valid(t):
		return
	_styles[t.get_instance_id()] = {"spacing": spacing, "curve": curve}
	_known[t.get_instance_id()] = true
	_write_mod_map_data()


# ── Public API (used by text_transform for selection box / hit-testing) ──────

# Returns the bounding rect of the curved glyphs in the text's local coords
# (unscaled), or Rect2() when the text has no active curvature.
func get_curved_local_rect(t: Node) -> Rect2:
	if t == null or not is_instance_valid(t):
		return Rect2()
	var st = _styles.get(t.get_instance_id())
	if st == null or float(st["curve"]) == 0.0:
		return Rect2()
	var ov = t.get_node_or_null(OVERLAY_NAME)
	if ov == null:
		return Rect2()
	var layout = ov.compute_layout()
	if layout.size() == 0:
		return Rect2()
	var font = t.get("custom_fonts/font")
	if font == null or not (font is DynamicFont):
		return Rect2()
	var asc = font.get_ascent()
	var desc = font.get_descent()
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for e in layout:
		# e = [pos: Vector2, rot: float, w: float]
		var pos = e[0]
		var rot = e[1]
		var hw = e[2] / 2.0
		for corner in [Vector2(-hw, -asc), Vector2(hw, -asc), Vector2(hw, desc), Vector2(-hw, desc)]:
			var pt = pos + corner.rotated(rot)
			mn.x = min(mn.x, pt.x); mn.y = min(mn.y, pt.y)
			mx.x = max(mx.x, pt.x); mx.y = max(mx.y, pt.y)
	if mn.x == INF:
		return Rect2()
	return Rect2(mn, mx - mn)


# ── Curved text overlay ──────────────────────────────────────────────────────

class CurveOverlay:
	extends Node2D

	# -100..100 ; 100 == the text spans a half circle (arch), negative == bowl
	var curve := 0.0

	# Per-char placement along the arc, in host-local coords.
	# Returns [[pos: Vector2, rot: float, w: float], ...] ([] when flat/empty).
	func compute_layout() -> Array:
		if curve == 0.0:
			return []
		var host = get_parent()
		if host == null:
			return []
		var font = host.get("custom_fonts/font")
		if font == null or not (font is DynamicFont):
			return []
		var s = host.get("text")
		if s == null or str(s).length() == 0:
			return []
		s = str(s)

		# Per-char advances (extra_spacing_char is already included by the font)
		var adv := []
		var total := 0.0
		for i in range(s.length()):
			var c = s.ord_at(i)
			var n = s.ord_at(i + 1) if i + 1 < s.length() else 0
			var w = font.get_char_size(c, n).x
			adv.append(w)
			total += w
		if total <= 0.0:
			return []

		var angle_total = clamp(curve, -100.0, 100.0) / 100.0 * PI
		var radius = total / abs(angle_total)
		var sgn = 1.0 if angle_total > 0.0 else -1.0

		# Baseline of the straight layout (LineEdit auto-shrinks to min size,
		# so style margin + ascent is a good approximation of the baseline)
		var sb = host.get_stylebox("normal") if host.has_method("get_stylebox") else null
		var top = sb.get_margin(MARGIN_TOP) if sb != null else 0.0
		var left = sb.get_margin(MARGIN_LEFT) if sb != null else 0.0
		var baseline_y = top + font.get_ascent()
		var cx = left + total / 2.0
		var cy = baseline_y + sgn * radius  # circle center

		var out := []
		var srun := 0.0
		for i in range(s.length()):
			var w = adv[i]
			var mid = srun + w / 2.0
			var theta = (mid - total / 2.0) / radius
			var px = cx + radius * sin(theta)
			var py = cy - sgn * radius * cos(theta)
			out.append([Vector2(px, py), sgn * theta, w])
			srun += w
		return out

	func _draw():
		var layout = compute_layout()
		if layout.size() == 0:
			return
		var host = get_parent()
		var font = host.get("custom_fonts/font")
		var s = str(host.get("text"))
		var col = host.get("fontColor")
		if col == null or not (col is Color):
			col = Color.black
		for i in range(layout.size()):
			var e = layout[i]
			draw_set_transform(e[0], e[1], Vector2.ONE)
			var nxt = ""
			if i + 1 < s.length():
				nxt = s.substr(i + 1, 1)
			draw_char(font, Vector2(-e[2] / 2.0, 0.0), s.substr(i, 1), nxt, col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
