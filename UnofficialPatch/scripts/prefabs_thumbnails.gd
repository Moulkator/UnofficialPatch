# prefabs_thumbnails.gd
# Sub-mod -- Prefab thumbnail generation in PrefabTool itemList

var _g

const THUMB_SIZE = 64
const THUMB_SIZE_MD = 96
const THUMB_SIZE_LG = 240

const MODE_LIST       = 0
const MODE_LIST_THUMB = 1
const MODE_GRID_SM    = 2
const MODE_GRID_MD    = 3
const MODE_GRID_LG    = 4

const RECOLOR_SHADER = """
shader_type canvas_item;
render_mode blend_mix;
uniform vec4 tint_r : hint_color;
uniform float min_redness = 0.1;
uniform float red_tolerance = 0.04;
uniform float min_saturation = 0.0;
float luma(vec3 color) {
  return dot(color, vec3(0.299, 0.587, 0.114));
}
void fragment() {
    vec4 original = texture(TEXTURE, UV);
    vec3 texel = vec3(0.0);
    float alpha = 1.0;
    bool is_red = abs(original.g - original.b) <= red_tolerance;
    bool is_within_saturation = 1.0 - ((original.g + original.b) * 0.5f) >= min_saturation;
    float redness = original.r - (original.g + original.b) * 0.5;
    if (is_red && is_within_saturation && redness > min_redness) {
        texel = original.r * tint_r.rgb;
        float l = luma(original.rgb);
        if (l > 0.333) {
            texel = mix(texel, vec3(1.0), l - 0.333);
        }
        alpha = mix(1.0, tint_r.a, 1.0);
    } else {
        texel = original.rgb;
    }
    COLOR = vec4(texel, original.a * alpha);
}
"""

var _thumb_cache := {}
var _missing_status_cache := {}  # set_key/prefab_key -> "ok", "partial", "all_missing"
var _orange_badge: ImageTexture = null  # cached orange dot badge
var _prefab_index := {}
var _panel = null
var _item_list = null
var _set_option = null
var _current_set_name := ""
var _missing_assets_dialog = null  # AcceptDialog shown when a prefab has missing assets
var _session_missing_choice = null  # null=ask, true=place anyway, false=cancel
var _dd_item_connections = []       # Stored DD item_selected connections
var _clone_list = null              # Unused - kept for _sync_clone_list compatibility
var _click_interceptor = null       # Node that intercepts clicks on the prefab list
var _bypassing_intercept := false   # True while we intentionally trigger the original list
var _custom_assets_dir_cache := ""
var _custom_assets_dir_loaded := false
var _recolor_shader : Shader = null
var _vp_holder : Node = null
var _ctx_popup : PopupMenu = null
var _right_was_pressed := false
var _right_click_idx := -1
var _search_bar : LineEdit = null
var _search_text := ""
var _search_overlay : ItemList = null
# _filtered_to_original : Array[int] -- index overlay -> index dans _item_list DD
var _filtered_to_original := []
var _prefetch_done := false
var _prefetch_running := false
var _display_mode : int = MODE_LIST_THUMB
const PREFS_PATH = "user://UnofficialPatch/prefabs_thumbnails_prefs.json"
var _mode_toolbar : HBoxContainer = null
var _original_theme = null
# Cache de la texture d'outline pour les PatternShape (default_border.png).
# Chargee paresseusement au premier appel via _get_outline_texture().
var _cached_outline_texture : Texture = null

# UI Rescaler integration. The UI Rescaler mod publishes its Asset
# Thumbnails effective scale via meta "uir_asset_thumb_scale" on _g.World.
# We read that scale when computing fixed_icon_size + fixed_column_width
# so the prefab thumbnails grow alongside the rest of the asset library.
# Polling in update() detects scale changes (when user moves the UI
# Rescaler slider) and triggers a re-apply.
var _last_uir_scale : float = 1.0
var _uir_poll_accum : float = 0.0
const UIR_POLL_INTERVAL : float = 0.25


func initialize() -> void:
	print("[PrefabsThumbs] Initialized")
	call_deferred("_setup")


func update(_delta) -> void:
	var right_now = Input.is_mouse_button_pressed(BUTTON_RIGHT)
	if right_now and not _right_was_pressed:
		_on_right_click()
	_right_was_pressed = right_now
	# Poll UI Rescaler's Asset Thumbnails scale (published via meta on
	# _g.World by ui_rescaler.gd after each apply). When it changes, we
	# re-apply our thumbnails to match the new size.
	_uir_poll_accum += _delta
	if _uir_poll_accum >= UIR_POLL_INTERVAL:
		_uir_poll_accum = 0.0
		var cur = _get_uir_scale()
		if abs(cur - _last_uir_scale) > 0.001:
			_last_uir_scale = cur
			if _panel != null and is_instance_valid(_panel) \
					and _panel.is_visible_in_tree():
				_apply_thumbnails()


# Read the UI Rescaler's published Asset Thumbnails scale. Returns 1.0
# when the meta isn't set (UI Rescaler not loaded, or first apply hasn't
# happened yet).
func _get_uir_scale() -> float:
	if _g == null or _g.World == null:
		return 1.0
	if not is_instance_valid(_g.World):
		return 1.0
	if _g.World.has_meta("uir_asset_thumb_scale"):
		var v = _g.World.get_meta("uir_asset_thumb_scale")
		if typeof(v) == TYPE_REAL or typeof(v) == TYPE_INT:
			return float(v)
	return 1.0



func _setup() -> void:
	_panel = _g.Editor.Toolset.GetToolPanel("PrefabTool")
	if _panel == null:
		return
	_item_list = _panel.get("itemList")
	_set_option = _panel.get("setOption")
	if not (_set_option is OptionButton):
		return
	_set_option.connect("item_selected", self, "_on_set_selected")
	_load_prefs()
	_build_mode_toolbar()
	_build_prefab_index()
	# Intercept item_selected: disconnect DD's C# OnSelectPrefab handler and
	# replace it with ours. We call OnSelectPrefab manually only when safe.
	if _item_list != null and is_instance_valid(_item_list):
		_hook_item_list_interception()
	# Le clic droit est gere via polling dans update()
	# Charger les thumbnails du set initial si le panel est deja visible
	_panel.connect("visibility_changed", self, "_on_panel_visibility_changed")
	# Declencher le chargement initial via un timer (yield ne fonctionne pas dans _setup)
	var t = _g.World.get_tree().create_timer(0.5)
	t.connect("timeout", self, "_load_initial_set")
	# Noeud holder isole pour les Viewports de rendu -- hors de _g.World
	_vp_holder = Node.new()
	_vp_holder.name = "PrefabsThumbsVPHolder"
	_panel.get_tree().root.add_child(_vp_holder)
	print("[PrefabsThumbs] Ready -- %d sets indexed" % _prefab_index.size())
	call_deferred("_discover_prefab_tool_methods")
	# Lancer la generation en arriere-plan pour tous les sets
	var pt = _g.World.get_tree().create_timer(1.0)
	pt.connect("timeout", self, "_start_prefetch")


func _build_prefab_index() -> void:
	_index_prefab_root("user://prefabs")
	_index_prefab_root("res://prefabs")


func _index_prefab_root(root: String) -> void:
	var dir = Directory.new()
	if dir.open(root) != OK:
		return
	dir.list_dir_begin(true, true)
	var entry = dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not _prefab_index.has(entry):
				_prefab_index[entry] = {}
			var sub = Directory.new()
			if sub.open(root + "/" + entry) == OK:
				sub.list_dir_begin(true, true)
				var f = sub.get_next()
				while f != "":
					if f.ends_with(".dungeondraft_prefab"):
						var name_lower = f.replace(".dungeondraft_prefab", "").to_lower()
						if not _prefab_index[entry].has(name_lower):
							_prefab_index[entry][name_lower] = root + "/" + entry + "/" + f
					f = sub.get_next()
				sub.list_dir_end()
		entry = dir.get_next()
	dir.list_dir_end()


