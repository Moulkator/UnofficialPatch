# level_settings_extra.gd
# Ajoute au panneau "Level Settings" :
#  1) un BOUTON cliquable (icône native checkbox_on/off) par ligne, à DROITE :
#     clic = bascule du niveau courant. checkbox_on = actif, checkbox_off =
#     inactif. Seul le clic SUR le bouton bascule (pas le clic sur le nom).
#     -> Bouton à droite : les boutons d'un Tree Godot sont alignés à droite.
#        Un bouton cliquable à gauche forcerait le nom hors de la col0 et
#        casserait le drag-reorder + l'en-tête "Levels".
#  2) "Clone level" dans le menu clic droit (icône icons/copy.png) : ouvre la
#     fenêtre New Level avec le champ "Clone Level" déjà positionné.
#  3) Label laissé en blanc.
# -> Une seule colonne : renommage, drag-reorder et en-tête natifs intacts.

var _g
var _panel = null
var _tree = null
var _menu = null
var _menu_connected = false
var _btn_connected = false
var _copy_icon = null
var _icon_on = null
var _icon_off = null
var _base_on_img = null
var _base_off_img = null
var _icon_h = 0
var _pending_clone_src = null
var _logged_menu = false
var _mouse_was_down = false

const CLONE_ID = 9001
const SWITCH_ID = 9002
const SCAN_EVERY = 12
const ICON_SCALE = 0.7  # taille du bouton = 70% de la hauteur de police

var _frame = 0


func initialize() -> void:
	pass


func update(_delta) -> void:
	if _g == null or _g.Editor == null:
		return

	if _tree == null or not is_instance_valid(_tree):
		_acquire()
		if _tree == null:
			return

	_ensure_menu()

	if not _btn_connected:
		if not _tree.is_connected("button_pressed", self, "_on_row_button"):
			_tree.connect("button_pressed", self, "_on_row_button")
		_btn_connected = true

	_frame += 1
	if _frame >= SCAN_EVERY:
		_frame = 0
		if _panel != null and is_instance_valid(_panel) and _panel.is_visible_in_tree():
			_refresh_rows()

	_check_outside_click()


# Désélectionne l'arbre quand on clique en dehors du panneau Level Settings
# (les boutons Create/Delete sont dans le panneau, donc ils restent ok).
func _check_outside_click() -> void:
	if _tree == null or not is_instance_valid(_tree):
		return
	if _panel == null or not is_instance_valid(_panel):
		return
	if not _panel.has_method("get_global_rect"):
		return
	var down = Input.is_mouse_button_pressed(BUTTON_LEFT)
	if down and not _mouse_was_down and _panel.is_visible_in_tree():
		var inside = _panel.get_global_rect().has_point(_panel.get_global_mouse_position())
		print("[LevelSettingsExtra] clic detecte, dans le panneau=", inside)
		if not inside:
			_deselect_tree()
	_mouse_was_down = down


func _deselect_tree() -> void:
	var sel = _tree.get_selected()
	print("[LevelSettingsExtra] deselect_tree, selection=",
		("oui" if sel != null else "non"))
	if sel != null:
		sel.deselect(0)


# --- Acquisition du panel / de la Tree -------------------------------------

func _acquire() -> void:
	_panel = null
	_tree = null
	_menu = null
	_menu_connected = false
	_btn_connected = false
	if _g.Editor.Toolset == null or not _g.Editor.Toolset.has_method("GetToolPanel"):
		return
	var panel = _g.Editor.Toolset.GetToolPanel("LevelSettings")
	if panel == null or not is_instance_valid(panel):
		return
	var tree = _find_tree(panel)
	if tree == null:
		return
	_panel = panel
	_tree = tree


