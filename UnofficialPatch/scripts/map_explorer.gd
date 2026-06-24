# map_explorer.gd
# Sub-mod for UnofficialPatch -- Map Explorer with Thumbnails

var _g

const THUMB_SIZE = 500  # Max thumbnail size for storage
const THUMB_ASPECT = 16.0 / 9.0  # Forced thumbnail aspect ratio (16:9)
const DATA_DIR = "user://UnofficialPatch/map_explorer/"
const INDEX_FILE = "user://UnofficialPatch/map_explorer/index.json"
const THUMB_DIR = "user://UnofficialPatch/map_explorer/thumbnails/"
const PREFS_FILE = "user://UnofficialPatch/map_explorer/prefs.json"

var _map_index := {}
var _explorer_window = null
var _grid_container = null
var _scroll_container = null
var _search_bar = null
var _sort_option = null
var _hide_missing_checkbox = null
var _open_btn = null
var _delete_btn = null
var _delete_all_missing_btn = null
var _view_packs_btn = null
var _size_btn_small = null
var _size_btn_med = null
var _size_btn_max = null
var _maps_counter_label = null
var _fav_icon_on : Texture = null
var _fav_icon_off : Texture = null
var _fav_icon_hover : Texture = null  # fav2.png for hover effect
var _favorites := {}  # map_id -> true
var _show_favorites_only := false
var _favorites_btn = null
var _view_mode := "grid"  # "grid" or "list"
var _view_grid_btn = null
var _view_list_btn = null
var _list_container = null
var _hide_info := false  # Hide name, size, date on cards
var _hide_info_btn = null
var _save_connected := false
var _pending_thumbnail := false
var _menu_button_added := false
var _destroyed := false
var _trash_icon : Texture = null
var _trash_icon_small : Texture = null
var _size_small_icon : Texture = null
var _size_med_icon : Texture = null
var _size_max_icon : Texture = null
var _grid_icon : Texture = null
var _list_icon : Texture = null

# Layout containers for adaptive resize
var _toolbar_row1 = null
var _toolbar_row2 = null
var _toolbar_vbox = null
var _search_row = null
var _footer_row = null
var _is_compact_mode := false

# Window size constants
const WINDOW_DEFAULT_SIZE := Vector2(1472, 820)
const WINDOW_MIN_SIZE := Vector2(1089, 550)
const COMPACT_THRESHOLD := 1200  # Width below which toolbar wraps

const SORT_DATE_DESC = 0
const SORT_DATE_ASC = 1
const SORT_NAME_ASC = 2
const SORT_NAME_DESC = 3
const SORT_CUSTOM = 4

# List view column sorts
const SORT_FAV_DESC = 10
const SORT_FAV_ASC = 11
const SORT_SIZE_DESC = 12
const SORT_SIZE_ASC = 13
const SORT_PACKS_DESC = 14
const SORT_PACKS_ASC = 15
const SORT_DEFAULT_DESC = 16
const SORT_DEFAULT_ASC = 17

var _current_sort := SORT_DATE_DESC
var _list_sort_column := ""  # Current column being sorted in list view
var _list_sort_asc := false  # Sort direction for list view
var _current_search := ""
var _hide_missing := false
var _selected_map_ids := []  # Array of selected map IDs
var _selected_cards := {}    # map_id -> card/panel reference
var _last_selected_id := ""  # For shift-click range selection
var _filtered_ids_order := []  # Current display order for shift-select
var _preview_size := 200  # Current display size (100, 200, 400)

# Manual drag and drop
var _dragging := false
var _drag_map_id := ""
var _drag_start_pos := Vector2.ZERO
var _drag_preview_node = null
const DRAG_THRESHOLD := 10.0  # Minimum distance to start drag

# Folders
var _folders := ["All"]  # List of folder names, "All" is always first
var _current_folder := "All"  # Current folder filter
var _folder_list_container = null  # Container for folder buttons in sidebar
var _assign_folder_btn = null

# Window position/size memory
var _window_size := WINDOW_DEFAULT_SIZE
var _window_pos := Vector2(-1, -1)  # -1 means centered

# Double-click detection
var _last_click_time := 0
var _last_click_map_id := ""
const DOUBLE_CLICK_TIME := 400  # ms


func initialize() -> void:
	_ensure_directories()
	_load_index()
	_load_prefs()
	_load_icons()
	_hook_save_button()
	call_deferred("_add_menu_button")
	print("[MapExplorer] Initialized — %d maps indexed" % _map_index.size())


func cleanup() -> void:
	_destroyed = true
	# Disconnect save button
	if _g != null and _g.Editor != null:
		var save_btn = _g.Editor.get("saveButton")
		if save_btn != null and is_instance_valid(save_btn):
			if save_btn.is_connected("pressed", self, "_on_save_pressed"):
				save_btn.disconnect("pressed", self, "_on_save_pressed")
		# Remove menu item + separator we added
		var menu_btn = _g.Editor.get("menuButton")
		if menu_btn != null:
			var popup = menu_btn.get_popup()
			if popup != null:
				var idx = -1
				for i in popup.get_item_count():
					if popup.get_item_text(i) == "Map Gallery":
						idx = i
						break
				if idx >= 0:
					popup.remove_item(idx)
					if idx > 0 and popup.is_item_separator(idx - 1):
						popup.remove_item(idx - 1)
				if popup.is_connected("id_pressed", self, "_on_menu_item_pressed"):
					popup.disconnect("id_pressed", self, "_on_menu_item_pressed")
	# Free explorer window if any
	if _explorer_window != null and is_instance_valid(_explorer_window):
		_explorer_window.queue_free()
	_explorer_window = null
	_save_connected = false
	_menu_button_added = false
	print("[MapExplorer] Cleaned up")


func update(_delta: float) -> void:
	if _destroyed:
		return
	if _pending_thumbnail:
		_pending_thumbnail = false
		call_deferred("_generate_thumbnail_after_save")
	if not _save_connected:
		_hook_save_button()
	if not _menu_button_added:
		_add_menu_button()


func _load_icons() -> void:
	# Try multiple paths for trash icon
	var paths_to_try = [
		_g.Root + "icons/trash.png",
		_g.Root + "icones/trash.png",
		"res://ui/icons/trash.png",
		"res://icons/trash.png"
	]
	for path in paths_to_try:
		var f = File.new()
		if f.file_exists(path):
			var img = Image.new()
			if img.load(path) == OK:
				# Create normal size (50%)
				var img_normal = img.duplicate()
				var new_w = int(img_normal.get_width() * 0.5)
				var new_h = int(img_normal.get_height() * 0.5)
				img_normal.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
				var tex = ImageTexture.new()
				tex.create_from_image(img_normal)
				_trash_icon = tex
				
				# Create small size for pack remove button (50%)
				var img_small = img.duplicate()
				var small_w = int(img.get_width() * 0.5)
				var small_h = int(img.get_height() * 0.5)
				img_small.resize(small_w, small_h, Image.INTERPOLATE_LANCZOS)
				var tex_small = ImageTexture.new()
				tex_small.create_from_image(img_small)
				_trash_icon_small = tex_small
				
				print("[MapExplorer] Trash icons loaded from: %s" % path)
				break
	
	# Load size icons (85% size)
	var size_icons = {
		"size_small": "_size_small_icon",
		"size_med": "_size_med_icon",
		"size_max": "_size_max_icon"
	}
	for icon_name in size_icons.keys():
		var icon_path = _g.Root + "icons/" + icon_name + ".png"
		var f = File.new()
		if f.file_exists(icon_path):
			var img = Image.new()
			if img.load(icon_path) == OK:
				# Resize to 85%
				var new_w = int(img.get_width() * 0.85)
				var new_h = int(img.get_height() * 0.85)
				img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
				var tex = ImageTexture.new()
				tex.create_from_image(img)
				set(size_icons[icon_name], tex)
				print("[MapExplorer] Size icon loaded: %s" % icon_name)
	
	# Load favorite icons (50% size)
	var fav_icons = {"fav0": "_fav_icon_off", "fav1": "_fav_icon_on"}
	for icon_name in fav_icons.keys():
		var icon_path = _g.Root + "icons/" + icon_name + ".png"
		var f = File.new()
		if f.file_exists(icon_path):
			var img = Image.new()
			if img.load(icon_path) == OK:
				# Resize to 50%
				var new_w = int(img.get_width() * 0.5)
				var new_h = int(img.get_height() * 0.5)
				img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
				var tex = ImageTexture.new()
				tex.create_from_image(img)
				set(fav_icons[icon_name], tex)
				print("[MapExplorer] Fav icon loaded: %s" % icon_name)
	
	# Load fav2.png for list header (50% size)
	var fav2_path = _g.Root + "icons/fav2.png"
	var f2 = File.new()
	if f2.file_exists(fav2_path):
		var img = Image.new()
		if img.load(fav2_path) == OK:
			var new_w = int(img.get_width() * 0.5)
			var new_h = int(img.get_height() * 0.5)
			img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
			var tex = ImageTexture.new()
			tex.create_from_image(img)
			_fav_icon_hover = tex
			print("[MapExplorer] Fav header icon loaded")
	
	# Generate Grid icon (4 squares)
	_grid_icon = _generate_grid_icon()
	
	# Generate List icon (3 horizontal lines)
	_list_icon = _generate_list_icon()


func _generate_grid_icon() -> ImageTexture:
	var size = 16
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	
	var color = Color(0.85, 0.85, 0.85, 1.0)
	var gap = 2
	var cell = 6
	
	# Draw 4 squares (2x2 grid)
	for row in range(2):
		for col in range(2):
			var x0 = col * (cell + gap) + 1
			var y0 = row * (cell + gap) + 1
			for x in range(cell):
				for y in range(cell):
					img.set_pixel(x0 + x, y0 + y, color)
	
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img)
	return tex


func _generate_list_icon() -> ImageTexture:
	var size = 16
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	
	var color = Color(0.85, 0.85, 0.85, 1.0)
	
	# Draw 3 horizontal lines
	for i in range(3):
		var y = 3 + i * 5
		for x in range(2, 14):
			img.set_pixel(x, y, color)
			img.set_pixel(x, y + 1, color)
	
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img)
	return tex


func _ensure_directories() -> void:
	var dir = Directory.new()
	if not dir.dir_exists(DATA_DIR):
		dir.make_dir_recursive(DATA_DIR)
	if not dir.dir_exists(THUMB_DIR):
		dir.make_dir_recursive(THUMB_DIR)


func _load_index() -> void:
	var f = File.new()
	if f.file_exists(INDEX_FILE):
		if f.open(INDEX_FILE, File.READ) == OK:
			var text = f.get_as_text()
			f.close()
			var parsed = JSON.parse(text)
			if parsed.error == OK and parsed.result is Dictionary:
				_map_index = parsed.result


func _save_index() -> void:
	var f = File.new()
	if f.open(INDEX_FILE, File.WRITE) == OK:
		f.store_line(JSON.print(_map_index, "\t"))
		f.close()


func _load_prefs() -> void:
	var f = File.new()
	if f.file_exists(PREFS_FILE):
		if f.open(PREFS_FILE, File.READ) == OK:
			var text = f.get_as_text()
			f.close()
			var parsed = JSON.parse(text)
			if parsed.error == OK and parsed.result is Dictionary:
				_current_sort = int(parsed.result.get("sort", SORT_DATE_DESC))
				_hide_missing = bool(parsed.result.get("hide_missing", false))
				_preview_size = int(parsed.result.get("preview_size", 200))
				_preview_size = clamp(_preview_size, 100, 400)
				_hide_info = bool(parsed.result.get("hide_info", false))
				# Window size/pos
				if parsed.result.has("window_width"):
					_window_size.x = float(parsed.result.get("window_width", 900))
				if parsed.result.has("window_height"):
					_window_size.y = float(parsed.result.get("window_height", 620))
				if parsed.result.has("window_x"):
					_window_pos.x = float(parsed.result.get("window_x", -1))
				if parsed.result.has("window_y"):
					_window_pos.y = float(parsed.result.get("window_y", -1))
				# Favorites
				_favorites = {}
				if parsed.result.has("favorites"):
					var fav_list = parsed.result.get("favorites", [])
					for fav_id in fav_list:
						_favorites[fav_id] = true
				# Folders
				if parsed.result.has("folders"):
					var folder_list = parsed.result.get("folders", [])
					_folders = ["All"]
					for folder_name in folder_list:
						if folder_name != "All" and not folder_name in _folders:
							_folders.append(folder_name)


func _save_prefs() -> void:
	var f = File.new()
	if f.open(PREFS_FILE, File.WRITE) == OK:
		# Save folders without "All" (it's always added on load)
		var folders_to_save = []
		for folder in _folders:
			if folder != "All":
				folders_to_save.append(folder)
		var data = {
			"sort": _current_sort,
			"hide_missing": _hide_missing,
			"preview_size": _preview_size,
			"hide_info": _hide_info,
			"window_width": _window_size.x,
			"window_height": _window_size.y,
			"window_x": _window_pos.x,
			"window_y": _window_pos.y,
			"favorites": _favorites.keys(),
			"folders": folders_to_save
		}
		f.store_line(JSON.print(data, "\t"))
		f.close()


func _generate_map_id(path: String) -> String:
	return str(path.hash())


func _get_datetime_string() -> String:
	var dt = OS.get_datetime()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]


# ── Save Hook ────────────────────────────────────────────────────────────────

func _hook_save_button() -> void:
	if _g == null or _g.Editor == null:
		return
	var save_btn = _g.Editor.get("saveButton")
	if save_btn == null or not is_instance_valid(save_btn):
		return
	if not save_btn.is_connected("pressed", self, "_on_save_pressed"):
		save_btn.connect("pressed", self, "_on_save_pressed")
		_save_connected = true
		print("[MapExplorer] Save button hooked")


func _on_save_pressed() -> void:
	var timer = _g.World.get_tree().create_timer(0.5)
	timer.connect("timeout", self, "_check_and_generate_thumbnail")


func _check_and_generate_thumbnail() -> void:
	var current_path = _g.Editor.get("CurrentMapFile") if _g.Editor else ""
	if current_path == null or current_path == "":
		return
	_pending_thumbnail = true


func _generate_thumbnail_after_save() -> void:
	var map_path = _g.Editor.get("CurrentMapFile") if _g.Editor else ""
	if map_path == null or map_path == "":
		return
	
	var map_name = _g.World.get("Title") if _g.World else "Untitled"
	if map_name == null or map_name == "":
		map_name = map_path.get_file().replace(".dungeondraft_map", "")
	
	var map_width = _g.World.get("Width") if _g.World else 0
	var map_height = _g.World.get("Height") if _g.World else 0
	
	var map_id = _generate_map_id(map_path)
	var thumb_filename = map_id + ".png"
	var thumb_path = THUMB_DIR + thumb_filename
	
	var success = yield(_capture_current_view(thumb_path), "completed")
	
	if success:
		# Preserve existing custom_order and folder if map already exists
		var existing_order = 0
		var existing_folder = ""
		if _map_index.has(map_id):
			existing_order = _map_index[map_id].get("custom_order", 0)
			existing_folder = _map_index[map_id].get("folder", "")
		else:
			# Calculate custom_order for new map (add at end)
			for mid in _map_index.keys():
				var order = _map_index[mid].get("custom_order", 0)
				if order >= existing_order:
					existing_order = order + 1
		
		_map_index[map_id] = {
			"path": map_path,
			"name": map_name,
			"thumb_file": thumb_filename,
			"last_saved": _get_datetime_string(),
			"width": map_width,
			"height": map_height,
			"custom_order": existing_order,
			"folder": existing_folder
		}
		_save_index()
		print("[MapExplorer] Thumbnail saved for: %s (%dx%d)" % [map_name, map_width, map_height])
	else:
		print("[MapExplorer] Failed to generate thumbnail for: %s" % map_name)


# ── Thumbnail Capture (hide UI, full viewport, preserve ratio) ───────────────