func _on_set_selected(index: int) -> void:
	_current_set_name = _set_option.get_item_text(index)
	# Reindexer le set courant pour detecter les nouveaux prefabs
	_reindex_current_set()
	var set_key_sel = _find_set_key(_current_set_name)
	_apply_missing_status_to_list(set_key_sel)
	yield(_g.World.get_tree().create_timer(0.15), "timeout")
	_apply_thumbnails()


func _on_panel_visibility_changed() -> void:
	if not _panel.visible:
		return
	_missing_status_cache.clear()  # Packs may have changed since last open
	_current_set_name = _set_option.get_item_text(_set_option.selected)
	_reindex_current_set()
	var t = _g.World.get_tree().create_timer(0.2)
	t.connect("timeout", self, "_load_initial_set")


func _start_prefetch() -> void:
	if _prefetch_done or _prefetch_running:
		return
	_prefetch_running = true
	_prefetch_all()


func _prefetch_all() -> void:
	var sizes = [THUMB_SIZE, THUMB_SIZE_MD, -THUMB_SIZE_LG]
	var sets_snapshot = _prefab_index.duplicate(true)  # snapshot pour eviter modif pendant iteration
	var total = 0
	var skipped = 0
	for set_key in sets_snapshot.keys():
		for prefab_name in sets_snapshot[set_key].keys():
			var status = _get_prefab_asset_status(prefab_name, set_key)
			if status != "ok":
				skipped += 1
				continue
			total += sizes.size()
	if total == 0:
		_prefetch_done = true
		_prefetch_running = false
		if skipped > 0:
			print("[PrefabsThumbs] Prefetch: skipped %d prefabs with missing assets, nothing to generate" % skipped)
		return
	print("[PrefabsThumbs] Prefetch: %d thumbnails a generer (skipped %d prefabs with missing assets)..." % [total, skipped])
	var done = 0
	for thumb_size in sizes:
		for set_key in sets_snapshot.keys():
			for prefab_name in sets_snapshot[set_key].keys():
				# Verifier que le contexte est toujours valide
				if _vp_holder == null or not is_instance_valid(_vp_holder):
					_prefetch_running = false
					return
				# Skip prefabs with missing assets -- no point generating thumbnails
				var status = _get_prefab_asset_status(prefab_name, set_key)
				if status != "ok":
					continue
				var cache_key = "%s/%s/%d" % [set_key, prefab_name, abs(thumb_size)]
				if not _thumb_cache.has(cache_key):
					var tex = yield(_generate_thumbnail(set_key, prefab_name, thumb_size), "completed")
					if tex != null:
						_thumb_cache[cache_key] = tex
				done += 1
				if done % 3 == 0:
					if _vp_holder == null or not is_instance_valid(_vp_holder):
						_prefetch_running = false
						return
					yield(_vp_holder.get_tree(), "idle_frame")
	_prefetch_done = true
	_prefetch_running = false
	print("[PrefabsThumbs] Prefetch termine: %d thumbnails en cache" % _thumb_cache.size())


func _load_initial_set() -> void:
	_current_set_name = _set_option.get_item_text(_set_option.selected)
	# Apply missing status immediately (before async thumbnail generation)
	var set_key_init = _find_set_key(_current_set_name)
	_apply_missing_status_to_list(set_key_init)
	_apply_thumbnails()


func _discover_prefab_tool_methods() -> void:
	var dir = Directory.new()
	if dir.open("res://ui/icons") == OK:
		dir.list_dir_begin(true, true)
		var e = dir.get_next()
		while e != "":
			print("[PrefabsThumbs] icon: %s" % e)
			e = dir.get_next()
		dir.list_dir_end()

func _UNUSED() -> void:
	var shaders_to_read = [
		"res://shaders/CustomColors.shader",
		"res://shaders/Object.shader",
		"res://shaders/PatternCustomColor.shader",
	]
	for path in shaders_to_read:
		var f = File.new()
		if f.open(path, File.READ) == OK:
			print("[PrefabsThumbs] === %s ===" % path)
			print(f.get_as_text())
			f.close()


func _reindex_current_set() -> void:
	var set_key = _find_set_key(_current_set_name)
	if set_key == "":
		return
	for root in ["user://prefabs", "res://prefabs"]:
		var sub = Directory.new()
		if sub.open(root + "/" + set_key) != OK:
			continue
		sub.list_dir_begin(true, true)
		var f = sub.get_next()
		while f != "":
			if f.ends_with(".dungeondraft_prefab"):
				var name_lower = f.replace(".dungeondraft_prefab", "").to_lower()
				if not _prefab_index[set_key].has(name_lower):
					_prefab_index[set_key][name_lower] = root + "/" + set_key + "/" + f
					var cache_key = "%s/%s" % [_current_set_name, name_lower]
					_thumb_cache.erase(cache_key)
					print("[PrefabsThumbs] New prefab detected: %s" % f)
			f = sub.get_next()
		sub.list_dir_end()


func _apply_thumbnails() -> void:
	if not (_item_list is ItemList):
		return
	var count = _item_list.get_item_count()
	if count == 0:
		return

	# _get_thumb_size() now returns the size scaled by the UI Rescaler's
	# Asset Thumbnails slider. Used both for display (fixed_icon_size,
	# fixed_column_width) and for thumbnail generation/cache lookup.
	# Thumbnails are GENERATED at this size — no Godot upscaling, sharp
	# textures at any scale (regeneration on demand when scale changes).
	var thumb_size = _get_thumb_size()
	var disp_size = abs(thumb_size)  # positive size for fixed_icon_size

	match _display_mode:
		MODE_LIST:
			_apply_mode_list()
			return
		MODE_LIST_THUMB:
			_item_list.icon_mode = ItemList.ICON_MODE_LEFT
			_item_list.fixed_icon_size = Vector2(disp_size, disp_size)
			_item_list.max_columns = 1
			_item_list.same_column_width = true
			_item_list.fixed_column_width = 0

		MODE_GRID_SM:
			_item_list.icon_mode = ItemList.ICON_MODE_TOP
			_item_list.fixed_icon_size = Vector2(disp_size, disp_size)
			_item_list.max_columns = 0
			_item_list.same_column_width = true
			_item_list.fixed_column_width = disp_size + 4
		MODE_GRID_MD:
			_item_list.icon_mode = ItemList.ICON_MODE_TOP
			_item_list.fixed_icon_size = Vector2(disp_size, disp_size)
			_item_list.max_columns = 0
			_item_list.same_column_width = true
			_item_list.fixed_column_width = disp_size + 4
		MODE_GRID_LG:
			_item_list.icon_mode = ItemList.ICON_MODE_TOP
			_item_list.fixed_icon_size = Vector2(0, 0)
			_item_list.max_columns = 1
			_item_list.same_column_width = true
			# Largeur = panel entier moins la scrollbar (~14px)
			var list_w = int(_item_list.rect_size.x) - 14
			if list_w < 32: list_w = 200
			_item_list.fixed_column_width = list_w
			_item_list.add_constant_override("icon_margin", 4)

	_item_list.icon_scale = 1.0
	var is_grid = _display_mode != MODE_LIST_THUMB
	var set_key = _find_set_key(_current_set_name)
	# thumb_size declared above (used for both display sizes in the match
	# statement and for cache lookup / generation in the loop below)
	# Filter out prefabs with missing assets BEFORE generating thumbnails
	_apply_missing_status_to_list(set_key)
	count = _item_list.get_item_count()
	for i in range(count):
		# Toujours garder le texte -- DD l'utilise pour placer le prefab
		# Recuperer le vrai nom (tooltip = backup si deja in tooltip)
		var item_name = _item_list.get_item_text(i)
		if item_name == "":
			item_name = _item_list.get_item_tooltip(i)
		if item_name == "":
			continue
		_item_list.set_item_text(i, item_name)
		_item_list.set_item_tooltip(i, item_name)
		var cache_key = "%s/%s/%d" % [_current_set_name, item_name.to_lower(), abs(thumb_size)]
		if _thumb_cache.has(cache_key):
			_item_list.set_item_icon(i, _thumb_cache[cache_key])
			continue
		var tex = yield(_generate_thumbnail(set_key, item_name.to_lower(), thumb_size), "completed")
		if tex != null:
			_thumb_cache[cache_key] = tex
			if i < _item_list.get_item_count():
				_item_list.set_item_icon(i, tex)
	# Apply missing status: already done before thumbnail generation
	# Sync our clone list with the updated original
	_sync_clone_list()
	# Rafraichir l'overlay si une recherche est active
	if _search_text != "":
		_apply_search_filter()


