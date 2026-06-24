var _g  # Global reference
const PREVIEW_CHECK_INTERVAL = 0.5  # seconds between preview-size checks
const DEFAULT_PREVIEW_PERCENT := 15
const MIN_PREVIEW_PERCENT := 5
const MAX_PREVIEW_PERCENT := 100
var _patched_textures = {}


var _last_tool_name = ""
var _preview_nodes = []
var _was_focused = true
var _mouse_watcher = null
var _had_selection = false  # tracks whether SelectTool had objects selected
var _preview_check_accum = 0.0

# Configurable max preview height as % of screen height (loaded from disk).
var _max_preview_percent: int = DEFAULT_PREVIEW_PERCENT
var _prefs_hooked: bool = false
var _preview_slider = null
var _preview_spinbox = null
var _save_pending_frames: int = 0


func _settings_path() -> String:
	return "user://UnofficialPatch/PreviewFix/settings.json"


func _load_settings():
	var f = File.new()
	if f.open(_settings_path(), File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error == OK and parsed.result is Dictionary:
		var d = parsed.result
		if d.has("max_preview_percent"):
			var v = int(d["max_preview_percent"])
			if v < MIN_PREVIEW_PERCENT: v = MIN_PREVIEW_PERCENT
			if v > MAX_PREVIEW_PERCENT: v = MAX_PREVIEW_PERCENT
			_max_preview_percent = v


func _save_settings():
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch/PreviewFix"):
		dir.make_dir_recursive("user://UnofficialPatch/PreviewFix")
	var f = File.new()
	if f.open(_settings_path(), File.WRITE) == OK:
		f.store_string(JSON.print({"max_preview_percent": _max_preview_percent}, "\t"))
		f.close()


func _try_hook_preferences() -> void:
	# Inject "Max Preview Size" slider into Preferences > Interface tab.
	# Re-attempted every frame from update() until the Preferences node exists.
	if _prefs_hooked: return
	if not _g.Editor or not is_instance_valid(_g.Editor): return
	var prefs = _g.Editor.get_node_or_null("Windows/Preferences")
	if prefs == null: return
	var interface_vbox = prefs.get_node_or_null("Margins/VAlign/Interface")
	if interface_vbox == null: return
	# Avoid double-injection
	if interface_vbox.get_node_or_null("PreviewFixSizeRow") != null:
		_prefs_hooked = true
		return
	var row = HBoxContainer.new()
	row.name = "PreviewFixSizeRow"
	var lbl = Label.new()
	lbl.text = "Max Preview Size"
	# Match popup_blur's label width so the sliders align vertically in the
	# Interface tab. The "%" suffix on the SpinBox conveys the unit.
	lbl.rect_min_size = Vector2(170, 0)
	row.add_child(lbl)
	_preview_slider = HSlider.new()
	_preview_slider.min_value = MIN_PREVIEW_PERCENT
	_preview_slider.max_value = MAX_PREVIEW_PERCENT
	_preview_slider.step = 1
	_preview_slider.value = _max_preview_percent
	_preview_slider.rect_min_size = Vector2(150, 20)
	_preview_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_preview_slider.connect("value_changed", self, "_on_preview_slider")
	row.add_child(_preview_slider)
	_preview_spinbox = SpinBox.new()
	_preview_spinbox.min_value = MIN_PREVIEW_PERCENT
	_preview_spinbox.max_value = MAX_PREVIEW_PERCENT
	_preview_spinbox.step = 1
	_preview_spinbox.value = _max_preview_percent
	_preview_spinbox.suffix = "%"
	_preview_spinbox.rect_min_size = Vector2(70, 0)
	_preview_spinbox.connect("value_changed", self, "_on_preview_spinbox")
	row.add_child(_preview_spinbox)
	# Reset button
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.connect("pressed", self, "_on_preview_reset")
	row.add_child(reset_btn)
	interface_vbox.add_child(row)
	_prefs_hooked = true
	print("[PreviewFix] Max preview size slider injected in Preferences (value=", _max_preview_percent, "%)")


func _on_preview_slider(value: float) -> void:
	if _preview_spinbox != null and _preview_spinbox.value != value:
		_preview_spinbox.value = value
	_apply_preview_percent(int(value))


func _on_preview_spinbox(value: float) -> void:
	if _preview_slider != null and _preview_slider.value != value:
		_preview_slider.value = value
	_apply_preview_percent(int(value))


func _on_preview_reset() -> void:
	if _preview_slider != null: _preview_slider.value = DEFAULT_PREVIEW_PERCENT
	if _preview_spinbox != null: _preview_spinbox.value = DEFAULT_PREVIEW_PERCENT
	_apply_preview_percent(DEFAULT_PREVIEW_PERCENT)


func _apply_preview_percent(pct: int) -> void:
	if pct < MIN_PREVIEW_PERCENT: pct = MIN_PREVIEW_PERCENT
	if pct > MAX_PREVIEW_PERCENT: pct = MAX_PREVIEW_PERCENT
	if pct == _max_preview_percent: return
	_max_preview_percent = pct
	# Drop the patched-texture cache so currently-open previews re-resize
	# at the new ratio on the next scan tick. Restore originals first so we
	# don't try to re-patch an already-patched texture.
	_invalidate_patched_textures()
	# Debounce save: don't write to disk on every slider tick.
	_save_pending_frames = 30


func _invalidate_patched_textures() -> void:
	for nid in _patched_textures.keys():
		var entry = _patched_textures[nid]
		var obj = instance_from_id(nid)
		if obj != null and is_instance_valid(obj) and obj is TextureRect:
			obj.texture = entry["original"]
	_patched_textures.clear()


func initialize():
	_load_settings()
	# Create a Node that watches for mouse exit notification
	var script_src = """
extends Node

var preview_fix = null

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_MOUSE_EXIT:
		if preview_fix != null:
			preview_fix._on_mouse_exit_window()
	if what == MainLoop.NOTIFICATION_WM_MOUSE_ENTER:
		if preview_fix != null:
			preview_fix._on_mouse_enter_window()
"""
	var script = GDScript.new()
	script.source_code = script_src
	script.reload()
	_mouse_watcher = Node.new()
	_mouse_watcher.set_script(script)
	_mouse_watcher.preview_fix = self
	_mouse_watcher.name = "PreviewFixWatcher"
	_g.Editor.add_child(_mouse_watcher)
	print("[PreviewFix] Initialized with mouse watcher (max=", _max_preview_percent, "%)")

func _find_all_preview_containers(node, result):
	if node == null or not is_instance_valid(node): return
	if "preview" in node.name.to_lower() and node is PanelContainer:
		result.append(node)
	for child in node.get_children():
		_find_all_preview_containers(child, result)


func _find_child_texture_rect(node):
	if node is TextureRect: return node
	for child in node.get_children():
		var r = _find_child_texture_rect(child)
		if r != null: return r
	return null


func _limit_preview_sizes() -> void:
	# Scan only the Editor UI subtree — previews never live under World,
	# so this avoids walking thousands of map nodes on big maps.
	if _g.Editor == null or not is_instance_valid(_g.Editor): return
	var screen_h = OS.get_real_window_size().y
	var ratio = float(_max_preview_percent) / 100.0
	var max_h = int(screen_h * ratio)
	if max_h <= 0: return
	var found = []
	_find_all_preview_containers(_g.Editor, found)
	for node in found:
		if not is_instance_valid(node): continue
		var tex_rect = _find_child_texture_rect(node)
		if tex_rect == null: continue
		var nid = tex_rect.get_instance_id()
		if not node.visible:
			if _patched_textures.has(nid):
				tex_rect.texture = _patched_textures[nid]["original"]
				_patched_textures.erase(nid)
			continue
		var tex = tex_rect.texture
		if tex == null: continue
		if _patched_textures.has(nid) and _patched_textures[nid]["patched"] == tex: continue
		var th = tex.get_height()
		var tw = tex.get_width()
		if th <= max_h: continue
		var img = tex.get_data()
		if img == null: continue
		var r = float(max_h) / float(th)
		var new_w = max(int(tw * r), 1)
		img.resize(new_w, max_h, Image.INTERPOLATE_BILINEAR)
		var new_tex = ImageTexture.new()
		new_tex.create_from_image(img)
		var orig = tex
		if _patched_textures.has(nid):
			orig = _patched_textures[nid]["original"]
		_patched_textures[nid] = {"original": orig, "patched": new_tex}
		tex_rect.texture = new_tex
		node.rect_size = Vector2(new_w + 20, max_h + 50)


func update(delta):
	# Inject the Preferences slider as soon as the window exists.
	_try_hook_preferences()

	# Debounced save: write to disk only after the slider has been idle
	# for ~30 frames (~500ms) of no value change.
	if _save_pending_frames > 0:
		_save_pending_frames -= 1
		if _save_pending_frames == 0:
			_save_settings()

	# Throttle the (still recursive) preview-size scan — every frame is overkill,
	# a few times per second is more than enough for a visual resize.
	_preview_check_accum += delta
	if _preview_check_accum >= PREVIEW_CHECK_INTERVAL:
		_preview_check_accum = 0.0
		_limit_preview_sizes()

	# Detect tool change (including Escape which deselects tool)
	var current_tool = _g.Editor.ActiveToolName
	if current_tool != _last_tool_name:
		_last_tool_name = current_tool
		_hide_previews()
	
	# Detect window focus loss (handles click outside)
	var is_focused = OS.is_window_focused()
	if not is_focused:
		_hide_previews()
	if is_focused and not _was_focused:
		_hide_previews()
	_was_focused = is_focused
	
	# Detect asset deletion while preview is open:
	# if the selection just became empty, hide any visible preview.
	if current_tool == "SelectTool":
		var select_tool = _g.Editor.Tools["SelectTool"]
		var raw = select_tool.RawSelectables
		var has_selection = raw != null and raw.size() > 0
		if _had_selection and not has_selection and _has_visible_preview():
			_hide_previews()
		_had_selection = has_selection
	else:
		_had_selection = false

func _on_mouse_exit_window():
	_hide_previews()

func _on_mouse_enter_window():
	pass

func _has_visible_preview() -> bool:
	if _preview_nodes.size() == 0:
		_find_preview_nodes(_g.Editor)
	for node in _preview_nodes:
		if node != null and is_instance_valid(node) and node.visible:
			return true
	return false

func _hide_previews():
	if _preview_nodes.size() == 0:
		_find_preview_nodes(_g.Editor)
	for node in _preview_nodes:
		if node != null and is_instance_valid(node) and node.visible:
			node.visible = false

func _find_preview_nodes(root):
	_preview_nodes.clear()
	_scan_for_previews(root)

func _scan_for_previews(node):
	if node == null or not is_instance_valid(node):
		return
	var name_lower = node.name.to_lower()
	if "preview" in name_lower and (node is PopupPanel or node is Popup or node is PanelContainer or node is Panel):
		_preview_nodes.append(node)
	if node.get_class() == "ItemList" or "GridMenu" in str(node.get_class()):
		for child in node.get_children():
			if child is Popup or child is PopupPanel or child is Panel:
				if "preview" in child.name.to_lower() or child is PopupPanel:
					_preview_nodes.append(child)
	for child in node.get_children():
		_scan_for_previews(child)