func _capture_current_view(save_path: String):
	if _g.World == null:
		yield(_g.World.get_tree(), "idle_frame")
		return false
	
	var world_vp = _g.World.get_viewport()
	if world_vp == null:
		yield(_g.World.get_tree(), "idle_frame")
		return false
	
	# Hide UI elements
	var ui_elements = []
	
	# Try to hide the main Editor UI
	if _g.Editor != null:
		var editor_node = _g.Editor as Node
		if editor_node and editor_node.has_method("get_parent"):
			var parent = editor_node.get_parent()
			# Look for UI containers
			for child in _g.World.get_tree().root.get_children():
				if child != _g.World and child is CanvasLayer:
					if child.visible:
						ui_elements.append(child)
						child.visible = false
				elif child is Control and child.visible:
					ui_elements.append(child)
					child.visible = false
	
	# Hide grid
	var grid_mesh = _g.World.get_node_or_null("GridMesh")
	var grid_visible = false
	if grid_mesh:
		grid_visible = grid_mesh.visible
		grid_mesh.visible = false
	
	# Hide tool previews (object/light/path in hand)
	var hidden_previews = _hide_tool_previews()
	
	# Force visual update and wait for render
	VisualServer.force_draw(true)
	yield(_g.World.get_tree(), "idle_frame")
	yield(_g.World.get_tree(), "idle_frame")
	
	# Capture
	var img = world_vp.get_texture().get_data()
	
	# Restore UI
	for elem in ui_elements:
		if is_instance_valid(elem):
			elem.visible = true
	
	# Restore grid
	if grid_mesh:
		grid_mesh.visible = grid_visible
	
	# Restore tool previews
	_restore_tool_previews(hidden_previews)
	
	if img == null:
		return false
	
	img.flip_y()
	
	# Crop to the map canvas bounds (drop the empty margin around the map)
	var crop = _compute_canvas_crop_rect(world_vp, img.get_width(), img.get_height())
	if crop != null:
		# Force a 16:9 frame: grow into the surrounding margin first (no map
		# loss), only cropping the map if the image has no room left.
		crop = _fit_rect_to_aspect(crop, img.get_width(), img.get_height(), THUMB_ASPECT)
		img = img.get_rect(crop)
	
	# Resize to 200px wide, keeping aspect ratio
	var aspect = float(img.get_height()) / float(img.get_width())
	var new_width = THUMB_SIZE
	var new_height = int(THUMB_SIZE * aspect)
	
	img.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
	
	var err = img.save_png(save_path)
	return err == OK


# Computes the pixel rect (in the captured/flipped image) covered by the map
# canvas, so we can crop away the empty margin shown when the whole map is
# visible. Returns null if it can't be determined (then no crop is applied).
func _compute_canvas_crop_rect(world_vp, img_w: int, img_h: int):
	if _g.World == null or world_vp == null:
		return null
	var wr = _g.World.get("WorldRect")
	if wr == null or not (wr is Rect2):
		return null
	
	var xf = world_vp.canvas_transform  # world -> viewport pixels
	if xf == null:
		return null
	
	# Scale factor in case the texture resolution differs from viewport size
	var vp_size = world_vp.size
	var sx = 1.0
	var sy = 1.0
	if vp_size.x > 0 and vp_size.y > 0:
		sx = float(img_w) / vp_size.x
		sy = float(img_h) / vp_size.y
	
	# Transform all 4 corners (robust even if the transform has rotation/scale)
	var corners = [
		xf.xform(wr.position),
		xf.xform(wr.position + Vector2(wr.size.x, 0)),
		xf.xform(wr.position + Vector2(0, wr.size.y)),
		xf.xform(wr.position + wr.size),
	]
	var min_x = INF
	var min_y = INF
	var max_x = -INF
	var max_y = -INF
	for c in corners:
		min_x = min(min_x, c.x * sx)
		max_x = max(max_x, c.x * sx)
		min_y = min(min_y, c.y * sy)
		max_y = max(max_y, c.y * sy)
	
	# Clamp to the image bounds (map may extend past the screen when zoomed in)
	min_x = clamp(min_x, 0.0, float(img_w))
	max_x = clamp(max_x, 0.0, float(img_w))
	min_y = clamp(min_y, 0.0, float(img_h))
	max_y = clamp(max_y, 0.0, float(img_h))
	
	var rw = int(max_x - min_x)
	var rh = int(max_y - min_y)
	if rw < 2 or rh < 2:
		return null
	
	return Rect2(int(min_x), int(min_y), rw, rh)


# Expands/crops a rect to a target aspect ratio, kept centered and clamped
# inside the image. Prefers to GROW into the available image area (reclaiming
# the cropped margin) rather than cutting; only crops when the image is too
# small in a dimension to grow further.
func _fit_rect_to_aspect(rect: Rect2, img_w: int, img_h: int, target: float) -> Rect2:
	var cx = rect.position.x + rect.size.x * 0.5
	var cy = rect.position.y + rect.size.y * 0.5
	var w = rect.size.x
	var h = rect.size.y
	
	if w / h < target:
		w = h * target   # too narrow -> widen
	else:
		h = w / target   # too wide -> heighten
	
	# Can't exceed the image; if it does, clamp that side and recompute the
	# other to preserve the aspect (this is where actual map cropping happens).
	if w > img_w:
		w = float(img_w)
		h = w / target
	if h > img_h:
		h = float(img_h)
		w = h * target
	
	var x = clamp(cx - w * 0.5, 0.0, float(img_w) - w)
	var y = clamp(cy - h * 0.5, 0.0, float(img_h) - h)
	return Rect2(int(x), int(y), int(w), int(h))


func _hide_tool_previews() -> Array:
	# Hide preview nodes from all tools and return list of hidden nodes
	var hidden = []
	
	if _g.Editor == null:
		return hidden
	
	# === 0. Hide Editor.Preview (library hover preview - PanelContainer) ===
	var editor_preview = _g.Editor.get("Preview")
	if editor_preview != null and is_instance_valid(editor_preview) and editor_preview.visible:
		_hide_node(editor_preview, hidden)
	
	# === 1. Hide tool previews by accessing tool properties ===
	if _g.Editor.Tools != null:
		# ObjectTool - Preview with capital P
		if _g.Editor.Tools.has("ObjectTool"):
			var ot = _g.Editor.Tools["ObjectTool"]
			if ot != null:
				var preview = ot.get("Preview")
				if preview != null and is_instance_valid(preview) and preview is CanvasItem and preview.visible:
					_hide_node(preview, hidden)
					print("[MapExplorer] Hidden ObjectTool.Preview")
		
		# LightTool - preview with lowercase p
		if _g.Editor.Tools.has("LightTool"):
			var lt = _g.Editor.Tools["LightTool"]
			if lt != null:
				var preview = lt.get("preview")
				if preview != null and is_instance_valid(preview) and preview is CanvasItem and preview.visible:
					_hide_node(preview, hidden)
					print("[MapExplorer] Hidden LightTool.preview")
		
		# PrefabTool - preview is a Dictionary
		if _g.Editor.Tools.has("PrefabTool"):
			var pt = _g.Editor.Tools["PrefabTool"]
			if pt != null:
				var preview = pt.get("preview")
				if preview != null and preview is Dictionary:
					for node in preview.keys():
						if is_instance_valid(node) and node is CanvasItem and node.visible:
							_hide_node(node, hidden)
							print("[MapExplorer] Hidden PrefabTool preview node")
	
	# === 2. Search World for any node with "preview" in name (case insensitive) ===
	if _g.World != null:
		_find_and_hide_preview_nodes(_g.World, hidden)
	
	# === 3. Hide preview popups (hover preview in UI panels) ===
	_hide_preview_popups(_g.Editor, hidden)
	
	return hidden


func _hide_node(node: Node, hidden: Array) -> void:
	# Hide a node and store its state for restoration
	var state = {"node": node, "visible": node.visible}
	
	# Store and set modulate to transparent for CanvasItems
	if node is CanvasItem:
		state["modulate"] = node.modulate
		node.modulate = Color(0, 0, 0, 0)
	
	# Handle Light2D - need to disable as well
	if node is Light2D:
		state["enabled"] = node.enabled
		node.enabled = false
	
	node.visible = false
	hidden.append(state)