func _apply_mode_list() -> void:
	_item_list.fixed_icon_size = Vector2(0, 0)
	_item_list.icon_mode = ItemList.ICON_MODE_LEFT
	_item_list.max_columns = 1
	_item_list.same_column_width = true
	_item_list.fixed_column_width = 0
	for i in range(_item_list.get_item_count()):
		_item_list.set_item_icon(i, null)
		var tip = _item_list.get_item_tooltip(i)
		if tip != "" and _item_list.get_item_text(i) == "":
			_item_list.set_item_text(i, tip)
	var set_key2 = _find_set_key(_current_set_name)
	_apply_missing_status_to_list(set_key2)
	_sync_clone_list()


func _get_thumb_size() -> int:
	# Multiplied by the UI Rescaler's Asset Thumbnails scale so the
	# thumbnails are GENERATED at the displayed size — sharp, not
	# upscaled. The cache key includes the size, so cache stays valid
	# per (set, prefab, size) tuple. Changing the scale invalidates
	# the cache for the new size and triggers regeneration on demand.
	var s = _get_uir_scale()
	match _display_mode:
		MODE_GRID_MD:
			return int(round(THUMB_SIZE_MD * s))
		MODE_GRID_LG:
			return -int(round(THUMB_SIZE_LG * s))  # negatif = mode adaptatif
		_:
			return int(round(THUMB_SIZE * s))


func _make_mode_icon(mode: int) -> ImageTexture:
	var img = Image.new()
	img.create(40, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var fg = Color(0.85, 0.85, 0.85, 1.0)
	var dim = Color(0.5, 0.5, 0.5, 1.0)
	img.lock()
	match mode:
		MODE_LIST:
			# 5 lignes texte espacees sur 40px
			for row in [3, 10, 17, 24, 31]:
				for x in range(3, 37):
					img.set_pixel(x, row,     fg)
					img.set_pixel(x, row + 1, fg)
					img.set_pixel(x, row + 2, fg)
		MODE_LIST_THUMB:
			# 3 rangees : carre 9x9 + 2 lignes texte
			for row in [3, 15, 27]:
				for y in range(row, row + 9):
					for x in range(3, 12):
						img.set_pixel(x, y, fg)
				for x in range(15, 37):
					img.set_pixel(x, row + 1, fg)
					img.set_pixel(x, row + 2, fg)
					img.set_pixel(x, row + 3, fg)
					img.set_pixel(x, row + 6, fg)
					img.set_pixel(x, row + 7, fg)
		MODE_GRID_SM:
			# 3x3 carres 9x9 avec gap de 2
			for row in [3, 14, 25]:
				for col in [3, 14, 25]:
					for y in range(row, row + 9):
						for x in range(col, col + 9):
							img.set_pixel(x, y, fg)
		MODE_GRID_MD:
			# 2x2 carres 16x16 avec gap de 4
			for row in [3, 21]:
				for col in [3, 21]:
					for y in range(row, row + 16):
						for x in range(col, col + 16):
							img.set_pixel(x, y, fg)
		MODE_GRID_LG:
			# 1 grand carre 34x34 avec bordure + interieur grise
			for y in range(3, 37):
				for x in range(3, 37):
					if x == 3 or x == 36 or y == 3 or y == 36:
						img.set_pixel(x, y, fg)
					else:
						img.set_pixel(x, y, dim)
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _build_mode_toolbar() -> void:
	if _item_list == null:
		return
	_original_theme = _item_list.theme
	var toolbar = HBoxContainer.new()
	toolbar.rect_min_size = Vector2(0, 48)
	toolbar.set("custom_constants/separation", 4)
	toolbar.alignment = BoxContainer.ALIGN_CENTER
	_mode_toolbar = toolbar

	var buttons = [
		[MODE_LIST,       "Liste texte uniquement"],
		[MODE_LIST_THUMB, "Liste avec thumbnails"],
		[MODE_GRID_SM,    "Grille petite"],
		[MODE_GRID_MD,    "Grille moyenne"],
		[MODE_GRID_LG,    "Grille grande (pleine largeur)"],
	]

	for btn_data in buttons:
		var btn = Button.new()
		btn.hint_tooltip = btn_data[1]
		btn.rect_min_size = Vector2(0, 44)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.flat = true
		btn.toggle_mode = true
		btn.expand_icon = true
		btn.icon = _make_mode_icon(btn_data[0])
		btn.set_meta("mode", btn_data[0])
		# Clic droit = definir comme mode par defaut
		btn.connect("pressed", self, "_on_mode_button_pressed", [btn])
		toolbar.add_child(btn)

	# Inserer toolbar + search bar juste avant itemList dans son parent
	var parent = _item_list.get_parent()
	if parent == null:
		print("[PrefabsThumbs] toolbar: itemList has no parent!")
		return
	var idx = _item_list.get_index()
	print("[PrefabsThumbs] toolbar: inserting at idx=%d in parent=%s" % [idx, parent.get_class()])
	parent.add_child(toolbar)
	parent.move_child(toolbar, idx)
	# Search bar (label + field dans un HBox)
	var search_hbox = HBoxContainer.new()
	search_hbox.rect_min_size = Vector2(0, 28)
	search_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var search_label = Label.new()
	search_label.text = "Search"
	search_label.valign = Label.VALIGN_CENTER
	search_hbox.add_child(search_label)
	var search = LineEdit.new()
	search.rect_min_size = Vector2(0, 28)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.clear_button_enabled = true
	_search_bar = search
	search_hbox.add_child(search)
	var spacer = Control.new()
	spacer.rect_min_size = Vector2(6, 0)
	search_hbox.add_child(spacer)
	parent.add_child(search_hbox)
	parent.move_child(search_hbox, idx + 1)
	search.connect("text_changed", self, "_on_search_changed")
	print("[PrefabsThumbs] toolbar: added, children=%d" % parent.get_child_count())

	_update_mode_buttons()



func _on_mode_button_pressed(btn: Button) -> void:
	_display_mode = btn.get_meta("mode")
	_save_mode()
	_update_mode_buttons()
	if _display_mode == MODE_LIST:
		_apply_mode_list()
		_scroll_to_selected()
		return
	# Restaurer les textes si on revenait du mode grille
	for i in range(_item_list.get_item_count()):
		var tip = _item_list.get_item_tooltip(i)
		if tip != "" and _item_list.get_item_text(i) == "":
			_item_list.set_item_text(i, tip)
	_apply_thumbnails()
	# Scroll apres un court delai pour laisser le layout se recalculer
	var t = _g.World.get_tree().create_timer(0.1)
	t.connect("timeout", self, "_scroll_to_selected")


func _on_right_click() -> void:
	if _item_list == null or not is_instance_valid(_item_list):
		return
	if not _item_list.is_visible_in_tree():
		return
	var tree = _panel.get_tree()
	if tree == null:
		return
	var mouse_pos = tree.root.get_mouse_position()
	var rect = _item_list.get_global_rect()
	var overlay_rect = Rect2()
	if _search_overlay != null and is_instance_valid(_search_overlay) and _search_overlay.visible:
		overlay_rect = _search_overlay.get_global_rect()
	if not rect.has_point(mouse_pos) and not overlay_rect.has_point(mouse_pos):
		return
	var local_pos = mouse_pos - rect.position
	# Si l'overlay de recherche est actif, travailler dessus
	var click_list = _item_list
	if _search_overlay != null and is_instance_valid(_search_overlay) and _search_overlay.visible:
		var srect = _search_overlay.get_global_rect()
		if srect.has_point(mouse_pos):
			click_list = _search_overlay
			local_pos = mouse_pos - srect.position
	var idx = click_list.get_item_at_position(local_pos, true)
	if idx < 0:
		return
	# Convertir en index DD si on est sur l'overlay
	var dd_idx = idx
	if click_list == _search_overlay and idx < _filtered_to_original.size():
		dd_idx = _filtered_to_original[idx]
	_right_click_idx = dd_idx
	if _ctx_popup == null or not is_instance_valid(_ctx_popup):
		_ctx_popup = PopupMenu.new()
		_ctx_popup.connect("id_pressed", self, "_on_prefab_ctx_pressed")
		_get_popup_layer().add_child(_ctx_popup)
	_ctx_popup.clear()
	_ctx_popup.add_item("Forget prefab", 0)
	_ctx_popup.popup(Rect2(mouse_pos, Vector2(1, 1)))


func _on_prefab_ctx_pressed(id: int) -> void:
	if id == 0:
		if not _g.Editor or not _g.Editor.Tools:
			return
		var pt = _g.Editor.Tools.get("PrefabTool")
		if pt == null:
			return
		# Selectionner l'item sous la souris avant de Forget
		if _right_click_idx >= 0 and is_instance_valid(_item_list):
			_item_list.select(_right_click_idx)
			_item_list.emit_signal("item_selected", _right_click_idx)
		pt.Forget()
	_right_click_idx = -1


func _on_search_changed(text: String) -> void:
	_search_text = text.strip_edges().to_lower()
	_apply_search_filter()


func _apply_search_filter() -> void:
	if not is_instance_valid(_item_list):
		return
	# Creer l'overlay si besoin
	if _search_overlay == null or not is_instance_valid(_search_overlay):
		var overlay = ItemList.new()
		overlay.name = "SearchOverlay"
		overlay.size_flags_horizontal = _item_list.size_flags_horizontal
		overlay.size_flags_vertical = _item_list.size_flags_vertical
		overlay.rect_min_size = _item_list.rect_min_size
		_item_list.get_parent().add_child(overlay)
		_item_list.get_parent().move_child(overlay, _item_list.get_index() + 1)
		overlay.connect("item_selected", self, "_on_search_overlay_selected")
		_search_overlay = overlay
	# Pas de filtre : afficher la liste DD normale
	if _search_text == "":
		_item_list.visible = true
		_search_overlay.visible = false
		_filtered_to_original.clear()
		return
	# Construire l'overlay filtre
	_search_overlay.max_columns    = _item_list.max_columns
	_search_overlay.icon_mode      = _item_list.icon_mode
	_search_overlay.fixed_icon_size = _item_list.fixed_icon_size
	_search_overlay.same_column_width = _item_list.same_column_width
	_search_overlay.fixed_column_width = _item_list.fixed_column_width
	_search_overlay.icon_scale     = _item_list.icon_scale
	_search_overlay.clear()
	_filtered_to_original.clear()
	for i in range(_item_list.get_item_count()):
		var txt = _item_list.get_item_text(i)
		if _search_text in txt.to_lower():
			var fi = _search_overlay.get_item_count()
			_search_overlay.add_item(txt, _item_list.get_item_icon(i), true)
			_search_overlay.set_item_tooltip(fi, _item_list.get_item_tooltip(i))
			_filtered_to_original.append(i)
	_item_list.visible = false
	_search_overlay.visible = true


func _on_search_overlay_selected(fi: int) -> void:
	if fi < 0 or fi >= _filtered_to_original.size():
		return
	var di = _filtered_to_original[fi]
	_item_list.select(di)
	_item_list.emit_signal("item_selected", di)


# Missing assets interception--------

func _hook_item_list_interception() -> void:
	# Install a Node at position 0 in the tree root with _input().
	# It intercepts left-clicks on the ItemList before DD's C# handler.
	if _click_interceptor != null and is_instance_valid(_click_interceptor): return
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null: handler._on_prefab_list_input(e)\n"
	script.reload()
	_click_interceptor = Node.new()
	_click_interceptor.name = "PrefabsThumbsClickInterceptor"
	_click_interceptor.set_script(script)
	_click_interceptor.handler = self
	_g.World.get_tree().root.call_deferred("add_child", _click_interceptor)
	_g.World.get_tree().root.call_deferred("move_child", _click_interceptor, 0)
	print("[PrefabsThumbs] Click interceptor installed")


func _on_prefab_list_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton): return
	if not event.pressed or event.button_index != BUTTON_LEFT: return
	if not is_instance_valid(_item_list) or not _item_list.is_visible_in_tree(): return
	var rect = _item_list.get_global_rect()
	if not rect.has_point(event.position): return
	# Find which item was clicked
	var local_pos = _item_list.get_global_transform().affine_inverse().xform(event.position)
	var index = _item_list.get_item_at_position(local_pos, true)
	if index < 0: return
	var prefab_name = _item_list.get_item_text(index)
	var set_key = _find_set_key(_current_set_name)
	var status = _get_prefab_asset_status(prefab_name, set_key)
	if status == "ok": return
	if _session_missing_choice == true: return
	_click_interceptor.get_tree().set_input_as_handled()
	if _session_missing_choice == false: return
	var missing = _check_prefab_missing_assets(index)
	_show_missing_assets_dialog(prefab_name, missing, index, [])


