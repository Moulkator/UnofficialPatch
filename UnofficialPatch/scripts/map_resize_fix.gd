# map_resize_fix.gd
# Loaded dynamically by Core.gd
#
# Fix 1: Map resize limit raised from 128x128 to 200x200.
# Fix 2: Terrain splat cropped from wrong side on negative Left/Top resize.
# Fix 3: Cave walls/mesh offset on negative Left/Top resize.
# Feature: "Target Size" mode — enter desired dimensions + anchor direction.

var _g

var _dialog = null
var _top_sb = null
var _bottom_sb = null
var _left_sb = null
var _right_sb = null
var _ok_button = null
var _original_ok_target = null
var _original_ok_method = ""

var _current_size_label = null
var _resized_size_label = null
var _warning_label = null

# ── Target Size mode ─────────────────────────────────────────────────────────
var _mode = 0  # 0 = Offset, 1 = Target Size
var _offset_btn = null
var _target_btn = null
var _mode_container = null    # HBox des boutons Manual / Target Size
var _sep2 = null              # separator entre mode_container et _target_panel
var _offset_grid = null       # le GridContainer original DD
var _manual_wrapper = null    # MarginContainer autour du GridContainer
var _target_panel = null      # panel Target Size (width/height + anchor)
var _width_sb = null
var _height_sb = null
var _width_pct_sb = null
var _height_pct_sb = null
var _lock_btn = null
var _aspect_locked = false
var _locked_ratio = 1.0   # W/H en tiles, capturé au moment du toggle ON
var _orig_w = 0           # baseline pour calcul du %
var _orig_h = 0
var _syncing_pct = false  # anti-recursion entre tiles <-> %
var _last_w_pct = 100     # dernier % effectif appliqué (pour direction du skip)
var _last_h_pct = 100
var _unit_mode = 0        # 0 = tiles, 1 = %
var _unit_container = null
var _tiles_btn = null
var _pct_btn = null
var _anchor_x = 1  # 0=left, 1=center, 2=right
var _anchor_y = 1  # 0=top, 1=center, 2=bottom
var _anchor_buttons = []      # Array 9 boutons [row * 3 + col]
var _offset_top_label = null
var _offset_bottom_label = null
var _offset_left_label = null
var _offset_right_label = null
var _offset_top_arrow = null
var _offset_bottom_arrow = null
var _offset_left_arrow = null
var _offset_right_arrow = null
var _arrow_tex = null
var _updating_from_target = false

const ANCHOR_COLOR_SELECTED   = Color(0.35, 0.55, 0.85, 1.0)
const ANCHOR_COLOR_NORMAL     = Color(0.25, 0.28, 0.32, 1.0)
const ANCHOR_COLOR_HOVER      = Color(0.30, 0.42, 0.60, 1.0)
const MODE_COLOR_ACTIVE       = Color(0.30, 0.50, 0.78, 1.0)
const MODE_COLOR_INACTIVE     = Color(0.20, 0.22, 0.26, 1.0)
const LOCK_COLOR_ACTIVE       = Color(0.30, 0.50, 0.78, 1.0)
const LOCK_COLOR_INACTIVE     = Color(0.22, 0.24, 0.28, 1.0)
const SB_WIDTH                = 100
const LOCK_BTN_SIZE           = 28
const SB_ARROW_WIDTH          = 16  # largeur des fleches haut/bas du SpinBox
const ROW_SEPARATION          = 32


