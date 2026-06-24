# preserve_selection_undo.gd
# ─────────────────────────────────────────────────────────────────────────────
# Preserve the SelectTool selection across undo/redo.
#
# Additional role: defensively clean DD's internal selection state when
# we detect disposed nodes in it. DD can leave dead entries in
# RawSelectables after a Ctrl+Z that removed an asset, which later
# crashes SelectTool.GetSelectionRect() when any tool (wall, select…)
# touches the selection.
#
# RawSelectables is a C# getter that reconstructs from an internal
# store; we can't remove entries from it directly. The only way to
# clean the dead refs is to call DeselectAll() which clears the
# internal store entirely. That also drops the user's selection — so
# we make sure to re-capture our snapshot beforehand so it can be
# restored next.

var script_class = "tool"
var _g

var _prev_selection_nids: Array = []
# Per-nid transform fingerprint captured alongside _prev_selection_nids.
# Used at restore time to detect if the undo actually touched these
# nodes — if their position/rotation/scale didn't change, the undo
# acted on something else and we shouldn't reselect them (otherwise
# the user keeps seeing the wrong asset selected after each Ctrl+Z
# walking back through actions on different assets).
# Map: node_id (int) -> { "pos": Vector2, "rot": float, "scl": Vector2 }
var _prev_selection_fingerprints: Dictionary = {}
# True if the last captured selection contained a real prefab (a node
# with a small positive prefab_id, i.e. a vanilla DD prefab — not a
# group_assets custom group). Used to preempt Ctrl+Z BEFORE DD
# disposes the Props: by the time the input event reaches us, DD has
# often already started destroying things, so live-inspecting the
# selection at that moment returns disposed wrappers and we miss the
# detection.
var _prev_selection_has_prefab: bool = false
var _prev_frame_sel_size: int = 0
var _restore_pending_frames: int = 0
const RESTORE_DELAY_FRAMES: int = 2
# Snapshot of the RawSelectables size when we last tried _handle_dead_in_selection
# and it didn't manage to drain the list. Used to skip redundant cleanup
# attempts on every frame when DD is in a state we can't recover from.
var _last_unrecoverable_raw_size: int = -1

# After a restore that includes walls, we hide DD's native box for a
# few frames to give DragSelectWalls's on_process time to detect the
# selection change and paint its custom box. Without this, DD's box
# flickers between the restore frame and DragSelectWalls catching up.
var _hide_dd_box_frames: int = 0
const HIDE_DD_BOX_FRAMES_AFTER_WALL_RESTORE: int = 5


var input_listener: Node = null
var _destroyed := false


func initialize():
	_prev_selection_nids = []
	_prev_frame_sel_size = 0
	_restore_pending_frames = 0
	_hide_dd_box_frames = 0
	_install_input_listener()
	print("[PreserveSelectionUndo] initialized")


func cleanup() -> void:
	_destroyed = true
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	print("[PreserveSelectionUndo] Cleaned up")


func _install_input_listener() -> void:
	# DD's _ContentInput handler crashes when RawSelectables contains
	# disposed Props (typical after a Ctrl+Z that destroys an asset).
	# By the time our update() runs in the frame, DD has often already
	# attempted to read the selection and thrown an exception that
	# leaves things in a half-broken state (e.g. an asset stuck under
	# the cursor, the panel hidden, etc).
	# We install a higher-priority input handler that flushes the
	# disposed refs the moment a relevant input arrives — before DD
	# gets a chance to process it.
	input_listener = Node.new()
	input_listener.name = "PreserveSelectionUndoListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


func _on_input(event) -> void:
	if _destroyed:
		return
	# Pre-flush disposed selection refs before DD's _ContentInput has
	# a chance to read them. Empirically this only helps in some cases
	# (DeselectAll doesn't always actually drain the store), but it's
	# cheap so we do it anyway.
	#
	# NOTE: a vanilla DD bug exists where deleting a selected prefab
	# via Ctrl+Z leaves disposed Props in DD's internal selection
	# store, causing the next click to crash SelectTool/PrefabTool.
	# We tried preempting Ctrl+Z by deselecting before the undo runs,
	# but DeselectAll/DeselectAllEx don't drain the store when a real
	# prefab is selected — DD retains the references in C# state we
	# can't reach from GDScript. Worked around for non-prefab cases
	# only.
	if _g == null:
		return
	var editor = _g.get("Editor")
	if editor == null:
		return
	var select_tool = editor.Tools.get("SelectTool")
	if select_tool == null:
		return
	var should_check = false
	if event is InputEventMouseButton and event.pressed:
		should_check = true
	elif event is InputEventKey and event.pressed and event.control:
		if event.scancode == KEY_Z or event.scancode == KEY_Y:
			should_check = true
	if should_check and _raw_has_dead(select_tool):
		_handle_dead_in_selection(select_tool)
		_prev_frame_sel_size = 0