func _on_prefab_item_selected_interceptor(index: int) -> void:
	pass  # Unused - kept for compatibility


func _call_dd_via_original(index: int) -> void:
	# Trigger DD's C# OnSelectPrefab by selecting + emitting on the hidden original.
	# Use _bypassing_intercept to prevent our clone handler from re-firing.
	if not is_instance_valid(_item_list): return
	_bypassing_intercept = true
	_item_list.select(index)
	_item_list.emit_signal("item_selected", index)
	_bypassing_intercept = false


func _sync_clone_list() -> void:
	# No-op: clone list approach removed, using click interceptor instead.
	# _apply_missing_status_to_list handles badge/disable on _item_list directly.
	pass

func _apply_missing_status_to_list(set_key: String) -> void:
	if not is_instance_valid(_item_list): return
	if _orange_badge == null:
		_orange_badge = _make_orange_badge(12)
	# Iterate backwards so removal doesn't shift indices
	for i in range(_item_list.get_item_count() - 1, -1, -1):
		var name = _item_list.get_item_text(i)
		if name == "": continue
		var status = _get_prefab_asset_status(name, set_key)
		match status:
			"all_missing", "partial":
				# Remove from list - any missing asset means the prefab is incomplete
				_item_list.remove_item(i)
			"ok":
				_item_list.set_item_disabled(i, false)


func _check_prefab_missing_assets(index: int) -> Array:
	# Returns a list of missing resource paths for the prefab at the given index.
	if not is_instance_valid(_item_list): return []
	# Always use text (not tooltip) -- tooltip may be modified by _apply_missing_status_to_list
	var prefab_name = _item_list.get_item_text(index)
	if prefab_name == "": return []
	var prefab_key = prefab_name.to_lower()
	var set_key = _find_set_key(_current_set_name)
	if set_key == "": return []
	if not _prefab_index.has(set_key): return []
	var files = _prefab_index[set_key]
	if not files.has(prefab_key): return []
	var path = files[prefab_key]
	var file = File.new()
	if file.open(path, File.READ) != OK: return []
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	if parsed.error != OK or not (parsed.result is Dictionary): return []
	var data = parsed.result
	var missing = []
	_collect_missing(data.get("objects", []), "texture", missing)
	_collect_missing(data.get("pattern_shapes", []), "texture", missing)
	_collect_missing(data.get("pathways", []), "texture", missing)
	_collect_missing(data.get("walls", []), "texture", missing)
	return missing


