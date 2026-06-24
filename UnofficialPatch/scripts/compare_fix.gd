# compare_fix.gd
# Fix: CompareLevelsWindow keeps stale Level references after opening a new map.
# Solution: Bypass ALL C# compare code. We manage level visibility/modulate
# ourselves using fresh Level node references from get_AllLevels().
# v3: Multi-level compare, link sliders, remember settings, outline buttons.
# v4: Force z_index on reference levels so their terrain renders above the
#     current level's terrain, regardless of level order in the list.
# v5: Ignore C shortcut when a text input (LineEdit/TextEdit) has focus.
# v6: Also ignore C when DD's TextTool is active (custom Text nodes don't
#     register through get_focus_owner()).
# v7: Also ignore C during inline text edit in SelectTool (state published by
#     text_transform via Engine.set_meta("_inline_text_editing", ...)).
# v8: Skip C shortcut when modifier keys are held (Ctrl+C copy, etc.).
# v9: Reorder ref levels to end of World children via move_child, so that
#     same-layer assets (which use absolute z_index) render with ref above
#     current. Original tree order is restored on disable.
# v14: Each ref Level gets its own z range (base 1100, step adaptive ≤1100),
#      assigned in reverse iteration order so higher levels in the list get
#      higher z. DD's sub-containers are z_as_relative=true so they inherit
#      via the chain. Godot 3 caps z_index at 4096, which limits stacking
#      precision when comparing many ref levels with high internal layers.
# v15: Current level is now also z-stacked along with refs, so its position
#      in the level list is respected (e.g. a ref level below current in
#      the list correctly renders below current).
# v16: Use full [-4096, 4096] z range (instead of [0, 4096]) by stacking
#      levels around z=0. Doubles the budget — fits ~6 levels at step=1100
#      vs ~3 before. Step still shrinks for very high level counts.
# v17: Window size derived from content min size (get_combined_minimum_size)
#      instead of fixed px, so it follows DD's UI scaling (4K/hiDPI no longer
#      truncates content). Fixed constants kept only as a floor.

var _g
var _ct = null
var _compare_win = null
var _frame = 0
var _ready = false
var _comparing = false
var _saved_child_indices = {}   # {Level: original_index_in_parent}
var _saved_z_indices = {}        # {Level: original_z_index}

# Original DD controls (hidden, kept for structure)
var _orig_ref_options = null
var _orig_ref_slider = null
var _orig_cur_slider = null

# Our UI
var _margin = null
var _content_vbox = null
var _cur_label = null
var _cur_slider = null
var _cur_val = null
var _rows_container = null
var _ref_rows = []             # [{level, dropdown, slider, val_label, remove_btn, hbox}]
var _add_btn = null
var _all_btn = null
var _remove_all_btn = null
var _link_btn = null
var _btn_hbox = null
var _ok_btn = null
var _cancel_btn = null
var _input_listener = null

var _link_active := true
var _updating_linked := false  # prevent feedback loop when syncing sliders

# Saved state: persists across open/close of the compare window
# {cur_opacity: float, refs: [{level_idx: int, opacity: float}], link: bool}
var _saved_state = null

const ROW_HEIGHT = 32
const BASE_HEIGHT = 228
const WIN_WIDTH = 400
const MARGIN_PX = 16

var _last_world_id := -1


func initialize():
	print("[CompareFix] initialized")


func _on_map_changed() -> void:
	# DD recrée le World et les Windows à chaque ouverture de map. Toutes nos
	# refs (_ct, _compare_win, notre UI custom, _input_listener) sont freed.
	# Reset pour relancer le build complet.
	print("[CompareFix] World changed → reset")
	_ready = false
	_frame = 0
	_comparing = false
	_ct = null
	_compare_win = null
	_orig_ref_options = null
	_orig_ref_slider = null
	_orig_cur_slider = null
	_margin = null
	_content_vbox = null
	_cur_label = null
	_cur_slider = null
	_cur_val = null
	_rows_container = null
	_ref_rows.clear()
	_add_btn = null
	_all_btn = null
	_remove_all_btn = null
	_link_btn = null
	_btn_hbox = null
	_ok_btn = null
	_cancel_btn = null
	_input_listener = null
	# Les level indices changent entre maps, l'ancien saved_state est obsolète.
	_saved_state = null


