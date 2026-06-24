# pan_fix.gd
# Prevents selected assets from moving when panning the map
# (Space or middle mouse button) during a left-click drag

var _g
var select_tool
var ui_util
var input_listener: Node

var _left_held := false
var _pan_held := false
var _did_pan := false  # true if pan happened during this left click
var _saved_positions := {}

# Snapshots taken on pan start so HighlightThingAtPoint runs as a no-op
# during the pan. Restored on pan end. See _on_input for the rationale.
var _filter_menu = null         # the FILTER PopupMenu (C# SelectToolPanel)
var _toggled_filter_items := [] # indices we unchecked on pan start
var _texts_filter_was := null   # text_transform._texts_filter_enabled, if present

var _panel = null  # cached SelectTool panel

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[PanFix] Initialized")


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "PanFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _process(delta) -> void:\n\tif handler != null:\n\t\thandler._on_process(delta)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)
		# Process is only needed while panning; off by default
		input_listener.call_deferred("set_process", false)


func _get_panel():
	# Lazy cache; re-resolve if the cached node was freed
	if _panel == null or not is_instance_valid(_panel):
		_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	return _panel


func _on_input(event) -> void:
	# Cheap early-out: skip the vast majority of events (mouse motion spam,
	# unrelated keys, etc.) BEFORE doing any panel lookup.
	var is_mouse_btn = event is InputEventMouseButton
	var is_key = event is InputEventKey
	var is_motion = event is InputEventMouseMotion

	if not is_mouse_btn and not is_key:
		# Motion matters during a left-drag (to neutralize instant-drag)
		# OR during any pan (to consume the event and starve the hover scan)
		if not (is_motion and (_left_held or _pan_held)):
			return

	# Filter further: only the buttons/keys we actually care about
	if is_mouse_btn and event.button_index != BUTTON_LEFT and event.button_index != BUTTON_MIDDLE:
		return
	if is_key and event.scancode != KEY_SPACE:
		return

	# Only now do the (relatively) expensive panel visibility check
	var panel = _get_panel()
	if not (panel and panel is CanvasItem and panel.is_visible_in_tree()):
		return

	# Track pan keys (with edge detection so we can react to pan start/end)
	var pan_was_held = _pan_held
	if is_mouse_btn and event.button_index == BUTTON_MIDDLE:
		_pan_held = event.pressed
	if is_key and event.scancode == KEY_SPACE:
		_pan_held = event.pressed

	# Pan start/end → suppress hover scans.
	#
	# (1) DD's HighlightThingAtPoint() iterates Lights, Roofs, Portals,
	#     Walls, Paths, Patterns each motion event; each loop is gated by
	#     SelectTool.Filter[key] (Dictionary<string, bool>). Setting every
	#     entry to false turns the scan into O(1) (just dict lookups). The
	#     Filter popup only re-reads its checked state when opened, so
	#     flipping values during pan doesn't flash the UI.
	#
	# (2) text_transform.gd adds a "Texts" entry to the popup but stores
	#     its own _texts_filter_enabled flag — not in SelectTool.Filter.
	#     We flip it here too so the per-frame texts hover scan in
	#     text_transform's overlay _draw also short-circuits.
	#
	# (3) _pan_active flag is exposed for other mods (overlay_tool, etc.)
	#     that run their own per-frame hover scans.
	if not pan_was_held and _pan_held:
		_g.ModMapData["_pan_active"] = true
		_clear_current_highlight()
		_snapshot_and_clear_filters()
	elif pan_was_held and not _pan_held:
		_g.ModMapData["_pan_active"] = false
		_restore_filters()

	# Track left mouse
	if is_mouse_btn and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_left_held = true
			_did_pan = false
			if _pan_held:
				# Pan already active → block click entirely
				_did_pan = true
				_save_positions()
				input_listener.set_process(true)
				input_listener.get_tree().set_input_as_handled()
		else:
			# Left released → restore if we panned
			if _did_pan:
				_restore_positions()
			_left_held = false
			_did_pan = false
			_saved_positions = {}
			input_listener.set_process(false)

	# Left held, pan just started → save and kill transform
	if _left_held and not _did_pan and _pan_held:
		_did_pan = true
		_save_positions()
		_neutralize_instant_drag()
		select_tool.EnableTransformBox(false)
		select_tool.EnableTransformBox(true)
		input_listener.set_process(true)

	# During pan, keep killing any transform/instant-drag DD tries to start.
	# After a move, multiple SelectTool fields stay "dirty" (justManualMoved,
	# manualAction, movableThings, preMovePositions, moveDelta, instantDragTimer).
	# When the cursor is over the moved item, DD uses those on each motion event
	# to drive its instant-drag path → expensive. We force them back to neutral.
	if _did_pan and _left_held and is_motion:
		_neutralize_instant_drag()


func _on_process(_delta) -> void:
	# Force positions back every frame while panning
	if _did_pan and _left_held:
		for thing in _saved_positions:
			if is_instance_valid(thing):
				# Only assign if it actually drifted — setting global_position
				# can trigger transform notifications, shadow/light/occluder
				# recalcs etc., even when the value is unchanged.
				if thing.global_position != _saved_positions[thing]:
					thing.global_position = _saved_positions[thing]
	else:
		# Safety: shouldn't be processing if we're not panning
		input_listener.set_process(false)


