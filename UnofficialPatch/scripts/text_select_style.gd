# text_select_style.gd
# Panneau police + couleur dans SelectTool quand un texte est selectionne.

var _g
var text_transform = null

var _sep        = null
var _title      = null
var _font_row   = null
var _color_row  = null
var _font_btn   = null
var _color_btn  = null
var _font_list  = []

var _anchor_path   = ""
var _setup_done    = false
var _updating_ui   = false
var _last_sel_size = -1
var _last_sel_primary := 0  # instance_id of the first selected text
var _saved_texts_for_picker = []  # textes sauvegardés à l'ouverture du color picker


func initialize():
	_try_setup(0)
	_install_listener()


func _install_listener():
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	s.reload()
	var listener = Node.new()
	listener.name = "TextSelectStyleListener"
	listener.set_script(s)
	listener.handler = self
	_g.World.call_deferred("add_child", listener)


func _color_picker_open() -> bool:
	if _color_btn == null: return false
	var popup = _color_btn.get_popup()
	return popup != null and popup.visible


func _on_input(event):
	if _color_picker_open(): return
	if not (_g.Editor and _g.Editor.ActiveToolName == "SelectTool"): return
	if not (event is InputEventMouseButton): return
	if not (event.button_index == BUTTON_LEFT and event.pressed): return
	if Input.is_key_pressed(KEY_SHIFT): return
	# Si un texte est sous la souris, deselectionner tout avant
	var tt = text_transform
	if tt == null or not is_instance_valid(tt): return
	var vp_path = tt._viewport_path
	if str(vp_path) == "" or str(vp_path) == ".": return
	var vp = _g.World.get_tree().root.get_node_or_null(vp_path)
	if vp == null: return
	var level = _g.World.GetCurrentLevel() if _g.World else null
	var texts_node = level.Texts if level != null else null
	if texts_node == null: return
	var mp = _g.WorldUI.MousePosition if _g.WorldUI else null
	if mp == null: return
	for t in texts_node.get_children():
		if not (t is Control): continue
		var aabb = tt._text_aabb(t) if tt.has_method("_text_aabb") else Rect2()
		if aabb.has_point(mp):
			# Appeler DeselectAll apres que DD a traite son clic
			var timer = _g.World.get_tree().create_timer(0.0)
			timer.connect("timeout", self, "_deferred_deselect")
			return


func _try_setup(attempt):
	if attempt > 30:
		return
	var root = _g.World.get_tree().root
	var anchor = root.get_node_or_null("Master/Editor/VPartition/Panels/Tools/Anchor")
	if anchor == null:
		_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_setup", [attempt + 1])
		return
	_anchor_path = str(anchor.get_path())
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "SelectTool":
			var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
			if align != null and align.get_child_count() > 0:
				_build_ui(align)
				return
	_g.World.get_tree().create_timer(0.2).connect("timeout", self, "_try_setup", [attempt + 1])


func _build_ui(align):
	_sep = HSeparator.new()
	align.add_child(_sep)
	_title = Label.new()
	_title.text = "Text Style"
	_title.align = Label.ALIGN_CENTER
	align.add_child(_title)
	_font_row = HBoxContainer.new()
	var lbl1 = Label.new()
	lbl1.text = "Font"
	lbl1.rect_min_size = Vector2(45, 0)
	_font_row.add_child(lbl1)
	_font_btn = OptionButton.new()
	_font_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_font_btn.connect("item_selected", self, "_on_font_selected")
	_font_btn.connect("gui_input", self, "_on_font_scroll")
	_font_row.add_child(_font_btn)
	align.add_child(_font_row)
	_color_row = HBoxContainer.new()
	var lbl2 = Label.new()
	lbl2.text = "Color"
	lbl2.rect_min_size = Vector2(45, 0)
	_color_row.add_child(lbl2)
	_color_btn = ColorPickerButton.new()
	_color_btn.color = Color.white
	_color_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_color_btn.rect_min_size = Vector2(60, 22)
	_color_btn.connect("color_changed", self, "_on_color_changed")
	# Connecter les signaux du popup après que Godot l'a créé (lazy init)
	_color_btn.connect("tree_entered", self, "_connect_picker_popup")
	_color_row.add_child(_color_btn)
	align.add_child(_color_row)
	_set_visible(false)
	_setup_done = true
	print("[TextSelectStyle] UI injected")
	_try_load_font_list(0)