func _get_prefab_asset_status(prefab_name: String, set_key: String) -> String:
	# Returns "ok", "partial", or "all_missing" for the given prefab.
	var cache_key = set_key + "/" + prefab_name.to_lower()
	if _missing_status_cache.has(cache_key):
		return _missing_status_cache[cache_key]
	if not _prefab_index.has(set_key): return "ok"
	var files = _prefab_index[set_key]
	var prefab_key = prefab_name.to_lower()
	if not files.has(prefab_key): return "ok"
	var path = files[prefab_key]
	var file = File.new()
	if file.open(path, File.READ) != OK: return "ok"
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	if parsed.error != OK or not (parsed.result is Dictionary): return "ok"
	var data = parsed.result
	var counts = {"total_custom": 0, "missing_custom": 0, "total_vanilla": 0}
	_count_assets(data.get("objects", []), "texture", counts)
	_count_assets(data.get("pattern_shapes", []), "texture", counts)
	_count_assets(data.get("pathways", []), "texture", counts)
	_count_assets(data.get("walls", []), "texture", counts)
	var status = "ok"
	var total_all = counts["total_custom"] + counts["total_vanilla"]
	# all_missing: every asset in the prefab is missing (no asset can be placed)
	if total_all > 0 and counts["missing_custom"] == total_all:
		status = "all_missing"
	elif counts["missing_custom"] > 0:
		status = "partial"
	_missing_status_cache[cache_key] = status
	return status


func _get_loaded_pack_ids() -> Dictionary:
	var result = {}
	if _g.Header == null: return result
	if not ("AssetManifest" in _g.Header): return result
	var manifest = _g.Header.AssetManifest
	if manifest == null: return result
	for entry in manifest:
		var pid = entry.ID
		if pid != null and pid != "": result[pid] = true
	return result


func _pack_id_from_path(res_path: String) -> String:
	if res_path.begins_with("res://packs/"):
		var after = res_path.substr(len("res://packs/"))
		var slash = after.find("/")
		if slash > 0: return after.substr(0, slash)
	elif res_path.begins_with("user://packs/"):
		var after = res_path.substr(len("user://packs/"))
		var slash = after.find("/")
		if slash > 0: return after.substr(0, slash)
	return ""


func _are_default_assets_enabled() -> bool:
	if _g.Header == null: return true  # assume enabled if unknown
	var uses = _g.Header.get("UsesDefaultAssets")
	if uses == null: return true
	return bool(uses)


func _count_assets(items: Array, key: String, counts: Dictionary) -> void:
	var loaded = _get_loaded_pack_ids()
	var default_enabled = _are_default_assets_enabled()
	for item in items:
		var res_path = item.get(key, "")
		if res_path == "": continue
		if res_path.begins_with("res://packs/") or res_path.begins_with("user://packs/"):
			var pid = _pack_id_from_path(res_path)
			counts["total_custom"] += 1
			if pid == "" or not loaded.has(pid):
				counts["missing_custom"] += 1
		else:
			# Vanilla asset (res://textures/)
			counts["total_vanilla"] += 1
			if not default_enabled:
				counts["missing_custom"] += 1


func _make_orange_badge(size: int) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var cx = size / 2.0
	var cy = size / 2.0
	var r = size / 2.0 - 1
	for y in range(size):
		for x in range(size):
			var dx = x - cx
			var dy = y - cy
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, Color(1.0, 0.55, 0.0, 1.0))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _apply_badge_to_thumbnail(base_tex: Texture, badge_tex: Texture) -> ImageTexture:
	if base_tex == null: return null
	var base_img = base_tex.get_data()
	if base_img == null: return null
	base_img = base_img.duplicate()
	base_img.lock()
	var badge_img = badge_tex.get_data()
	badge_img.lock()
	var bw = badge_img.get_width()
	var bh = badge_img.get_height()
	var ox = base_img.get_width() - bw - 2
	var oy = base_img.get_height() - bh - 2
	for y in range(bh):
		for x in range(bw):
			var bc = badge_img.get_pixel(x, y)
			if bc.a > 0.01:
				base_img.set_pixel(ox + x, oy + y, bc)
	badge_img.unlock()
	base_img.unlock()
	var out = ImageTexture.new()
	out.create_from_image(base_img)
	return out


func _collect_missing(items: Array, key: String, out: Array) -> void:
	var loaded = _get_loaded_pack_ids()
	var default_enabled = _are_default_assets_enabled()
	for item in items:
		var res_path = item.get(key, "")
		if res_path == "": continue
		if res_path.begins_with("res://packs/") or res_path.begins_with("user://packs/"):
			var pid = _pack_id_from_path(res_path)
			if pid == "" or not loaded.has(pid):
				if not out.has(res_path):
					out.append(res_path)
		else:
			if not default_enabled:
				if not out.has(res_path):
					out.append(res_path)


func _can_load_file(res_path: String) -> bool:
	var f = File.new()
	return f.file_exists(res_path)


func _show_missing_assets_dialog(prefab_name: String, missing: Array, index: int, reconnect: Array) -> void:
	if _missing_assets_dialog != null and is_instance_valid(_missing_assets_dialog):
		_missing_assets_dialog.queue_free()

	# Extract unique pack names from missing paths
	# e.g. "res://packs/PACKID/objects/foo.png" -> "PACKID"
	var packs = []
	for res_path in missing:
		var pack_id = ""
		if res_path.begins_with("res://packs/"):
			var after = res_path.substr(len("res://packs/"))
			var slash = after.find("/")
			if slash > 0: pack_id = after.substr(0, slash)
		elif res_path.begins_with("user://packs/"):
			var after = res_path.substr(len("user://packs/"))
			var slash = after.find("/")
			if slash > 0: pack_id = after.substr(0, slash)
		if pack_id != "" and not packs.has(pack_id):
			packs.append(pack_id)

	var pack_list = PoolStringArray(packs).join("\n") if packs.size() > 0 else str(missing.size()) + " missing assets"
	var msg = "Prefab '" + prefab_name + "' requires asset pack(s) not loaded:\n\n" + pack_list + "\n\nLoad the required packs and try again, or place with missing assets (prefab link will be lost)."

	# Build a fully custom WindowDialog so we have complete control over layout.
	var dlg = WindowDialog.new()
	dlg.window_title = "Missing Asset Packs"
	dlg.rect_min_size = Vector2(440, 270)
	dlg.popup_exclusive = true
	dlg.resizable = false

	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -8
	vbox.add_constant_override("separation", 8)
	dlg.add_child(vbox)

	var lbl = Label.new()
	lbl.text = msg
	lbl.align = Label.ALIGN_CENTER
	lbl.autowrap = true
	lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(lbl)

	var check = CheckBox.new()
	check.name = "MissingAssetsRemember"
	check.text = "Remember for this session"
	check.pressed = false
	vbox.add_child(check)

	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGN_CENTER
	hbox.add_constant_override("separation", 16)
	vbox.add_child(hbox)

	var btn_place = Button.new()
	btn_place.text = "Place Anyway"
	btn_place.rect_min_size = Vector2(130, 0)
	hbox.add_child(btn_place)

	var btn_skip = Button.new()
	btn_skip.text = "Skip Prefab"
	btn_skip.rect_min_size = Vector2(130, 0)
	hbox.add_child(btn_skip)

	_add_missing_dialog(dlg)
	dlg.popup_centered()
	_missing_assets_dialog = dlg

	btn_place.connect("pressed", self, "_on_missing_place_anyway", [index, check, dlg])
	btn_skip.connect("pressed", self, "_on_missing_skip", [index, check, dlg])
	dlg.connect("popup_hide", self, "_on_missing_dialog_hidden", [dlg])
	_deferred_style_missing(dlg)


func _on_missing_place_anyway(index: int, check, dlg) -> void:
	if is_instance_valid(check) and check.pressed:
		_session_missing_choice = true
	_missing_dialog_done = true
	if is_instance_valid(dlg): dlg.hide()
	_call_dd_via_original(index)
	_missing_assets_dialog = null


func _on_missing_skip(index: int, check, dlg) -> void:
	if is_instance_valid(check) and check.pressed:
		_session_missing_choice = false
	if is_instance_valid(_item_list): _item_list.unselect_all()
	if is_instance_valid(_clone_list): _clone_list.unselect_all()
	_missing_dialog_done = true
	if is_instance_valid(dlg): dlg.hide()
	_missing_assets_dialog = null


