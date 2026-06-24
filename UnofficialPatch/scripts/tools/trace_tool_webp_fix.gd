var script_class = "tool"

var _done              := false
var _tool_panel
var _line_edit
var _clear_btn
var _global_node
var _world_node
var _zone              : PanelContainer = null
var _label             : Label          = null
var _panel_was_visible := false
var _threads           := []
var _converting        := false
var _original_name     := ""
var _last_lineedit_text := ""
var _saved_conns       := []
var _restore_checked   := false
var _current_map_path  := ""   # tracked per-map

const WORLD_PATH      = "/root/Master/ViewportContainer2D/Viewport2D/World"
const CACHE_DIR       = "user://UnofficialPatch/TraceToolWebp/"
const PATHS_FILE      = "user://UnofficialPatch/TraceToolWebp/map_paths.json"
const IMAGE_EXTS      = ["png", "jpg", "jpeg", "webp", "bmp", "tga", "tif", "tiff"]
const NO_CONV_EXTS    = ["png", "jpg", "jpeg"]
const DEFAULT_SCALE   = 1.0
const DEFAULT_OPACITY = 0.5
const MAX_NAME_LEN    = 32

const COLOR_IDLE    = Color(0.75, 0.75, 0.75)
const COLOR_HOVER   = Color(1.00, 1.00, 1.00)
const COLOR_SUCCESS = Color(0.4,  1.0,  0.4)
const COLOR_CONV    = Color(1.0,  0.85, 0.3)
const COLOR_ERROR   = Color(1.0,  0.4,  0.4)
const TEXT_IDLE     = "Drop image here\n(PNG, JPG, WebP...)"

func start() -> void:
	print("[TraceWebpFix] initialized")
	_done = false
	_tool_panel = null
	_line_edit = null
	_clear_btn = null
	_world_node = null
	_zone = null
	_label = null
	_panel_was_visible = false
	_last_lineedit_text = ""
	_original_name = ""
	_restore_checked = false
	_current_map_path = ""
	if _saved_conns.size() > 0:
		var tree := Engine.get_main_loop() as SceneTree
		for conn in _saved_conns:
			if is_instance_valid(conn.target) and not tree.is_connected("files_dropped", conn.target, conn.method):
				tree.connect("files_dropped", conn.target, conn.method,
					conn.get("binds", []), conn.get("flags", 0))
		_saved_conns.clear()
	var d := Directory.new()
	if not d.dir_exists(CACHE_DIR):
		d.make_dir(CACHE_DIR)