func update(_delta):
	if _destroyed:
		return
	if _g == null:
		return
	var editor = _g.get("Editor")
	if editor == null:
		return
	var select_tool = editor.Tools.get("SelectTool")
	if select_tool == null:
		return
	
	# Only act when SelectTool is the active tool. Outside of it, the
	# selection box and the internal selection state aren't relevant to
	# the user, and forcing EnableTransformBox(true) or calling
	# SelectThing would make the box appear over other tools.
	if editor.ActiveToolName != "SelectTool":
		_prev_frame_sel_size = 0
		_restore_pending_frames = 0
		_hide_dd_box_frames = 0
		return
	
	# Suppress DD's native box for a few frames after a wall-inclusive
	# restore. DragSelectWalls's on_process takes one or more frames to
	# detect the selection change and paint its own box; without this
	# countdown, DD's native box flickers in the gap.
	if _hide_dd_box_frames > 0:
		_hide_dd_box_frames -= 1
		if select_tool.has_method("EnableTransformBox"):
			select_tool.call("EnableTransformBox", false)
	
	# Safety net: if DD's selection contains disposed nodes, flush it
	# entirely via DeselectAll(). This is the only way to remove them
	# because RawSelectables is a reconstructed getter — removing from
	# the returned array doesn't affect the internal store.
	# We schedule a restore afterwards only for the nodes that are still
	# alive, filtering the dead ones out.
	if _raw_has_dead(select_tool):
		# Skip if we already tried at this size and DD's state didn't
		# change — calling DeselectAll/DeselectAllEx every frame on a
		# state they can't drain just spams the console.
		var raw = select_tool.get("RawSelectables")
		var raw_size = 0 if raw == null else raw.size()
		if raw_size != _last_unrecoverable_raw_size:
			_handle_dead_in_selection(select_tool)
			# Re-check: if it's still dead, remember the size so we
			# skip the next frames at the same size.
			if _raw_has_dead(select_tool):
				var raw2 = select_tool.get("RawSelectables")
				_last_unrecoverable_raw_size = 0 if raw2 == null else raw2.size()
			else:
				_last_unrecoverable_raw_size = -1
		_prev_frame_sel_size = 0
		return
	# Selection is clean now — reset the unrecoverable guard so a
	# fresh dead state in the future gets a real cleanup attempt.
	_last_unrecoverable_raw_size = -1
	
	# Update the cached prefab flag from RawSelectables every frame.
	# We can't rely solely on _capture_selection because:
	#   - It walks `Selected` (not `RawSelectables`); the wrappers
	#     there don't always carry the prefab_id meta we need.
	#   - It only runs when _is_selection_stable is true; while
	#     dragging or in a transform mode it won't refresh.
	# Refreshing here from RawSelectables (which we know exposes the
	# real Things via .Thing) guarantees the flag is correct at
	# Ctrl+Z time.
	_prev_selection_has_prefab = _raw_contains_prefab(select_tool)
	
	var sel_now = select_tool.get("Selected")
	var sel_size = 0
	if sel_now != null:
		sel_size = sel_now.size()
	
	# Deferred restore.
	if _restore_pending_frames > 0:
		_restore_pending_frames -= 1
		if _restore_pending_frames == 0:
			_restore_selection(select_tool)
			sel_now = select_tool.get("Selected")
			sel_size = 0
			if sel_now != null:
				sel_size = sel_now.size()
			_capture_selection(select_tool)
		_prev_frame_sel_size = sel_size
		return
	
	# Detection: non-empty → empty while Ctrl held = undo/redo.
	if sel_size == 0 and _prev_frame_sel_size > 0 and _is_undo_redo_key_held():
		if _prev_selection_nids.size() > 0:
			_restore_pending_frames = RESTORE_DELAY_FRAMES
	else:
		if _is_selection_stable(select_tool):
			_capture_selection(select_tool)
	
	_prev_frame_sel_size = sel_size