func update(delta):
	# Détection changement de map (convention partagée avec drop_embed/popup_blur).
	if _g != null and _g.World != null and is_instance_valid(_g.World):
		var wid = _g.World.get_instance_id()
		if wid != _last_world_id:
			if _last_world_id != -1:
				_on_map_changed()
			_last_world_id = wid

	# Watchdog (fallback) : si la détection via World ID rate, on détecte
	# directement que _compare_win a été freed (DD a recréé la popup).
	if _ready and (_compare_win == null or not is_instance_valid(_compare_win)):
		print("[CompareFix] _compare_win invalide → reset")
		_on_map_changed()

	if _ready:
		return
	_frame += 1
	if _frame < 10 or _frame % 10 != 0:
		return
	if _ct == null:
		_ct = _g.Editor.CompareToggle
	if _ct == null:
		return
	if _compare_win == null:
		var windows = _g.Editor.Windows
		if windows != null and windows is Dictionary and windows.has("CompareLevels"):
			_compare_win = windows["CompareLevels"]
	if _compare_win == null:
		return
	_orig_ref_options = _compare_win.get("referenceLevel")
	if _orig_ref_options == null:
		return
	_orig_ref_slider = _compare_win.get("referenceOpacitySlider")
	_orig_cur_slider = _compare_win.get("currentOpacitySlider")
	_ready = true
	_disconnect_dd_signals()
	_ct.connect("toggled", self, "_on_compare_toggled")
	_build_ui()
	_setup_input_listener()
	print("[CompareFix] Ready (multi-level)")


# ══ Disconnect DD's original handlers ═════════════════════════════════════════

func _disconnect_dd_signals():
	var conns = _ct.get_signal_connection_list("toggled")
	for c in conns:
		if str(c["method"]) == "_on_CompareToggle_toggled":
			_ct.disconnect("toggled", c["target"], c["method"])
			break
	var win_conns = _compare_win.get_signal_connection_list("about_to_show")
	for c in win_conns:
		if str(c["method"]) == "AboutToShow":
			_compare_win.disconnect("about_to_show", c["target"], c["method"])
			break
	if _orig_ref_slider != null:
		var sc = _orig_ref_slider.get_signal_connection_list("value_changed")
		for c in sc:
			if str(c["method"]).find("Reference") >= 0:
				_orig_ref_slider.disconnect("value_changed", c["target"], c["method"])
				break
	if _orig_cur_slider != null:
		var sc = _orig_cur_slider.get_signal_connection_list("value_changed")
		for c in sc:
			if str(c["method"]).find("Current") >= 0:
				_orig_cur_slider.disconnect("value_changed", c["target"], c["method"])
				break
	if _orig_ref_options != null:
		var rc = _orig_ref_options.get_signal_connection_list("item_selected")
		for c in rc:
			if str(c["method"]).find("Reference") >= 0:
				_orig_ref_options.disconnect("item_selected", c["target"], c["method"])
				break


# ══ Input listener (C key to close) ══════════════════════════════════════════

func _setup_input_listener():
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "CompareFixListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	_g.World.call_deferred("add_child", _input_listener)


func _is_text_input_focused() -> bool:
	# Standard Godot text controls (rename dialogs, SpinBox, etc.)
	if _ct != null and is_instance_valid(_ct):
		var focus = _ct.get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return true
	# DD's TextTool uses custom Text nodes (not LineEdit/TextEdit), so
	# get_focus_owner() misses it. Detect via the active tool name instead.
	if _g != null and _g.Editor != null:
		if str(_g.Editor.ActiveToolName) == "TextTool":
			return true
	# Inline text edit in SelectTool (text_transform mod). State is published
	# via Engine meta to keep mods decoupled.
	if Engine.has_meta("_inline_text_editing") and Engine.get_meta("_inline_text_editing"):
		return true
	return false