func _find_tree(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is Tree:
		return node
	for child in node.get_children():
		var r = _find_tree(child)
		if r != null:
			return r
	return null


# PopupMenu du Level Tool (items natifs CREATE=0, DELETE=1), en ignorant tout
# sous-arbre de LineEdit (le champ de renommage a son propre menu d'ids 0/1).
func _find_level_menu(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is LineEdit:
		return null
	if node is PopupMenu:
		var has0 = false
		var has1 = false
		for i in range(node.get_item_count()):
			var iid = node.get_item_id(i)
			if iid == 0:
				has0 = true
			elif iid == 1:
				has1 = true
		if has0 and has1:
			return node
	for child in node.get_children():
		var r = _find_level_menu(child)
		if r != null:
			return r
	return null


# --- Menu clic droit : "Clone level" ---------------------------------------

func _ensure_menu() -> void:
	if _menu == null or not is_instance_valid(_menu):
		_menu = _find_level_menu(_panel)
		_menu_connected = false
	if _menu == null:
		return

	if not _logged_menu:
		print("[LevelSettingsExtra] Menu trouve, items=", _menu.get_item_count())
		_logged_menu = true

	if not _menu_connected:
		if not _menu.is_connected("id_pressed", self, "_on_menu_id"):
			_menu.connect("id_pressed", self, "_on_menu_id")
		_menu_connected = true

	var ci = _get_copy_icon()
	var idx = _menu_item_index(CLONE_ID)
	if idx == -1:
		if ci != null:
			_menu.add_icon_item(ci, "Clone level", CLONE_ID)
		else:
			_menu.add_item("Clone level", CLONE_ID)
		print("[LevelSettingsExtra] Item 'Clone level' ajoute au menu")
	elif ci != null and _menu.get_item_icon(idx) == null:
		_menu.set_item_icon(idx, ci)


func _menu_item_index(id) -> int:
	if _menu == null:
		return -1
	for i in range(_menu.get_item_count()):
		if _menu.get_item_id(i) == id:
			return i
	return -1


func _on_menu_id(id) -> void:
	if id != CLONE_ID:
		return
	if _tree == null or not is_instance_valid(_tree):
		return
	var item = _tree.get_selected()
	if item == null or not item.has_meta("meta"):
		return
	var src = item.get_meta("meta")
	if src == null:
		return
	_pending_clone_src = src
	_menu.emit_signal("id_pressed", 0)
	call_deferred("_prefill_clone_window")


func _prefill_clone_window() -> void:
	var src = _pending_clone_src
	_pending_clone_src = null
	if src == null:
		return
	var win = _find_newlevel_window()
	if win == null:
		return
	var ob = _find_by_class(win, "OptionButton")
	var idx = _level_index(src)
	if ob != null and idx >= 0:
		ob.select(idx + 1)  # +1 : l'index 0 est "---"
	var le = _find_by_class(win, "LineEdit")
	if le != null:
		le.text = _unique_label(str(src.Label) + " copy")


func _find_newlevel_window():
	if _g.Editor != null and _g.Editor.has_method("find_node"):
		var w = _g.Editor.find_node("NewLevel", true, false)
		if w != null and is_instance_valid(w):
			return w
	if _tree != null and is_instance_valid(_tree):
		var root = _tree.get_tree().root
		var w2 = root.find_node("NewLevel", true, false)
		if w2 != null and is_instance_valid(w2):
			return w2
	return null


func _find_by_class(node, cls):
	if node == null or not is_instance_valid(node):
		return null
	if node.is_class(cls):
		return node
	for child in node.get_children():
		var r = _find_by_class(child, cls)
		if r != null:
			return r
	return null


func _level_index(lvl) -> int:
	if _g.World == null or _g.World.levels == null:
		return -1
	for i in range(_g.World.levels.size()):
		if _g.World.levels[i] == lvl:
			return i
	return -1


func _unique_label(wanted) -> String:
	var existing = {}
	if _g.World != null and _g.World.levels != null:
		for lvl in _g.World.levels:
			existing[str(lvl.Label)] = true
	if not existing.has(wanted):
		return wanted
	var n = 2
	while existing.has(wanted + " " + str(n)):
		n += 1
	return wanted + " " + str(n)


# --- Icônes ----------------------------------------------------------------

func _root_path() -> String:
	if _g and _g.get("Root") and _g.Root is String:
		return _g.Root
	return ""


func _resize_to_height(img, target_h) -> void:
	var h = img.get_height()
	if h <= 0 or h == target_h:
		return
	var sc = float(target_h) / float(h)
	var new_w = max(1, int(round(img.get_width() * sc)))
	img.resize(new_w, target_h, Image.INTERPOLATE_LANCZOS)


func _load_png(rel, target_h):
	var root = _root_path()
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + rel) != OK:
		return null
	_resize_to_height(img, target_h)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _get_copy_icon():
	if _copy_icon != null and is_instance_valid(_copy_icon):
		return _copy_icon
	_copy_icon = _load_png("icons/copy.png", 20)
	return _copy_icon


# Icônes natives DD déposées dans icons/ : checkbox_on (actif) / checkbox_off.
# Charge les images checkbox de base (croppées, taille du contenu = ICON_SCALE
# * hauteur de police). On les centrera ensuite dans un canvas de la hauteur du
# bouton météo voisin, pour remplir la ligne comme lui (le Tree cale en haut).
func _load_base_images() -> void:
	if _base_on_img != null and _base_off_img != null:
		return
	var ch = int(round(_font_height() * ICON_SCALE))
	if ch < 6:
		ch = 6
	if _base_on_img == null:
		_base_on_img = _load_cropped_image("icons/checkbox_on.png", ch)
	if _base_off_img == null:
		_base_off_img = _load_cropped_image("icons/checkbox_off.png", ch)
	if _base_on_img == null or _base_off_img == null:
		print("[LevelSettingsExtra] checkbox_on/off introuvables dans icons/")


func _load_cropped_image(rel, h):
	var root = _root_path()
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + rel) != OK:
		return null
	img = _autocrop(img)
	_resize_to_height(img, h)
	return img