func _clear_current_highlight() -> void:
	# DD only turns the hover box OFF at the top of HighlightThingAtPoint()
	# (Highlight(highlighted, false)), which is driven by motion events. During
	# pan we suppress that scan, so a box that was lit before the pan stays lit.
	# We turn it off directly via the asset's widget, mirroring DD's private
	# Highlight() switch on Selectable.Type.
	var hl = select_tool.get("highlighted")
	if hl == null:
		return
	var thing = hl.get("Thing")
	if thing == null or not is_instance_valid(thing):
		return
	var t = hl.get("Type")  # SelectableType enum (int)
	# 1=Wall 2=PortalFree 3=PortalWall 4=Object 5=Pathway 6=Light 7=PatternShape 8=Roof
	var w = null
	match t:
		1, 6, 7:                       # Wall / Light / PatternShape → GetWidget()
			if thing.has_method("GetWidget"):
				w = thing.call("GetWidget")
		5:                             # Pathway → .Widget property
			w = thing.get("Widget")
		2, 3, 4, 8:                    # Portal / Object / Roof → Highlight() on the thing itself
			w = thing
	if w != null and is_instance_valid(w) and w.has_method("Highlight"):
		w.call("Highlight", false)


func _find_filter_menu():
	if _filter_menu != null and is_instance_valid(_filter_menu):
		return _filter_menu

	# Primary: text_transform already resolved this exact PopupMenu (it added
	# the "Texts" item to it) and stored it as _filter_popup. Reuse it —
	# avoids re-walking the tree and is guaranteed to be the right node.
	var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
	if ttf != null and is_instance_valid(ttf):
		var p = ttf.get("_filter_popup")
		if p != null and is_instance_valid(p):
			_filter_menu = p
			return _filter_menu

	# Fallback: walk the tree like text_transform does at setup.
	if _g.Editor == null:
		return null
	var anchor = _g.Editor.get_node_or_null("VPartition/Panels/Tools/Anchor")
	if anchor == null:
		return null
	for child in anchor.get_children():
		if str(child.get("ForceTool")) != "SelectTool":
			continue
		var align = child.get_node_or_null("Divider/SelectToolPanel/Align")
		if align == null:
			return null
		for ch in align.get_children():
			if ch is MenuButton and str(ch.get("text")) == "FILTER":
				_filter_menu = ch.get_popup()
				return _filter_menu
		return null
	return null


func _snapshot_and_clear_filters() -> void:
	# We can't write select_tool.Filter directly: it's a C#
	# Dictionary<string, bool>, and GDScript indexing assigns to a marshaled
	# copy, not the live object. Instead we drive the same path the UI uses:
	# emit "id_pressed" on the FILTER PopupMenu, which runs the C# handler
	# SetFilterChecked() → writes the real dictionary.
	#
	# SetFilterChecked is a TOGGLE, so we only fire it for items currently
	# checked (to turn them off), and remember which ones to re-toggle later.
	# We skip index 0 ("All", a master toggle) and "Texts" (not a real
	# Filter key — handled separately below).
	_toggled_filter_items = []
	var menu = _find_filter_menu()
	if menu == null:
		print("[PanFix] FILTER menu NOT found — filter trick inactive")
	if menu != null:
		var n = 0
		for i in range(1, menu.get_item_count()):
			if menu.get_item_text(i) == "Texts":
				continue
			if menu.is_item_checked(i):
				menu.emit_signal("id_pressed", menu.get_item_id(i))
				_toggled_filter_items.append(i)
				n += 1
		print("[PanFix] pan start: unchecked %d filter items" % n)

	# Texts filter is managed by text_transform via its own flag, not by
	# select_tool.Filter. Flip it directly.
	_texts_filter_was = null
	var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
	if ttf != null and is_instance_valid(ttf):
		_texts_filter_was = ttf.get("_texts_filter_enabled")
		ttf.set("_texts_filter_enabled", false)


func _restore_filters() -> void:
	var menu = _find_filter_menu()
	if menu != null:
		for i in _toggled_filter_items:
			if i < menu.get_item_count():
				# Toggle back on (handler flips current state again)
				menu.emit_signal("id_pressed", menu.get_item_id(i))
	_toggled_filter_items = []

	if _texts_filter_was != null:
		var ttf = _g.ModMapData.get("_ttf_transform") if _g.ModMapData is Dictionary else null
		if ttf != null and is_instance_valid(ttf):
			ttf.set("_texts_filter_enabled", _texts_filter_was)
	_texts_filter_was = null


func _neutralize_instant_drag() -> void:
	# Reset every SelectTool field that drives instant-drag/transform on motion.
	if select_tool.get("transformMode") != 0:
		select_tool.set("transformMode", 0)
	if select_tool.get("manualAction") != 0:
		select_tool.set("manualAction", 0)
	if select_tool.get("justManualMoved"):
		select_tool.set("justManualMoved", false)
	var mt = select_tool.get("movableThings")
	if mt != null and not mt.empty():
		select_tool.set("movableThings", [])
	var pmp = select_tool.get("preMovePositions")
	if pmp != null and not pmp.empty():
		select_tool.set("preMovePositions", [])
	var md = select_tool.get("moveDelta")
	if md != null and md != Vector2.ZERO:
		select_tool.set("moveDelta", Vector2.ZERO)
	var idt = select_tool.get("instantDragTimer")
	if idt != null and idt != 0.0:
		select_tool.set("instantDragTimer", 0.0)


func _save_positions() -> void:
	_saved_positions = {}
	var raw = select_tool.RawSelectables
	if raw != null:
		for s in raw:
			if s == null or not is_instance_valid(s):
				continue
			var thing = s.get("Thing")
			if thing != null and is_instance_valid(thing) and thing is Node2D:
				_saved_positions[thing] = thing.global_position
	# Skip highlighted access - crashes with lights on the map


func _restore_positions() -> void:
	for thing in _saved_positions:
		if is_instance_valid(thing):
			thing.global_position = _saved_positions[thing]
	select_tool.EnableTransformBox(false)
	select_tool.EnableTransformBox(true)