func _on_input(event: InputEvent):
	# C key: toggle compare mode on/off
	if event is InputEventKey and event.pressed and not event.echo and event.scancode == KEY_C:
		# Skip modifier combos (Ctrl+C copy, Shift+C, Alt+C, Cmd+C on Mac).
		if event.control or event.shift or event.alt or event.meta:
			return
		# Don't intercept C when a text input has focus (Text tool, rename
		# dialogs, etc.). _input runs before GUI propagation so we have to
		# check focus ourselves.
		if _is_text_input_focused():
			return
		if _comparing:
			# Turn off compare
			_save_state()
			_disable_compare()
			_ct.pressed = false
			_compare_win.hide()
			_g.World.get_tree().set_input_as_handled()
		# If not comparing, don't consume — let DD handle C to toggle on
		return

	# Mouse click on the compare toggle button while popup is modal
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_LEFT:
		if not _comparing or not _compare_win.visible:
			return
		if _ct == null or not is_instance_valid(_ct):
			return
		var btn_rect = _ct.get_global_rect()
		var mouse = event.global_position
		if btn_rect.has_point(mouse):
			# Turn off compare
			_save_state()
			_disable_compare()
			_ct.pressed = false
			_compare_win.hide()
			_g.World.get_tree().set_input_as_handled()


# ══ Build our UI inside the DD popup ══════════════════════════════════════════

func _build_ui():
	for child in _compare_win.get_children():
		if child is Control:
			# Préserver les rects ajoutés par popup_blur (meta _no_blur).
			# Sans ce skip, ils sont cachés et le blur disparaît derrière la fenêtre.
			if child.has_meta("_no_blur"):
				continue
			child.visible = false

	_margin = MarginContainer.new()
	_margin.name = "CompareFixMargin"
	_margin.set("custom_constants/margin_left", MARGIN_PX)
	_margin.set("custom_constants/margin_right", MARGIN_PX)
	_margin.set("custom_constants/margin_top", MARGIN_PX)
	_margin.set("custom_constants/margin_bottom", MARGIN_PX)
	_margin.anchor_right = 1.0
	_margin.anchor_bottom = 1.0
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_content_vbox = VBoxContainer.new()
	_content_vbox.name = "CompareFixContent"
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_vbox.set("custom_constants/separation", 6)
	_margin.add_child(_content_vbox)

	# ── Current level ─────────────────────────────────────────────────────
	_cur_label = Label.new()
	_cur_label.text = "Current Level"
	_cur_label.align = Label.ALIGN_CENTER
	_content_vbox.add_child(_cur_label)

	var cur_hbox = HBoxContainer.new()
	cur_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cur_hbox.set("custom_constants/separation", 8)

	var cur_slider_label = Label.new()
	cur_slider_label.text = "Opacity"
	cur_hbox.add_child(cur_slider_label)

	_cur_slider = HSlider.new()
	_cur_slider.min_value = 0
	_cur_slider.max_value = 100
	_cur_slider.step = 1
	_cur_slider.value = 100
	_cur_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cur_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cur_slider.connect("value_changed", self, "_on_cur_slider_changed")
	cur_hbox.add_child(_cur_slider)

	_cur_val = Label.new()
	_cur_val.text = "100%"
	_cur_val.rect_min_size = Vector2(42, 0)
	_cur_val.align = Label.ALIGN_RIGHT
	cur_hbox.add_child(_cur_val)

	_content_vbox.add_child(cur_hbox)

	# ── Separator ─────────────────────────────────────────────────────────
	_content_vbox.add_child(HSeparator.new())

	var ref_label = Label.new()
	ref_label.text = "Reference Levels"
	ref_label.align = Label.ALIGN_CENTER
	_content_vbox.add_child(ref_label)

	# ── Ref rows container ────────────────────────────────────────────────
	_rows_container = VBoxContainer.new()
	_rows_container.name = "RefRows"
	_rows_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_container.set("custom_constants/separation", 4)
	_content_vbox.add_child(_rows_container)

	# ── Action buttons row ────────────────────────────────────────────────
	_btn_hbox = HBoxContainer.new()
	_btn_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_hbox.set("custom_constants/separation", 6)

	_add_btn = Button.new()
	_add_btn.text = "+ Add"
	_add_btn.connect("pressed", self, "_on_add_pressed")
	_btn_hbox.add_child(_add_btn)

	_all_btn = Button.new()
	_all_btn.text = "All Levels"
	_all_btn.connect("pressed", self, "_on_all_pressed")
	_btn_hbox.add_child(_all_btn)

	_remove_all_btn = Button.new()
	_remove_all_btn.text = "Remove All"
	_remove_all_btn.connect("pressed", self, "_on_remove_all_pressed")
	_btn_hbox.add_child(_remove_all_btn)

	# Spacer to push link button right
	var btn_spacer = Control.new()
	btn_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_hbox.add_child(btn_spacer)

	_link_btn = Button.new()
	_link_btn.text = "Link Sliders"
	_link_btn.toggle_mode = true
	_link_btn.pressed = true
	_link_btn.connect("toggled", self, "_on_link_toggled")
	_btn_hbox.add_child(_link_btn)

	_content_vbox.add_child(_btn_hbox)

	# ── OK / Cancel ───────────────────────────────────────────────────────
	_content_vbox.add_child(HSeparator.new())

	var ok_cancel_hbox = HBoxContainer.new()
	ok_cancel_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_cancel_hbox.alignment = BoxContainer.ALIGN_CENTER
	ok_cancel_hbox.set("custom_constants/separation", 12)

	_ok_btn = _make_outlined_button("OK", 80)
	_ok_btn.connect("pressed", self, "_on_ok_pressed")
	ok_cancel_hbox.add_child(_ok_btn)

	_cancel_btn = _make_outlined_button("Cancel", 80)
	_cancel_btn.connect("pressed", self, "_on_cancel_pressed")
	ok_cancel_hbox.add_child(_cancel_btn)

	_content_vbox.add_child(ok_cancel_hbox)

	_compare_win.add_child(_margin)
	_compare_win.rect_min_size = Vector2(WIN_WIDTH, BASE_HEIGHT)

	# Forcer le blur sur cette fenêtre via popup_blur (le compare popup n'est
	# pas dans Master/Editor/Windows children, donc fast_scan ne le patche pas).
	# register() est idempotent : si déjà patché par fast_scan, ne fait rien.
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and pb.has_method("register"):
			pb.register(_compare_win)