func _is_undo_redo_key_held() -> bool:
	return Input.is_key_pressed(KEY_CONTROL) or Input.is_key_pressed(KEY_META)


func _is_selection_stable(select_tool) -> bool:
	var is_drawing = select_tool.get("isDrawing")
	if is_drawing != null and is_drawing:
		return false
	var tm = select_tool.get("transformMode")
	if tm != null and tm != 0:
		return false
	return true


func _raw_has_dead(select_tool) -> bool:
	var raw = select_tool.get("RawSelectables")
	if raw == null:
		return false
	for s in raw:
		if s == null:
			return true
		if not is_instance_valid(s):
			return true
		var thing = s.get("Thing")
		if thing == null:
			return true
		if not is_instance_valid(thing):
			return true
		if not thing.is_inside_tree():
			return true
		if thing.get_parent() == null:
			return true
	return false


func _handle_dead_in_selection(select_tool) -> void:
	# Try to clear DD's selection of disposed entries. Empirically,
	# DeselectAll / DeselectAllEx don't actually drain RawSelectables
	# when prefabs are involved — DD seems to retain references in an
	# internal store we can't reach from GDScript. We try anyway since
	# it works for non-prefab cases, then hide the transform box and
	# move on.
	if select_tool.has_method("DeselectAllEx"):
		select_tool.call("DeselectAllEx")
	if select_tool.has_method("DeselectAll"):
		select_tool.call("DeselectAll")
	if select_tool.has_method("EnableTransformBox"):
		select_tool.call("EnableTransformBox", false)
	_prev_selection_nids = []
	_prev_selection_fingerprints = {}


func _capture_selection(select_tool) -> void:
	var sel = select_tool.get("Selected")
	if sel == null:
		if _prev_selection_nids.size() > 0:
			_prev_selection_nids = []
			_prev_selection_fingerprints = {}
			_prev_selection_has_prefab = false
		return
	
	var current_nids: Array = []
	var current_fingerprints: Dictionary = {}
	var has_prefab := false
	for node in sel:
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_meta("node_id"):
			continue
		var nid = node.get_meta("node_id")
		if typeof(nid) != TYPE_INT or nid < 0:
			continue
		if current_nids.has(nid):
			continue
		current_nids.append(nid)
		if node is Node2D:
			current_fingerprints[nid] = {
				"pos": node.global_position,
				"rot": node.global_rotation,
				"scl": node.global_scale,
			}
		# Track real-prefab membership: a small positive prefab_id is
		# a vanilla DD prefab (group_assets uses pid >= 10000).
		if node.has_meta("prefab_id"):
			var pid = node.get_meta("prefab_id")
			if (typeof(pid) == TYPE_INT or typeof(pid) == TYPE_REAL) and pid > 0 and pid < 10000:
				has_prefab = true
	_prev_selection_has_prefab = has_prefab
	
	if current_nids == _prev_selection_nids:
		# Same selection, but transforms may have evolved (during a
		# drag for instance). Always refresh fingerprints so the next
		# Ctrl+Z compares against the latest stable state.
		_prev_selection_fingerprints = current_fingerprints
		return
	_prev_selection_nids = current_nids
	_prev_selection_fingerprints = current_fingerprints