func _on_missing_dialog_hidden(dlg) -> void:
	if is_instance_valid(dlg): dlg.call_deferred("queue_free")
	_missing_dialog_done = false


var _missing_dialog_done := false



func _add_missing_dialog(dialog: Node) -> void:
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_panel.get_tree().root.add_child(dialog)


func _deferred_style_missing(dialog: Node) -> void:
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_missing_dialog", [dialog, timer])
	_panel.get_tree().root.add_child(timer)
	timer.start()


func _style_missing_dialog(dialog: Node, timer: Timer) -> void:
	timer.queue_free()
	if not is_instance_valid(dialog): return
	# Style buttons (same as save_reminder)
	for child in dialog.get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is HBoxContainer:
					for btn in sub.get_children():
						if btn is Button:
							var existing = btn.get_stylebox("normal")
							if existing != null and existing is StyleBoxFlat:
								var style = existing.duplicate()
								style.border_color = Color(0.6, 0.6, 0.6, 0.7)
								style.set_border_width_all(1)
								style.content_margin_left = 20
								style.content_margin_right = 20
								btn.add_stylebox_override("normal", style)


func _find_first_child(node: Node, class_name_str: String) -> Node:
	for child in node.get_children():
		if child.get_class() == class_name_str: return child
		var found = _find_first_child(child, class_name_str)
		if found != null: return found
	return null


func _reconnect_item_selected(connections: Array) -> void:
	if not is_instance_valid(_item_list): return
	for conn in connections:
		if not is_instance_valid(conn.target): continue
		if not _item_list.is_connected("item_selected", conn.target, conn.method):
			_item_list.connect("item_selected", conn.target, conn.method)


func _get_popup_layer() -> CanvasLayer:
	var tree = _panel.get_tree()
	if tree == null:
		return null
	for child in tree.root.get_children():
		if child is CanvasLayer and child.name == "PrefabsThumbsPopupLayer":
			return child
	var layer = CanvasLayer.new()
	layer.name = "PrefabsThumbsPopupLayer"
	layer.layer = 128
	tree.root.add_child(layer)
	return layer


func _scroll_to_selected() -> void:
	if not (_item_list is ItemList):
		return
	var selected = _item_list.get_selected_items()
	if selected.size() == 0:
		return
	_scroll_list_to_item(_item_list, selected[0])


func _scroll_list_to_item(item_list: ItemList, idx: int) -> void:
	var vbar = null
	for child in item_list.get_children():
		if child is VScrollBar:
			vbar = child
			break
	if vbar == null:
		return
	var item_count = item_list.get_item_count()
	if item_count <= 0:
		return
	var max_scroll = vbar.max_value - vbar.page
	if max_scroll <= 0:
		return
	var ratio = float(idx) / float(item_count)
	var target = ratio * vbar.max_value - vbar.page * 0.5
	vbar.value = clamp(target, 0.0, max_scroll)





func _save_mode() -> void:
	var data = {"default_mode": _display_mode}
	var file = File.new()
	if file.open(PREFS_PATH, File.WRITE) == OK:
		file.store_string(JSON.print(data))
		file.close()


func _load_prefs() -> void:
	var file = File.new()
	if not file.file_exists(PREFS_PATH):
		return
	if file.open(PREFS_PATH, File.READ) == OK:
		var text = file.get_as_text()
		file.close()
		var parsed = JSON.parse(text)
		if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
			var data = parsed.result
			if data.has("default_mode"):
				_display_mode = int(data["default_mode"])
				print("[PrefabsThumbs] Mode par defaut charge: %d" % _display_mode)


func _update_mode_buttons() -> void:
	if _mode_toolbar == null:
		return
	for btn in _mode_toolbar.get_children():
		if btn is Button:
			btn.pressed = (btn.get_meta("mode") == _display_mode)


func _find_set_key(set_name: String) -> String:
	var name_lower = set_name.to_lower()
	for key in _prefab_index.keys():
		if key.to_lower() == name_lower:
			return key
	return ""


func _generate_thumbnail(set_key: String, prefab_name: String, thumb_size: int = THUMB_SIZE):
	if set_key == "" or not _prefab_index.has(set_key):
		yield(_panel.get_tree(), "idle_frame")
		return null
	var files = _prefab_index[set_key]
	if not files.has(prefab_name):
		yield(_panel.get_tree(), "idle_frame")
		return null
	var path = files[prefab_name]
	var file = File.new()
	if file.open(path, File.READ) != OK:
		yield(_panel.get_tree(), "idle_frame")
		return null
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	if parsed.error != OK or not (parsed.result is Dictionary):
		yield(_panel.get_tree(), "idle_frame")
		return null
	var tex = yield(_render_prefab_data(parsed.result, thumb_size), "completed")
	return tex


func _render_prefab_data(data: Dictionary, thumb_size: int = THUMB_SIZE):
	var all_bb = []
	_collect_bb_objects(data.get("objects", []), all_bb)
	_collect_bb_shapes(data.get("pattern_shapes", []), all_bb)
	_collect_bb_paths(data.get("pathways", []), all_bb)
	_collect_bb_roofs(data.get("roofs", []), all_bb)

	if all_bb.size() == 0:
		yield(_panel.get_tree(), "idle_frame")
		return null

	var min_pos = Vector2(INF, INF)
	var max_pos = Vector2(-INF, -INF)
	for p in all_bb:
		if p.x < min_pos.x: min_pos.x = p.x
		if p.y < min_pos.y: min_pos.y = p.y
		if p.x > max_pos.x: max_pos.x = p.x
		if p.y > max_pos.y: max_pos.y = p.y

	var bb = max_pos - min_pos
	if bb.x < 1: bb.x = 1
	if bb.y < 1: bb.y = 1
	# Mode adaptatif (thumb_size=-1) : respecter le ratio bounding box
	var vp_w : int
	var vp_h : int
	var sf : float
	if thumb_size < 0:
		var max_dim = float(-thumb_size)
		sf = min(max_dim / bb.x, max_dim / bb.y) * 0.95
		vp_w = int(bb.x * sf / 0.95) + 4
		vp_h = int(bb.y * sf / 0.95) + 4
	else:
		sf = min(float(thumb_size) / bb.x, float(thumb_size) / bb.y) * 0.95
		vp_w = thumb_size
		vp_h = thumb_size
	var offset = -min_pos * sf + (Vector2(vp_w, vp_h) - bb * sf) * 0.5

	var vp = Viewport.new()
	vp.size = Vector2(vp_w, vp_h)
	vp.usage = Viewport.USAGE_2D
	vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	vp.transparent_bg = true
	vp.render_target_v_flip = true
	if _vp_holder == null or not is_instance_valid(_vp_holder):
		vp.queue_free()
		return null
	_vp_holder.add_child(vp)
	yield(_vp_holder.get_tree(), "idle_frame")
	if not is_instance_valid(vp):
		return null

	var nodes_with_layer = []
	_build_shape_nodes(data.get("pattern_shapes", []), sf, offset, nodes_with_layer)
	_build_path_nodes(data.get("pathways", []), sf, offset, nodes_with_layer)
	_build_object_nodes(data.get("objects", []), sf, offset, nodes_with_layer)
	_build_roof_nodes(data.get("roofs", []), sf, offset, nodes_with_layer)
	nodes_with_layer.sort_custom(self, "_sort_by_layer")
	for entry in nodes_with_layer:
		vp.add_child(entry["node"])

	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	for _i in range(4):
		if _vp_holder == null or not is_instance_valid(_vp_holder) or not is_instance_valid(vp):
			if is_instance_valid(vp):
				vp.queue_free()
			return null
		yield(_vp_holder.get_tree(), "idle_frame")

	if not is_instance_valid(vp):
		return null
	var img = vp.get_texture().get_data()
	for child in vp.get_children():
		if is_instance_valid(child):
			child.queue_free()
	vp.queue_free()

	if img == null:
		return null
	if thumb_size >= 0:
		img.resize(thumb_size, thumb_size, Image.INTERPOLATE_LANCZOS)
	# Mode adaptatif : pas de resize, garder les proportions naturelles
	var result = ImageTexture.new()
	result.create_from_image(img)
	return result