func update(_delta) -> void:
	for i in range(_threads.size() - 1, -1, -1):
		if not _threads[i].is_active():
			_threads[i].wait_to_finish()
			_threads.remove(i)

	if not _done:
		var tree := Engine.get_main_loop() as SceneTree
		if not tree or not tree.get_root():
			return
		_tool_panel = _search_trace_panel(tree.get_root())
		if not _tool_panel:
			return
		_line_edit   = _find_lineedit(_tool_panel)
		_clear_btn   = _find_clear_btn(_tool_panel)
		_global_node = tree.get_root().get_node_or_null("Global")
		_world_node  = tree.get_root().get_node_or_null(WORLD_PATH)
		_build_zone()
		if not tree.is_connected("files_dropped", self, "_on_files_dropped"):
			tree.connect("files_dropped", self, "_on_files_dropped")
		if _clear_btn and is_instance_valid(_clear_btn):
			if not _clear_btn.is_connected("pressed", self, "_on_clear_pressed"):
				_clear_btn.connect("pressed", self, "_on_clear_pressed")
		# Hook New Map button to clear trace.
		_hook_new_map_button(tree.get_root())
		_done = true
		print("[TraceWebpFix] ready  panel=", _tool_panel.get_path())
		call_deferred("_deferred_init")
		return

	if not _tool_panel or not is_instance_valid(_tool_panel):
		return

	# Track map path changes (save/open sets a new path).
	_poll_map_path()

	var visible_now := _tool_panel.visible
	if visible_now != _panel_was_visible:
		_panel_was_visible = visible_now
		var tree := Engine.get_main_loop() as SceneTree
		if visible_now:
			_saved_conns.clear()
			for conn in tree.get_signal_connection_list("files_dropped"):
				if conn.target == self:
					continue
				tree.disconnect("files_dropped", conn.target, conn.method)
				_saved_conns.append(conn)
			if _saved_conns.size() > 0:
				print("[TraceWebpFix] paused ", _saved_conns.size(), " other handler(s)")
		else:
			for conn in _saved_conns:
				if is_instance_valid(conn.target) and not tree.is_connected("files_dropped", conn.target, conn.method):
					tree.connect("files_dropped", conn.target, conn.method,
						conn.get("binds", []), conn.get("flags", 0))
			if _saved_conns.size() > 0:
				print("[TraceWebpFix] restored ", _saved_conns.size(), " handler(s)")
			_saved_conns.clear()

	if not _converting and _line_edit and is_instance_valid(_line_edit):
		var cur = str(_line_edit.get("text"))
		if cur != _last_lineedit_text:
			_last_lineedit_text = cur
			var is_empty = (cur == "" or cur == "Null" or cur == "null")
			if is_empty:
				_set_label(TEXT_IDLE, COLOR_IDLE)
				_original_name = ""
			else:
				_original_name = cur.get_file()
				_set_label(_truncate(_original_name), COLOR_IDLE)

	if not _converting and _zone and is_instance_valid(_zone) and _label and is_instance_valid(_label):
		var mouse := _zone.get_viewport().get_mouse_position()
		var over  := _zone.get_global_rect().has_point(mouse)
		_label.add_color_override("font_color", COLOR_HOVER if over else COLOR_IDLE)

# Poll the current map path from the window title or Global.
func _poll_map_path() -> void:
	var path := _get_map_path()
	if path == _current_map_path:
		return
	var was = _current_map_path
	_current_map_path = path
	if was != "" and path != "" and was != path:
		# Switched to a different saved map — attempt restore.
		_restore_checked = false
		call_deferred("_try_restore")
	elif path == "":
		# New unsaved map — clear trace image.
		_on_new_map()

func _get_map_path() -> String:
	# Try Global.MapPath or similar.
	if _global_node and is_instance_valid(_global_node):
		for prop in ["MapPath", "map_path", "FilePath", "CurrentFile"]:
			var v = _global_node.get(prop)
			if v and typeof(v) == TYPE_STRING and v != "":
				return v
	# Fallback: read window title (Dungeondraft puts map name in title).
	var title := OS.get_window_title()
	# Title format: "Dungeondraft - mapname.dungeondraft_map"
	if " - " in title:
		var parts = title.split(" - ", false, 1)
		if parts.size() > 1:
			var candidate = parts[1].strip_edges()
			if candidate.ends_with(".dungeondraft_map"):
				return candidate
	return ""

func _hook_new_map_button(root: Node) -> void:
	# Find the "New" button in the top menubar.
	var new_btn = _find_btn_by_hint(root, "New")
	if new_btn and not new_btn.is_connected("pressed", self, "_on_new_map_btn"):
		new_btn.connect("pressed", self, "_on_new_map_btn")
		print("[TraceWebpFix] hooked New button")

func _find_btn_by_hint(node: Node, hint: String):
	if not is_instance_valid(node): return null
	if (node.get_class() == "Button" or node.get_class() == "ToolButton") and node.hint_tooltip == hint:
		return node
	for child in node.get_children():
		var r = _find_btn_by_hint(child, hint)
		if r: return r
	return null

func _on_new_map_btn() -> void:
	# New map button clicked — clear after a frame so DD has time to reset.
	call_deferred("_on_new_map")

func _on_new_map() -> void:
	print("[TraceWebpFix] new map — clearing trace")
	_original_name = ""
	_last_lineedit_text = ""
	_current_map_path = ""
	_restore_checked = true   # don't try to restore on a new map
	_set_label(TEXT_IDLE, COLOR_IDLE)