func initialize():
	var editor = _g.Editor
	_dialog = editor.get_node_or_null("Windows/ChangeMapSize")
	if _dialog == null:
		print("[MapResizeFix] ERROR: dialog not found")
		return

	# Charger la flèche pour les indicateurs d'offset
	_load_arrow_texture()
	var valign = _dialog.get_node_or_null("Margins/VAlign")
	_offset_grid = _dialog.get_node_or_null("Margins/VAlign/GridContainer")
	_top_sb = _offset_grid.get_node_or_null("TopSpinBox")
	_bottom_sb = _offset_grid.get_node_or_null("BottomSpinBox")
	_left_sb = _offset_grid.get_node_or_null("LeftSpinBox")
	_right_sb = _offset_grid.get_node_or_null("RightSpinBox")
	_ok_button = _dialog.get_node_or_null("Margins/VAlign/Buttons/OkayButton")

	# Masquer le tip ("Expand or crop the map") et les fillers natifs
	var _tip_label = valign.get_node_or_null("Label")
	if _tip_label != null:
		_tip_label.visible = false
	var _filler1 = valign.get_node_or_null("Filler")
	if _filler1 != null:
		_filler1.visible = false
	var _filler2 = valign.get_node_or_null("Filler2")
	if _filler2 != null:
		_filler2.visible = false

	# ── Info labels (current + resized size) ─────────────────────────────
	var info_container = HBoxContainer.new()
	info_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var cur_vbox = VBoxContainer.new()
	cur_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur_title = Label.new()
	cur_title.text = "Current Map Size"
	cur_title.add_color_override("font_color", Color(0.7, 0.7, 0.7))
	cur_title.align = Label.ALIGN_CENTER
	_current_size_label = Label.new()
	_current_size_label.text = "-- x --"
	_current_size_label.align = Label.ALIGN_CENTER
	cur_vbox.add_child(cur_title)
	cur_vbox.add_child(_current_size_label)

	var vsep = VSeparator.new()
	vsep.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var new_vbox = VBoxContainer.new()
	new_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var new_title = Label.new()
	new_title.text = "Resized Map Size"
	new_title.add_color_override("font_color", Color(0.7, 0.7, 0.7))
	new_title.align = Label.ALIGN_CENTER
	_resized_size_label = Label.new()
	_resized_size_label.text = "-- x --"
	_resized_size_label.align = Label.ALIGN_CENTER
	new_vbox.add_child(new_title)
	new_vbox.add_child(_resized_size_label)

	info_container.add_child(cur_vbox)
	info_container.add_child(vsep)
	info_container.add_child(new_vbox)

	var sep = HSeparator.new()

	_warning_label = Label.new()
	_warning_label.text = "Warning: Maps larger than 200x200 may cause unexpected behaviour with some tools."
	_warning_label.add_color_override("font_color", Color(1.0, 0.75, 0.2))
	_warning_label.autowrap = true
	_warning_label.visible = false

	# ── Mode toggle ──────────────────────────────────────────────────────
	_mode_container = HBoxContainer.new()
	_mode_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_container.set("custom_constants/separation", 4)
	_mode_container.alignment = BoxContainer.ALIGN_CENTER

	_offset_btn = Button.new()
	_offset_btn.text = "Manual"
	_offset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_offset_btn.connect("pressed", self, "_set_mode", [0])

	_target_btn = Button.new()
	_target_btn.text = "Target Size"
	_target_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_btn.connect("pressed", self, "_set_mode", [1])

	_mode_container.add_child(_target_btn)
	_mode_container.add_child(_offset_btn)

	# ── Target Size panel ────────────────────────────────────────────────
	_target_panel = VBoxContainer.new()
	_target_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_panel.size_flags_vertical = Control.SIZE_EXPAND | 4  # EXPAND + SHRINK_CENTER
	_target_panel.set("custom_constants/separation", 14)
	_target_panel.visible = false

	# Width / Height : 2 rows (labels au-dessus, inputs en dessous)
	# Permet de centrer verticalement le lock button dans la rangée des SpinBox.
	var size_block = VBoxContainer.new()
	size_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_block.set("custom_constants/separation", 4)

	# --- Row 1 : labels (centrés sur la zone de texte du SpinBox, pas sur l'ensemble) ---
	var labels_row = HBoxContainer.new()
	labels_row.alignment = BoxContainer.ALIGN_CENTER
	labels_row.set("custom_constants/separation", ROW_SEPARATION)

	var w_label_box = HBoxContainer.new()
	w_label_box.rect_min_size = Vector2(SB_WIDTH, 0)
	w_label_box.set("custom_constants/separation", 0)
	var w_label = Label.new()
	w_label.text = "Width"
	w_label.add_color_override("font_color", Color(0.7, 0.7, 0.7))
	w_label.align = Label.ALIGN_CENTER
	w_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var w_arrow_spacer = Control.new()
	w_arrow_spacer.rect_min_size = Vector2(SB_ARROW_WIDTH, 0)
	w_label_box.add_child(w_label)
	w_label_box.add_child(w_arrow_spacer)

	var lock_label_spacer = Control.new()
	lock_label_spacer.rect_min_size = Vector2(LOCK_BTN_SIZE, 0)

	var h_label_box = HBoxContainer.new()
	h_label_box.rect_min_size = Vector2(SB_WIDTH, 0)
	h_label_box.set("custom_constants/separation", 0)
	var h_label = Label.new()
	h_label.text = "Height"
	h_label.add_color_override("font_color", Color(0.7, 0.7, 0.7))
	h_label.align = Label.ALIGN_CENTER
	h_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h_arrow_spacer = Control.new()
	h_arrow_spacer.rect_min_size = Vector2(SB_ARROW_WIDTH, 0)
	h_label_box.add_child(h_label)
	h_label_box.add_child(h_arrow_spacer)

	labels_row.add_child(w_label_box)
	labels_row.add_child(lock_label_spacer)
	labels_row.add_child(h_label_box)

	# --- Row 2 : inputs (SpinBoxes + lock button centré verticalement) ---
	var inputs_row = HBoxContainer.new()
	inputs_row.alignment = BoxContainer.ALIGN_CENTER
	inputs_row.set("custom_constants/separation", ROW_SEPARATION)

	_width_sb = SpinBox.new()
	_width_sb.min_value = 1
	_width_sb.max_value = 500
	_width_sb.value = 10
	_width_sb.rect_min_size = Vector2(SB_WIDTH, 0)
	_width_sb.get_line_edit().align = LineEdit.ALIGN_CENTER
	_width_sb.connect("value_changed", self, "_on_target_changed", ["w_tiles"])

	_width_pct_sb = SpinBox.new()
	_width_pct_sb.min_value = 1
	_width_pct_sb.max_value = 5000
	_width_pct_sb.value = 100
	_width_pct_sb.step = 1
	_width_pct_sb.suffix = "%"
	_width_pct_sb.rect_min_size = Vector2(SB_WIDTH, 0)
	_width_pct_sb.get_line_edit().align = LineEdit.ALIGN_CENTER
	_width_pct_sb.connect("value_changed", self, "_on_target_changed", ["w_pct"])

	_lock_btn = Button.new()
	_lock_btn.toggle_mode = true
	_lock_btn.text = ""
	_lock_btn.rect_min_size = Vector2(LOCK_BTN_SIZE, LOCK_BTN_SIZE)
	_lock_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_lock_btn.hint_tooltip = "Lock aspect ratio"
	_lock_btn.focus_mode = Control.FOCUS_NONE
	_lock_btn.connect("toggled", self, "_on_lock_toggled")
	_style_lock_button(false)

	# Icône centrée via CenterContainer (Button.icon de Godot 3 garde
	# un offset interne réservé au layout texte+icône, même sans texte).
	var lock_icon_container = CenterContainer.new()
	lock_icon_container.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	lock_icon_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lock_icon_rect = TextureRect.new()
	lock_icon_rect.texture = _load_lock_icon()
	lock_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock_icon_container.add_child(lock_icon_rect)
	_lock_btn.add_child(lock_icon_container)

	_height_sb = SpinBox.new()
	_height_sb.min_value = 1
	_height_sb.max_value = 500
	_height_sb.value = 10
	_height_sb.rect_min_size = Vector2(SB_WIDTH, 0)
	_height_sb.get_line_edit().align = LineEdit.ALIGN_CENTER
	_height_sb.connect("value_changed", self, "_on_target_changed", ["h_tiles"])

	_height_pct_sb = SpinBox.new()
	_height_pct_sb.min_value = 1
	_height_pct_sb.max_value = 5000
	_height_pct_sb.value = 100
	_height_pct_sb.step = 1
	_height_pct_sb.suffix = "%"
	_height_pct_sb.rect_min_size = Vector2(SB_WIDTH, 0)
	_height_pct_sb.get_line_edit().align = LineEdit.ALIGN_CENTER
	_height_pct_sb.connect("value_changed", self, "_on_target_changed", ["h_pct"])

	inputs_row.add_child(_width_sb)
	inputs_row.add_child(_width_pct_sb)
	inputs_row.add_child(_lock_btn)
	inputs_row.add_child(_height_sb)
	inputs_row.add_child(_height_pct_sb)

	size_block.add_child(labels_row)
	size_block.add_child(inputs_row)

	# Toggle Tiles / % (au-dessus de size_block)
	_unit_container = HBoxContainer.new()
	_unit_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_container.set("custom_constants/separation", 4)
	_unit_container.alignment = BoxContainer.ALIGN_CENTER

	_tiles_btn = Button.new()
	_tiles_btn.text = "Tiles"
	_tiles_btn.rect_min_size = Vector2(80, 0)
	_tiles_btn.connect("pressed", self, "_set_unit_mode", [0])

	_pct_btn = Button.new()
	_pct_btn.text = "%"
	_pct_btn.rect_min_size = Vector2(80, 0)
	_pct_btn.connect("pressed", self, "_set_unit_mode", [1])

	_unit_container.add_child(_tiles_btn)
	_unit_container.add_child(_pct_btn)

	# Anchor 3x3 grid avec flèches d'offset autour
	var anchor_wrapper = VBoxContainer.new()
	anchor_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	anchor_wrapper.set("custom_constants/separation", 4)

	# Flèche + label du haut
	var top_hbox = HBoxContainer.new()
	top_hbox.alignment = BoxContainer.ALIGN_CENTER
	top_hbox.set("custom_constants/separation", 4)
	_offset_top_arrow = _make_arrow_rect(90)
	_offset_top_label = Label.new()
	_offset_top_label.add_color_override("font_color", Color(0.5, 0.5, 0.5))
	top_hbox.add_child(_offset_top_arrow)
	top_hbox.add_child(_offset_top_label)
	anchor_wrapper.add_child(top_hbox)

	# Ligne du milieu : left + grid + right
	var anchor_mid = HBoxContainer.new()
	anchor_mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	anchor_mid.alignment = BoxContainer.ALIGN_CENTER
	anchor_mid.set("custom_constants/separation", 8)

	# Gauche : label + flèche (vers la gauche)
	var left_hbox = HBoxContainer.new()
	left_hbox.alignment = BoxContainer.ALIGN_END
	left_hbox.rect_min_size = Vector2(55, 0)
	left_hbox.set("custom_constants/separation", 4)
	_offset_left_label = Label.new()
	_offset_left_label.valign = Label.VALIGN_CENTER
	_offset_left_label.add_color_override("font_color", Color(0.5, 0.5, 0.5))
	_offset_left_arrow = _make_arrow_rect(0)
	left_hbox.add_child(_offset_left_label)
	left_hbox.add_child(_offset_left_arrow)

	var anchor_grid = GridContainer.new()
	anchor_grid.columns = 3
	anchor_grid.set("custom_constants/hseparation", 3)
	anchor_grid.set("custom_constants/vseparation", 3)

	_anchor_buttons = []
	for row in range(3):
		for col in range(3):
			var btn = Button.new()
			btn.rect_min_size = Vector2(28, 28)
			btn.text = ""
			btn.connect("pressed", self, "_on_anchor_pressed", [col, row])
			var style_n = StyleBoxFlat.new()
			style_n.bg_color = ANCHOR_COLOR_NORMAL
			style_n.set_corner_radius_all(3)
			btn.add_stylebox_override("normal", style_n)
			var style_h = StyleBoxFlat.new()
			style_h.bg_color = ANCHOR_COLOR_HOVER
			style_h.set_corner_radius_all(3)
			btn.add_stylebox_override("hover", style_h)
			var style_p = StyleBoxFlat.new()
			style_p.bg_color = ANCHOR_COLOR_SELECTED
			style_p.set_corner_radius_all(3)
			btn.add_stylebox_override("pressed", style_p)
			anchor_grid.add_child(btn)
			_anchor_buttons.append(btn)

	# Droite : flèche + label
	var right_hbox = HBoxContainer.new()
	right_hbox.alignment = BoxContainer.ALIGN_BEGIN
	right_hbox.rect_min_size = Vector2(55, 0)
	right_hbox.set("custom_constants/separation", 4)
	_offset_right_arrow = _make_arrow_rect(180)
	_offset_right_label = Label.new()
	_offset_right_label.valign = Label.VALIGN_CENTER
	_offset_right_label.add_color_override("font_color", Color(0.5, 0.5, 0.5))
	right_hbox.add_child(_offset_right_arrow)
	right_hbox.add_child(_offset_right_label)

	anchor_mid.add_child(left_hbox)
	anchor_mid.add_child(anchor_grid)
	anchor_mid.add_child(right_hbox)
	anchor_wrapper.add_child(anchor_mid)

	# Flèche + label du bas
	var bottom_hbox = HBoxContainer.new()
	bottom_hbox.alignment = BoxContainer.ALIGN_CENTER
	bottom_hbox.set("custom_constants/separation", 4)
	_offset_bottom_arrow = _make_arrow_rect(-90)
	_offset_bottom_label = Label.new()
	_offset_bottom_label.add_color_override("font_color", Color(0.5, 0.5, 0.5))
	bottom_hbox.add_child(_offset_bottom_arrow)
	bottom_hbox.add_child(_offset_bottom_label)
	anchor_wrapper.add_child(bottom_hbox)

	_target_panel.add_child(_unit_container)
	_target_panel.add_child(size_block)
	_target_panel.add_child(anchor_wrapper)

	# ── Assemble into dialog ─────────────────────────────────────────────
	_sep2 = HSeparator.new()

	valign.add_child(info_container)
	valign.add_child(sep)
	valign.add_child(_warning_label)
	valign.add_child(_mode_container)
	valign.add_child(_sep2)
	valign.add_child(_target_panel)

	# Order: info, sep, warning, mode_toggle, sep2, target_panel, grid, buttons
	valign.move_child(info_container, 0)
	valign.move_child(sep, 1)
	valign.move_child(_warning_label, 2)
	valign.move_child(_mode_container, 3)
	valign.move_child(_sep2, 4)
	valign.move_child(_target_panel, 5)

	# Envelopper le GridContainer (Manual) dans un MarginContainer
	var grid_index = _offset_grid.get_index()
	valign.remove_child(_offset_grid)
	_manual_wrapper = MarginContainer.new()
	_manual_wrapper.size_flags_vertical = Control.SIZE_EXPAND | 4  # EXPAND + SHRINK_CENTER
	_manual_wrapper.add_constant_override("margin_top", 25)
	_manual_wrapper.add_constant_override("margin_bottom", 25)
	_manual_wrapper.add_child(_offset_grid)
	valign.add_child(_manual_wrapper)
	valign.move_child(_manual_wrapper, 6)

	# Fix 1: disconnect C# value_changed clampers, replace with ours
	for sb in [_top_sb, _bottom_sb, _left_sb, _right_sb]:
		if sb == null:
			continue
		var conns = sb.get_signal_connection_list("value_changed")
		for c in conns:
			var m = c["method"]
			if m.begins_with("_on_") and m.ends_with("_value_changed"):
				sb.disconnect("value_changed", c["target"], m)
	for sb in [_top_sb, _bottom_sb, _left_sb, _right_sb]:
		sb.connect("value_changed", self, "_on_spinbox_changed", [sb])

	# Fix 2 & 3: intercept OK to fix terrain splat + cave
	var ok_conns = _ok_button.get_signal_connection_list("pressed")
	for c in ok_conns:
		_original_ok_target = c["target"]
		_original_ok_method = c["method"]
		_ok_button.disconnect("pressed", _original_ok_target, _original_ok_method)
	_ok_button.connect("pressed", self, "_on_ok_pressed")
	if _dialog.has_signal("about_to_show"):
		_dialog.connect("about_to_show", self, "_on_dialog_show")

	_set_mode(1)
	_set_unit_mode(0)
	_update_anchor_visuals()
	_resize_dialog()

	# Style des boutons OK/Cancel avec outline blanche
	var buttons_container = _dialog.get_node_or_null("Margins/VAlign/Buttons")
	if buttons_container != null:
		for btn in buttons_container.get_children():
			if btn is Button:
				_style_dialog_button(btn)

	print("[MapResizeFix] initialized (terrain + cave fixes + Target Size mode)")

	# Appliquer l'etat actuel du toggle (peut etre OFF -> on cache l'UI Target Size).
	set_target_size_visible(_is_target_size_enabled())