# Centre l'image dans un canvas haut de `h` -> texture.
func _pad_content(src, h):
	var cw = src.get_width()
	var ch = src.get_height()
	var height = int(max(h, ch))
	var out = Image.new()
	out.create(cw, height, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	out.blit_rect(src, Rect2(0, 0, cw, ch), Vector2(0, int((height - ch) / 2)))
	var tex = ImageTexture.new()
	tex.create_from_image(out, 0)
	return tex


# Hauteur du premier bouton natif voisin (le nuage de LevelSettingsPatch est en
# COLONNE 1, 28px) : c'est lui qui fixe la hauteur de ligne. On y aligne notre
# bouton. On scanne toutes les colonnes en ignorant notre propre bouton (col0).
func _sibling_button_height(root) -> int:
	if _tree == null or not is_instance_valid(_tree):
		return 0
	var cols = _tree.get_columns()
	var item = root.get_children()
	while item != null:
		for c in range(cols):
			for i in range(item.get_button_count(c)):
				if c == 0 and item.get_button_id(c, i) == SWITCH_ID:
					continue
				var t = item.get_button(c, i)
				if t != null:
					return int(t.get_height())
		item = item.get_next()
	return 0


func _font_height() -> int:
	if _tree != null and is_instance_valid(_tree):
		var f = _tree.get_font("font")
		if f != null:
			return int(f.get_height())
	return 16


func _autocrop(img):
	img.lock()
	var w = img.get_width()
	var h = img.get_height()
	var minx = w
	var miny = h
	var maxx = -1
	var maxy = -1
	for y in range(h):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.05:
				if x < minx:
					minx = x
				if x > maxx:
					maxx = x
				if y < miny:
					miny = y
				if y > maxy:
					maxy = y
	img.unlock()
	if maxx < minx or maxy < miny:
		return img
	if minx == 0 and miny == 0 and maxx == w - 1 and maxy == h - 1:
		return img
	var cw = maxx - minx + 1
	var ch = maxy - miny + 1
	var out = Image.new()
	out.create(cw, ch, false, Image.FORMAT_RGBA8)
	out.blit_rect(img, Rect2(minx, miny, cw, ch), Vector2(0, 0))
	return out


# --- Bouton d'état (droite) + bascule au clic du bouton --------------------

func _refresh_rows() -> void:
	if _tree == null or not is_instance_valid(_tree):
		return
	if _g.World == null or not _g.World.has_method("GetCurrentLevel"):
		return
	_load_base_images()
	if _base_on_img == null or _base_off_img == null:
		return
	var root = _tree.get_root()
	if root == null:
		return
	# Hauteur cible = hauteur du bouton météo (fixe la hauteur de ligne).
	# Fallback police si pas encore de bouton météo.
	var th = _sibling_button_height(root)
	if th <= 0:
		th = _font_height() + 6
	var force = false
	if th != _icon_h:
		_icon_on = _pad_content(_base_on_img, th)
		_icon_off = _pad_content(_base_off_img, th)
		_icon_h = th
		force = true
	if _icon_on == null or _icon_off == null:
		return
	var current = _g.World.GetCurrentLevel()
	var item = root.get_children()
	while item != null:
		var lvl = item.get_meta("meta") if item.has_meta("meta") else null
		var active = (lvl != null and lvl == current)
		item.clear_custom_color(0)  # label en blanc
		var stored = item.get_meta("_lse_active") if item.has_meta("_lse_active") else -1
		if force or stored != int(active):
			_apply_button(item, active)
			item.set_meta("_lse_active", int(active))
		item = item.get_next()


# Garantit EXACTEMENT un bouton (col0, aligné à droite) avec la bonne icône.
func _apply_button(item, active) -> void:
	var icon = _icon_on if active else _icon_off
	if icon == null:
		return
	var i = item.get_button_count(0) - 1
	while i >= 0:
		if item.get_button_id(0, i) == SWITCH_ID:
			item.erase_button(0, i)
		i -= 1
	item.add_button(0, icon, SWITCH_ID, false, "Switch to this level")


func _on_row_button(item, _column, id) -> void:
	if id != SWITCH_ID:
		return
	if item == null or not item.has_meta("meta"):
		return
	var lvl = item.get_meta("meta")
	if lvl == null:
		return
	var ok = _switch_via_dropdown(lvl)
	if not ok:
		var idx = _level_index(lvl)
		if idx >= 0 and _g.World.has_method("SetLevel"):
			_g.World.SetLevel(idx)
	if _g.Editor.has_method("UpdateLevelOptions"):
		_g.Editor.UpdateLevelOptions()
	if _panel != null and is_instance_valid(_panel) and _panel.is_visible_in_tree():
		_refresh_rows()


# --- Bascule via le menu déroulant de niveaux du haut ----------------------

func _find_level_dropdown():
	if _tree == null or not is_instance_valid(_tree):
		return null
	return _scan_dropdown(_tree.get_tree().root)


func _scan_dropdown(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is OptionButton and _ob_matches_levels(node):
		return node
	for c in node.get_children():
		var r = _scan_dropdown(c)
		if r != null:
			return r
	return null


func _ob_matches_levels(ob) -> bool:
	if _g.World == null or _g.World.levels == null:
		return false
	var n = _g.World.levels.size()
	if n == 0 or ob.get_item_count() != n:
		return false
	var labels = {}
	for lvl in _g.World.levels:
		labels[str(lvl.Label)] = true
	for i in range(ob.get_item_count()):
		if not labels.has(ob.get_item_text(i)):
			return false
	return true


func _switch_via_dropdown(lvl) -> bool:
	var ob = _find_level_dropdown()
	if ob == null:
		return false
	var target = str(lvl.Label)
	for i in range(ob.get_item_count()):
		if ob.get_item_text(i) == target:
			ob.select(i)
			ob.emit_signal("item_selected", i)
			return true
	return false