func _collect_bb_objects(objects: Array, out: Array) -> void:
	for obj in objects:
		var tex = _safe_load_texture(obj.get("texture", ""))
		if tex == null:
			continue
		var pos = _parse_vector2(obj.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(obj.get("scale", "Vector2( 1, 1 )"))
		var r = max(tex.get_width() * abs(scale.x), tex.get_height() * abs(scale.y)) * 0.5
		out.append(pos + Vector2(-r, -r))
		out.append(pos + Vector2(r, r))


func _collect_bb_shapes(shapes: Array, out: Array) -> void:
	for shape in shapes:
		var origin = _parse_vector2(shape.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(shape.get("scale", "Vector2( 1, 1 )"))
		var rot = float(shape.get("shape_rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		# Doit matcher la formule de _build_shape_nodes : world = origin + rotate(p * scale)
		# sinon BB fausse pour les patterns rotated/resized -> mauvais centrage
		for p in _parse_pool_vector2(shape.get("points", "")):
			var s = p * scale
			out.append(origin + Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs))


func _collect_bb_paths(paths: Array, out: Array) -> void:
	for path in paths:
		var origin = _parse_vector2(path.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(path.get("scale", "Vector2( 1, 1 )"))
		var rot = float(path.get("rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		# Plafonner le padding width a 64 pour eviter que les grands paths (ex: shadow width=396)
		# ne decalent massivement le bounding box
		var w = min(float(path.get("width", 32)) * 0.5, 64.0)
		for p in _parse_pool_vector2(path.get("edit_points", "")):
			var s = p * scale
			var world = origin + Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs)
			out.append(world + Vector2(-w, -w))
			out.append(world + Vector2(w, w))


func _build_object_nodes(objects: Array, sf: float, offset: Vector2, out: Array) -> void:
	for i in range(objects.size()):
		var obj = objects[i]
		var tex = _safe_load_texture(obj.get("texture", ""))
		if tex == null:
			continue
		var sprite = Sprite.new()
		sprite.texture = tex
		sprite.position = _parse_vector2(obj.get("position", "Vector2( 0, 0 )")) * sf + offset
		# Le mirror est gere via flip_h/flip_v (flip UV) plutot que scale negatif
		# (flip geometrique). DD utilise des flips UV, et bien que mathematiquement
		# equivalents, Godot peut produire des artefacts visuels avec scale
		# negatif (culling, ordre d'application des transforms). On force scale
		# a abs() et on applique le flip via les proprietes du Sprite :
		# - mirror=true OU scale.x<0 -> flip_h (flip horizontal)
		# - scale.y<0 -> flip_v (flip vertical)
		# Important : traiter scale.y<0 comme flip_h donnait une rotation 180°
		# parasite (flip_h + flip_v = rotation 180°), ce qui rendait certains
		# sprites a l'envers dans les thumbnails.
		var raw_scale = _parse_vector2(obj.get("scale", "Vector2( 1, 1 )"))
		var flip_h = bool(obj.get("mirror", false)) or raw_scale.x < 0.0
		var flip_v = raw_scale.y < 0.0
		sprite.scale = Vector2(abs(raw_scale.x), abs(raw_scale.y)) * sf
		sprite.flip_h = flip_h
		sprite.flip_v = flip_v
		sprite.rotation = float(obj.get("rotation", 0))
		var color_hex = obj.get("custom_color", "")
		if color_hex != "":
			var mat = ShaderMaterial.new()
			mat.shader = _make_recolor_shader()
			mat.set_shader_param("tint_r", _parse_color(color_hex))
			sprite.material = mat
		out.append({"node": sprite, "layer": int(obj.get("layer", 100)), "category": 2, "src_idx": i})


func _build_shape_nodes(shapes: Array, sf: float, offset: Vector2, out: Array) -> void:
	for i in range(shapes.size()):
		var shape = shapes[i]
		var origin = _parse_vector2(shape.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(shape.get("scale", "Vector2( 1, 1 )"))
		var rot = float(shape.get("shape_rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		var points = _parse_pool_vector2(shape.get("points", ""))
		if points.size() < 3:
			continue
		var poly = Polygon2D.new()
		var transformed = PoolVector2Array()
		for p in points:
			# Appliquer scale puis rotation autour de l'origin, puis transformer en viewport
			var s = p * scale
			var rotated = Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs)
			transformed.append((origin + rotated) * sf + offset)
		poly.polygon = transformed
		poly.color = _parse_color(shape.get("color", "ffffffff"))
		var tex = _safe_load_texture(shape.get("texture", ""))
		if tex != null:
			poly.texture = tex
			# texture_scale en world units : taille texture / (scale monde * sf)
			# Les vertices sont en espace viewport (world * sf)
			# Pour que la texture tile a la meme frequence qu'en world space :
			# texture_scale = tex_size * sf
			poly.texture_scale = Vector2(18.0, 18.0)
		out.append({"node": poly, "layer": int(shape.get("layer", 100)), "category": 0, "src_idx": i})
		# Si outline activee, ajouter un Line2D ferme par-dessus avec la texture
		# d'outline tilable (default_border.png). Meme layer/categorie que le
		# poly mais src_idx superieur pour qu'il soit dessine au-dessus.
		if bool(shape.get("outline", false)):
			var outline_tex = _get_outline_texture()
			if outline_tex != null and transformed.size() >= 2:
				var line = Line2D.new()
				var pts = PoolVector2Array()
				for p in transformed:
					pts.append(p)
				# Fermer la boucle
				pts.append(transformed[0])
				line.points = pts
				line.texture = outline_tex
				line.texture_mode = Line2D.LINE_TEXTURE_TILE
				line.width = 6.0 * sf
				line.default_color = Color(1, 1, 1, 1)
				out.append({"node": line, "layer": int(shape.get("layer", 100)), "category": 0, "src_idx": i + 10000})


func _get_outline_texture() -> Texture:
	# Charge paresseusement default_border.png depuis res:///.import comme
	# pattern_fix.gd. La texture est tilable et destinee a etre utilisee comme
	# bordure de PatternShape (Line2D.LINE_TEXTURE_TILE).
	if _cached_outline_texture != null:
		return _cached_outline_texture
	var candidates = ["default_border.png", "narrow_line.png", "thick_line.png"]
	var stex_path = _find_outline_stex("res:///.import", candidates)
	if stex_path != "":
		var t = ResourceLoader.load(stex_path, "StreamTexture")
		if t != null:
			_cached_outline_texture = t
			return t
	return null


func _find_outline_stex(import_dir: String, prefixes: Array) -> String:
	var dir = Directory.new()
	if dir.open(import_dir) != OK:
		return ""
	if dir.list_dir_begin(true, true) != OK:
		return ""
	var entry = dir.get_next()
	while entry != "":
		for prefix in prefixes:
			if entry.begins_with(prefix + "-") and entry.ends_with(".stex"):
				dir.list_dir_end()
				return import_dir + "/" + entry
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


func _build_path_nodes(paths: Array, sf: float, offset: Vector2, out: Array) -> void:
	for i in range(paths.size()):
		var path = paths[i]
		var origin = _parse_vector2(path.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(path.get("scale", "Vector2( 1, 1 )"))
		var rot = float(path.get("rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		var points = _parse_pool_vector2(path.get("edit_points", ""))
		if points.size() < 2:
			continue
		var line = Line2D.new()
		var pts = PoolVector2Array()
		for p in points:
			var s = p * scale
			var rotated = Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs)
			pts.append((origin + rotated) * sf + offset)
		line.points = pts
		line.width = float(path.get("width", 32)) * sf
		var tex = _safe_load_texture(path.get("texture", ""))
		var path_color = _parse_color(path.get("custom_color", "ffffffff"))
		line.default_color = path_color
		if tex != null:
			line.texture = tex
			line.texture_mode = Line2D.LINE_TEXTURE_TILE
			line.modulate = path_color
		out.append({"node": line, "layer": int(path.get("layer", 100)), "category": 1, "src_idx": i})


func _build_roof_nodes(roofs: Array, sf: float, offset: Vector2, out: Array) -> void:
	# Un roof est defini par une ligne de crete (`points`) extrudee
	# perpendiculairement de `width` unites *de chaque cote* (total = 2 * width),
	# selon l'observation visuelle du rendu DD. On construit un Polygon2D qui
	# suit la perpendiculaire moyennee aux jointures pour gerer correctement les
	# ridges en plusieurs segments (toitures non droites). Pas de champ `layer`
	# dans le JSON : on utilise une categorie dediee (3) pour rendre les roofs
	# au-dessus de tout le reste.
	for i in range(roofs.size()):
		var roof = roofs[i]
		var origin = _parse_vector2(roof.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(roof.get("scale", "Vector2( 1, 1 )"))
		var rot = float(roof.get("rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		var points = _parse_pool_vector2(roof.get("points", ""))
		if points.size() < 2:
			continue
		# Ridge en espace viewport
		var ridge = PoolVector2Array()
		for p in points:
			var s = p * scale
			var rotated = Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs)
			ridge.append((origin + rotated) * sf + offset)
		var extrusion = float(roof.get("width", 320)) * sf
		# Bords haut et bas : on calcule la perpendiculaire a chaque point
		# (moyennee aux jointures pour eviter les pics aux coins)
		var top_pts = PoolVector2Array()
		var bot_pts = PoolVector2Array()
		for j in range(ridge.size()):
			var perp: Vector2
			if j == 0:
				var d0 = (ridge[1] - ridge[0]).normalized()
				perp = Vector2(-d0.y, d0.x)
			elif j == ridge.size() - 1:
				var dN = (ridge[j] - ridge[j-1]).normalized()
				perp = Vector2(-dN.y, dN.x)
			else:
				var d1 = (ridge[j] - ridge[j-1]).normalized()
				var d2 = (ridge[j+1] - ridge[j]).normalized()
				var p1 = Vector2(-d1.y, d1.x)
				var p2 = Vector2(-d2.y, d2.x)
				var avg = p1 + p2
				if avg.length() > 0.001:
					perp = avg.normalized()
				else:
					perp = p1
			top_pts.append(ridge[j] + perp * extrusion)
			bot_pts.append(ridge[j] - perp * extrusion)
		# Polygon ferme : top forward + bottom backward
		var poly_pts = PoolVector2Array()
		for p in top_pts:
			poly_pts.append(p)
		for k in range(bot_pts.size() - 1, -1, -1):
			poly_pts.append(bot_pts[k])
		var poly = Polygon2D.new()
		poly.polygon = poly_pts
		var tex = _safe_load_texture(roof.get("texture", ""))
		if tex != null:
			poly.texture = tex
			poly.texture_scale = Vector2(18.0, 18.0)
		poly.color = Color(1, 1, 1, 1)
		# Categorie 3 : rendu apres objects (qui sont en 2) pour matcher DD ou
		# les roofs sont au-dessus du reste de la scene.
		out.append({"node": poly, "layer": 1000, "category": 3, "src_idx": i})


func _collect_bb_roofs(roofs: Array, out: Array) -> void:
	for roof in roofs:
		var origin = _parse_vector2(roof.get("position", "Vector2( 0, 0 )"))
		var scale = _parse_vector2(roof.get("scale", "Vector2( 1, 1 )"))
		var rot = float(roof.get("rotation", 0))
		var cs = cos(rot)
		var sn = sin(rot)
		# Marge = `width` sur chaque cote (extrusion totale = 2 * width).
		# Plafond a 320 pour eviter qu'un roof tres large ne decale le BB.
		var w = min(float(roof.get("width", 320)), 320.0)
		for p in _parse_pool_vector2(roof.get("points", "")):
			var s = p * scale
			var world = origin + Vector2(s.x * cs - s.y * sn, s.x * sn + s.y * cs)
			out.append(world + Vector2(-w, -w))
			out.append(world + Vector2(w, w))


func _sort_by_layer(a: Dictionary, b: Dictionary) -> bool:
	# Tri primaire par layer (croissant), puis par categorie pour matcher
	# l'ordre de rendu DD a layer egal : pattern (0) < path (1) < object (2).
	# Tie-break final : ordre source JSON (premier object dans le JSON = dessine
	# en premier = au-dessous). C'est l'ordre naturel d'ajout des enfants a un
	# Node2D Godot, et il correspond a ce que DD affiche en placement.
	# Necessaire car sort_custom de Godot 3 n'est pas stable.
	if a["layer"] != b["layer"]:
		return a["layer"] < b["layer"]
	if a["category"] != b["category"]:
		return a["category"] < b["category"]
	return a["src_idx"] < b["src_idx"]


func _safe_load_texture(res_path: String) -> Texture:
	if res_path == "":
		return null
	# Paths vanilla (res://textures/) : on passe EXCLUSIVEMENT par ResourceLoader,
	# qui lit le .stex compile via le systeme d'import. Image.load tenterait de
	# lire le PNG brut, qui n'est PAS inclus dans data.pck (seul le .stex l'est) :
	# cela genere un flot d'erreurs ImageLoader::load_image impossibles a
	# intercepter depuis GDScript.
	if res_path.begins_with("res://textures/"):
		if ResourceLoader.exists(res_path):
			return ResourceLoader.load(res_path, "Texture", true)
		return null
	# Paths de packs (res://packs/, user://packs/) : ces textures sont mountees
	# via load_packed SANS metadata d'import. Image.load lit le fichier brut.
	var lower = res_path.to_lower()
	if lower.ends_with(".webp") or lower.ends_with(".png") \
			or lower.ends_with(".jpg") or lower.ends_with(".jpeg") \
			or lower.ends_with(".bmp") or lower.ends_with(".tga"):
		var img = Image.new()
		if img.load(res_path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img)
			return tex
		# Fall through au ResourceLoader si Image.load echoue
	if ResourceLoader.exists(res_path):
		return ResourceLoader.load(res_path, "Texture", true)
	return null


func _get_custom_assets_dir() -> String:
	if _custom_assets_dir_loaded:
		return _custom_assets_dir_cache
	_custom_assets_dir_loaded = true
	var f = File.new()
	if f.open("user://config.ini", File.READ) != OK:
		return ""
	for line in f.get_as_text().split("\n"):
		line = line.strip_edges()
		if line.begins_with("custom_assets_directory="):
			var val = line.substr(len("custom_assets_directory=")).strip_edges()
			if val.begins_with("\"") and val.ends_with("\""):
				val = val.substr(1, val.length() - 2)
			val = val.replace("\\\\", "/").replace("\\", "/")
			_custom_assets_dir_cache = val
			break
	f.close()
	return _custom_assets_dir_cache


func _make_recolor_shader() -> Shader:
	if _recolor_shader == null:
		_recolor_shader = Shader.new()
		_recolor_shader.code = RECOLOR_SHADER
	return _recolor_shader


func _parse_color(hex: String) -> Color:
	if hex.length() == 8:
		var a = ("0x" + hex.substr(0, 2)).hex_to_int() / 255.0
		var r = ("0x" + hex.substr(2, 2)).hex_to_int() / 255.0
		var g = ("0x" + hex.substr(4, 2)).hex_to_int() / 255.0
		var b = ("0x" + hex.substr(6, 2)).hex_to_int() / 255.0
		return Color(r, g, b, a)
	return Color.white


func _parse_pool_vector2(s: String) -> Array:
	var clean = s.replace("PoolVector2Array(", "").replace(")", "").strip_edges()
	if clean == "":
		return []
	var nums = clean.split(",")
	var result = []
	var i = 0
	while i + 1 < nums.size():
		result.append(Vector2(float(nums[i].strip_edges()), float(nums[i+1].strip_edges())))
		i += 2
	return result


func _parse_vector2(s: String) -> Vector2:
	var clean = s.replace("Vector2(", "").replace(")", "").replace(" ", "")
	var parts = clean.split(",")
	if parts.size() >= 2:
		return Vector2(float(parts[0]), float(parts[1]))
	return Vector2.ZERO