# Hot-toggle: cache/montre l'UI Target Size sans toucher aux bugfixes.
# Quand OFF, force le mode Manual et masque mode_container + sep2 + target_panel.
func set_target_size_visible(enabled: bool) -> void:
	if _mode_container == null or _sep2 == null or _target_panel == null:
		return
	_mode_container.visible = enabled
	_sep2.visible = enabled
	if enabled:
		# Re-active : repasse en Target Size par defaut.
		_set_mode(1)
	else:
		# Force Manual + planque le panel Target Size.
		_set_mode(0)
		_target_panel.visible = false
	_resize_dialog()


func _is_target_size_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("map_resize_target_size")


# ═══════════════════════════════════════════════════════════════════════════
#  Mode switching
# ═══════════════════════════════════════════════════════════════════════════

func _set_mode(mode: int) -> void:
	_mode = mode
	_manual_wrapper.visible = (mode == 0)
	_target_panel.visible = (mode == 1)
	_style_mode_button(_offset_btn, mode == 0)
	_style_mode_button(_target_btn, mode == 1)

	if mode == 1:
		# Transférer les valeurs du mode Manual vers Target Size
		var w = _g.World.Width
		var h = _g.World.Height
		if _orig_w <= 0:
			_orig_w = w
		if _orig_h <= 0:
			_orig_h = h
		var target_w = w + int(_left_sb.value) + int(_right_sb.value)
		var target_h = h + int(_top_sb.value) + int(_bottom_sb.value)
		_syncing_pct = true
		_width_sb.value = clamp(target_w, 1, 500)
		_height_sb.value = clamp(target_h, 1, 500)
		if _orig_w > 0:
			_width_pct_sb.value = int(round(float(_width_sb.value) * 100.0 / float(_orig_w)))
		if _orig_h > 0:
			_height_pct_sb.value = int(round(float(_height_sb.value) * 100.0 / float(_orig_h)))
		_last_w_pct = int(_width_pct_sb.value)
		_last_h_pct = int(_height_pct_sb.value)
		_syncing_pct = false
		_compute_offsets_from_target()

	_resize_dialog()