func _make_outlined_button(text: String, min_w: float) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.rect_min_size = Vector2(min_w, 0)
	# Style is applied deferred so the theme stylebox exists to duplicate
	_g.World.get_tree().create_timer(0.1).connect("timeout", self, "_style_button", [btn])
	return btn


func _style_button(btn: Button) -> void:
	if not is_instance_valid(btn):
		return
	var existing = btn.get_stylebox("normal")
	if existing != null and existing is StyleBoxFlat:
		var style = existing.duplicate()
		style.border_color = Color(0.6, 0.6, 0.6, 0.7)
		style.set_border_width_all(1)
		style.content_margin_left = 20
		style.content_margin_right = 20
		btn.add_stylebox_override("normal", style)


# ══ Window sizing ═════════════════════════════════════════════════════════════

func _resize_window():
	# Taille basée sur le contenu réel (et non sur des px fixes) pour suivre le
	# scaling UI de DD : en 4K/hiDPI, polices et contrôles grossissent, donc une
	# taille codée en dur déborde. get_combined_minimum_size() inclut déjà les
	# marges du MarginContainer et la hauteur des rows. Les constantes WIN_WIDTH/
	# BASE_HEIGHT ne servent plus que de plancher en résolution standard.
	# Déféré : laisser le layout recalculer les min sizes après ajout/retrait.
	call_deferred("_apply_content_size")


func _apply_content_size():
	if _margin == null or not is_instance_valid(_margin):
		return
	if _compare_win == null or not is_instance_valid(_compare_win):
		return
	var min_size = _margin.get_combined_minimum_size()
	var w = max(WIN_WIDTH, min_size.x)
	var h = max(BASE_HEIGHT, min_size.y) + 8  # petit tampon
	_compare_win.rect_min_size = Vector2(w, h)
	_compare_win.rect_size = Vector2(w, h)


# ══ Toggle ════════════════════════════════════════════════════════════════════

func _on_compare_toggled(pressed):
	var world = _g.World
	if world == null:
		return
	if pressed:
		var all_levels = world.get_AllLevels()
		if all_levels == null or all_levels.size() < 2:
			_ct.pressed = false
			return
		_comparing = true
		_clear_all_rows()
		_update_current_label()
		if _saved_state != null:
			_restore_state()
		else:
			var current = world.Level
			for lvl in all_levels:
				if lvl != current:
					_add_ref_row(lvl)
					break
		_apply_compare()
		_apply_content_size()  # synchrone : taille correcte avant popup_centered
		if _saved_state != null and _saved_state.has("win_pos"):
			_compare_win.popup()
			_compare_win.rect_position = _saved_state["win_pos"]
		else:
			_compare_win.popup_centered()
	else:
		# Toggle off: save and disable
		_save_state()
		_disable_compare()
		_compare_win.hide()