func _try_load_font_list(attempt):
	if attempt > 20:
		return
	var root = _g.World.get_tree().root
	var anchor = root.get_node_or_null(_anchor_path)
	if anchor == null:
		_g.World.get_tree().create_timer(0.3).connect("timeout", self, "_try_load_font_list", [attempt + 1])
		return
	for child in anchor.get_children():
		if str(child.get("ForceTool")) == "TextTool":
			var ctrl = _find_option_button(child)
			if ctrl != null and ctrl.get_item_count() > 0:
				_font_list = []
				for i in range(ctrl.get_item_count()):
					_font_list.append(ctrl.get_item_text(i))
				_font_btn.clear()
				for fname in _font_list:
					_font_btn.add_item(fname)
				print("[TextSelectStyle] Font list: %d fonts" % _font_list.size())
				return
	_g.World.get_tree().create_timer(0.3).connect("timeout", self, "_try_load_font_list", [attempt + 1])


func _find_option_button(node):
	if node is OptionButton and node.get_item_count() > 1:
		return node
	for child in node.get_children():
		var r = _find_option_button(child)
		if r != null:
			return r
	return null


func _set_visible(show):
	if _sep != null:        _sep.visible = show
	if _title != null:      _title.visible = show
	if _font_row != null:   _font_row.visible = show
	if _color_row != null:  _color_row.visible = show
	# Garder nos elements en haut du panel
	if show and _sep != null and _sep.get_parent() != null:
		var align = _sep.get_parent()
		var count = align.get_child_count()
		var pos = min(15, count - 1)
		align.move_child(_sep, pos)
		align.move_child(_title, pos + 1)
		align.move_child(_font_row, pos + 2)
		align.move_child(_color_row, pos + 3)


func update(_delta):
	if not _setup_done:
		return
	# Fast tool gate: short-circuit before any other check when not in SelectTool.
	# _set_visible is idempotent (it no-ops when state already matches), so this
	# is cheap and avoids _color_picker_open / _get_selected_texts every frame.
	var in_sel = _g.Editor and _g.Editor.ActiveToolName == "SelectTool"
	if not in_sel:
		_set_visible(false)
		_last_sel_size = -1
		_last_sel_primary = 0
		return
	# Si text_transform est absent (desactive), on NE bascule PAS sur le chemin
	# de repli (_get_selected_texts via RawSelectables) : il peut faire planter
	# le C# de DD sur certaines selections. text_select_style depend de
	# text_transform pour fonctionner correctement de toute facon -> on s'efface.
	if text_transform == null or not is_instance_valid(text_transform):
		_set_visible(false)
		_last_sel_size = -1
		_last_sel_primary = 0
		return
	# Ne pas toucher au panel tant que le color picker est ouvert —
	# cela evite que le popup se ferme quand DD interprete le drag comme une deselection.
	if _color_picker_open():
		return
	var texts = _get_selected_texts()
	var show = texts.size() > 0
	_set_visible(show)
	if show:
		var primary_id = texts[0].get_instance_id() if is_instance_valid(texts[0]) else 0
		if texts.size() != _last_sel_size or primary_id != _last_sel_primary:
			_last_sel_size    = texts.size()
			_last_sel_primary = primary_id
			_refresh_ui(texts[0])
	else:
		_last_sel_size    = -1
		_last_sel_primary = 0


func _deferred_deselect():
	var st = _g.Editor.Tools["SelectTool"] if _g.Editor else null
	if st == null: return
	var has_text = text_transform != null and is_instance_valid(text_transform) and text_transform._selected_texts.size() > 0
	if not has_text: return
	var sel = st.get("Selected")
	if sel == null or sel.size() == 0: return
	# Verifier si la selection contient des non-textes via RawSelectables
	var raw = st.RawSelectables
	if raw == null or raw.size() == 0: return
	var has_non_text = false
	for s in raw:
		if s == null or not is_instance_valid(s): continue
		var thing = s.get("Thing")
		if thing != null and is_instance_valid(thing):
			if not (thing is Control and thing.has_method("SetFont")):
				has_non_text = true
				break
	if not has_non_text: return
	st.DeselectAll()
	for i in range(text_transform._selected_texts.size()):
		var txt = text_transform._selected_texts[i]
		if is_instance_valid(txt):
			st.SelectThing(txt, i > 0)