func _style_mode_button(btn: Button, active: bool) -> void:
	var color = MODE_COLOR_ACTIVE if active else MODE_COLOR_INACTIVE
	for state in ["normal", "hover", "pressed", "focus"]:
		var style = StyleBoxFlat.new()
		style.bg_color = color if state == "normal" else Color(color.r + 0.05, color.g + 0.05, color.b + 0.05, 1.0)
		style.set_corner_radius_all(4)
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		btn.add_stylebox_override(state, style)


func _style_dialog_button(btn: Button) -> void:
	var existing = btn.get_stylebox("normal")
	for state in ["normal", "hover"]:
		var base = btn.get_stylebox(state)
		if base != null and base is StyleBoxFlat:
			var s = base.duplicate()
			s.border_color = Color(0.6, 0.6, 0.6, 0.7) if state == "normal" else Color(0.8, 0.8, 0.8, 0.9)
			s.set_border_width_all(1)
			s.content_margin_left = 20
			s.content_margin_right = 20
			s.content_margin_top = 6
			s.content_margin_bottom = 6
			btn.add_stylebox_override(state, s)
		else:
			var s = StyleBoxFlat.new()
			s.bg_color = Color(0.2, 0.22, 0.26, 1.0)
			s.border_color = Color(0.6, 0.6, 0.6, 0.7) if state == "normal" else Color(0.8, 0.8, 0.8, 0.9)
			s.set_border_width_all(1)
			s.content_margin_left = 20
			s.content_margin_right = 20
			s.content_margin_top = 6
			s.content_margin_bottom = 6
			btn.add_stylebox_override(state, s)


# ═══════════════════════════════════════════════════════════════════════════
#  Anchor grid
# ═══════════════════════════════════════════════════════════════════════════

func _on_anchor_pressed(col: int, row: int) -> void:
	_anchor_x = col
	_anchor_y = row
	_update_anchor_visuals()
	if _mode == 1:
		_compute_offsets_from_target()


func _update_anchor_visuals() -> void:
	for row in range(3):
		for col in range(3):
			var idx = row * 3 + col
			var btn = _anchor_buttons[idx]
			var selected = (col == _anchor_x and row == _anchor_y)
			var color = ANCHOR_COLOR_SELECTED if selected else ANCHOR_COLOR_NORMAL
			var style = StyleBoxFlat.new()
			style.bg_color = color
			style.set_corner_radius_all(3)
			btn.add_stylebox_override("normal", style)
			var style_h = StyleBoxFlat.new()
			style_h.bg_color = ANCHOR_COLOR_SELECTED if selected else ANCHOR_COLOR_HOVER
			style_h.set_corner_radius_all(3)
			btn.add_stylebox_override("hover", style_h)


# ═══════════════════════════════════════════════════════════════════════════
#  Target Size → Offset computation
# ═══════════════════════════════════════════════════════════════════════════

func _on_target_changed(_value, which := "w_tiles") -> void:
	if _syncing_pct or _mode != 1:
		return
	_syncing_pct = true

	match which:
		"w_tiles":
			_sync_pct_from_tile("w")
			if _aspect_locked:
				_propagate_lock_tile("w")
		"h_tiles":
			_sync_pct_from_tile("h")
			if _aspect_locked:
				_propagate_lock_tile("h")
		"w_pct":
			_apply_pct_to_tile("w")
		"h_pct":
			_apply_pct_to_tile("h")

	# Mémo (utile uniquement si on réactive un mode skip plus tard)
	_last_w_pct = int(_width_pct_sb.value)
	_last_h_pct = int(_height_pct_sb.value)

	_syncing_pct = false
	_compute_offsets_from_target()