func _deferred_init() -> void:
	# Detect map path now that everything is loaded.
	_current_map_path = _get_map_path()
	print("[TraceWebpFix] map path: '", _current_map_path, "'")
	_try_restore()

func _try_restore() -> void:
	if _restore_checked:
		return
	_restore_checked = true

	var cur_text := ""
	if _line_edit and is_instance_valid(_line_edit):
		cur_text = str(_line_edit.get("text"))
	var lineedit_broken = (cur_text == "" or cur_text == "Null" or
		cur_text == "null" or cur_text.begins_with("embedded://"))

	if not lineedit_broken:
		return

	if _current_map_path == "":
		return  # new unsaved map, nothing to restore

	var db := _load_db()
	if not db.has(_current_map_path):
		return

	var saved_path : String = db[_current_map_path]
	if saved_path == "" or not File.new().file_exists(saved_path):
		print("[TraceWebpFix] restore: cached path not found: ", saved_path)
		return

	print("[TraceWebpFix] restore: reapplying '", saved_path, "' for map '", _current_map_path, "'")
	_original_name = saved_path.get_file()
	_apply(saved_path)

# ── Persistence helpers ────────────────────────────────────────────────────

func _load_db() -> Dictionary:
	var f := File.new()
	if f.open(PATHS_FILE, File.READ) != OK:
		return {}
	var text := f.get_as_text()
	f.close()
	var result = JSON.parse(text)
	if result.error != OK:
		return {}
	if typeof(result.result) != TYPE_DICTIONARY:
		return {}
	return result.result

func _save_db(db: Dictionary) -> void:
	var f := File.new()
	if f.open(PATHS_FILE, File.WRITE) == OK:
		f.store_string(JSON.print(db, "  "))
		f.close()

func _save_path_for_map(image_path: String) -> void:
	if _current_map_path == "":
		return
	var db := _load_db()
	db[_current_map_path] = image_path
	_save_db(db)
	print("[TraceWebpFix] saved path for map '", _current_map_path, "'")

func _clear_path_for_map() -> void:
	if _current_map_path == "":
		return
	var db := _load_db()
	db.erase(_current_map_path)
	_save_db(db)

# ── Rest of the script ─────────────────────────────────────────────────────

func _on_clear_pressed() -> void:
	_original_name = ""
	_last_lineedit_text = ""
	_set_label(TEXT_IDLE, COLOR_IDLE)
	_clear_path_for_map()

func _truncate(name: String) -> String:
	if name.length() <= MAX_NAME_LEN:
		return name
	var ext  = "." + name.get_extension()
	var stem = name.get_basename().get_file()
	var keep = MAX_NAME_LEN - ext.length() - 3
	if keep < 4:
		return name.left(MAX_NAME_LEN - 3) + "..."
	return stem.left(keep) + "..." + ext

func _cache_path(source_path: String) -> String:
	var stem = source_path.get_file().get_basename()
	return CACHE_DIR + stem + ".png"

func _find_align(node: Node, depth: int = 0):
	if depth > 4: return null
	for child in node.get_children():
		if child is VBoxContainer and child.name == "Align":
			return child
		var r = _find_align(child, depth + 1)
		if r != null: return r
	return null


func _search_trace_panel(node: Node):
	if not is_instance_valid(node):
		return null
	if node.get_script() != null and node.get_class() == "ScrollContainer":
		var align = _find_align(node)
		if align:
			for child in align.get_children():
				if child.get_class() == "HBoxContainer":
					for btn in child.get_children():
						if btn.get_class() == "Button" and btn.hint_tooltip == "Browse":
							return node
	for child in node.get_children():
		var r = _search_trace_panel(child)
		if r: return r
	return null

func _find_lineedit(panel: Node):
	var align = _find_align(panel)
	if not align: return null
	for child in align.get_children():
		if child.get_class() == "HBoxContainer":
			for sub in child.get_children():
				if sub.get_class() == "LineEdit":
					return sub
	return null