func _update_current_label():
	if _cur_label == null:
		return
	var current = _g.World.Level
	var name = ""
	if current != null:
		name = str(current.Label)
		if name == "" or name == "Null":
			var all_levels = _g.World.get_AllLevels()
			if all_levels != null:
				for i in range(all_levels.size()):
					if all_levels[i] == current:
						name = "Level " + str(i)
						break
	if name != "":
		_cur_label.text = "Current Level (" + name + ")"
	else:
		_cur_label.text = "Current Level"


# ══ Save / Restore state ═════════════════════════════════════════════════════

func _save_state():
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return
	var refs = []
	for row in _ref_rows:
		var idx = row.dropdown.get_selected_id()
		refs.append({"level_idx": idx, "opacity": row.slider.value})
	_saved_state = {
		"cur_opacity": _cur_slider.value,
		"refs": refs,
		"link": _link_active,
		"win_pos": _compare_win.rect_position,
	}


func _restore_state():
	if _saved_state == null:
		return
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return
	var current = _g.World.Level
	_cur_slider.value = _saved_state.get("cur_opacity", 100)
	_link_active = _saved_state.get("link", true)
	if _link_btn != null:
		_link_btn.pressed = _link_active
	var refs = _saved_state.get("refs", [])
	for ref in refs:
		var idx = ref.get("level_idx", -1)
		if idx < 0 or idx >= all_levels.size():
			continue
		var lvl = all_levels[idx]
		if lvl == current:
			continue
		var row = _add_ref_row(lvl)
		if row.has("slider"):
			row.slider.value = ref.get("opacity", 50)


# ══ Level name helper ═════════════════════════════════════════════════════════

func _get_level_name(lvl, index: int) -> String:
	var label = str(lvl.Label)
	if label == "" or label == "Null":
		return "Level " + str(index)
	return label


# ══ Ref level rows ════════════════════════════════════════════════════════════

func _add_ref_row(level) -> Dictionary:
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return {}
	var current = _g.World.Level

	var hbox = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.set("custom_constants/separation", 6)

	# Dropdown — exclude current level
	var dropdown = OptionButton.new()
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dropdown.rect_min_size = Vector2(120, 0)
	var selected_idx = 0
	var item_count = 0
	for i in range(all_levels.size()):
		if all_levels[i] == current:
			continue
		var label = _get_level_name(all_levels[i], i)
		dropdown.add_item(label, i)
		if all_levels[i] == level:
			selected_idx = item_count
		item_count += 1
	dropdown.select(selected_idx)
	hbox.add_child(dropdown)

	# Slider
	var slider = HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = 50
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.rect_min_size = Vector2(80, 0)
	hbox.add_child(slider)

	# Value label
	var val_label = Label.new()
	val_label.text = "50%"
	val_label.rect_min_size = Vector2(42, 0)
	val_label.align = Label.ALIGN_RIGHT
	hbox.add_child(val_label)

	# Remove button
	var remove_btn = Button.new()
	remove_btn.text = "×"
	remove_btn.rect_min_size = Vector2(28, 0)
	hbox.add_child(remove_btn)

	var row = {
		"level": level,
		"dropdown": dropdown,
		"slider": slider,
		"val_label": val_label,
		"remove_btn": remove_btn,
		"hbox": hbox,
	}

	var row_idx = _ref_rows.size()
	dropdown.connect("item_selected", self, "_on_ref_dropdown_changed", [row_idx])
	slider.connect("value_changed", self, "_on_ref_slider_changed", [row_idx])
	remove_btn.connect("pressed", self, "_on_remove_pressed", [row_idx])

	_ref_rows.append(row)
	_rows_container.add_child(hbox)

	_update_add_btn_state()
	_resize_window()
	return row


func _remove_ref_row(row_idx: int):
	if row_idx < 0 or row_idx >= _ref_rows.size():
		return
	var row = _ref_rows[row_idx]
	if row.hbox != null and is_instance_valid(row.hbox):
		row.hbox.queue_free()
	_ref_rows.remove(row_idx)
	_reconnect_row_signals()
	_apply_compare()
	_update_add_btn_state()
	_resize_window()