func _sync_pct_from_tile(axis: String) -> void:
	if axis == "w":
		if _orig_w > 0:
			_width_pct_sb.value = int(round(float(_width_sb.value) * 100.0 / float(_orig_w)))
	else:
		if _orig_h > 0:
			_height_pct_sb.value = int(round(float(_height_sb.value) * 100.0 / float(_orig_h)))


func _compute_locked_other(source_tiles: int, source_axis: String) -> int:
	if _locked_ratio <= 0.0:
		return source_tiles
	if source_axis == "w":
		return clamp(int(round(float(source_tiles) / _locked_ratio)), 1, 500)
	else:
		return clamp(int(round(float(source_tiles) * _locked_ratio)), 1, 500)


func _propagate_lock_tile(source_axis: String) -> void:
	if source_axis == "w":
		var new_h = _compute_locked_other(int(_width_sb.value), "w")
		_height_sb.value = new_h
		if _orig_h > 0:
			_height_pct_sb.value = int(round(float(new_h) * 100.0 / float(_orig_h)))
	else:
		var new_w = _compute_locked_other(int(_height_sb.value), "h")
		_width_sb.value = new_w
		if _orig_w > 0:
			_width_pct_sb.value = int(round(float(new_w) * 100.0 / float(_orig_w)))


func _apply_pct_to_tile(axis: String) -> void:
	# Convertit le % saisi/scrollé en tiles puis resynchronise le %.
	# Le step dynamique de la SpinBox % garantit qu'un scroll natif change déjà
	# d'environ 1 tile : pas besoin de skip-loop, ce qui élimine le bug de
	# direction inversée lié à _last_w_pct.
	var sb_pct = _width_pct_sb if axis == "w" else _height_pct_sb
	var orig = _orig_w if axis == "w" else _orig_h
	if orig <= 0:
		return

	var typed = int(sb_pct.value)
	var new_tiles = clamp(int(round(float(orig) * float(typed) / 100.0)), 1, 500)

	var new_w = int(_width_sb.value)
	var new_h = int(_height_sb.value)
	if axis == "w":
		new_w = new_tiles
		if _aspect_locked:
			new_h = _compute_locked_other(new_w, "w")
	else:
		new_h = new_tiles
		if _aspect_locked:
			new_w = _compute_locked_other(new_h, "h")

	_width_sb.value = new_w
	_height_sb.value = new_h
	if _orig_w > 0:
		_width_pct_sb.value = int(round(float(new_w) * 100.0 / float(_orig_w)))
	if _orig_h > 0:
		_height_pct_sb.value = int(round(float(new_h) * 100.0 / float(_orig_h)))


func _on_lock_toggled(pressed: bool) -> void:
	_aspect_locked = pressed
	_style_lock_button(pressed)
	if pressed:
		# Capture le ratio courant (en tiles) au moment du verrouillage.
		var w = float(_width_sb.value)
		var h = float(_height_sb.value)
		if h > 0.0:
			_locked_ratio = w / h


func _style_lock_button(active: bool) -> void:
	if _lock_btn == null:
		return
	var color = LOCK_COLOR_ACTIVE if active else LOCK_COLOR_INACTIVE
	for state in ["normal", "hover", "pressed", "focus"]:
		var style = StyleBoxFlat.new()
		if state == "hover":
			style.bg_color = Color(color.r + 0.06, color.g + 0.06, color.b + 0.06, 1.0)
		else:
			style.bg_color = color
		style.set_corner_radius_all(4)
		style.content_margin_left = 4
		style.content_margin_right = 4
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		_lock_btn.add_stylebox_override(state, style)


# ─────────────────────────────────────────────────────────────────────────────
#  Unit toggle (Tiles ↔ %)
# ─────────────────────────────────────────────────────────────────────────────

func _set_unit_mode(mode: int) -> void:
	_unit_mode = mode
	if _width_sb != null:
		_width_sb.visible = (mode == 0)
	if _height_sb != null:
		_height_sb.visible = (mode == 0)
	if _width_pct_sb != null:
		_width_pct_sb.visible = (mode == 1)
	if _height_pct_sb != null:
		_height_pct_sb.visible = (mode == 1)
	_style_mode_button(_tiles_btn, mode == 0)
	_style_mode_button(_pct_btn, mode == 1)
	_resize_dialog()


# ─────────────────────────────────────────────────────────────────────────────
#  Lock icon (deux maillons reliés, dessiné en code)
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
#  Lock icon (charge icons/link.png, fallback sur icône dessinée)
# ─────────────────────────────────────────────────────────────────────────────

func _load_lock_icon() -> Texture:
	var full_path = _g.Root + "icons/link.png"
	var image = Image.new()
	var err = image.load(full_path)
	if err == OK and image.get_width() > 0:
		# Resize a ~18px pour matcher la taille du bouton 28x28 avec marge
		var scale = 18.0 / float(max(image.get_width(), image.get_height()))
		if scale != 1.0:
			var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
			image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
		var tex = ImageTexture.new()
		tex.create_from_image(image)
		print("[MapResizeFix] Lock icon loaded: ", full_path)
		return tex
	print("[MapResizeFix] Lock icon not found at ", full_path, ", using drawn fallback")
	return _create_lock_icon()


func _create_lock_icon() -> ImageTexture:
	# Icône 16x16 : deux maillons horizontaux reliés.
	# 'X' = pixel blanc, '.' = transparent.
	var pattern = [
		"................",
		"................",
		"....XXXX..XXXX..",
		"...X....XX....X.",
		"...X....XX....X.",
		"...X..........X.",
		"...X..XXXXXX..X.",
		"...X..XXXXXX..X.",
		"...X..........X.",
		"...X....XX....X.",
		"...X....XX....X.",
		"....XXXX..XXXX..",
		"................",
		"................",
		"................",
		"................",
	]
	var img = Image.new()
	img.create(16, 16, false, Image.FORMAT_RGBA8)
	img.lock()
	for y in range(pattern.size()):
		var row = pattern[y]
		for x in range(row.length()):
			if row[x] == "X":
				img.set_pixel(x, y, Color(1, 1, 1, 1))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _compute_offsets_from_target() -> void:
	var cur_w = _g.World.Width
	var cur_h = _g.World.Height
	var target_w = int(_width_sb.value)
	var target_h = int(_height_sb.value)

	var delta_w = target_w - cur_w
	var delta_h = target_h - cur_h

	# Répartir le delta selon l'ancrage
	var left = 0
	var right = 0
	var top = 0
	var bottom = 0

	# Horizontal
	match _anchor_x:
		0:  # Ancré à gauche → tout va à droite
			right = delta_w
		1:  # Centré → réparti (extra pixel à droite)
			left = int(delta_w / 2)
			right = delta_w - left
		2:  # Ancré à droite → tout va à gauche
			left = delta_w

	# Vertical
	match _anchor_y:
		0:  # Ancré en haut → tout va en bas
			bottom = delta_h
		1:  # Centré → réparti (extra pixel en bas)
			top = int(delta_h / 2)
			bottom = delta_h - top
		2:  # Ancré en bas → tout va en haut
			top = delta_h

	# Appliquer aux spinboxes existantes (sans déclencher de boucle)
	_updating_from_target = true
	_top_sb.value = top
	_bottom_sb.value = bottom
	_left_sb.value = left
	_right_sb.value = right
	_updating_from_target = false
	_update_size_labels()
	_update_offset_labels(top, bottom, left, right)