func _get_selected_texts():
	# text_transform absent -> on n'utilise PAS le repli RawSelectables (cause
	# probable du crash C# de DD). Renvoie vide.
	if text_transform == null or not is_instance_valid(text_transform):
		return []
	if text_transform != null and is_instance_valid(text_transform):
		var tt = text_transform._selected_texts
		if tt != null and tt.size() > 0:
			# Filtrer les nœuds potentiellement freés par DD (ex: après SetFontColor)
			var valid = []
			for n in tt:
				if n != null and is_instance_valid(n):
					valid.append(n)
			if valid.size() > 0:
				return valid
	var result = []
	if _g.Editor == null:
		return result
	var st = _g.Editor.Tools["SelectTool"]
	if st == null:
		return result
	var raw = st.RawSelectables
	if raw == null:
		return result
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing != null and is_instance_valid(thing):
			if thing is Control and thing.has_method("SetFont"):
				result.append(thing)
	if result.size() > 0 and text_transform != null and is_instance_valid(text_transform):
		text_transform._selected_texts = result
		text_transform._primary_text = result[0]
	return result


func _refresh_ui(text_node):
	_updating_ui = true
	# Priority 1: direct C# property (always up-to-date)
	var fname = ""
	var direct_name = text_node.get("fontName")
	if direct_name != null and str(direct_name) != "":
		fname = str(direct_name)
	# Priority 2: dataOnFocus (snapshot — may be stale)
	if fname == "":
		var base = text_node.get("dataOnFocus")
		if base != null and base is Dictionary and base.has("font_name"):
			fname = str(base["font_name"])
	if fname != "":
		var idx = _font_list.find(fname)
		if idx >= 0 and _font_btn != null:
			_font_btn.select(idx)
	var fc = text_node.get("fontColor")
	if fc != null and _color_btn != null:
		_color_btn.color = fc
	_updating_ui = false


func _on_font_scroll(event):
	if not (event is InputEventMouseButton): return
	if not (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN): return
	if not event.pressed: return
	if _font_list.size() == 0: return
	var dir = -1 if event.button_index == BUTTON_WHEEL_UP else 1
	var cur = _font_btn.selected if _font_btn.selected >= 0 else 0
	var idx = (cur + dir + _font_list.size()) % _font_list.size()
	_font_btn.select(idx)
	_on_font_selected(idx)


func _on_font_selected(idx):
	if _updating_ui: return
	if idx < 0 or idx >= _font_list.size(): return
	var fname = _font_list[idx]
	for t in _get_selected_texts().duplicate():
		if is_instance_valid(t):
			var fsize = 48
			# Priority 1: direct C# property
			var direct_size = t.get("fontSize")
			if direct_size != null and int(direct_size) > 0:
				fsize = int(direct_size)
			else:
				var base = t.get("dataOnFocus")
				if base != null and base.has("font_size"):
					fsize = int(base["font_size"])
			t.call("SetFont", fname, fsize)


func _connect_picker_popup():
	if _color_btn == null: return
	# Le popup est créé lazily par Godot — on attend un frame
	_g.World.get_tree().create_timer(0.0).connect("timeout", self, "_connect_picker_popup_deferred")


func _connect_picker_popup_deferred():
	if _color_btn == null: return
	var popup = _color_btn.get_popup()
	if popup == null: return
	if not popup.is_connected("about_to_show", self, "_on_picker_opened"):
		popup.connect("about_to_show", self, "_on_picker_opened")


func _on_picker_opened():
	_saved_texts_for_picker = _get_selected_texts().duplicate()


func _on_color_changed(color):
	if _updating_ui: return
	var texts = (_saved_texts_for_picker if _saved_texts_for_picker.size() > 0 else _get_selected_texts()).duplicate()
	for t in texts:
		if t != null and is_instance_valid(t):
			t.call("SetFontColor", color)