func _clear_all_rows():
	for row in _ref_rows:
		if row.hbox != null and is_instance_valid(row.hbox):
			row.hbox.queue_free()
	_ref_rows.clear()
	_update_add_btn_state()


func _reconnect_row_signals():
	for i in range(_ref_rows.size()):
		var row = _ref_rows[i]
		if row.dropdown.is_connected("item_selected", self, "_on_ref_dropdown_changed"):
			row.dropdown.disconnect("item_selected", self, "_on_ref_dropdown_changed")
		if row.slider.is_connected("value_changed", self, "_on_ref_slider_changed"):
			row.slider.disconnect("value_changed", self, "_on_ref_slider_changed")
		if row.remove_btn.is_connected("pressed", self, "_on_remove_pressed"):
			row.remove_btn.disconnect("pressed", self, "_on_remove_pressed")
		row.dropdown.connect("item_selected", self, "_on_ref_dropdown_changed", [i])
		row.slider.connect("value_changed", self, "_on_ref_slider_changed", [i])
		row.remove_btn.connect("pressed", self, "_on_remove_pressed", [i])


func _update_add_btn_state():
	if _add_btn == null:
		return
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return
	var used = _get_ref_levels_set()
	var current = _g.World.Level
	var available = 0
	for lvl in all_levels:
		if lvl != current and not used.has(lvl):
			available += 1
	_add_btn.disabled = (available == 0)
	_all_btn.disabled = (available == 0)
	_remove_all_btn.disabled = (_ref_rows.size() == 0)
	# Linking only makes sense with 2+ ref sliders to sync.
	if _link_btn != null:
		_link_btn.disabled = (_ref_rows.size() <= 1)


func _get_ref_levels_set() -> Dictionary:
	var s = {}
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return s
	for row in _ref_rows:
		var idx = row.dropdown.get_selected_id()
		if idx >= 0 and idx < all_levels.size():
			s[all_levels[idx]] = true
	return s


# ══ Signal handlers ═══════════════════════════════════════════════════════════

func _on_ref_dropdown_changed(item_idx: int, row_idx: int):
	if row_idx < 0 or row_idx >= _ref_rows.size():
		return
	var real_idx = _ref_rows[row_idx].dropdown.get_selected_id()
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null or real_idx < 0 or real_idx >= all_levels.size():
		return
	_ref_rows[row_idx].level = all_levels[real_idx]
	if _comparing:
		_apply_compare()
	_update_add_btn_state()


func _on_ref_slider_changed(value: float, row_idx: int):
	if row_idx >= 0 and row_idx < _ref_rows.size():
		_ref_rows[row_idx].val_label.text = str(int(value)) + "%"
	# Linked mode: sync all other ref sliders
	if _link_active and not _updating_linked:
		_updating_linked = true
		for i in range(_ref_rows.size()):
			if i != row_idx:
				_ref_rows[i].slider.value = value
				_ref_rows[i].val_label.text = str(int(value)) + "%"
		_updating_linked = false
	if _comparing:
		_apply_compare()


func _on_cur_slider_changed(value: float):
	if _cur_val != null:
		_cur_val.text = str(int(value)) + "%"
	if _comparing:
		_apply_compare()


func _on_remove_pressed(row_idx: int):
	_remove_ref_row(row_idx)


func _on_add_pressed():
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return
	var current = _g.World.Level
	var used = _get_ref_levels_set()
	for lvl in all_levels:
		if lvl != current and not used.has(lvl):
			_add_ref_row(lvl)
			if _comparing:
				_apply_compare()
			return


func _on_all_pressed():
	var all_levels = _g.World.get_AllLevels()
	if all_levels == null:
		return
	var current = _g.World.Level
	var used = _get_ref_levels_set()
	for lvl in all_levels:
		if lvl != current and not used.has(lvl):
			_add_ref_row(lvl)
	if _comparing:
		_apply_compare()


func _on_remove_all_pressed():
	_clear_all_rows()
	_resize_window()
	if _comparing:
		_apply_compare()


func _on_link_toggled(pressed: bool):
	_link_active = pressed


func _on_ok_pressed():
	_save_state()
	_compare_win.hide()
	# Keep _comparing = true, keep _ct.pressed = true