func _update_offset_labels(top: int, bottom: int, left: int, right: int) -> void:
	_style_offset(_offset_top_label, _offset_top_arrow, top)
	_style_offset(_offset_bottom_label, _offset_bottom_arrow, bottom)
	_style_offset(_offset_left_label, _offset_left_arrow, left)
	_style_offset(_offset_right_label, _offset_right_arrow, right)

	# Retourner les flèches rouges (négatif = sens opposé au vert)
	_offset_top_arrow.flip_v = (top < 0)
	_offset_bottom_arrow.flip_v = (bottom < 0)
	_offset_left_arrow.flip_h = (left < 0)
	# Right arrow a flip_h=true par défaut (créé avec rotation 180)
	_offset_right_arrow.flip_h = (right >= 0)


func _style_offset(lbl: Label, arrow, value: int) -> void:
	if lbl == null:
		return
	var color: Color
	if value > 0:
		lbl.text = "+" + str(value)
		color = Color(0.5, 0.8, 0.5)
	elif value < 0:
		lbl.text = str(value)
		color = Color(0.9, 0.5, 0.4)
	else:
		lbl.text = "0"
		color = Color(0.5, 0.5, 0.5)
	lbl.add_color_override("font_color", color)
	if arrow != null and arrow is CanvasItem:
		arrow.modulate = color
		arrow.visible = (value != 0)


# ═══════════════════════════════════════════════════════════════════════════
#  Arrow texture helpers
# ═══════════════════════════════════════════════════════════════════════════

func _load_arrow_texture() -> void:
	for path in ["res://icons/right_arrow.png", "res://right_arrow.png", "res://ui/right_arrow.png", "res://ui/icons/right_arrow.png"]:
		if ResourceLoader.exists(path):
			_arrow_tex = ResourceLoader.load(path, "Texture")
			if _arrow_tex != null:
				print("[MapResizeFix] Arrow loaded: ", path)
				return
	print("[MapResizeFix] Arrow texture not found, using fallback")
	_arrow_tex = _create_fallback_arrow()


func _create_fallback_arrow() -> ImageTexture:
	# Petite flèche blanche 12x12 pointant vers la droite
	var img = Image.new()
	img.create(12, 12, false, Image.FORMAT_RGBA8)
	img.lock()
	for y in range(12):
		var half = min(y, 11 - y)
		for x in range(6 - half, 7):
			if x >= 0 and x < 12:
				img.set_pixel(x, y, Color(1, 1, 1, 1))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _make_arrow_rect(rotation_deg: float) -> TextureRect:
	# Crée un TextureRect avec la flèche, pivotée selon rotation_deg
	# 0=droite, 90=bas, -90=haut, 180=gauche
	var tex_rect = TextureRect.new()
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _arrow_tex != null:
		tex_rect.texture = _arrow_tex
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tex_rect.rect_min_size = Vector2(16, 16)

	if rotation_deg == 180:
		tex_rect.flip_h = true
	elif abs(rotation_deg) == 90 or abs(rotation_deg) == 270:
		# Pour les rotations verticales, créer une texture pivotée
		if _arrow_tex != null:
			var img = _arrow_tex.get_data().duplicate()
			if rotation_deg == -90 or rotation_deg == 270:
				# Haut : transpose + flip_x
				_rotate_image_ccw(img)
			else:
				# Bas : transpose + flip_y
				_rotate_image_cw(img)
			var rotated = ImageTexture.new()
			rotated.create_from_image(img, 0)
			tex_rect.texture = rotated

	return tex_rect


func _rotate_image_cw(img: Image) -> void:
	# Rotation 90° horaire : (x,y) → (h-1-y, x)
	var w = img.get_width()
	var h = img.get_height()
	var copy = img.duplicate()
	img.create(h, w, false, img.get_format())
	img.lock()
	copy.lock()
	for y in range(h):
		for x in range(w):
			img.set_pixel(h - 1 - y, x, copy.get_pixel(x, y))
	img.unlock()
	copy.unlock()


func _rotate_image_ccw(img: Image) -> void:
	# Rotation 90° anti-horaire : (x,y) → (y, w-1-x)
	var w = img.get_width()
	var h = img.get_height()
	var copy = img.duplicate()
	img.create(h, w, false, img.get_format())
	img.lock()
	copy.lock()
	for y in range(h):
		for x in range(w):
			img.set_pixel(y, w - 1 - x, copy.get_pixel(x, y))
	img.unlock()
	copy.unlock()


# ═══════════════════════════════════════════════════════════════════════════
#  Dialog events
# ═══════════════════════════════════════════════════════════════════════════

func _on_dialog_show():
	var w = _g.World.Width
	var h = _g.World.Height
	_orig_w = w
	_orig_h = h
	_left_sb.min_value = -(w - 1)
	_left_sb.max_value = 500
	_right_sb.min_value = -(w - 1)
	_right_sb.max_value = 500
	_top_sb.min_value = -(h - 1)
	_top_sb.max_value = 500
	_bottom_sb.min_value = -(h - 1)
	_bottom_sb.max_value = 500
	_top_sb.value = 0
	_bottom_sb.value = 0
	_left_sb.value = 0
	_right_sb.value = 0
	# Reset target spinboxes (sans declencher de propagation)
	_syncing_pct = true
	_width_sb.value = w
	_height_sb.value = h
	# Step dynamique : chaque scroll = ~1 tile de variation
	_width_pct_sb.step = max(1, int(round(100.0 / max(w, 1))))
	_height_pct_sb.step = max(1, int(round(100.0 / max(h, 1))))
	_width_pct_sb.value = 100
	_height_pct_sb.value = 100
	_last_w_pct = 100
	_last_h_pct = 100
	_locked_ratio = float(w) / float(h) if h > 0 else 1.0
	_syncing_pct = false
	_update_size_labels()
	_update_offset_labels(0, 0, 0, 0)
	_resize_dialog()


var _adjusting = false