func _find_clear_btn(panel: Node):
	var align = _find_align(panel)
	if not align: return null
	for child in align.get_children():
		if child.get_class() == "HBoxContainer":
			for btn in child.get_children():
				if btn.get_class() == "Button" and btn.hint_tooltip != "Browse":
					return btn
	return null

func _on_files_dropped(files: PoolStringArray, _screen: int) -> void:
	if not _tool_panel or not is_instance_valid(_tool_panel) or not _tool_panel.visible:
		return
	if not _zone or not is_instance_valid(_zone):
		return
	var mouse := _zone.get_viewport().get_mouse_position()
	if not _zone.get_global_rect().has_point(mouse):
		return
	for f in files:
		if f.get_extension().to_lower() in IMAGE_EXTS:
			_load_file(f)
			return

func _load_file(path: String) -> void:
	_original_name = path.get_file()
	if path.get_extension().to_lower() in NO_CONV_EXTS:
		_apply(path.replace("/", "\\"))
		return

	_converting = true
	_set_label("Converting...\n" + _truncate(_original_name), COLOR_CONV)
	var cache = _cache_path(path)
	var args = {"path": path, "temp": cache, "name": _original_name}
	var t = Thread.new()
	_threads.append(t)
	t.start(self, "_convert_thread", args)

func _convert_thread(args: Dictionary) -> void:
	var img := Image.new()
	if img.load(args.path) != OK:
		call_deferred("_conversion_done", "", args.name)
		return
	if img.save_png(args.temp) != OK:
		call_deferred("_conversion_done", "", args.name)
		return
	var final_path = ProjectSettings.globalize_path(args.temp).replace("/", "\\")
	call_deferred("_conversion_done", final_path, args.name)

func _conversion_done(final_path: String, orig_name: String) -> void:
	_converting = false
	if final_path == "":
		_set_label("Error loading file", COLOR_ERROR)
		yield((Engine.get_main_loop() as SceneTree).create_timer(2.0), "timeout")
		_set_label(TEXT_IDLE, COLOR_IDLE)
		return
	_original_name = orig_name
	_apply(final_path)

func _apply(final_path: String) -> void:
	if not _world_node or not is_instance_valid(_world_node):
		var tree := Engine.get_main_loop() as SceneTree
		_world_node = tree.get_root().get_node_or_null(WORLD_PATH)
		if not _world_node:
			_set_label("Error: World not found", COLOR_ERROR)
			return

	_world_node.call("AddTraceImage", final_path, DEFAULT_SCALE, DEFAULT_OPACITY)
	_tool_panel.call("SelectFile", final_path)
	_last_lineedit_text = final_path
	_save_path_for_map(final_path)
	print("[TraceWebpFix] applied: ", final_path)

	var short = _truncate(_original_name)
	_set_label(short, COLOR_SUCCESS)
	yield((Engine.get_main_loop() as SceneTree).create_timer(2.0), "timeout")
	if is_instance_valid(_label):
		_set_label(short, COLOR_IDLE)

func _set_label(text: String, color: Color) -> void:
	if not _label or not is_instance_valid(_label):
		return
	_label.text = text
	_label.add_color_override("font_color", color)

func _build_zone() -> void:
	var container = _find_align(_tool_panel)
	if not container: return
	if _zone and is_instance_valid(_zone):
		_zone.queue_free()
	_zone = PanelContainer.new()
	_zone.rect_min_size         = Vector2(0, 52)
	_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color     = Color(0.13, 0.13, 0.13, 0.6)
	style.border_color = Color(0.55, 0.55, 0.55, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	_zone.add_stylebox_override("panel", style)
	_label = Label.new()
	_label.text   = TEXT_IDLE
	_label.align  = Label.ALIGN_CENTER
	_label.valign = Label.VALIGN_CENTER
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_label.add_color_override("font_color", COLOR_IDLE)
	_zone.add_child(_label)
	container.add_child(_zone)
	container.move_child(_zone, 0)
	print("[TraceWebpFix] zone built")