func _on_cancel_pressed():
	_save_state()
	_disable_compare()
	_ct.pressed = false
	_compare_win.hide()


# ══ Apply compare ═════════════════════════════════════════════════════════════

func _apply_compare():
	var world = _g.World
	if world == null:
		return
	var current = world.Level
	var all_levels = world.get_AllLevels()
	if all_levels == null:
		return

	var cur_opacity = _cur_slider.value / 100.0

	var ref_map = {}
	for row in _ref_rows:
		var idx = row.dropdown.get_selected_id()
		if idx >= 0 and idx < all_levels.size():
			ref_map[all_levels[idx]] = row.slider.value / 100.0

	# DD uses absolute z_index on layer containers (Walls=600, Portals=500,
	# Objects~100, etc., max ~1000). Godot 3 clamps z_index at 4096. So we
	# bump each ref level by 3000 (giving 3000+1000=4000 < 4096 headroom).
	# Multiple ref levels are stacked via tree order (move_child below)
	# rather than progressive offsets, to avoid hitting the clamp.
	# Use the full Godot 3 z_index range [-4096, 4096] to maximize headroom.
	# We reserve 1000 on each side for DD's internal layer values (max ~1000),
	# giving us a usable span of [-3000, 3000] = 6000 (vs 2996 before).
	# That fits ~6-7 levels cleanly at step=1100; beyond that step shrinks.
	var n_visible = 1 + ref_map.size()
	var z_top = 3000
	var z_bot = -3000
	var step = 1100
	if n_visible > 1:
		var max_step = int((z_top - z_bot) / (n_visible - 1))
		if max_step < step:
			step = max_step

	_saved_child_indices.clear()
	_saved_z_indices.clear()

	# Iterate all_levels (top-to-bottom in the list). idx counts visible
	# levels as we encounter them; the first visible gets the highest z.
	var idx = 0
	for lvl in all_levels:
		if not is_instance_valid(lvl):
			continue
		if lvl == current or ref_map.has(lvl):
			lvl.visible = true
			if lvl == current:
				lvl.modulate = Color(1, 1, 1, cur_opacity)
			else:
				lvl.modulate = Color(1, 1, 1, ref_map[lvl])
			# DD's sub-containers are z_as_relative=true so they inherit via
			# the chain. z descends from z_top by step per visible level.
			_saved_z_indices[lvl] = lvl.z_index
			var z = z_top - idx * step
			# Safety clamp — shouldn't trigger given step calculation above.
			if z > 4096:
				z = 4096
			elif z < -4096:
				z = -4096
			lvl.z_index = z
			idx += 1
			# Tree-order fallback for the few absolute UI overlays.
			var parent = lvl.get_parent()
			if parent != null:
				_saved_child_indices[lvl] = lvl.get_index()
				parent.move_child(lvl, parent.get_child_count() - 1)
		else:
			lvl.visible = false


# ══ Disable compare ═══════════════════════════════════════════════════════════

func _disable_compare():
	_comparing = false
	var world = _g.World
	if world == null:
		return
	var current = world.Level
	var all_levels = world.get_AllLevels()
	if all_levels == null:
		return
	# Restore z_index on every node we bumped.
	for n in _saved_z_indices.keys():
		if is_instance_valid(n):
			n.z_index = _saved_z_indices[n]
	_saved_z_indices.clear()

	# Restore original tree order. Sort by saved index ascending so that
	# each move_child places the node at the right slot regardless of
	# intermediate states.
	var entries = []
	for lvl in _saved_child_indices.keys():
		entries.append([lvl, _saved_child_indices[lvl]])
	entries.sort_custom(self, "_cmp_saved_idx")
	for entry in entries:
		var lvl = entry[0]
		var orig_idx = entry[1]
		if is_instance_valid(lvl) and lvl.get_parent() != null:
			lvl.get_parent().move_child(lvl, orig_idx)
	_saved_child_indices.clear()

	for lvl in all_levels:
		if not is_instance_valid(lvl):
			continue
		if lvl == current:
			lvl.visible = true
			lvl.modulate = Color(1, 1, 1, 1)
		else:
			lvl.visible = false
			lvl.modulate = Color(1, 1, 1, 1)


func _cmp_saved_idx(a, b):
	return a[1] < b[1]