func _on_spinbox_changed(_value, spinbox):
	if _adjusting or _updating_from_target:
		return
	_adjusting = true
	var w = _g.World.Width
	var h = _g.World.Height
	var new_w = w + int(_left_sb.value) + int(_right_sb.value)
	var new_h = h + int(_top_sb.value) + int(_bottom_sb.value)
	if new_w > 500:
		spinbox.value = int(spinbox.value) - (new_w - 500)
	elif new_w < 1:
		spinbox.value = int(spinbox.value) + (1 - new_w)
	if new_h > 500:
		spinbox.value = int(spinbox.value) - (new_h - 500)
	elif new_h < 1:
		spinbox.value = int(spinbox.value) + (1 - new_h)
	_adjusting = false
	_update_size_labels()


func _update_size_labels():
	var w = _g.World.Width
	var h = _g.World.Height
	var new_w = w + int(_left_sb.value) + int(_right_sb.value)
	var new_h = h + int(_top_sb.value) + int(_bottom_sb.value)
	new_w = clamp(new_w, 1, 500)
	new_h = clamp(new_h, 1, 500)
	if _current_size_label != null:
		_current_size_label.text = "%d x %d" % [w, h]
	if _resized_size_label != null:
		_resized_size_label.text = "%d x %d" % [new_w, new_h]
	if _warning_label != null:
		var should_warn = (new_w > 200 or new_h > 200)
		if _warning_label.visible != should_warn:
			_warning_label.visible = should_warn
			_resize_dialog()


func _resize_dialog() -> void:
	call_deferred("_apply_dialog_size")


func _apply_dialog_size() -> void:
	if not is_instance_valid(_dialog):
		return
	var valign = _dialog.get_node_or_null("Margins/VAlign")
	if valign == null:
		return
	var margins = _dialog.get_node_or_null("Margins")
	var pad_top = abs(margins.margin_top) if margins else 10
	var pad_bottom = abs(margins.margin_bottom) if margins else 10
	var title_h = 20
	if _dialog.has_constant("title_height", "WindowDialog"):
		title_h = _dialog.get_constant("title_height", "WindowDialog")
	var content_h = valign.get_combined_minimum_size().y
	_dialog.rect_size.y = content_h + title_h + pad_top + pad_bottom


# ═══════════════════════════════════════════════════════════════════════════
#  OK button handler (Fix 2 + Fix 3)
# ═══════════════════════════════════════════════════════════════════════════

func _on_ok_pressed():
	var left = int(_left_sb.value)
	var top = int(_top_sb.value)
	var right = int(_right_sb.value)
	var bottom = int(_bottom_sb.value)
	var fix = (left < 0 or top < 0)

	# ── Gather pre-resize data ──────────────────────────────────────────
	var lvls = []
	var sp1s = []
	var sp2s = []
	var tws = []
	var ths = []
	var cave_snaps = []
	var old_w = _g.World.Width
	var old_h = _g.World.Height

	if fix:
		var levels = _g.World.get("levels")
		if levels != null:
			for lv in levels:
				var ter = lv.get("Terrain")
				if ter != null:
					lvls.append(lv)
					sp1s.append(ter.CloneSplatImage())
					var s2 = null
					if ter.get("ExpandedSlots"):
						s2 = ter.CloneSplatImage2()
					sp2s.append(s2)
					tws.append(ter.get("width"))
					ths.append(ter.get("height"))
				var snap = _snapshot_cave(lv)
				cave_snaps.append(snap)

	# ── Call original C# resize handler ─────────────────────────────────
	print("[MapResizeFix] Calling original resize handler...")
	if _original_ok_target != null:
		_original_ok_target.call(_original_ok_method)
	print("[MapResizeFix] Original resize done, applying fixes...")

	# ── Apply fixes ─────────────────────────────────────────────────────
	if fix:
		if lvls.size() > 0:
			_fix_splats(lvls, sp1s, sp2s, tws, ths, left, top)
		_fix_caves(cave_snaps, old_w, old_h, left, top)

	# Let terrain_slots_extended remap its extended splats (3..6) the same way
	# (DD only repositions the native splat/splat2).
	if Engine.has_meta("terrain_slots_extended_singleton"):
		var _tse = Engine.get_meta("terrain_slots_extended_singleton")
		if _tse != null and is_instance_valid(_tse) and _tse.has_method("on_map_resized"):
			_tse.on_map_resized(left, top, old_w, old_h)


# ═══════════════════════════════════════════════════════════════════════════
#  Fix 3 – snapshot cave state before resize
# ═══════════════════════════════════════════════════════════════════════════

func _snapshot_cave(lv) -> Dictionary:
	var result = {"level": lv, "has_cave": false}
	var cave = lv.get("CaveMesh")
	if cave == null:
		return result
	result["has_cave"] = true

	var ebm = cave.get("entranceBitmap")
	if ebm != null and ebm is BitMap:
		var sz = ebm.get_size()
		if sz.x > 0 and sz.y > 0:
			var clone = ebm.duplicate()
			if clone != null:
				result["entrance_bm"] = clone
				result["entrance_sz"] = sz
				print("[MapResizeFix] Snapshot entrance bitmap (%dx%d)" % [int(sz.x), int(sz.y)])

	var grid_prop = _probe_grid_bitmap(cave)
	if grid_prop != "":
		var val = cave.get(grid_prop)
		if val != null:
			var sz = val.get_size()
			if sz.x > 0 and sz.y > 0:
				var clone = val.duplicate()
				if clone != null:
					result["grid_bm"] = clone
					result["grid_sz"] = sz
					result["grid_prop"] = grid_prop
					print("[MapResizeFix] Snapshot cave grid '%s' (%dx%d)" % [grid_prop, int(sz.x), int(sz.y)])

	print("[MapResizeFix] Cave snapshot complete")
	return result


func _probe_grid_bitmap(cave) -> String:
	for prop in ["bitmap", "Bitmap", "cells", "Cells", "grid", "Grid"]:
		var val = cave.get(prop)
		if val != null and val is BitMap:
			return prop
	return ""


# ═══════════════════════════════════════════════════════════════════════════
#  Fix 2 – Terrain splat blit
# ═══════════════════════════════════════════════════════════════════════════