func _find_and_hide_preview_nodes(node: Node, hidden: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	
	var name_lower = node.name.to_lower()
	if "preview" in name_lower and node is CanvasItem and node.visible:
		_hide_node(node, hidden)
		print("[MapExplorer] Hidden node by name: %s" % node.name)
	
	for child in node.get_children():
		_find_and_hide_preview_nodes(child, hidden)


func _hide_preview_popups(node: Node, hidden: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	
	var name_lower = node.name.to_lower()
	
	# Check if this is a preview popup/panel
	if "preview" in name_lower:
		if (node is PopupPanel or node is Popup or node is PanelContainer or node is Panel):
			if node.visible:
				_hide_node(node, hidden)
				return  # Don't recurse into hidden popups
	
	# Also check for popups inside ItemLists/GridMenus
	if node.get_class() == "ItemList" or "GridMenu" in str(node.get_class()):
		for child in node.get_children():
			if child is Popup or child is PopupPanel or child is Panel:
				if "preview" in child.name.to_lower() or child is PopupPanel:
					if child.visible:
						_hide_node(child, hidden)
	
	# Recurse
	for child in node.get_children():
		_hide_preview_popups(child, hidden)


func _restore_tool_previews(hidden: Array) -> void:
	for item in hidden:
		if not item is Dictionary:
			continue
		var node = item.get("node")
		if node == null or not is_instance_valid(node):
			continue
		
		# Restore visibility
		if item.has("visible"):
			node.visible = item["visible"]
		else:
			node.visible = true
		
		# Restore modulate
		if node is CanvasItem and item.has("modulate"):
			node.modulate = item["modulate"]
		
		# Restore Light2D enabled state
		if node is Light2D and item.has("enabled"):
			node.enabled = item["enabled"]


# ── Menu Button ──────────────────────────────────────────────────────────────

func _add_menu_button() -> void:
	if _menu_button_added:
		return
	if _g == null or _g.Editor == null:
		return
	var menu_btn = _g.Editor.get("menuButton")
	if menu_btn == null:
		return
	var popup = menu_btn.get_popup()
	if popup == null:
		return
	for i in popup.get_item_count():
		if popup.get_item_text(i) == "Map Gallery":
			_menu_button_added = true
			return
	popup.add_separator()
	popup.add_item("Map Gallery", 9999)
	if not popup.is_connected("id_pressed", self, "_on_menu_item_pressed"):
		popup.connect("id_pressed", self, "_on_menu_item_pressed")
	_menu_button_added = true
	print("[MapExplorer] Menu button added")


func _on_menu_item_pressed(id: int) -> void:
	if id == 9999:
		_show_explorer_window()


# ── Explorer Window ──────────────────────────────────────────────────────────

func _show_explorer_window() -> void:
	_selected_map_ids = []
	_selected_cards = {}
	
	# Ensure window fits on screen
	var screen_size = OS.get_screen_size()
	var safe_margin = Vector2(100, 100)  # Keep some margin from screen edges
	var max_size = screen_size - safe_margin
	var actual_size = Vector2(
		min(_window_size.x, max_size.x),
		min(_window_size.y, max_size.y)
	)
	
	if _explorer_window != null and is_instance_valid(_explorer_window):
		_explorer_window.rect_size = actual_size
		if _window_pos.x >= 0 and _window_pos.y >= 0:
			# Ensure position is on screen
			var safe_pos = Vector2(
				clamp(_window_pos.x, 0, max(0, screen_size.x - actual_size.x)),
				clamp(_window_pos.y, 0, max(0, screen_size.y - actual_size.y))
			)
			_explorer_window.rect_position = safe_pos
			_explorer_window.popup()
		else:
			_explorer_window.popup_centered()
		_refresh_folder_list()
		_refresh_explorer_grid()
		_update_buttons_state()
		return
	
	_explorer_window = WindowDialog.new()
	_explorer_window.window_title = "Map Gallery"
	_explorer_window.rect_min_size = WINDOW_MIN_SIZE
	_explorer_window.resizable = true
	_explorer_window.connect("resized", self, "_on_window_resized")
	
	# Main horizontal split: folders panel (left) + content (right)
	var main_hbox = HBoxContainer.new()
	main_hbox.anchor_right = 1.0
	main_hbox.anchor_bottom = 1.0
	main_hbox.margin_left = 10
	main_hbox.margin_right = -10
	main_hbox.margin_top = 10
	main_hbox.margin_bottom = -6
	main_hbox.set("custom_constants/separation", 10)
	_explorer_window.add_child(main_hbox)
	
	# ── Left Panel: Folders ──
	var folders_panel = VBoxContainer.new()
	folders_panel.rect_min_size = Vector2(180, 0)
	folders_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	folders_panel.set("custom_constants/separation", 4)
	main_hbox.add_child(folders_panel)
	
	var folders_header = HBoxContainer.new()
	folders_header.set("custom_constants/separation", 4)
	folders_panel.add_child(folders_header)
	
	var folders_title = Label.new()
	folders_title.text = "Folders"
	folders_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folders_header.add_child(folders_title)
	
	var add_folder_btn = Button.new()
	add_folder_btn.text = "+"
	add_folder_btn.hint_tooltip = "Add folder"
	add_folder_btn.rect_min_size = Vector2(24, 24)
	add_folder_btn.connect("pressed", self, "_show_add_folder_dialog")
	folders_header.add_child(add_folder_btn)
	
	# Separator under "Folders"
	folders_panel.add_child(HSeparator.new())
	
	# Folder list scroll
	var folders_scroll = ScrollContainer.new()
	folders_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	folders_panel.add_child(folders_scroll)
	
	_folder_list_container = VBoxContainer.new()
	_folder_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder_list_container.set("custom_constants/separation", 2)
	folders_scroll.add_child(_folder_list_container)
	
	# Vertical separator
	var vsep = VSeparator.new()
	main_hbox.add_child(vsep)
	
	# ── Right Panel: Content ──
	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.set("custom_constants/separation", 6)
	main_hbox.add_child(main_vbox)
	
	# ── Toolbar (adaptive layout with 2 rows) ──
	_toolbar_vbox = VBoxContainer.new()
	_toolbar_vbox.set("custom_constants/separation", 4)
	main_vbox.add_child(_toolbar_vbox)
	
	# Row 1: Sort, Filters, Info/View/Size
	_toolbar_row1 = HBoxContainer.new()
	_toolbar_row1.set("custom_constants/separation", 6)
	_toolbar_vbox.add_child(_toolbar_row1)
	
	# Row 2: Info/View/Size overflow (shown in compact mode)
	_toolbar_row2 = HBoxContainer.new()
	_toolbar_row2.set("custom_constants/separation", 6)
	_toolbar_row2.visible = false
	_toolbar_vbox.add_child(_toolbar_row2)
	
	# Search row: the search bar alone, on its own line below the controls
	_search_row = HBoxContainer.new()
	_search_row.set("custom_constants/separation", 6)
	_toolbar_vbox.add_child(_search_row)
	
	# === Search row ===
	var search_label = Label.new()
	search_label.text = "Search:"
	_search_row.add_child(search_label)
	
	_search_bar = LineEdit.new()
	_search_bar.placeholder_text = "Filter..."
	_search_bar.rect_min_size = Vector2(120, 0)
	_search_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_bar.connect("text_changed", self, "_on_search_changed")
	_search_row.add_child(_search_bar)
	
	# Clear button
	var clear_btn = Button.new()
	if _trash_icon != null:
		clear_btn.icon = _trash_icon
	else:
		clear_btn.text = "X"
	clear_btn.hint_tooltip = "Clear search"
	clear_btn.connect("pressed", self, "_on_clear_search")
	_search_row.add_child(clear_btn)
	
	# === Row 1 elements ===
	
	# Sort
	var sort_label = Label.new()
	sort_label.text = "Sort:"
	_toolbar_row1.add_child(sort_label)
	
	_sort_option = OptionButton.new()
	_sort_option.add_item("Newest", SORT_DATE_DESC)
	_sort_option.add_item("Oldest", SORT_DATE_ASC)
	_sort_option.add_item("A-Z", SORT_NAME_ASC)
	_sort_option.add_item("Z-A", SORT_NAME_DESC)
	_sort_option.add_item("Custom", SORT_CUSTOM)
	_sort_option.select(_get_sort_index(_current_sort))
	_sort_option.connect("item_selected", self, "_on_sort_changed")
	_toolbar_row1.add_child(_sort_option)
	
	_toolbar_row1.add_child(VSeparator.new())
	
	# Hide missing
	_hide_missing_checkbox = CheckBox.new()
	_hide_missing_checkbox.text = "Hide missing"
	_hide_missing_checkbox.pressed = _hide_missing
	_hide_missing_checkbox.connect("toggled", self, "_on_hide_missing_toggled")
	_toolbar_row1.add_child(_hide_missing_checkbox)
	
	# Favorites filter
	_favorites_btn = CheckBox.new()
	_favorites_btn.text = "Favorites"
	if _fav_icon_hover != null:
		_favorites_btn.icon = _fav_icon_hover
	_favorites_btn.pressed = _show_favorites_only
	_favorites_btn.connect("toggled", self, "_on_favorites_toggled")
	_toolbar_row1.add_child(_favorites_btn)
	
	# Separator before Info/View/Size (will be hidden in compact mode)
	var info_sep = VSeparator.new()
	info_sep.set_meta("size_view_element", true)
	_toolbar_row1.add_child(info_sep)
	
	# === Info toggle button ===
	_hide_info_btn = Button.new()
	_hide_info_btn.text = "Info"
	_hide_info_btn.hint_tooltip = "Show/hide map info (name, size, date)"
	_hide_info_btn.toggle_mode = true
	_hide_info_btn.pressed = not _hide_info  # Pressed = info visible
	_hide_info_btn.set_meta("size_view_element", true)
	_hide_info_btn.connect("toggled", self, "_on_hide_info_toggled")
	_toolbar_row1.add_child(_hide_info_btn)
	
	var view_sep = VSeparator.new()
	view_sep.set_meta("size_view_element", true)
	_toolbar_row1.add_child(view_sep)
	
	# === View controls ===
	var view_label = Label.new()
	view_label.text = "View:"
	view_label.set_meta("size_view_element", true)
	_toolbar_row1.add_child(view_label)
	
	_view_grid_btn = Button.new()
	if _grid_icon != null:
		_view_grid_btn.icon = _grid_icon
	else:
		_view_grid_btn.text = "Grid"
	_view_grid_btn.hint_tooltip = "Grid view"
	_view_grid_btn.set_meta("size_view_element", true)
	_view_grid_btn.connect("pressed", self, "_on_view_mode_changed", ["grid"])
	_toolbar_row1.add_child(_view_grid_btn)
	
	_view_list_btn = Button.new()
	if _list_icon != null:
		_view_list_btn.icon = _list_icon
	else:
		_view_list_btn.text = "List"
	_view_list_btn.hint_tooltip = "List view"
	_view_list_btn.set_meta("size_view_element", true)
	_view_list_btn.connect("pressed", self, "_on_view_mode_changed", ["list"])
	_toolbar_row1.add_child(_view_list_btn)
	
	# === Size controls (hidden in list mode) ===
	var size_sep = VSeparator.new()
	size_sep.set_meta("size_view_element", true)
	size_sep.set_meta("size_only_element", true)
	_toolbar_row1.add_child(size_sep)
	
	var size_label_txt = Label.new()
	size_label_txt.text = "Size:"
	size_label_txt.set_meta("size_view_element", true)
	size_label_txt.set_meta("size_only_element", true)
	_toolbar_row1.add_child(size_label_txt)
	
	var size_container = HBoxContainer.new()
	size_container.set("custom_constants/separation", 0)
	size_container.set_meta("size_view_element", true)
	size_container.set_meta("size_only_element", true)
	_toolbar_row1.add_child(size_container)
	
	_size_btn_small = Button.new()
	_size_btn_small.flat = true
	_size_btn_small.hint_tooltip = "Small thumbnails"
	if _size_small_icon != null:
		_size_btn_small.icon = _size_small_icon
	else:
		_size_btn_small.text = "S"
	_size_btn_small.connect("pressed", self, "_on_size_preset", [100])
	size_container.add_child(_size_btn_small)
	
	_size_btn_med = Button.new()
	_size_btn_med.flat = true
	_size_btn_med.hint_tooltip = "Medium thumbnails"
	if _size_med_icon != null:
		_size_btn_med.icon = _size_med_icon
	else:
		_size_btn_med.text = "M"
	_size_btn_med.connect("pressed", self, "_on_size_preset", [200])
	size_container.add_child(_size_btn_med)
	
	_size_btn_max = Button.new()
	_size_btn_max.flat = true
	_size_btn_max.hint_tooltip = "Large thumbnails"
	if _size_max_icon != null:
		_size_btn_max.icon = _size_max_icon
	else:
		_size_btn_max.text = "L"
	_size_btn_max.connect("pressed", self, "_on_size_preset", [400])
	size_container.add_child(_size_btn_max)
	
	_update_size_buttons_highlight()
	_update_view_buttons_highlight()
	
	# ── Separator under toolbar ──
	main_vbox.add_child(HSeparator.new())
	
	# ── Info message (fixed, not scrolling) ──
	var info_label = Label.new()
	info_label.text = "Save a map to add it to your gallery."
	info_label.modulate = Color(0.9, 0.7, 0.3, 1.0)  # Jaune orangé
	info_label.align = Label.ALIGN_CENTER
	info_label.valign = Label.VALIGN_CENTER
	info_label.rect_min_size = Vector2(0, 30)
	main_vbox.add_child(info_label)
	
	# ── Separator under info ──
	main_vbox.add_child(HSeparator.new())
	
	# ── Scroll container ──
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.connect("gui_input", self, "_on_scroll_container_input")
	main_vbox.add_child(_scroll_container)
	
	# Inner container for grid/list
	var scroll_vbox = VBoxContainer.new()
	scroll_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_vbox.set("custom_constants/separation", 12)
	_scroll_container.add_child(scroll_vbox)
	
	_grid_container = GridContainer.new()
	_grid_container.columns = 4
	_grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_container.set("custom_constants/hseparation", 8)
	_grid_container.set("custom_constants/vseparation", 8)
	scroll_vbox.add_child(_grid_container)
	
	_list_container = VBoxContainer.new()
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_container.set("custom_constants/separation", 2)
	_list_container.visible = false
	scroll_vbox.add_child(_list_container)
	
	# ── Footer ──
	var footer = HBoxContainer.new()
	footer.set("custom_constants/separation", 12)
	main_vbox.add_child(footer)
	
	# Delete buttons (left side)
	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.disabled = true
	_delete_btn.rect_min_size = Vector2(80, 0)
	_delete_btn.connect("pressed", self, "_on_delete_selected")
	_style_button(_delete_btn)
	footer.add_child(_delete_btn)
	
	_delete_all_missing_btn = Button.new()
	_delete_all_missing_btn.text = "Delete All Missing"
	_delete_all_missing_btn.connect("pressed", self, "_on_delete_all_missing")
	_style_button(_delete_all_missing_btn)
	footer.add_child(_delete_all_missing_btn)
	
	_view_packs_btn = Button.new()
	_view_packs_btn.text = "View Packs"
	_view_packs_btn.disabled = true
	_view_packs_btn.connect("pressed", self, "_on_view_packs")
	_style_button(_view_packs_btn)
	footer.add_child(_view_packs_btn)
	
	_assign_folder_btn = Button.new()
	_assign_folder_btn.text = "Move to..."
	_assign_folder_btn.disabled = true
	_assign_folder_btn.hint_tooltip = "Move selected maps to a folder"
	_assign_folder_btn.connect("pressed", self, "_show_assign_folder_dialog")
	_style_button(_assign_folder_btn)
	footer.add_child(_assign_folder_btn)
	
	# Spacer
	var footer_spacer = Control.new()
	footer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(footer_spacer)
	
	# Maps counter
	_maps_counter_label = Label.new()
	_maps_counter_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	footer.add_child(_maps_counter_label)
	
	# Spacer 2
	var footer_spacer2 = Control.new()
	footer_spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(footer_spacer2)
	
	# Open button
	_open_btn = Button.new()
	_open_btn.text = "Open"
	_open_btn.disabled = true
	_open_btn.rect_min_size = Vector2(80, 0)
	_open_btn.connect("pressed", self, "_on_open_selected")
	_style_button(_open_btn)
	footer.add_child(_open_btn)
	
	# New map button
	var new_btn = Button.new()
	new_btn.text = "New"
	new_btn.rect_min_size = Vector2(80, 0)
	new_btn.hint_tooltip = "Create a new map"
	new_btn.connect("pressed", self, "_on_new_map")
	_style_button(new_btn)
	footer.add_child(new_btn)
	
	# Cancel button
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.rect_min_size = Vector2(80, 0)
	cancel_btn.connect("pressed", self, "_close_explorer_window")
	_style_button(cancel_btn)
	footer.add_child(cancel_btn)
	
	_add_window(_explorer_window)
	_explorer_window.connect("about_to_show", _g.Editor, "OnWindowOpen", [_explorer_window])
	_explorer_window.connect("popup_hide", self, "_on_window_closed")
	
	_refresh_explorer_grid()
	_update_buttons_state()
	
	# Open at saved position/size or centered (using screen_size calculated at function start)
	if _window_pos.x >= 0 and _window_pos.y >= 0:
		var safe_pos = Vector2(
			clamp(_window_pos.x, 0, max(0, screen_size.x - actual_size.x)),
			clamp(_window_pos.y, 0, max(0, screen_size.y - actual_size.y))
		)
		_explorer_window.rect_position = safe_pos
		_explorer_window.rect_size = actual_size
		_explorer_window.popup()
	else:
		_explorer_window.popup_centered(actual_size)
	
	_refresh_folder_list()
	_refresh_explorer_grid()
	_update_buttons_state()


func _get_sort_index(sort_id: int) -> int:
	match sort_id:
		SORT_DATE_DESC: return 0
		SORT_DATE_ASC: return 1
		SORT_NAME_ASC: return 2
		SORT_NAME_DESC: return 3
		SORT_CUSTOM: return 4
	return 0


func _on_search_changed(new_text: String) -> void:
	_current_search = new_text.to_lower().strip_edges()
	_refresh_explorer_grid()


func _on_clear_search() -> void:
	if _search_bar:
		_search_bar.text = ""
	_current_search = ""
	_refresh_explorer_grid()


func _on_sort_changed(index: int) -> void:
	_current_sort = _sort_option.get_item_id(index)
	_list_sort_column = ""  # Reset column sort when using dropdown
	_save_prefs()
	_refresh_explorer_grid()


func _on_hide_missing_toggled(pressed: bool) -> void:
	_hide_missing = pressed
	_save_prefs()
	_refresh_explorer_grid()


func _on_favorites_toggled(pressed: bool) -> void:
	_show_favorites_only = pressed
	_refresh_explorer_grid()


# ── Folder Management ─────────────────────────────────────────────────────────

func _refresh_folder_list() -> void:
	if _folder_list_container == null or not is_instance_valid(_folder_list_container):
		return
	
	for child in _folder_list_container.get_children():
		child.queue_free()
	
	for folder_name in _folders:
		# Use PanelContainer for background color
		var panel = PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.set_meta("folder_name", folder_name)
		
		# Apply style based on selection
		var panel_style = StyleBoxFlat.new()
		if folder_name == _current_folder:
			panel_style.bg_color = Color(0.25, 0.35, 0.5, 1.0)  # Blue background
			panel_style.border_color = Color(0.4, 0.55, 0.8, 1.0)
			panel_style.set_border_width_all(1)
		else:
			panel_style.bg_color = Color(0.15, 0.15, 0.18, 0.0)  # Transparent
			panel_style.set_border_width_all(0)
		panel_style.set_corner_radius_all(4)
		panel_style.content_margin_left = 2
		panel_style.content_margin_right = 2
		panel_style.content_margin_top = 2
		panel_style.content_margin_bottom = 2
		panel.add_stylebox_override("panel", panel_style)
		panel.set_meta("panel_style", panel_style)
		panel.set_meta("is_drag_hover", false)
		
		var row = HBoxContainer.new()
		row.set("custom_constants/separation", 4)
		panel.add_child(row)
		
		var btn = Button.new()
		btn.text = folder_name
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.flat = true
		btn.align = Button.ALIGN_LEFT
		btn.set_meta("folder_name", folder_name)
		btn.connect("pressed", self, "_on_folder_selected", [folder_name])
		row.add_child(btn)
		
		# Map count
		var count = _count_maps_in_folder(folder_name) if folder_name != "All" else _map_index.size()
		var count_label = Label.new()
		count_label.text = str(count)
		count_label.modulate = Color(0.5, 0.5, 0.5, 1.0)
		count_label.rect_min_size = Vector2(30, 0)
		count_label.align = Label.ALIGN_RIGHT
		row.add_child(count_label)
		
		# Delete button (not for "All")
		if folder_name != "All":
			var del_btn = Button.new()
			del_btn.flat = true
			if _trash_icon_small != null:
				del_btn.icon = _trash_icon_small
			else:
				del_btn.text = "x"
			del_btn.hint_tooltip = "Delete folder"
			del_btn.connect("pressed", self, "_on_delete_folder_sidebar", [folder_name])
			row.add_child(del_btn)
		else:
			# Placeholder for alignment
			var spacer = Control.new()
			spacer.rect_min_size = Vector2(24, 0)
			row.add_child(spacer)
		
		_folder_list_container.add_child(panel)


func _on_folder_selected(folder_name: String) -> void:
	_current_folder = folder_name
	_refresh_folder_list()
	_refresh_explorer_grid()


func _show_add_folder_dialog() -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "New Folder"
	dialog.rect_min_size = Vector2(300, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -8
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var input = LineEdit.new()
	input.placeholder_text = "Folder name..."
	vbox.add_child(input)
	
	var btn_row = HBoxContainer.new()
	btn_row.set("custom_constants/separation", 8)
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	vbox.add_child(btn_row)
	
	var create_btn = Button.new()
	create_btn.text = "Create"
	create_btn.connect("pressed", self, "_on_create_folder", [input, dialog])
	_style_button(create_btn)
	btn_row.add_child(create_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(300, h)
	dialog.popup_centered()
	input.grab_focus()


func _on_create_folder(input: LineEdit, dialog: WindowDialog) -> void:
	var folder_name = input.text.strip_edges()
	if folder_name == "" or folder_name == "All":
		return
	if folder_name in _folders:
		return
	
	_folders.append(folder_name)
	_save_prefs()
	_refresh_folder_list()
	dialog.hide()


func _on_delete_folder_sidebar(folder_name: String) -> void:
	_folders.erase(folder_name)
	_save_prefs()
	
	# Clear folder from maps
	for map_id in _map_index.keys():
		if _map_index[map_id].get("folder", "") == folder_name:
			_map_index[map_id]["folder"] = ""
	_save_index()
	
	if _current_folder == folder_name:
		_current_folder = "All"
	
	_refresh_folder_list()
	_refresh_explorer_grid()


func _count_maps_in_folder(folder_name: String) -> int:
	var count = 0
	for map_id in _map_index.keys():
		if _map_index[map_id].get("folder", "") == folder_name:
			count += 1
	return count


func _show_assign_folder_dialog() -> void:
	if _selected_map_ids.size() == 0:
		return
	
	var dialog = WindowDialog.new()
	dialog.window_title = "Move to Folder"
	dialog.rect_min_size = Vector2(300, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -8
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var msg = Label.new()
	if _selected_map_ids.size() == 1:
		var info = _map_index.get(_selected_map_ids[0], {})
		msg.text = "Move '%s' to:" % info.get("name", "Unknown")
	else:
		msg.text = "Move %d maps to:" % _selected_map_ids.size()
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	# Folder buttons
	for folder_name in _folders:
		var btn = Button.new()
		btn.text = folder_name
		btn.connect("pressed", self, "_do_assign_folder", [folder_name if folder_name != "All" else "", dialog])
		_style_button(btn)
		vbox.add_child(btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	vbox.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(300, h)
	dialog.popup_centered()


func _do_assign_folder(folder_name: String, dialog: WindowDialog) -> void:
	for map_id in _selected_map_ids:
		if _map_index.has(map_id):
			_map_index[map_id]["folder"] = folder_name
	_save_index()
	dialog.hide()
	_refresh_explorer_grid()
	print("[MapExplorer] Moved %d maps to folder: %s" % [_selected_map_ids.size(), folder_name if folder_name != "" else "(none)"])


func _on_size_preset(size: int) -> void:
	_preview_size = size
	_save_prefs()
	_update_size_buttons_highlight()
	_refresh_explorer_grid()


func _on_scroll_container_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_LEFT:
		# Clear selection when clicking on empty area
		if _selected_map_ids.size() > 0:
			_clear_selection()
			_update_buttons_state()


func _update_size_buttons_highlight() -> void:
	var buttons = {
		100: _size_btn_small,
		200: _size_btn_med,
		400: _size_btn_max
	}
	for size in buttons.keys():
		var btn = buttons[size]
		if btn == null or not is_instance_valid(btn):
			continue
		btn.flat = false
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(3)
		style.content_margin_left = 2
		style.content_margin_right = 2
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		if size == _preview_size:
			# Active: highlighted background
			style.bg_color = Color(0.3, 0.5, 0.7, 0.6)
		else:
			# Inactive: transparent
			style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		btn.add_stylebox_override("normal", style)
		btn.add_stylebox_override("hover", style)
		btn.add_stylebox_override("pressed", style)


func _on_view_mode_changed(mode: String) -> void:
	_view_mode = mode
	_list_sort_column = ""  # Reset column sort when changing view
	_update_view_buttons_highlight()
	_update_size_controls_visibility()
	_refresh_explorer_grid()


func _update_size_controls_visibility() -> void:
	# Hide size controls in list mode
	var show_size = (_view_mode == "grid")
	for child in _toolbar_row1.get_children():
		if child.has_meta("size_only_element"):
			child.visible = show_size
	if _toolbar_row2 != null:
		for child in _toolbar_row2.get_children():
			if child.has_meta("size_only_element"):
				child.visible = show_size


func _on_hide_info_toggled(pressed: bool) -> void:
	_hide_info = not pressed  # pressed = info visible
	_save_prefs()
	_refresh_explorer_grid()


func _update_view_buttons_highlight() -> void:
	var buttons = {"grid": _view_grid_btn, "list": _view_list_btn}
	for mode in buttons.keys():
		var btn = buttons[mode]
		if btn == null or not is_instance_valid(btn):
			continue
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(3)
		style.content_margin_left = 4
		style.content_margin_right = 4
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		if mode == _view_mode:
			style.bg_color = Color(0.3, 0.5, 0.7, 0.6)
		else:
			style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
		btn.add_stylebox_override("normal", style)
		btn.add_stylebox_override("hover", style)
		btn.add_stylebox_override("pressed", style)


func _on_delete_selected() -> void:
	if _selected_map_ids.size() == 0:
		return
	
	if _selected_map_ids.size() == 1:
		var info = _map_index.get(_selected_map_ids[0])
		if info == null:
			return
		var name = info.get("name", "Unknown")
		_show_delete_confirm_dialog(_selected_map_ids[0], name)
	else:
		_show_delete_multiple_confirm_dialog(_selected_map_ids)


func _show_delete_multiple_confirm_dialog(map_ids: Array) -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "Confirm Delete"
	dialog.rect_min_size = Vector2(350, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -6
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var msg = Label.new()
	msg.text = "Delete %d maps from list?" % map_ids.size()
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 20)
	vbox.add_child(btn_row)
	
	var confirm_btn = Button.new()
	confirm_btn.text = "Delete All"
	confirm_btn.connect("pressed", self, "_do_delete_multiple", [map_ids.duplicate(), dialog])
	_style_button(confirm_btn)
	btn_row.add_child(confirm_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(350, h)
	dialog.popup_centered()


func _do_delete_multiple(map_ids: Array, dialog) -> void:
	for map_id in map_ids:
		if _map_index.has(map_id):
			var info = _map_index[map_id]
			var thumb_file = info.get("thumb_file", "")
			if thumb_file != "":
				var dir = Directory.new()
				dir.remove(THUMB_DIR + thumb_file)
			_map_index.erase(map_id)
	_save_index()
	_selected_map_ids = []
	_selected_cards = {}
	dialog.hide()
	_refresh_explorer_grid()


func _show_delete_confirm_dialog(map_id: String, map_name: String) -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "Confirm Delete"
	dialog.rect_min_size = Vector2(350, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -6
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var msg = Label.new()
	msg.text = "Delete '%s' from list?" % map_name
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 20)
	vbox.add_child(btn_row)
	
	var confirm_btn = Button.new()
	confirm_btn.text = "Delete"
	confirm_btn.connect("pressed", self, "_do_delete_selected", [map_id, dialog])
	_style_button(confirm_btn)
	btn_row.add_child(confirm_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(350, h)
	dialog.popup_centered()


func _do_delete_selected(map_id: String, dialog: Node) -> void:
	dialog.hide()
	if _map_index.has(map_id):
		var thumb_file = _map_index[map_id].get("thumb_file", "")
		_map_index.erase(map_id)
		_save_index()
		if thumb_file != "":
			var dir = Directory.new()
			if dir.file_exists(THUMB_DIR + thumb_file):
				dir.remove(THUMB_DIR + thumb_file)
		_selected_map_ids = []
		_selected_cards = {}
		_refresh_explorer_grid()
		_update_buttons_state()
		print("[MapExplorer] Map deleted from index: %s" % map_id)


func _on_open_selected() -> void:
	if _selected_map_ids.size() == 0:
		return
	# Open the first selected map
	var map_id = _selected_map_ids[0]
	var info = _map_index.get(map_id)
	if info == null:
		return
	var path = info.get("path", "")
	var f = File.new()
	if not f.file_exists(path):
		_on_missing_map_clicked(map_id, info)
		return
	_close_explorer_window()
	yield(_g.World.get_tree().create_timer(0.1), "timeout")
	_g.Editor.ForceOpenMap(path)
	print("[MapExplorer] Opening map: %s" % path)


func _update_buttons_state() -> void:
	# Update Open, Delete, and View Packs buttons based on selection
	var has_selection = (_selected_map_ids.size() > 0)
	var selection_count = _selected_map_ids.size()
	
	if _open_btn != null:
		# Disable if no selection OR multiple selection (can only open one map)
		_open_btn.disabled = (selection_count != 1)
		_open_btn.text = "Open"
	
	if _delete_btn != null:
		_delete_btn.disabled = not has_selection
		_delete_btn.text = "Delete" if selection_count <= 1 else "Delete (%d)" % selection_count
	
	if _view_packs_btn != null:
		# Only enable if exactly one selected and file exists
		var can_view_packs = false
		if selection_count == 1 and _map_index.has(_selected_map_ids[0]):
			var path = _map_index[_selected_map_ids[0]].get("path", "")
			var f = File.new()
			can_view_packs = f.file_exists(path)
		_view_packs_btn.disabled = not can_view_packs
	
	if _assign_folder_btn != null:
		_assign_folder_btn.disabled = not has_selection
	
	# Update Delete All Missing based on missing count
	if _delete_all_missing_btn != null:
		var missing_count = _count_missing_maps()
		_delete_all_missing_btn.disabled = (missing_count == 0)


func _count_missing_maps() -> int:
	var count = 0
	var f = File.new()
	for map_id in _map_index.keys():
		var path = _map_index[map_id].get("path", "")
		if not f.file_exists(path):
			count += 1
	return count


func _on_window_resized() -> void:
	if _explorer_window == null or not is_instance_valid(_explorer_window):
		return
	
	# Enforce minimum size
	var current_size = _explorer_window.rect_size
	var needs_resize = false
	
	if current_size.x < WINDOW_MIN_SIZE.x:
		current_size.x = WINDOW_MIN_SIZE.x
		needs_resize = true
	if current_size.y < WINDOW_MIN_SIZE.y:
		current_size.y = WINDOW_MIN_SIZE.y
		needs_resize = true
	
	if needs_resize:
		_explorer_window.rect_size = current_size
		return  # Will trigger another resize event
	
	# Update grid columns
	if _grid_container != null and is_instance_valid(_grid_container):
		var available_width = current_size.x - 240  # Account for folder panel
		var card_width = _preview_size + 12
		var columns = max(1, int(available_width / card_width))
		_grid_container.columns = columns
	
	# Adaptive layout: wrap toolbar to 2 rows when narrow
	_update_adaptive_layout(current_size.x)


func _update_adaptive_layout(_width: float) -> void:
	# Compact wrapping disabled on purpose: all controls stay on row 1, and the
	# search bar keeps its own row below — exactly two toolbar rows.
	if _is_compact_mode:
		_is_compact_mode = false
		_move_elements_to_row1()


func _move_elements_to_row2() -> void:
	if _toolbar_row1 == null or _toolbar_row2 == null:
		return
	
	# Clear row2 first
	for child in _toolbar_row2.get_children():
		child.queue_free()
	
	# Find and move elements marked as "size_view_element"
	var elements_to_move = []
	for child in _toolbar_row1.get_children():
		if child.has_meta("size_view_element"):
			elements_to_move.append(child)
	
	for element in elements_to_move:
		_toolbar_row1.remove_child(element)
		_toolbar_row2.add_child(element)
	
	_toolbar_row2.visible = true


func _move_elements_to_row1() -> void:
	if _toolbar_row1 == null or _toolbar_row2 == null:
		return
	
	# Move all elements from row2 back to row1
	var elements_to_move = []
	for child in _toolbar_row2.get_children():
		elements_to_move.append(child)
	
	for element in elements_to_move:
		_toolbar_row2.remove_child(element)
		_toolbar_row1.add_child(element)
	
	_toolbar_row2.visible = false


func _on_window_closed() -> void:
	# Save window position and size when closing
	if _explorer_window != null and is_instance_valid(_explorer_window):
		_window_size = _explorer_window.rect_size
		_window_pos = _explorer_window.rect_position
		_save_prefs()
	_g.Editor.OnWindowClose(_explorer_window)


func _on_delete_all_missing() -> void:
	var missing_count = 0
	var f = File.new()
	for map_id in _map_index.keys():
		var path = _map_index[map_id].get("path", "")
		if not f.file_exists(path):
			missing_count += 1
	
	if missing_count == 0:
		_show_message("No Missing Maps", "All indexed maps exist.")
		return
	_show_confirm_delete_all_missing(missing_count)


func _show_confirm_delete_all_missing(count: int) -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "Confirm"
	dialog.rect_min_size = Vector2(350, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -6
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var msg = Label.new()
	msg.text = "Remove %d missing map(s) from list?" % count
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 20)
	vbox.add_child(btn_row)
	
	var confirm_btn = Button.new()
	confirm_btn.text = "Delete"
	confirm_btn.connect("pressed", self, "_do_delete_all_missing", [dialog])
	btn_row.add_child(confirm_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(350, h)
	dialog.popup_centered()


func _do_delete_all_missing(dialog: Node) -> void:
	dialog.hide()
	var f = File.new()
	var dir = Directory.new()
	var to_delete = []
	
	for map_id in _map_index.keys():
		var path = _map_index[map_id].get("path", "")
		if not f.file_exists(path):
			to_delete.append(map_id)
	
	for map_id in to_delete:
		var thumb_file = _map_index[map_id].get("thumb_file", "")
		_map_index.erase(map_id)
		if thumb_file != "":
			var thumb_path = THUMB_DIR + thumb_file
			if dir.file_exists(thumb_path):
				dir.remove(thumb_path)
	
	_save_index()
	_selected_map_ids = []
	_selected_cards = {}
	_refresh_explorer_grid()
	_update_buttons_state()
	print("[MapExplorer] Deleted %d missing maps" % to_delete.size())


func _show_message(title: String, text: String) -> void:
	var dialog = PopupPanel.new()
	
	# Style the popup panel with white border
	var popup_style = StyleBoxFlat.new()
	popup_style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	popup_style.border_color = Color(0.6, 0.6, 0.6, 1.0)
	popup_style.set_border_width_all(1)
	popup_style.set_corner_radius_all(3)
	dialog.add_stylebox_override("panel", popup_style)
	
	var vbox = VBoxContainer.new()
	vbox.set("custom_constants/separation", 15)
	vbox.rect_min_size = Vector2(200, 0)
	dialog.add_child(vbox)
	
	# Add margins
	var margin = MarginContainer.new()
	margin.set("custom_constants/margin_left", 20)
	margin.set("custom_constants/margin_right", 20)
	margin.set("custom_constants/margin_top", 15)
	margin.set("custom_constants/margin_bottom", 15)
	dialog.add_child(margin)
	
	var inner_vbox = VBoxContainer.new()
	inner_vbox.set("custom_constants/separation", 15)
	margin.add_child(inner_vbox)
	
	var label = Label.new()
	label.text = text
	label.align = Label.ALIGN_CENTER
	inner_vbox.add_child(label)
	
	var ok_btn = Button.new()
	ok_btn.text = "OK"
	ok_btn.rect_min_size = Vector2(80, 0)
	ok_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok_btn.connect("pressed", dialog, "hide")
	_style_button(ok_btn)
	inner_vbox.add_child(ok_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	dialog.popup_centered()


func _refresh_explorer_grid() -> void:
	if _grid_container == null or not is_instance_valid(_grid_container):
		return
	if _list_container == null or not is_instance_valid(_list_container):
		return
	
	# Clear both containers
	for child in _grid_container.get_children():
		child.queue_free()
	for child in _list_container.get_children():
		child.queue_free()
	
	# Show/hide based on view mode
	_grid_container.visible = (_view_mode == "grid")
	_list_container.visible = (_view_mode == "list")
	
	# Calculate columns based on window width (for grid mode)
	var available_width = _window_size.x - 40
	if _explorer_window != null and is_instance_valid(_explorer_window):
		available_width = _explorer_window.rect_size.x - 40
	var card_width = _preview_size + 12
	var columns = max(1, int(available_width / card_width))
	_grid_container.columns = columns
	
	_load_index()
	
	var f = File.new()
	var filtered_ids = []
	
	for map_id in _map_index.keys():
		var info = _map_index[map_id]
		var name = info.get("name", "").to_lower()
		var path = info.get("path", "")
		var exists = f.file_exists(path)
		var map_folder = info.get("folder", "")
		
		if _hide_missing and not exists:
			continue
		if _show_favorites_only and not _favorites.has(map_id):
			continue
		if _current_folder != "All" and map_folder != _current_folder:
			continue
		if _current_search == "" or _current_search in name or _current_search in path.to_lower():
			filtered_ids.append(map_id)
	
	# Get target container
	var target_container = _grid_container if _view_mode == "grid" else _list_container
	
	if filtered_ids.size() == 0:
		var empty_label = Label.new()
		if _current_folder != "All":
			empty_label.text = "No maps in folder '%s'." % _current_folder
		elif _show_favorites_only:
			empty_label.text = "No favorite maps yet."
		elif _current_search != "":
			empty_label.text = "No maps matching '%s'" % _current_search
		else:
			empty_label.text = "No maps yet. Save a map to see it here."
		empty_label.align = Label.ALIGN_CENTER
		target_container.add_child(empty_label)
		_update_maps_counter(0, _map_index.size())
		_filtered_ids_order = []
		return
	
	filtered_ids.sort_custom(self, "_sort_comparator")
	
	# Store order for shift-select
	_filtered_ids_order = filtered_ids.duplicate()
	
	# Clear selection on refresh
	_selected_map_ids = []
	_selected_cards = {}
	_last_selected_id = ""
	
	# Add header for list view
	if _view_mode == "list":
		var header = _create_list_header()
		_list_container.add_child(header)
	
	for map_id in filtered_ids:
		var info = _map_index[map_id]
		if _view_mode == "grid":
			var card = _create_map_card(map_id, info)
			_grid_container.add_child(card)
		else:
			var row = _create_list_row(map_id, info)
			_list_container.add_child(row)
	
	# Update maps counter
	_update_maps_counter(filtered_ids.size(), _map_index.size())
	
	# Update button states after refresh
	call_deferred("_update_buttons_state")


func _sort_comparator(a, b) -> bool:
	var info_a = _map_index[a]
	var info_b = _map_index[b]
	
	# If in list view with column sort, use that
	if _view_mode == "list" and _list_sort_column != "":
		return _list_sort_compare(info_a, info_b, a, b)
	
	match _current_sort:
		SORT_DATE_DESC:
			return info_a.get("last_saved", "") > info_b.get("last_saved", "")
		SORT_DATE_ASC:
			return info_a.get("last_saved", "") < info_b.get("last_saved", "")
		SORT_NAME_ASC:
			return info_a.get("name", "").to_lower() < info_b.get("name", "").to_lower()
		SORT_NAME_DESC:
			return info_a.get("name", "").to_lower() > info_b.get("name", "").to_lower()
		SORT_CUSTOM:
			return info_a.get("custom_order", 999999) < info_b.get("custom_order", 999999)
	return false


func _list_sort_compare(info_a: Dictionary, info_b: Dictionary, id_a: String, id_b: String) -> bool:
	var val_a
	var val_b
	
	match _list_sort_column:
		"fav":
			val_a = 1 if _favorites.has(id_a) else 0
			val_b = 1 if _favorites.has(id_b) else 0
		"name":
			val_a = info_a.get("name", "").to_lower()
			val_b = info_b.get("name", "").to_lower()
		"size":
			val_a = int(info_a.get("width", 0)) * int(info_a.get("height", 0))
			val_b = int(info_b.get("width", 0)) * int(info_b.get("height", 0))
		"date":
			val_a = info_a.get("last_saved", "")
			val_b = info_b.get("last_saved", "")
		"packs":
			val_a = _get_pack_count_for_map(info_a.get("path", ""))
			val_b = _get_pack_count_for_map(info_b.get("path", ""))
		"default":
			val_a = 1 if _get_uses_default_for_map(info_a.get("path", "")) else 0
			val_b = 1 if _get_uses_default_for_map(info_b.get("path", "")) else 0
		"folder":
			val_a = info_a.get("folder", "").to_lower()
			val_b = info_b.get("folder", "").to_lower()
			# Empty folders sort last
			if val_a == "" and val_b != "":
				return not _list_sort_asc
			if val_b == "" and val_a != "":
				return _list_sort_asc
		_:
			return false
	
	if _list_sort_asc:
		return val_a < val_b
	else:
		return val_a > val_b


func _on_list_sort_column(column: String) -> void:
	if _list_sort_column == column:
		# Toggle direction
		_list_sort_asc = not _list_sort_asc
	else:
		# New column, default to descending (except name which is asc)
		_list_sort_column = column
		_list_sort_asc = (column == "name")
	
	_refresh_explorer_grid()


func _get_column_header_text(column: String) -> String:
	var base_text = ""
	match column:
		"name": base_text = "Name"
		"size": base_text = "Size"
		"date": base_text = "Date"
		"packs": base_text = "Packs"
		"default": base_text = "Default"
		"folder": base_text = "Folder"
		_: base_text = column.capitalize()
	
	if _list_sort_column == column:
		if _list_sort_asc:
			return base_text + " ^"
		else:
			return base_text + " v"
	return base_text


func _get_pack_count_for_map(path: String) -> int:
	var f = File.new()
	if not f.file_exists(path):
		return 0
	if f.open(path, File.READ) != OK:
		return 0
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not parsed.result is Dictionary:
		return 0
	var header = parsed.result.get("header", {})
	var manifest = header.get("asset_manifest", [])
	return manifest.size()


func _get_uses_default_for_map(path: String) -> bool:
	var f = File.new()
	if not f.file_exists(path):
		return false
	if f.open(path, File.READ) != OK:
		return false
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not parsed.result is Dictionary:
		return false
	var header = parsed.result.get("header", {})
	return header.get("uses_default_assets", false)


func _update_maps_counter(shown: int, total: int) -> void:
	if _maps_counter_label == null or not is_instance_valid(_maps_counter_label):
		return
	if shown == total:
		_maps_counter_label.text = "%d map%s" % [total, "s" if total != 1 else ""]
	else:
		_maps_counter_label.text = "%d of %d maps" % [shown, total]


# ── Drag and Drop (Manual) ────────────────────────────────────────────────────

func _on_card_gui_input(event: InputEvent, map_id: String, thumb_panel: Panel) -> void:
	# Get the button that sent this event to check exists state
	var exists = true
	var info = {}
	for child in thumb_panel.get_children():
		if child is Button and child.has_meta("exists"):
			exists = child.get_meta("exists")
			info = child.get_meta("info") if child.has_meta("info") else {}
			break
	
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				_drag_start_pos = event.position
				_drag_map_id = map_id
			else:
				# Mouse released
				if _dragging:
					_end_drag(event.global_position)
				else:
					# It was a click, not a drag
					if exists:
						_on_card_selected(map_id, thumb_panel)
					else:
						_on_missing_map_clicked(map_id, info)
				_dragging = false
				_drag_map_id = ""
	
	elif event is InputEventMouseMotion:
		if _drag_map_id != "" and not _dragging:
			# Check if we've moved enough to start dragging
			var distance = event.position.distance_to(_drag_start_pos)
			if distance > DRAG_THRESHOLD and _view_mode == "grid":
				_start_drag(_drag_map_id)
		
		if _dragging:
			_update_drag_preview(event.global_position)


func _start_drag(map_id: String) -> void:
	_dragging = true
	
	# Create drag preview
	if _drag_preview_node != null and is_instance_valid(_drag_preview_node):
		_drag_preview_node.queue_free()
	
	var info = _map_index.get(map_id, {})
	_drag_preview_node = Label.new()
	_drag_preview_node.text = info.get("name", "Unknown")
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.3, 0.5, 0.9)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_drag_preview_node.add_stylebox_override("normal", style)
	
	# Add to explorer window so it's on top
	if _explorer_window != null and is_instance_valid(_explorer_window):
		_explorer_window.add_child(_drag_preview_node)


func _update_drag_preview(global_pos: Vector2) -> void:
	if _drag_preview_node != null and is_instance_valid(_drag_preview_node):
		# Convert to local position in explorer window
		if _explorer_window != null and is_instance_valid(_explorer_window):
			var local_pos = _explorer_window.get_global_transform().affine_inverse().xform(global_pos)
			_drag_preview_node.rect_position = local_pos + Vector2(10, 10)
	
	# Highlight folder under mouse
	_update_folder_drag_highlight(global_pos)


func _update_folder_drag_highlight(global_pos: Vector2) -> void:
	if _folder_list_container == null or not is_instance_valid(_folder_list_container):
		return
	
	var hover_folder = _find_folder_at_position(global_pos)
	
	# Check if dragged map is already in a folder
	var drag_map_folder = ""
	if _drag_map_id != "" and _map_index.has(_drag_map_id):
		drag_map_folder = _map_index[_drag_map_id].get("folder", "")
	
	for panel in _folder_list_container.get_children():
		if not panel is PanelContainer:
			continue
		if not panel.has_meta("folder_name"):
			continue
		
		var folder_name = panel.get_meta("folder_name")
		var is_hover = (folder_name == hover_folder)
		var was_hover = panel.get_meta("is_drag_hover") if panel.has_meta("is_drag_hover") else false
		
		if is_hover != was_hover:
			panel.set_meta("is_drag_hover", is_hover)
			var style = panel.get_meta("panel_style")
			if style != null:
				if is_hover:
					# Check if map is already in this folder or moving from another folder
					var target_folder_value = "" if folder_name == "All" else folder_name
					if drag_map_folder != "" and drag_map_folder == target_folder_value:
						# Already in this folder - use gray
						style.bg_color = Color(0.35, 0.35, 0.35, 1.0)
						style.border_color = Color(0.5, 0.5, 0.5, 1.0)
					elif drag_map_folder != "":
						# Moving from another folder - use gray
						style.bg_color = Color(0.4, 0.4, 0.45, 1.0)
						style.border_color = Color(0.55, 0.55, 0.6, 1.0)
					else:
						# New assignment - use green
						style.bg_color = Color(0.25, 0.45, 0.25, 1.0)
						style.border_color = Color(0.4, 0.7, 0.4, 1.0)
					style.set_border_width_all(1)
				else:
					# Restore normal or selected style
					if folder_name == _current_folder:
						style.bg_color = Color(0.25, 0.35, 0.5, 1.0)
						style.border_color = Color(0.4, 0.55, 0.8, 1.0)
						style.set_border_width_all(1)
					else:
						style.bg_color = Color(0.15, 0.15, 0.18, 0.0)
						style.set_border_width_all(0)


func _find_folder_at_position(global_pos: Vector2) -> String:
	if _folder_list_container == null or not is_instance_valid(_folder_list_container):
		return ""
	
	for panel in _folder_list_container.get_children():
		if not panel is PanelContainer:
			continue
		var rect = Rect2(panel.rect_global_position, panel.rect_size)
		if rect.has_point(global_pos):
			if panel.has_meta("folder_name"):
				return panel.get_meta("folder_name")
	
	return ""


func _end_drag(global_pos: Vector2) -> void:
	# Clear folder highlights
	_update_folder_drag_highlight(Vector2(-9999, -9999))
	
	# Check if dropping on a folder first
	var target_folder = _find_folder_at_position(global_pos)
	if target_folder != "":
		# Assign map to folder (or remove from folder if "All")
		var folder_value = "" if target_folder == "All" else target_folder
		if _map_index.has(_drag_map_id):
			_map_index[_drag_map_id]["folder"] = folder_value
			_save_index()
			# Flash the folder green briefly to confirm drop
			_flash_folder_success(target_folder)
			_refresh_folder_list()
			_refresh_explorer_grid()
			print("[MapExplorer] Moved map to folder: %s" % target_folder)
	else:
		# Check if dropping on another card (reorder) - only in Custom sort mode
		if _current_sort == SORT_CUSTOM:
			var target_id = _find_card_at_position(global_pos)
			if target_id != "" and target_id != _drag_map_id:
				_do_reorder(_drag_map_id, target_id)
	
	# Clean up preview
	if _drag_preview_node != null and is_instance_valid(_drag_preview_node):
		_drag_preview_node.queue_free()
		_drag_preview_node = null


func _flash_folder_success(folder_name: String) -> void:
	# This will be called before _refresh_folder_list, so we just print for now
	# The visual feedback is provided by the green highlight during drag
	pass


func _find_card_at_position(global_pos: Vector2) -> String:
	if _grid_container == null or not is_instance_valid(_grid_container):
		return ""
	
	for card in _grid_container.get_children():
		if not card.has_meta("map_id"):
			continue
		
		var rect = Rect2(card.rect_global_position, card.rect_size)
		if rect.has_point(global_pos):
			return card.get_meta("map_id")
	
	return ""


func _do_reorder(source_id: String, target_id: String) -> void:
	var source_idx = _filtered_ids_order.find(source_id)
	var target_idx = _filtered_ids_order.find(target_id)
	
	if source_idx == -1 or target_idx == -1:
		return
	
	# Move source to target position
	_filtered_ids_order.remove(source_idx)
	if source_idx < target_idx:
		target_idx -= 1
	_filtered_ids_order.insert(target_idx, source_id)
	
	# Update custom_order for all maps in the filtered list
	for i in range(_filtered_ids_order.size()):
		var mid = _filtered_ids_order[i]
		if _map_index.has(mid):
			_map_index[mid]["custom_order"] = i
	
	_save_index()
	_refresh_explorer_grid()
	print("[MapExplorer] Reordered: %s moved to position %d" % [source_id, target_idx])


func _create_map_card(map_id: String, info: Dictionary) -> Control:
	var path = info.get("path", "")
	var name = info.get("name", "Unknown")
	var thumb_file = info.get("thumb_file", "")
	var thumb_path = THUMB_DIR + thumb_file
	var last_saved = str(info.get("last_saved", ""))
	var map_width = int(info.get("width", 0))
	var map_height = int(info.get("height", 0))
	
	var f = File.new()
	var exists = f.file_exists(path)
	
	var card = VBoxContainer.new()
	card.rect_min_size = Vector2(_preview_size, _preview_size * 0.7)
	card.set("custom_constants/separation", 2)
	card.set_meta("map_id", map_id)  # Store map_id for drag and drop
	
	# Thumbnail panel - width based on _preview_size, variable height based on image
	var thumb_panel = Panel.new()
	thumb_panel.rect_min_size = Vector2(_preview_size, _preview_size * 0.65)  # Default size
	thumb_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.13, 0.13, 0.16, 1.0)
	panel_style.border_color = Color(0.25, 0.25, 0.3, 1.0) if exists else Color(0.4, 0.3, 0.25, 0.8)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(3)
	thumb_panel.add_stylebox_override("panel", panel_style)
	thumb_panel.set_meta("map_id", map_id)
	thumb_panel.set_meta("panel_style", panel_style)
	thumb_panel.set_meta("exists", exists)
	thumb_panel.set_meta("default_border", panel_style.border_color)
	
	var thumb_btn = Button.new()
	thumb_btn.anchor_right = 1.0
	thumb_btn.anchor_bottom = 1.0
	thumb_btn.flat = true
	thumb_btn.set_meta("map_id", map_id)
	thumb_btn.set_meta("thumb_panel", thumb_panel)
	thumb_btn.connect("gui_input", self, "_on_card_gui_input", [map_id, thumb_panel])
	thumb_panel.add_child(thumb_btn)
	
	# Hover effect - connect on button since it's on top
	thumb_btn.connect("mouse_entered", self, "_on_card_hover", [thumb_panel, true])
	thumb_btn.connect("mouse_exited", self, "_on_card_hover", [thumb_panel, false])
	
	var thumb_rect = TextureRect.new()
	thumb_rect.anchor_right = 1.0
	thumb_rect.anchor_bottom = 1.0
	thumb_rect.margin_left = 2
	thumb_rect.margin_top = 2
	thumb_rect.margin_right = -2
	thumb_rect.margin_bottom = -2
	thumb_rect.expand = true
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	if f.file_exists(thumb_path):
		var img = Image.new()
		if img.load(thumb_path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img)
			thumb_rect.texture = tex
			# Adjust panel height based on image ratio
			var img_ratio = float(img.get_height()) / float(img.get_width())
			var panel_height = int(_preview_size * img_ratio)
			thumb_panel.rect_min_size = Vector2(_preview_size, panel_height)
	
	thumb_btn.add_child(thumb_rect)
	
	# Favorite button (top-right corner)
	var fav_btn = Button.new()
	fav_btn.flat = true
	fav_btn.anchor_left = 1.0
	fav_btn.anchor_right = 1.0
	fav_btn.margin_left = -28
	fav_btn.margin_right = -4
	fav_btn.margin_top = -1
	fav_btn.margin_bottom = 23
	var is_fav = _favorites.has(map_id)
	if is_fav and _fav_icon_on != null:
		fav_btn.icon = _fav_icon_on
	elif not is_fav and _fav_icon_off != null:
		fav_btn.icon = _fav_icon_off
	else:
		fav_btn.text = "*" if is_fav else "-"
	fav_btn.hint_tooltip = "Remove from favorites" if is_fav else "Add to favorites"
	fav_btn.set_meta("is_fav", is_fav)
	fav_btn.connect("pressed", self, "_on_toggle_favorite", [map_id])
	fav_btn.connect("mouse_entered", self, "_on_fav_btn_hover", [fav_btn, true])
	fav_btn.connect("mouse_exited", self, "_on_fav_btn_hover", [fav_btn, false])
	thumb_panel.add_child(fav_btn)
	
	if exists:
		thumb_btn.hint_tooltip = path
	else:
		thumb_rect.modulate = Color(0.5, 0.5, 0.5, 0.7)
		thumb_panel.modulate = Color(0.8, 0.8, 0.8, 0.9)
		thumb_btn.hint_tooltip = "MISSING: " + path
	
	# Store exists state for gui_input handler
	thumb_btn.set_meta("exists", exists)
	thumb_btn.set_meta("info", info)
	
	card.add_child(thumb_panel)
	
	# Name (hidden when _hide_info is true)
	var name_label = Label.new()
	var display_name = name if name.length() <= 24 else name.substr(0, 21) + "..."
	name_label.text = ("[!] " + display_name) if not exists else display_name
	name_label.align = Label.ALIGN_CENTER
	if not exists:
		name_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	name_label.visible = not _hide_info
	card.add_child(name_label)
	
	# Size (hidden when _hide_info is true)
	var size_label = Label.new()
	size_label.text = "%d × %d" % [map_width, map_height] if map_width > 0 else ""
	size_label.align = Label.ALIGN_CENTER
	size_label.modulate = Color(0.5, 0.5, 0.5, 1.0)
	size_label.visible = not _hide_info
	card.add_child(size_label)
	
	# Date (hidden when _hide_info is true)
	var date_label = Label.new()
	date_label.text = _format_date(last_saved)
	date_label.align = Label.ALIGN_CENTER
	date_label.modulate = Color(0.45, 0.45, 0.45, 1.0)
	date_label.visible = not _hide_info
	card.add_child(date_label)
	
	return card


func _create_list_header() -> Control:
	var header = HBoxContainer.new()
	header.set("custom_constants/separation", 8)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	
	var panel = PanelContainer.new()
	panel.add_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var hbox = HBoxContainer.new()
	hbox.set("custom_constants/separation", 25)
	panel.add_child(hbox)
	
	# Fav column (small) - sortable
	var fav_btn = Button.new()
	if _fav_icon_hover != null:
		fav_btn.icon = _fav_icon_hover
	else:
		fav_btn.text = "*"
	fav_btn.rect_min_size = Vector2(24, 0)
	fav_btn.flat = true
	fav_btn.hint_tooltip = "Sort by favorites"
	fav_btn.connect("pressed", self, "_on_list_sort_column", ["fav"])
	hbox.add_child(fav_btn)
	
	# Thumbnail column (not sortable)
	var thumb_header = Label.new()
	thumb_header.text = ""
	thumb_header.rect_min_size = Vector2(50, 0)
	hbox.add_child(thumb_header)
	
	# Name column (expandable) - sortable
	var name_btn = Button.new()
	name_btn.text = _get_column_header_text("name")
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.flat = true
	name_btn.align = Button.ALIGN_LEFT
	name_btn.hint_tooltip = "Sort by name"
	name_btn.connect("pressed", self, "_on_list_sort_column", ["name"])
	hbox.add_child(name_btn)
	
	# Size column - sortable
	var size_btn = Button.new()
	size_btn.text = _get_column_header_text("size")
	size_btn.rect_min_size = Vector2(70, 0)
	size_btn.flat = true
	size_btn.hint_tooltip = "Sort by size"
	size_btn.connect("pressed", self, "_on_list_sort_column", ["size"])
	hbox.add_child(size_btn)
	
	# Date column - sortable
	var date_btn = Button.new()
	date_btn.text = _get_column_header_text("date")
	date_btn.rect_min_size = Vector2(90, 0)
	date_btn.flat = true
	date_btn.hint_tooltip = "Sort by date"
	date_btn.connect("pressed", self, "_on_list_sort_column", ["date"])
	hbox.add_child(date_btn)
	
	# Packs column - sortable
	var packs_btn = Button.new()
	packs_btn.text = _get_column_header_text("packs")
	packs_btn.rect_min_size = Vector2(50, 0)
	packs_btn.flat = true
	packs_btn.hint_tooltip = "Sort by pack count"
	packs_btn.connect("pressed", self, "_on_list_sort_column", ["packs"])
	hbox.add_child(packs_btn)
	
	# Default assets column - sortable
	var default_btn = Button.new()
	default_btn.text = _get_column_header_text("default")
	default_btn.rect_min_size = Vector2(55, 0)
	default_btn.flat = true
	default_btn.hint_tooltip = "Sort by default assets"
	default_btn.connect("pressed", self, "_on_list_sort_column", ["default"])
	hbox.add_child(default_btn)
	
	# Folder column - sortable
	var folder_btn = Button.new()
	folder_btn.text = _get_column_header_text("folder")
	folder_btn.rect_min_size = Vector2(80, 0)
	folder_btn.flat = true
	folder_btn.hint_tooltip = "Sort by folder"
	folder_btn.connect("pressed", self, "_on_list_sort_column", ["folder"])
	hbox.add_child(folder_btn)
	
	return panel


func _create_list_row(map_id: String, info: Dictionary) -> Control:
	var path = info.get("path", "")
	var name = info.get("name", "Unknown")
	var thumb_file = info.get("thumb_file", "")
	var thumb_path = THUMB_DIR + thumb_file
	var last_saved = str(info.get("last_saved", ""))
	var map_width = int(info.get("width", 0))
	var map_height = int(info.get("height", 0))
	
	var f = File.new()
	var exists = f.file_exists(path)
	
	# Read pack info from map file
	var pack_count = 0
	var uses_default = false
	if exists and f.open(path, File.READ) == OK:
		var content = f.get_as_text()
		f.close()
		var parsed = JSON.parse(content)
		if parsed.error == OK and parsed.result is Dictionary:
			var header = parsed.result.get("header", {})
			var manifest = header.get("asset_manifest", [])
			pack_count = manifest.size()
			uses_default = bool(header.get("uses_default_assets", false))
	
	var row_style = StyleBoxFlat.new()
	row_style.bg_color = Color(0.13, 0.13, 0.16, 1.0)
	row_style.border_color = Color(0.25, 0.25, 0.3, 1.0) if exists else Color(0.4, 0.3, 0.25, 0.8)
	row_style.set_border_width_all(1)
	row_style.content_margin_left = 4
	row_style.content_margin_right = 4
	row_style.content_margin_top = 2
	row_style.content_margin_bottom = 2
	
	var panel = PanelContainer.new()
	panel.add_stylebox_override("panel", row_style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.set_meta("map_id", map_id)
	panel.set_meta("row_style", row_style)
	panel.set_meta("exists", exists)
	panel.set_meta("default_border", row_style.border_color)
	
	var hbox = HBoxContainer.new()
	hbox.set("custom_constants/separation", 25)
	panel.add_child(hbox)
	
	# Favorite button
	var fav_btn = Button.new()
	fav_btn.flat = true
	fav_btn.rect_min_size = Vector2(24, 0)
	var is_fav = _favorites.has(map_id)
	if is_fav and _fav_icon_on != null:
		fav_btn.icon = _fav_icon_on
	elif not is_fav and _fav_icon_off != null:
		fav_btn.icon = _fav_icon_off
	else:
		fav_btn.text = "*" if is_fav else "-"
	fav_btn.set_meta("is_fav", is_fav)
	fav_btn.connect("pressed", self, "_on_toggle_favorite", [map_id])
	fav_btn.connect("mouse_entered", self, "_on_fav_btn_hover", [fav_btn, true])
	fav_btn.connect("mouse_exited", self, "_on_fav_btn_hover", [fav_btn, false])
	hbox.add_child(fav_btn)
	
	# Mini thumbnail
	var thumb_rect = TextureRect.new()
	thumb_rect.rect_min_size = Vector2(50, 35)
	thumb_rect.expand = true
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if f.file_exists(thumb_path):
		var img = Image.new()
		if img.load(thumb_path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img)
			thumb_rect.texture = tex
	if not exists:
		thumb_rect.modulate = Color(0.5, 0.5, 0.5, 0.7)
	hbox.add_child(thumb_rect)
	
	# Name (clickable button with drag support)
	var name_btn = Button.new()
	name_btn.flat = true
	name_btn.text = ("[!] " + name) if not exists else name
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.align = Button.ALIGN_LEFT
	name_btn.clip_text = true
	name_btn.set_meta("map_id", map_id)
	name_btn.set_meta("panel", panel)
	name_btn.set_meta("exists", exists)
	name_btn.set_meta("info", info)
	if exists:
		name_btn.connect("gui_input", self, "_on_list_row_gui_input", [map_id, panel])
		name_btn.hint_tooltip = path
	else:
		name_btn.modulate = Color(0.6, 0.6, 0.6, 1.0)
		name_btn.connect("pressed", self, "_on_missing_map_clicked", [map_id, info])
		name_btn.hint_tooltip = "MISSING: " + path
	hbox.add_child(name_btn)
	
	# Hover effect
	name_btn.connect("mouse_entered", self, "_on_list_row_hover", [panel, true])
	name_btn.connect("mouse_exited", self, "_on_list_row_hover", [panel, false])
	
	# Size
	var size_label = Label.new()
	size_label.text = "%d×%d" % [map_width, map_height] if map_width > 0 else "-"
	size_label.rect_min_size = Vector2(70, 0)
	size_label.align = Label.ALIGN_CENTER
	size_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	hbox.add_child(size_label)
	
	# Date
	var date_label = Label.new()
	date_label.text = _format_date(last_saved)
	date_label.rect_min_size = Vector2(90, 0)
	date_label.align = Label.ALIGN_CENTER
	date_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	hbox.add_child(date_label)
	
	# Pack count
	var packs_label = Label.new()
	packs_label.text = str(pack_count) if exists else "-"
	packs_label.rect_min_size = Vector2(50, 0)
	packs_label.align = Label.ALIGN_CENTER
	packs_label.modulate = Color(0.6, 0.6, 0.6, 1.0)
	hbox.add_child(packs_label)
	
	# Default assets
	var default_label = Label.new()
	default_label.text = "Yes" if uses_default else "No"
	default_label.rect_min_size = Vector2(55, 0)
	default_label.align = Label.ALIGN_CENTER
	default_label.modulate = Color(0.5, 0.8, 0.5, 1.0) if uses_default else Color(0.6, 0.6, 0.6, 0.5)
	hbox.add_child(default_label)
	
	# Folder
	var map_folder = info.get("folder", "")
	var folder_label = Label.new()
	folder_label.text = map_folder if map_folder != "" else "-"
	folder_label.rect_min_size = Vector2(80, 0)
	folder_label.align = Label.ALIGN_CENTER
	folder_label.clip_text = true
	folder_label.modulate = Color(0.7, 0.7, 0.8, 1.0) if map_folder != "" else Color(0.5, 0.5, 0.5, 0.5)
	hbox.add_child(folder_label)
	
	return panel


func _on_list_row_hover(panel: PanelContainer, is_hovering: bool) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	var style = panel.get_meta("row_style")
	if style == null:
		return
	
	# Don't change if this row is selected
	var map_id = panel.get_meta("map_id")
	if map_id != null and map_id in _selected_map_ids:
		return
	
	var default_border = panel.get_meta("default_border")
	if is_hovering:
		style.border_color = Color(0.5, 0.6, 0.7, 1.0)
		style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	else:
		style.border_color = default_border
		style.bg_color = Color(0.13, 0.13, 0.16, 1.0)


func _on_list_row_selected(map_id: String, panel: PanelContainer) -> void:
	# Use the same logic as card selection
	_on_card_selected(map_id, panel)


func _on_card_hover(panel: Panel, is_hovering: bool) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	var style = panel.get_meta("panel_style")
	if style == null:
		return
	
	# Don't change if this card is selected
	var map_id = panel.get_meta("map_id")
	if map_id != null and map_id in _selected_map_ids:
		return
	
	var default_border = panel.get_meta("default_border")
	if is_hovering:
		# Lighten border on hover
		style.border_color = Color(0.5, 0.6, 0.7, 1.0)
		style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	else:
		# Restore default
		style.border_color = default_border
		style.bg_color = Color(0.13, 0.13, 0.16, 1.0)


func _on_list_row_gui_input(event: InputEvent, map_id: String, panel: PanelContainer) -> void:
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				_drag_start_pos = event.global_position
				_drag_map_id = map_id
			else:
				# Mouse released
				if _dragging:
					_end_drag(event.global_position)
					_dragging = false
				else:
					# Normal click - select the row
					_on_list_row_selected(map_id, panel)
				# Always clear drag state on release
				_drag_map_id = ""
	
	elif event is InputEventMouseMotion:
		if _drag_map_id != "" and not _dragging:
			var dist = event.global_position.distance_to(_drag_start_pos)
			if dist > DRAG_THRESHOLD:
				_dragging = true
				_start_drag(_drag_map_id)
		
		if _dragging:
			_update_drag_preview(event.global_position)


func _on_toggle_favorite(map_id: String) -> void:
	if _favorites.has(map_id):
		_favorites.erase(map_id)
	else:
		_favorites[map_id] = true
	_save_prefs()
	_refresh_explorer_grid()


func _on_fav_btn_hover(fav_btn: Button, is_hovering: bool) -> void:
	if fav_btn == null or not is_instance_valid(fav_btn):
		return
	
	var is_fav = fav_btn.get_meta("is_fav") if fav_btn.has_meta("is_fav") else false
	
	if is_hovering:
		# Show fav2 (hover icon) when hovering - for both add and remove
		if _fav_icon_hover != null:
			fav_btn.icon = _fav_icon_hover
	else:
		# Restore original icon
		if is_fav and _fav_icon_on != null:
			fav_btn.icon = _fav_icon_on
		elif not is_fav and _fav_icon_off != null:
			fav_btn.icon = _fav_icon_off


func _on_card_selected(map_id: String, panel: Control) -> void:
	var current_time = OS.get_ticks_msec()
	
	# Check for double-click
	if map_id == _last_click_map_id and (current_time - _last_click_time) < DOUBLE_CLICK_TIME:
		# Double-click detected - open first selected
		_last_click_time = 0
		_last_click_map_id = ""
		if _selected_map_ids.size() > 0:
			_show_open_confirm_dialog(_selected_map_ids[0])
		return
	
	# Record this click for double-click detection
	_last_click_time = current_time
	_last_click_map_id = map_id
	
	var ctrl_pressed = Input.is_key_pressed(KEY_CONTROL) or Input.is_key_pressed(KEY_META)
	var shift_pressed = Input.is_key_pressed(KEY_SHIFT)
	
	if shift_pressed and _last_selected_id != "" and _filtered_ids_order.size() > 0:
		# Shift-click: select range
		_select_range(_last_selected_id, map_id)
	elif ctrl_pressed:
		# Ctrl-click: toggle selection
		if map_id in _selected_map_ids:
			_deselect_card(map_id)
		else:
			_select_card(map_id, panel)
		_last_selected_id = map_id
	else:
		# Normal click: clear and select one
		_clear_selection()
		_select_card(map_id, panel)
		_last_selected_id = map_id
	
	_update_buttons_state()


func _select_card(map_id: String, panel) -> void:
	if map_id in _selected_map_ids:
		return
	_selected_map_ids.append(map_id)
	_selected_cards[map_id] = panel
	_highlight_card(panel, true)


func _deselect_card(map_id: String) -> void:
	if not map_id in _selected_map_ids:
		return
	_selected_map_ids.erase(map_id)
	var panel = _selected_cards.get(map_id)
	if panel != null and is_instance_valid(panel):
		_highlight_card(panel, false)
	_selected_cards.erase(map_id)


func _clear_selection() -> void:
	for map_id in _selected_map_ids:
		var panel = _selected_cards.get(map_id)
		if panel != null and is_instance_valid(panel):
			_highlight_card(panel, false)
	_selected_map_ids = []
	_selected_cards = {}


func _highlight_card(panel, selected: bool) -> void:
	# Try panel_style (grid view) or row_style (list view)
	var style = panel.get_meta("panel_style")
	if style == null:
		style = panel.get_meta("row_style")
	if style == null:
		return
	
	var exists = panel.get_meta("exists")
	var default_border = panel.get_meta("default_border")
	
	if selected:
		style.border_color = Color(0.3, 0.5, 0.8, 1.0)
		if panel.has_meta("panel_style"):
			style.set_border_width_all(3)
		else:
			style.bg_color = Color(0.2, 0.25, 0.35, 1.0)
	else:
		style.border_color = default_border if default_border else (Color(0.25, 0.25, 0.3, 1.0) if exists else Color(0.4, 0.3, 0.25, 0.8))
		if panel.has_meta("panel_style"):
			style.set_border_width_all(2)
		else:
			style.bg_color = Color(0.13, 0.13, 0.16, 1.0)


func _select_range(from_id: String, to_id: String) -> void:
	var from_idx = _filtered_ids_order.find(from_id)
	var to_idx = _filtered_ids_order.find(to_id)
	
	if from_idx == -1 or to_idx == -1:
		return
	
	var start_idx = min(from_idx, to_idx)
	var end_idx = max(from_idx, to_idx)
	
	# Clear current selection first
	_clear_selection()
	
	# Select all in range - need to find panels
	for i in range(start_idx, end_idx + 1):
		var mid = _filtered_ids_order[i]
		var panel = _find_panel_for_map(mid)
		if panel != null:
			_select_card(mid, panel)


func _find_panel_for_map(map_id: String):
	# Search in grid container
	if _view_mode == "grid" and _grid_container != null:
		for child in _grid_container.get_children():
			for subchild in child.get_children():
				if subchild.has_meta("map_id") and subchild.get_meta("map_id") == map_id:
					return subchild
	# Search in list container
	elif _view_mode == "list" and _list_container != null:
		for child in _list_container.get_children():
			if child.has_meta("map_id") and child.get_meta("map_id") == map_id:
				return child
	return null


func _show_open_confirm_dialog(map_id: String) -> void:
	var info = _map_index.get(map_id)
	if info == null:
		return
	var path = info.get("path", "")
	var filename = path.get_file()
	
	var dialog = PopupPanel.new()
	
	# Style the popup panel with border
	var popup_style = StyleBoxFlat.new()
	popup_style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	popup_style.border_color = Color(0.6, 0.6, 0.6, 1.0)
	popup_style.set_border_width_all(1)
	popup_style.set_corner_radius_all(3)
	dialog.add_stylebox_override("panel", popup_style)
	
	var margin = MarginContainer.new()
	margin.set("custom_constants/margin_left", 20)
	margin.set("custom_constants/margin_right", 20)
	margin.set("custom_constants/margin_top", 15)
	margin.set("custom_constants/margin_bottom", 15)
	dialog.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.set("custom_constants/separation", 15)
	vbox.alignment = BoxContainer.ALIGN_CENTER
	margin.add_child(vbox)
	
	var msg = Label.new()
	msg.text = "Do you want to open %s?" % filename
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 20)
	vbox.add_child(btn_row)
	
	var open_btn = Button.new()
	open_btn.text = "Open"
	open_btn.rect_min_size = Vector2(80, 0)
	open_btn.connect("pressed", self, "_do_open_map", [map_id, dialog])
	_style_button(open_btn)
	btn_row.add_child(open_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.rect_min_size = Vector2(80, 0)
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	dialog.popup_centered()


func _do_open_map(map_id: String, dialog: Node) -> void:
	dialog.hide()
	var info = _map_index.get(map_id)
	if info == null:
		return
	var path = info.get("path", "")
	var f = File.new()
	if not f.file_exists(path):
		_on_missing_map_clicked(map_id, info)
		return
	_close_explorer_window()
	yield(_g.World.get_tree().create_timer(0.1), "timeout")
	_g.Editor.ForceOpenMap(path)
	print("[MapExplorer] Opening map: %s" % path)


func _format_date(datetime_str: String) -> String:
	if datetime_str == "":
		return ""
	# Format: "2024-01-15 14:30:00" -> "Jan 15, 2024"
	var date_part = datetime_str.split(" ")[0]
	var parts = date_part.split("-")
	if parts.size() >= 3:
		var months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		var month_idx = int(parts[1])
		if month_idx > 0 and month_idx <= 12:
			return "%s %d, %s" % [months[month_idx], int(parts[2]), parts[0]]
	return date_part


func _on_missing_map_clicked(map_id: String, info: Dictionary) -> void:
	_show_missing_map_dialog(map_id, info)


func _show_missing_map_dialog(map_id: String, info: Dictionary) -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "Map Not Found"
	dialog.rect_min_size = Vector2(380, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -6
	vbox.set("custom_constants/separation", 10)
	dialog.add_child(vbox)
	
	var msg = Label.new()
	msg.text = "'%s' not found" % info.get("name", "Unknown")
	msg.align = Label.ALIGN_CENTER
	vbox.add_child(msg)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 12)
	vbox.add_child(btn_row)
	
	var relink_btn = Button.new()
	relink_btn.text = "Relocate..."
	relink_btn.connect("pressed", self, "_on_relink_map", [map_id, dialog])
	btn_row.add_child(relink_btn)
	
	var remove_btn = Button.new()
	remove_btn.text = "Remove"
	remove_btn.connect("pressed", self, "_on_remove_map", [map_id, dialog])
	btn_row.add_child(remove_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(380, h)
	dialog.popup_centered()


func _on_relink_map(map_id: String, dialog: Node) -> void:
	dialog.hide()
	var file_dialog = FileDialog.new()
	file_dialog.mode = FileDialog.MODE_OPEN_FILE
	file_dialog.filters = PoolStringArray(["*.dungeondraft_map ; Dungeondraft Maps"])
	file_dialog.window_title = "Locate Map"
	file_dialog.connect("file_selected", self, "_on_map_relocated", [map_id])
	file_dialog.connect("popup_hide", file_dialog, "queue_free")
	_add_window(file_dialog)
	file_dialog.popup_centered(Vector2(600, 400))


func _on_map_relocated(new_path: String, map_id: String) -> void:
	if _map_index.has(map_id):
		_map_index[map_id]["path"] = new_path
		_map_index[map_id]["name"] = new_path.get_file().replace(".dungeondraft_map", "")
		_save_index()
		_refresh_explorer_grid()
		print("[MapExplorer] Map relocated: %s" % new_path)


func _on_remove_map(map_id: String, dialog: Node) -> void:
	dialog.hide()
	if _map_index.has(map_id):
		var thumb_file = _map_index[map_id].get("thumb_file", "")
		_map_index.erase(map_id)
		_save_index()
		if thumb_file != "":
			var dir = Directory.new()
			if dir.file_exists(THUMB_DIR + thumb_file):
				dir.remove(THUMB_DIR + thumb_file)
		if map_id in _selected_map_ids:
			_selected_map_ids.erase(map_id)
			_selected_cards.erase(map_id)
		_refresh_explorer_grid()
		_update_buttons_state()


func _close_explorer_window() -> void:
	if _explorer_window != null and is_instance_valid(_explorer_window):
		_explorer_window.hide()


func _on_new_map() -> void:
	# Close the gallery first
	_close_explorer_window()
	
	# Emit click on the New button in the toolbar
	if _g.Editor and _g.Editor.newButton:
		_g.Editor.newButton.emit_signal("pressed")


func _add_window(dialog: Node) -> void:
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)


func _style_button(btn: Button) -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.18, 0.22, 1.0)
	style.border_color = Color(0.6, 0.6, 0.6, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	btn.add_stylebox_override("normal", style)
	
	var hover = style.duplicate()
	hover.bg_color = Color(0.25, 0.25, 0.3, 1.0)
	btn.add_stylebox_override("hover", hover)
	
	var pressed = style.duplicate()
	pressed.bg_color = Color(0.15, 0.15, 0.18, 1.0)
	btn.add_stylebox_override("pressed", pressed)


func _style_dialog(dialog: WindowDialog) -> void:
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.15, 0.18, 1.0)
	panel_style.border_color = Color(1.0, 1.0, 1.0, 1.0)
	panel_style.set_border_width_all(1)
	dialog.add_stylebox_override("panel", panel_style)


# ── View Packs ───────────────────────────────────────────────────────────────

func _on_view_packs() -> void:
	if _selected_map_ids.size() == 0:
		return
	var map_id = _selected_map_ids[0]
	if not _map_index.has(map_id):
		return
	
	var info = _map_index[map_id]
	var path = info.get("path", "")
	var map_name = info.get("name", "Unknown")
	
	var f = File.new()
	if not f.file_exists(path):
		_show_message("Error", "Map file not found.")
		return
	
	# Read and parse the map file
	if f.open(path, File.READ) != OK:
		_show_message("Error", "Could not open map file.")
		return
	
	var content = f.get_as_text()
	f.close()
	
	var parsed = JSON.parse(content)
	if parsed.error != OK:
		_show_message("Error", "Could not parse map file.")
		return
	
	var map_data = parsed.result
	if not map_data is Dictionary or not map_data.has("header"):
		_show_message("Error", "Invalid map file format.")
		return
	
	var header = map_data.get("header", {})
	var uses_default = header.get("uses_default_assets", false)
	var asset_manifest = header.get("asset_manifest", [])
	
	# Scan the full map once: per-pack usage + per-type instance totals,
	# plus terrains assigned via the Terrain Slots Extended mod (sidecar).
	var audit = _audit_map(map_data, path)
	_packs_usage = audit["packs"]
	_packs_type_counts = audit["types"]
	
	_show_packs_window(path, map_name, uses_default, asset_manifest)


# ── Asset usage audit (file-based, similar to AssetManager) ──────────────────

const TSE_META_PATH := "user://UnofficialPatch/Terrain Slots Extended/terrain_slots_extended.json"


func _audit_map(map_data, map_path := "") -> Dictionary:
	# Counts only PLACED / PAINTED assets — never the available palettes (e.g.
	# the tileset lookup table, which lists every tileset of every enabled pack
	# whether or not it was ever placed).
	var used := {}          # pack_id -> { texture_path: true } (placed assets only)
	var types := {}         # type label -> count
	var terrain_set := {}   # distinct painted terrain texture paths
	var world = map_data.get("world", {}) if map_data is Dictionary else {}
	var levels = world.get("levels", {}) if world is Dictionary else {}
	if levels is Dictionary:
		for lk in levels.keys():
			var lvl = levels[lk]
			if not (lvl is Dictionary):
				continue
			# Discrete placed entities: one count per array element.
			_count_entity_array(lvl.get("objects"), "Objects", types)
			_count_entity_array(lvl.get("walls"), "Walls", types)
			_count_entity_array(lvl.get("portals"), "Portals", types)
			_count_entity_array(lvl.get("lights"), "Lights", types)
			_count_entity_array(lvl.get("paths"), "Paths", types)
			_count_entity_array(lvl.get("patterns"), "Patterns", types)
			var roofs = lvl.get("roofs", {})
			if roofs is Dictionary:
				_count_entity_array(roofs.get("roofs"), "Roofs", types)
			# Tiles actually painted (decode cells against the lookup table).
			_count_placed_tiles(lvl.get("tiles", {}), types, used)
			# Cave only if it was actually carved.
			_count_cave(lvl.get("cave", {}), types, used)
			# Pack usage for all placed content (objects, walls, shapes, water…),
			# skipping palettes/settings and the specials handled above/below.
			_credit_level_packs(lvl, used)
	# Vanilla terrain (slots 1-8): painted channels of the splat.
	_account_vanilla_terrain(map_data, used, terrain_set)
	# Terrain Slots Extended (slots 9-24): sidecar paths + splat PNG paint.
	for p in _get_extended_painted_terrains(map_path):
		_account_painted_terrain(p, used, terrain_set)
	if terrain_set.size() > 0:
		types["Terrain"] = terrain_set.size()
	var pack_counts := {}
	for pid in used.keys():
		pack_counts[pid] = used[pid].size()
	return {"packs": pack_counts, "types": types}


func _count_entity_array(arr, label: String, types: Dictionary) -> void:
	# Each element is one placed entity; add its count to the type.
	if not (arr is Array) or arr.size() == 0:
		return
	types[label] = types.get(label, 0) + arr.size()


func _credit_level_packs(lvl: Dictionary, used: Dictionary) -> void:
	# Credit pack usage from every placed-content key. Excludes palettes/settings
	# and the specials (tiles/terrain/cave) which are credited with placed/painted
	# filtering elsewhere, so a merely-loaded pack is never counted as used.
	var skip = {
		"tiles": true, "terrain": true, "cave": true,
		"materials": true, "layers": true, "environment": true,
	}
	for k in lvl.keys():
		if skip.has(k):
			continue
		_credit_pack_usage(lvl[k], used)


func _count_placed_tiles(tiles, types: Dictionary, used: Dictionary) -> void:
	if not (tiles is Dictionary):
		return
	var used_idx = _poolint_used_indices(tiles.get("cells", ""))
	if used_idx.size() == 0:
		return
	var lookup = tiles.get("lookup", {})
	var distinct := {}
	for idx in used_idx.keys():
		var p = null
		if lookup is Dictionary:
			p = lookup.get(str(idx), null)
		elif lookup is Array and idx < lookup.size():
			p = lookup[idx]
		if p is String and p != "":
			distinct[p] = true
			_credit_pack(p, used)
	if distinct.size() > 0:
		types["Tiles"] = types.get("Tiles", 0) + distinct.size()


func _count_cave(cave, types: Dictionary, used: Dictionary) -> void:
	if not (cave is Dictionary):
		return
	if not (_poolbyte_has_nonzero(cave.get("bitmap", "")) or _poolbyte_has_nonzero(cave.get("entrance_bitmap", ""))):
		return
	var tex = cave.get("texture", "")
	if tex is String and tex != "":
		types["Caves"] = types.get("Caves", 0) + 1
		_credit_pack(tex, used)


func _credit_pack_usage(node, used: Dictionary) -> void:
	# Recursively credit pack usage for every res://packs/ string under a placed node.
	if node is Dictionary:
		for k in node.keys():
			_credit_pack_usage(node[k], used)
	elif node is Array:
		for it in node:
			_credit_pack_usage(it, used)
	elif node is String:
		_credit_pack(node, used)


func _credit_pack(path, used: Dictionary) -> void:
	if not (path is String):
		return
	var idx = path.find("res://packs/")
	if idx < 0:
		return
	var rest = path.substr(idx + 12)  # strip "res://packs/"
	var slash = rest.find("/")
	if slash > 0:
		var pid = rest.substr(0, slash)
		if not used.has(pid):
			used[pid] = {}
		used[pid][path] = true


func _poolint_used_indices(s) -> Dictionary:
	# Parses "PoolIntArray( -1, 0, 2, ... )" -> { index: true } for indices >= 0.
	var out := {}
	if not (s is String):
		return out
	var lp = s.find("(")
	if lp < 0:
		return out
	var rp = s.rfind(")")
	var inner = s.substr(lp + 1) if rp <= lp else s.substr(lp + 1, rp - lp - 1)
	for tok in inner.split(",", false):
		var v = int(tok.strip_edges())
		if v >= 0:
			out[v] = true
	return out


func _poolbyte_has_nonzero(s) -> bool:
	if not (s is String) or s == "":
		return false
	var lp = s.find("(")
	if lp < 0:
		return false
	var rp = s.rfind(")")
	var inner = s.substr(lp + 1) if rp <= lp else s.substr(lp + 1, rp - lp - 1)
	for tok in inner.split(",", false):
		if int(tok.strip_edges()) > 0:
			return true
	return false


func _account_painted_terrain(path, used: Dictionary, terrain_set: Dictionary) -> void:
	# Credits a painted terrain texture to the distinct-terrain set + pack usage.
	if not (path is String) or path == "":
		return
	terrain_set[path] = true
	_credit_pack(path, used)


func _account_vanilla_terrain(map_data, used: Dictionary, terrain_set: Dictionary) -> void:
	if not (map_data is Dictionary):
		return
	var world = map_data.get("world", {})
	if not (world is Dictionary):
		return
	var levels = world.get("levels", {})
	if not (levels is Dictionary):
		return
	for lk in levels.keys():
		var lvl = levels[lk]
		if not (lvl is Dictionary):
			continue
		var terr = lvl.get("terrain", {})
		if not (terr is Dictionary):
			continue
		if not bool(terr.get("enabled", true)):
			continue
		# splat -> slots 1-4 (R,G,B,A), splat2 -> slots 5-8
		var painted = _splat_painted_channels(terr.get("splat", ""))
		var p2 = _splat_painted_channels(terr.get("splat2", ""))
		for c in range(4):
			painted.append(p2[c])
		for s in range(8):
			if painted[s]:
				_account_painted_terrain(terr.get("texture_%d" % (s + 1), ""), used, terrain_set)


func _splat_painted_channels(s) -> Array:
	# Parses a DD "PoolByteArray( r, g, b, a, ... )" string and returns
	# [bool, bool, bool, bool] = whether each RGBA channel has any non-zero byte.
	var found = [false, false, false, false]
	if not (s is String) or s == "":
		return found
	var lp = s.find("(")
	if lp < 0:
		return found
	var rp = s.rfind(")")
	var inner = s.substr(lp + 1) if rp <= lp else s.substr(lp + 1, rp - lp - 1)
	var parts = inner.split(",", false)
	var c = 0
	for tok in parts:
		if int(tok.strip_edges()) > 0:
			found[c] = true
		c += 1
		if c >= 4:
			c = 0
		if found[0] and found[1] and found[2] and found[3]:
			break
	return found


func _get_extended_painted_terrains(map_path: String) -> Array:
	# Returns the distinct terrain paths whose Terrain Slots Extended slot (9-24)
	# is actually painted (non-empty splat channel), across all levels.
	var result := {}
	if map_path == "":
		return []
	var f = File.new()
	if not f.file_exists(TSE_META_PATH):
		return []
	if f.open(TSE_META_PATH, File.READ) != OK:
		return []
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return []
	var all = parsed.result
	if not all.has(map_path) or not (all[map_path] is Dictionary):
		return []
	var levels = all[map_path].get("levels", {})
	if not (levels is Dictionary):
		return []
	var key = map_path.sha256_text()
	for lvl_key in levels.keys():
		var lvl = levels[lvl_key]
		if not (lvl is Dictionary):
			continue
		var lp = lvl.get("paths", [])
		if not (lp is Array):
			continue
		var painted = _painted_extended_slots(key, str(lvl_key))
		for i in range(min(lp.size(), 16)):
			if i < painted.size() and painted[i]:
				var p = lp[i]
				if p is String and p != "":
					result[p] = true
	return result.keys()


func _painted_extended_slots(map_key: String, lvl_key: String) -> Array:
	# 16 bools (slots 9-24). splat3 -> slots 0..3, splat4 -> 4..7,
	# splat5 -> 8..11, splat6 -> 12..15; within a splat: R,G,B,A.
	var painted := []
	for i in range(16):
		painted.append(false)
	var base = "user://UnofficialPatch/Terrain Slots Extended/" + map_key + "_L" + lvl_key
	_mark_painted_channels(base + ".s3.png", painted, 0)
	_mark_painted_channels(base + ".s4.png", painted, 4)
	_mark_painted_channels(base + ".s5.png", painted, 8)
	_mark_painted_channels(base + ".s6.png", painted, 12)
	return painted


func _mark_painted_channels(png_path: String, painted: Array, offset: int) -> void:
	var f = File.new()
	if not f.file_exists(png_path):
		return
	var img = Image.new()
	if img.load(png_path) != OK:
		return
	img.convert(Image.FORMAT_RGBA8)
	# Downsample for speed; any painted stroke survives a 256px bilinear shrink.
	if img.get_width() > 256 or img.get_height() > 256:
		img.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	var data = img.get_data()
	var n = data.size()
	var found = [false, false, false, false]
	var i = 0
	while i + 3 < n:
		if not found[0] and data[i] > 0: found[0] = true
		if not found[1] and data[i + 1] > 0: found[1] = true
		if not found[2] and data[i + 2] > 0: found[2] = true
		if not found[3] and data[i + 3] > 0: found[3] = true
		if found[0] and found[1] and found[2] and found[3]:
			break
		i += 4
	for c in range(4):
		if found[c]:
			painted[offset + c] = true


func _build_type_stats_text() -> String:
	if _packs_type_counts.empty():
		return "No asset textures found."
	var order = ["Objects", "Walls", "Portals", "Paths", "Lights", "Patterns", "Roofs", "Terrain", "Tiles", "Caves", "Materials"]
	var text = ""
	var total = 0
	for t in order:
		if _packs_type_counts.has(t):
			if text != "":
				text += "     "
			text += "%s: %d" % [t, _packs_type_counts[t]]
			total += _packs_type_counts[t]
	# Any types not in the predefined order
	for t in _packs_type_counts.keys():
		if not (t in order):
			if text != "":
				text += "     "
			text += "%s: %d" % [t, _packs_type_counts[t]]
			total += _packs_type_counts[t]
	return text + "     (Total: %d)" % total


func _pack_entry_id(pack: Dictionary) -> String:
	for key in ["id", "ID", "Id"]:
		if pack.has(key):
			return str(pack[key])
	return ""


# ── Packs Window with Edit Mode ──────────────────────────────────────────────

var _packs_dialog = null
var _packs_map_path := ""
var _packs_edit_mode := false
var _packs_default_checkbox : CheckButton = null
var _packs_list_container = null
var _packs_footer = null
var _packs_data := []  # Current packs list (modified in edit mode)
var _packs_original_default := false
var _packs_original_data := []
var _packs_usage := {}  # pack_id -> count of unique textures used in the map
var _packs_type_counts := {}  # asset type -> total instance count in the map


func _show_packs_window(map_path: String, map_name: String, uses_default: bool, packs: Array) -> void:
	_packs_map_path = map_path
	_packs_edit_mode = false
	_packs_original_default = uses_default
	_packs_original_data = packs.duplicate(true)
	_packs_data = packs.duplicate(true)
	
	var dialog = WindowDialog.new()
	_packs_dialog = dialog
	dialog.window_title = "Asset Packs - " + map_name
	dialog.rect_min_size = Vector2(420, 180)
	dialog.resizable = true
	
	# Add white border to the window
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.15, 0.18, 1.0)
	panel_style.border_color = Color(1.0, 1.0, 1.0, 1.0)
	panel_style.set_border_width_all(1)
	dialog.add_stylebox_override("panel", panel_style)
	
	var main_vbox = VBoxContainer.new()
	main_vbox.anchor_right = 1.0
	main_vbox.anchor_bottom = 1.0
	main_vbox.margin_left = 12
	main_vbox.margin_right = -12
	main_vbox.margin_top = 8
	main_vbox.margin_bottom = -8
	main_vbox.set("custom_constants/separation", 2)
	dialog.add_child(main_vbox)
	
	# Default assets row with CheckButton
	var default_hbox = HBoxContainer.new()
	default_hbox.set("custom_constants/separation", 8)
	main_vbox.add_child(default_hbox)
	
	var default_label = Label.new()
	default_label.text = "Default Assets:"
	default_hbox.add_child(default_label)
	
	_packs_default_checkbox = CheckButton.new()
	_packs_default_checkbox.pressed = uses_default
	_packs_default_checkbox.text = ""  # No text, just ON/OFF switch
	_packs_default_checkbox.disabled = true  # Disabled until edit mode
	default_hbox.add_child(_packs_default_checkbox)
	
	# Separator
	main_vbox.add_child(HSeparator.new())
	
	# Packs section - reduced vertical margin
	var packs_label = Label.new()
	packs_label.text = "Asset Packs (%d):" % packs.size()
	packs_label.name = "PacksLabel"
	main_vbox.add_child(packs_label)
	
	# Asset count by type (instances placed on the map)
	var stats_label = Label.new()
	stats_label.text = _build_type_stats_text()
	stats_label.autowrap = true
	stats_label.modulate = Color(0.6, 0.7, 0.85, 1.0)
	main_vbox.add_child(stats_label)
	main_vbox.add_child(HSeparator.new())
	
	# Scroll container for packs list
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll)
	
	_packs_list_container = VBoxContainer.new()
	_packs_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_packs_list_container.set("custom_constants/separation", 4)
	scroll.add_child(_packs_list_container)
	
	_rebuild_packs_list()
	
	# Footer
	_packs_footer = HBoxContainer.new()
	_packs_footer.set("custom_constants/separation", 12)
	main_vbox.add_child(_packs_footer)
	
	_rebuild_footer()
	
	dialog.connect("popup_hide", self, "_on_packs_window_closed")
	_add_window(dialog)
	
	# Calculate height based on content
	var base_height = 210
	var pack_count = packs.size()
	var content_height = base_height + min(pack_count, 6) * 36
	dialog.popup_centered(Vector2(440, max(260, min(content_height, 440))))


func _on_packs_window_closed() -> void:
	if _packs_dialog != null and is_instance_valid(_packs_dialog):
		_packs_dialog.queue_free()
	_packs_dialog = null
	_packs_list_container = null
	_packs_default_checkbox = null
	_packs_footer = null


func _rebuild_footer() -> void:
	if _packs_footer == null:
		return
	
	for child in _packs_footer.get_children():
		child.queue_free()
	
	if _packs_edit_mode:
		# Edit mode: Purge Unused on left, centered Save and Cancel
		_packs_footer.alignment = BoxContainer.ALIGN_BEGIN
		
		var purge_btn = Button.new()
		purge_btn.text = "Purge Unused"
		purge_btn.hint_tooltip = "Remove all packs that have no used assets in this map"
		purge_btn.connect("pressed", self, "_on_purge_unused")
		_style_button(purge_btn)
		_packs_footer.add_child(purge_btn)
		
		var spacer = Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_packs_footer.add_child(spacer)
		
		var save_btn = Button.new()
		save_btn.text = "Save"
		save_btn.rect_min_size = Vector2(70, 0)
		save_btn.connect("pressed", self, "_on_save_packs_clicked")
		_style_button(save_btn)
		_packs_footer.add_child(save_btn)
		
		var cancel_btn = Button.new()
		cancel_btn.text = "Cancel"
		cancel_btn.rect_min_size = Vector2(70, 0)
		cancel_btn.connect("pressed", self, "_on_cancel_edit")
		_style_button(cancel_btn)
		_packs_footer.add_child(cancel_btn)
	else:
		# View mode: Edit on left, Close on right
		_packs_footer.alignment = BoxContainer.ALIGN_BEGIN
		
		var edit_btn = Button.new()
		edit_btn.text = "Edit"
		edit_btn.rect_min_size = Vector2(70, 0)
		edit_btn.connect("pressed", self, "_on_toggle_edit_mode")
		_style_button(edit_btn)
		_packs_footer.add_child(edit_btn)
		
		var spacer = Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_packs_footer.add_child(spacer)
		
		var close_btn = Button.new()
		close_btn.text = "Close"
		close_btn.rect_min_size = Vector2(70, 0)
		close_btn.connect("pressed", _packs_dialog, "hide")
		_style_button(close_btn)
		_packs_footer.add_child(close_btn)


func _on_toggle_edit_mode() -> void:
	_packs_edit_mode = true
	if _packs_default_checkbox:
		_packs_default_checkbox.disabled = false
	_rebuild_packs_list()
	_rebuild_footer()


func _on_cancel_edit() -> void:
	_packs_edit_mode = false
	# Restore original data
	_packs_data = _packs_original_data.duplicate(true)
	if _packs_default_checkbox:
		_packs_default_checkbox.disabled = true
		_packs_default_checkbox.pressed = _packs_original_default
	_rebuild_packs_list()
	_rebuild_footer()


func _rebuild_packs_list() -> void:
	if _packs_list_container == null:
		return
	
	for child in _packs_list_container.get_children():
		child.queue_free()
	
	# Update packs count label
	if _packs_dialog != null:
		var packs_label = _packs_dialog.get_node_or_null("VBoxContainer/PacksLabel")
		if packs_label == null:
			# Try to find it differently
			for child in _packs_dialog.get_children():
				if child is VBoxContainer:
					for subchild in child.get_children():
						if subchild is Label and subchild.name == "PacksLabel":
							packs_label = subchild
							break
		if packs_label:
			packs_label.text = "Asset Packs (%d):" % _packs_data.size()
	
	if _packs_data.size() == 0:
		var no_packs = Label.new()
		no_packs.text = "No external asset packs used."
		no_packs.modulate = Color(0.6, 0.6, 0.6, 1.0)
		_packs_list_container.add_child(no_packs)
	else:
		for i in range(_packs_data.size()):
			var pack = _packs_data[i]
			var pack_row = _create_pack_row(pack, i)
			_packs_list_container.add_child(pack_row)


func _create_pack_row(pack: Dictionary, index: int) -> Panel:
	var panel = Panel.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 1.0)
	style.border_color = Color(0.3, 0.3, 0.35, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_stylebox_override("panel", style)
	
	var hbox = HBoxContainer.new()
	hbox.anchor_right = 1.0
	hbox.anchor_bottom = 1.0
	hbox.margin_left = 8
	hbox.margin_right = -8
	hbox.margin_top = 0
	hbox.margin_bottom = 0
	hbox.alignment = BoxContainer.ALIGN_CENTER
	hbox.set("custom_constants/separation", 6)
	panel.add_child(hbox)
	
	# Pack name - clips automatically when window is too small
	var name_label = Label.new()
	name_label.text = pack.get("name", "Unknown Pack")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.valign = Label.VALIGN_CENTER
	hbox.add_child(name_label)
	
	# Author (if present) - no cropping
	var author = pack.get("author", "")
	if author != "":
		var author_label = Label.new()
		author_label.text = "by %s" % author
		author_label.modulate = Color(0.55, 0.55, 0.55, 1.0)
		author_label.valign = Label.VALIGN_CENTER
		hbox.add_child(author_label)
	
	# Usage count badge - how many unique textures from this pack the map uses
	var pid = _pack_entry_id(pack)
	var used_count = _packs_usage.get(pid, 0)
	var count_label = Label.new()
	if used_count > 0:
		count_label.text = "%d used" % used_count
		count_label.modulate = Color(0.5, 0.8, 0.5, 1.0)
	else:
		count_label.text = "unused"
		count_label.modulate = Color(0.85, 0.45, 0.45, 1.0)
	count_label.valign = Label.VALIGN_CENTER
	count_label.rect_min_size = Vector2(70, 0)
	count_label.align = Label.ALIGN_RIGHT
	hbox.add_child(count_label)
	
	# Remove button (only in edit mode) - just the trash icon, no frame
	if _packs_edit_mode:
		var remove_btn = Button.new()
		remove_btn.hint_tooltip = "Remove this pack"
		remove_btn.flat = true  # No frame
		if _trash_icon_small != null:
			remove_btn.icon = _trash_icon_small
		else:
			remove_btn.text = "X"
		remove_btn.connect("pressed", self, "_on_remove_pack", [index])
		hbox.add_child(remove_btn)
	
	panel.rect_min_size = Vector2(0, 28)
	return panel


func _on_remove_pack(index: int) -> void:
	if index >= 0 and index < _packs_data.size():
		_packs_data.remove(index)
		_rebuild_packs_list()


func _on_purge_unused() -> void:
	var kept := []
	var removed := 0
	for pack in _packs_data:
		var pid = _pack_entry_id(pack)
		if _packs_usage.get(pid, 0) > 0:
			kept.append(pack)
		else:
			removed += 1
	if removed == 0:
		_show_message("Purge Unused", "All packs are in use. Nothing to purge.")
		return
	_packs_data = kept
	_rebuild_packs_list()
	_show_message("Purge Unused", "%d unused pack(s) removed from the list.\nClick Save to write the changes to the map file." % removed)


func _on_save_packs_clicked() -> void:
	# Check what changed
	var default_changed = (_packs_default_checkbox.pressed != _packs_original_default)
	var packs_removed = _packs_original_data.size() - _packs_data.size()
	
	if not default_changed and packs_removed == 0:
		_show_message("No Changes", "Nothing to save.")
		return
	
	# Build confirmation message
	var changes = []
	if default_changed:
		var new_state = "enabled" if _packs_default_checkbox.pressed else "disabled"
		changes.append("Default assets will be %s" % new_state)
	if packs_removed > 0:
		changes.append("%d pack(s) will be removed" % packs_removed)
	
	_show_save_confirm_dialog(changes)


func _show_save_confirm_dialog(changes: Array) -> void:
	var dialog = WindowDialog.new()
	dialog.window_title = "Confirm Changes"
	dialog.rect_min_size = Vector2(350, 0)
	_style_dialog(dialog)
	
	var vbox = VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 12
	vbox.margin_right = -12
	vbox.margin_top = 8
	vbox.margin_bottom = -6
	vbox.set("custom_constants/separation", 8)
	dialog.add_child(vbox)
	
	var title_label = Label.new()
	title_label.text = "Save changes to map file?"
	title_label.align = Label.ALIGN_CENTER
	vbox.add_child(title_label)
	
	for change in changes:
		var change_label = Label.new()
		change_label.text = "• " + change
		change_label.modulate = Color(0.8, 0.8, 0.5, 1.0)
		vbox.add_child(change_label)
	
	var warning = Label.new()
	warning.text = "This cannot be undone!"
	warning.align = Label.ALIGN_CENTER
	warning.modulate = Color(0.9, 0.5, 0.5, 1.0)
	vbox.add_child(warning)
	
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 20)
	vbox.add_child(btn_row)
	
	var save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.connect("pressed", self, "_do_save_packs", [dialog])
	_style_button(save_btn)
	btn_row.add_child(save_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.connect("pressed", dialog, "hide")
	_style_button(cancel_btn)
	btn_row.add_child(cancel_btn)
	
	dialog.connect("popup_hide", dialog, "queue_free")
	_add_window(dialog)
	
	yield(_g.World.get_tree(), "idle_frame")
	var h = vbox.rect_size.y + dialog.get_constant("title_height", "WindowDialog") + 16
	dialog.rect_size = Vector2(350, h)
	dialog.popup_centered()


func _do_save_packs(confirm_dialog: Node) -> void:
	confirm_dialog.hide()
	
	# Read the map file
	var f = File.new()
	if f.open(_packs_map_path, File.READ) != OK:
		_show_message("Error", "Could not open map file.")
		return
	
	var content = f.get_as_text()
	f.close()
	
	var parsed = JSON.parse(content)
	if parsed.error != OK:
		_show_message("Error", "Could not parse map file.")
		return
	
	var map_data = parsed.result
	
	# Modify the header
	map_data["header"]["uses_default_assets"] = _packs_default_checkbox.pressed
	map_data["header"]["asset_manifest"] = _packs_data
	
	# Write back
	if f.open(_packs_map_path, File.WRITE) != OK:
		_show_message("Error", "Could not write to map file.")
		return
	
	f.store_string(JSON.print(map_data, "\t"))
	f.close()
	
	# Update original data to reflect saved state
	_packs_original_default = _packs_default_checkbox.pressed
	_packs_original_data = _packs_data.duplicate(true)
	
	# Exit edit mode
	_packs_edit_mode = false
	_packs_default_checkbox.disabled = true
	_rebuild_packs_list()
	_rebuild_footer()
	
	print("[MapExplorer] Map packs saved: %s" % _packs_map_path)
	_show_message("Saved", "Map file updated successfully.")
