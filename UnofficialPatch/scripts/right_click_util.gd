# right_click_util.gd
# Central right-click context menu for SelectTool selections.
#
# Providers register to contribute items to the context menu.
# Each provider can implement (all optional):
#   check_right_click() -> bool       — return true to intercept the click
#   get_context_items(raw) -> Array   — return [{label, icon, action_id}]
#   on_context_action(action_id, raw) — handle a menu click

var _g
var ui_util

var _right_was_pressed := false
var _providers := []
var _context_menu: PopupMenu = null
var _popup_layer: CanvasLayer = null
var _item_map := []   # [{provider_idx, action_id}] — maps menu index to provider
var _last_raw = null


func initialize() -> void:
	print("[RightClickUtil] Initialized with ", _providers.size(), " provider(s)")


func register(provider) -> void:
	if provider in _providers:
		return
	_providers.append(provider)


func unregister(provider) -> void:
	if provider in _providers:
		_providers.erase(provider)


func update(_delta: float) -> void:
	var right_now = Input.is_mouse_button_pressed(BUTTON_RIGHT)
	if right_now and not _right_was_pressed:
		_on_right_click()
	_right_was_pressed = right_now


func _on_right_click() -> void:
	# Let providers intercept (e.g. favorites list click).
	# Providers run regardless of active tool — their asset panels are
	# visible everywhere (WallTool, PathTool, etc.).
	for p in _providers:
		if p.has_method("check_right_click") and p.check_right_click():
			return

	# The selection-based context menu only makes sense when SelectTool is
	# active. Calling SelectTool.GetSelectionRect() from another tool
	# CRASHES when DD's internal selection store contains disposed C#
	# nodes — the state DD leaves after a Ctrl+Z that removed a selected
	# asset. preserve_selection_undo.gd can clean those dead refs, but
	# only while SelectTool is the active tool; if the user Ctrl+Z's and
	# immediately switches to WallTool/PathTool, cleanup doesn't run and
	# the next right-click (e.g. to close a wall) would crash here.
	if _g == null:
		return
	var editor = _g.Editor
	if editor == null or not is_instance_valid(editor):
		return
	if editor.get("ActiveToolName") != "SelectTool":
		return

	# Don't show context menu when Free Transform is active
	if _g.ModMapData is Dictionary and _g.ModMapData.get("_free_transform_active", false):
		return

	# Get select tool + selection
	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return

	# Defense in depth: even with SelectTool active, if the selection
	# contains dead entries (edge case where cleanup hasn't run yet on
	# this frame), bail out. GetSelectionRect() would crash on them.
	if _raw_has_dead(raw):
		return

	# Check if cursor is near the selection box (256px screen space)
	if not _is_mouse_near_selection(select_tool):
		return

	# Ask each provider for items
	var all_items := []
	_item_map = []
	_last_raw = raw

	for pi in range(_providers.size()):
		var p = _providers[pi]
		if not p.has_method("get_context_items"):
			continue
		var items = p.get_context_items(raw)
		if items == null or items.size() == 0:
			continue
		# Add separator between providers (except before the first group)
		if all_items.size() > 0:
			all_items.append({label = "", icon = null, action_id = "", _sep = true})
			_item_map.append({provider_idx = -1, action_id = ""})
		for item in items:
			all_items.append(item)
			_item_map.append({provider_idx = pi, action_id = item.action_id})

	if all_items.size() == 0:
		return

	_show_popup(all_items)


func _show_popup(items: Array) -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null

	_context_menu = PopupMenu.new()

	for i in range(items.size()):
		var item = items[i]
		if item.get("_sep", false):
			_context_menu.add_separator()
		else:
			_context_menu.add_item(item.label, i)
			if item.icon != null:
				var idx = _context_menu.get_item_index(i)
				_context_menu.set_item_icon(idx, item.icon)

	_context_menu.connect("id_pressed", self, "_on_item_pressed")
	_context_menu.connect("popup_hide", self, "_on_popup_closed")

	_get_popup_layer().add_child(_context_menu)
	var mouse_pos = _g.World.get_tree().root.get_mouse_position()
	_context_menu.popup(Rect2(mouse_pos, Vector2(1, 1)))


func _on_item_pressed(id: int) -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null

	if id < 0 or id >= _item_map.size():
		return
	var mapping = _item_map[id]
	if mapping.provider_idx < 0:
		return
	var provider = _providers[mapping.provider_idx]
	if provider.has_method("on_context_action"):
		provider.on_context_action(mapping.action_id, _last_raw)


func _on_popup_closed() -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
		_context_menu = null


# ── Helpers ──────────────────────────────────────────────────────────────────

func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not tools is Dictionary:
		return null
	return tools.get("SelectTool")


func _raw_has_dead(raw) -> bool:
	# Mirror of preserve_selection_undo._raw_has_dead(): returns true if
	# any entry in SelectTool.RawSelectables refers to a disposed or
	# detached node. Touching GetSelectionRect() in that state crashes.
	if raw == null:
		return false
	for s in raw:
		if s == null or not is_instance_valid(s):
			return true
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			return true
		if not thing.is_inside_tree() or thing.get_parent() == null:
			return true
	return false


func _is_mouse_near_selection(select_tool) -> bool:
	var world_mouse = _g.WorldUI.get("MousePosition") if _g.WorldUI and is_instance_valid(_g.WorldUI) else null
	if world_mouse == null:
		return true  # can't check, allow
	if not select_tool.has_method("GetSelectionRect"):
		return true
	var sel_rect = select_tool.GetSelectionRect()
	if not sel_rect or not sel_rect is Rect2 or sel_rect.size.length() == 0:
		return true
	var cam = _g.Editor.get("Camera") if _g.Editor else null
	var zoom_factor = 1.0
	if cam and is_instance_valid(cam) and cam is Camera2D:
		zoom_factor = cam.zoom.x
	var margin = 256.0 * max(zoom_factor, 0.2)
	var expanded = sel_rect.grow(margin)
	return expanded.has_point(world_mouse)


func _get_popup_layer() -> CanvasLayer:
	if _popup_layer and is_instance_valid(_popup_layer):
		return _popup_layer
	_popup_layer = CanvasLayer.new()
	_popup_layer.name = "RightClickPopupLayer"
	_popup_layer.layer = 128
	_g.World.get_tree().root.add_child(_popup_layer)
	return _popup_layer