func _fix_splats(lvls, sp1s, sp2s, tws, ths, left, top):
	var zero = Vector2(0, 0)
	var cw = _g.World.Width
	var ch = _g.World.Height
	var i = 0
	while i < lvls.size():
		var ter = lvls[i].get("Terrain")
		if ter == null:
			i += 1
			continue
		var ntw = ter.get("width")
		var nth = ter.get("height")
		var otw = tws[i]
		var oth = ths[i]
		if otw == 0 or oth == 0 or ntw == 0 or nth == 0:
			i += 1
			continue
		var omw = float(otw) * float(cw) / float(ntw)
		var omh = float(oth) * float(ch) / float(nth)
		var px = float(otw) / omw
		var py = float(oth) / omh
		var sx = 0
		if left < 0:
			sx = int(round(abs(left) * px))
		var sy = 0
		if top < 0:
			sy = int(round(abs(top) * py))
		var sr = Rect2(sx, sy, ntw, nth)
		var f1 = Image.new()
		f1.create(ntw, nth, false, sp1s[i].get_format())
		f1.blit_rect(sp1s[i], sr, zero)
		var s2ok = false
		if sp2s[i] != null:
			if sp2s[i].get_width() > 0:
				s2ok = true
		if s2ok:
			var f2 = Image.new()
			f2.create(ntw, nth, false, sp2s[i].get_format())
			f2.blit_rect(sp2s[i], sr, zero)
			ter.RestoreSplat2(f1, f2)
		else:
			ter.RestoreSplat(f1)
		ter.UpdateSplat()
		i += 1


# ═══════════════════════════════════════════════════════════════════════════
#  Fix 3 – Cave bitmap restoration + wall regeneration
# ═══════════════════════════════════════════════════════════════════════════

func _fix_caves(cave_snaps, old_w, old_h, left, top):
	var new_w = _g.World.Width
	var new_h = _g.World.Height

	for snap in cave_snaps:
		if not snap["has_cave"]:
			continue
		var lv = snap["level"]
		var cave = lv.get("CaveMesh")
		if cave == null:
			continue

		var something_fixed = false

		if snap.has("entrance_bm"):
			var ok = _restore_bitmap_with_offset(
				snap["entrance_bm"], snap["entrance_sz"],
				cave, "entranceBitmap", "SetEntranceBitmap",
				old_w, old_h, new_w, new_h, left, top
			)
			if ok:
				print("[MapResizeFix] Restored entrance bitmap")
				something_fixed = true

		if snap.has("grid_bm"):
			var prop = snap["grid_prop"]
			var ok = _restore_grid_with_offset(
				snap["grid_bm"], snap["grid_sz"],
				cave, prop,
				old_w, old_h, new_w, new_h, left, top
			)
			if ok:
				print("[MapResizeFix] Restored cave grid '%s'" % prop)
				something_fixed = true

		if something_fixed:
			print("[MapResizeFix] Regenerating cave mesh + walls...")
			cave.FinalizeMeshAndBorders()
			_reclip_cave_walls(lv, cave)
			print("[MapResizeFix] Cave fix complete")
		else:
			_fallback_offset_walls(cave, left, top)


func _restore_bitmap_with_offset(old_bm, old_sz, cave, get_prop, set_method, old_w, old_h, new_w, new_h, left, top) -> bool:
	var ppx = old_sz.x / float(old_w)
	var ppy = old_sz.y / float(old_h)
	var ox = int(round(abs(left) * ppx)) if left < 0 else 0
	var oy = int(round(abs(top) * ppy)) if top < 0 else 0
	if ox == 0 and oy == 0:
		return false

	var new_bw = int(round(new_w * ppx))
	var new_bh = int(round(new_h * ppy))
	var cur = cave.get(get_prop)
	if cur != null and cur is BitMap:
		var csz = cur.get_size()
		if csz.x > 0 and csz.y > 0:
			new_bw = int(csz.x)
			new_bh = int(csz.y)

	var fixed = BitMap.new()
	fixed.create(Vector2(new_bw, new_bh))
	_blit_bitmap(old_bm, fixed, ox, oy, new_bw, new_bh)

	if cave.has_method(set_method):
		cave.call(set_method, fixed)
		return true
	return false


func _restore_grid_with_offset(old_bm, old_sz, cave, prop, old_w, old_h, new_w, new_h, left, top) -> bool:
	var ppx = old_sz.x / float(old_w)
	var ppy = old_sz.y / float(old_h)
	var ox = int(round(abs(left) * ppx)) if left < 0 else 0
	var oy = int(round(abs(top) * ppy)) if top < 0 else 0
	if ox == 0 and oy == 0:
		return false

	var cur = cave.get(prop)
	if cur == null or not (cur is BitMap):
		return false
	var csz = cur.get_size()
	var new_bw = int(csz.x)
	var new_bh = int(csz.y)
	if new_bw <= 0 or new_bh <= 0:
		return false

	var fixed = BitMap.new()
	fixed.create(Vector2(new_bw, new_bh))
	_blit_bitmap(old_bm, fixed, ox, oy, new_bw, new_bh)

	cave.set(prop, fixed)
	var verify = cave.get(prop)
	if verify == fixed:
		return true
	print("[MapResizeFix] Grid '%s' is read-only, will use fallback" % prop)
	return false


func _reclip_cave_walls(lv, cave):
	var dungeon_walls = lv.get("Walls")
	var has_manual = false
	if dungeon_walls != null:
		var children = dungeon_walls.get_children()
		if children != null:
			for w in children:
				var wtype = w.get("Type")
				if wtype != null and int(wtype) != 2:
					has_manual = true
					break
	if has_manual:
		cave.FullClipWalls()
		print("[MapResizeFix]   -> FullClipWalls")
	else:
		cave.SimpleClipWalls()
		print("[MapResizeFix]   -> SimpleClipWalls")


func _fallback_offset_walls(cave, left, top):
	var cell = _g.WorldUI.CellSize
	var offset = Vector2(0, 0)
	if left < 0:
		offset.x = left * cell.x
	if top < 0:
		offset.y = top * cell.y
	if offset == Vector2(0, 0):
		return
	var walls = cave.get("Walls")
	if walls == null:
		print("[MapResizeFix] Fallback: no cave walls found")
		return
	var count = 0
	for w in walls:
		if w != null and w.has_method("Offset"):
			w.Offset(offset)
			count += 1
	print("[MapResizeFix] Fallback: offset %d cave walls by (%d,%d)" % [count, int(offset.x), int(offset.y)])


# ═══════════════════════════════════════════════════════════════════════════
#  BitMap helper
# ═══════════════════════════════════════════════════════════════════════════

func _blit_bitmap(src: BitMap, dst: BitMap, ox: int, oy: int, dw: int, dh: int):
	"""Copy set bits from src at offset (ox, oy) into dst of size dw x dh."""
	var sw = int(src.get_size().x)
	var sh = int(src.get_size().y)
	for y in range(dh):
		var sy = y + oy
		if sy < 0 or sy >= sh:
			continue
		for x in range(dw):
			var sx = x + ox
			if sx < 0 or sx >= sw:
				continue
			if src.get_bit(Vector2(sx, sy)):
				dst.set_bit(Vector2(x, y), true)