func _restore_selection(select_tool) -> void:
	if _prev_selection_nids.empty():
		return
	if not select_tool.has_method("SelectThing"):
		return
	
	var world = null
	if _g != null:
		world = _g.get("World")
	if world == null or not world.has_method("HasNodeID"):
		return
	
	# Resolve every captured nid. If ANY is missing from the World now,
	# the undo was destructive (deleted at least one asset). In that
	# case we don't restore the selection at all — DD's own state is
	# inconsistent enough that re-selecting the survivors leads to
	# UI bugs (ghost transform box, broken copy, can't deselect, etc.)
	# Better to leave the selection cleared as DD did and let the user
	# re-select manually.
	var live_nodes: Array = []
	var any_missing := false
	for nid in _prev_selection_nids:
		if not world.HasNodeID(nid):
			any_missing = true
			break
		var node = world.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			any_missing = true
			break
		if not node.is_inside_tree() or node.get_parent() == null:
			any_missing = true
			break
		# An undo can hide a node without removing it from the tree —
		# clipboard_fix's PasteHistoryRecord toggles visibility +
		# processing on Ctrl+Z so Ctrl+Y can revive the same instance.
		# A hidden node is "gone" from the user's perspective; restoring
		# the selection on it would leave the transform box hovering
		# over invisible items.
		if node is CanvasItem and not node.visible:
			any_missing = true
			break
		live_nodes.append(node)
	
	if any_missing:
		_prev_selection_nids = []
		_prev_selection_fingerprints = {}
		return
	
	if live_nodes.empty():
		_prev_selection_nids = []
		_prev_selection_fingerprints = {}
		return
	
	# If none of the previously-selected nodes was actually touched
	# by this undo (their position/rotation/scale all match the
	# fingerprints we captured at selection time), the action being
	# undone affected something else. Don't restore — keeping our
	# stale selection would mean the user sees their last-clicked
	# asset selected even when each Ctrl+Z is walking back through
	# actions on completely different assets.
	var any_changed := false
	for node in live_nodes:
		if not (node is Node2D):
			any_changed = true
			break
		var nid = node.get_meta("node_id")
		var fp = _prev_selection_fingerprints.get(nid, null)
		if fp == null:
			# No fingerprint captured — be permissive and restore.
			any_changed = true
			break
		if node.global_position != fp["pos"]:
			any_changed = true
			break
		if node.global_rotation != fp["rot"]:
			any_changed = true
			break
		if node.global_scale != fp["scl"]:
			any_changed = true
			break
	if not any_changed:
		# Drop the snapshot so the next Ctrl+Z evaluates fresh.
		_prev_selection_nids = []
		_prev_selection_fingerprints = {}
		return
	
	# Restore all live nodes including walls. DragSelectWalls handles the
	# custom transform box for selections that contain walls (or wall +
	# non-wall mixes). When walls are present we skip our
	# EnableTransformBox call so DragSelectWalls can paint its own box —
	# forcing DD's native box would race with the custom one.
	var nodes_to_select: Array = []
	var first_type := -1
	var has_portal := false
	var has_wall := false
	for node in live_nodes:
		var type = -1
		if select_tool.has_method("GetSelectableType"):
			type = select_tool.call("GetSelectableType", node)
		nodes_to_select.append(node)
		if first_type == -1:
			first_type = type
		if type == 2 or type == 3:
			has_portal = true
		if type == 1:
			has_wall = true
	
	if nodes_to_select.empty():
		_prev_selection_nids = []
		return
	
	if select_tool.has_method("DeselectAll"):
		select_tool.call("DeselectAll")
	
	for node in nodes_to_select:
		select_tool.call("SelectThing", node, true)
	
	if first_type > 0 and _g != null:
		var toolset = _g.Editor.get("Toolset")
		if toolset != null and toolset.has_method("GetToolPanel"):
			var panel = toolset.call("GetToolPanel", "SelectTool")
			if panel != null and panel.has_method("OnSelect"):
				panel.call("OnSelect", first_type)
	# When walls are present, DragSelectWalls will paint its own custom
	# box and is responsible for hiding DD's native box each frame.
	# Problem: there's a 1-frame gap between our restore (which causes
	# DD to re-enable its box via panel.OnSelect) and the next time
	# DragSelectWalls's on_process runs and hides it. The gap is enough
	# to render DD's box for a single frame → visible flicker.
	#
	# Workaround: pump DragSelectWalls's on_process manually right now,
	# in the same frame, so it hides DD's box before the frame is
	# rendered. The countdown still runs as a safety net for subsequent
	# frames in case DD re-enables again.
	if has_wall:
		_hide_dd_box_frames = HIDE_DD_BOX_FRAMES_AFTER_WALL_RESTORE
		if select_tool.has_method("EnableTransformBox"):
			select_tool.call("EnableTransformBox", false)
		var dsw = null
		if _g.get("ModMapData") != null:
			dsw = _g.ModMapData.get("_drag_select_walls")
		if dsw != null and dsw.has_method("on_process"):
			dsw.call("on_process", 0.0)
	elif not has_portal:
		if select_tool.has_method("EnableTransformBox"):
			select_tool.call("EnableTransformBox", true)
