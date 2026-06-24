# selection_resize.gd
# SelectTool resize improvements:
#   Alt   + resize = scale from center (anchor at box center, axes grow x2)
#   Shift + resize = snap dragged handle to next snap point
#                    Always snaps even if global Snap is OFF.
#                    Compatible with Snappy Mod (uses its custom snap points
#                    when custom_snap_enabled is true).
#
# Strategy:
#   * High-priority input listener catches left-mouse-down. On press, we
#     check if the cursor sits on one of the 8 transform handles of the
#     current selection box. If yes, we snapshot the state (without
#     consuming the event — DD still gets the click and starts its own
#     scale logic).
#   * Each frame while LMB is held AND modifier (Alt or Shift) is pressed,
#     we override DD's per-frame transform with our own (centered scale,
#     snapped handle).
#   * On mouse release we clear state. DD's RecordTransforms() captures
#     whatever positions items ended up at (ours if modifiers were held).
#
# We do NOT rely on transformMode because other mods (alt_deselect,
# pan_fix, etc.) can reset it mid-drag, which made the previous version
# of this mod fragile.
#
# Limitations:
#   * Skips rotated boxes (preDragTransform with non-identity basis).
#   * Walls are not repositioned by us; DD's native scale still applies
#     to them.

var _g
var ui_util
var _select_tool = null
var _input_listener: Node = null

# ── State (set on LMB press over a handle) ─────────────────────────────────
var _drag_active := false
# World position of the mouse at click time. Used as a reference to
# compute the mouse delta each frame (the dragged corner follows the
# mouse delta, not the absolute mouse position — that way an off-corner
# click within the handle hit zone doesn't immediately produce a non-1.0
# scale at frame 0).
var _pre_mouse := Vector2.ZERO
# World position of the actual AABB corner being dragged. Computed from
# the selection rect (the AABB corner nearest the click), independently
# of where the click actually landed inside the handle hit zone.
var _pre_corner := Vector2.ZERO
# Centre of the selection's world-axis-aligned bounding box at click time.
# AABB centre coincides with the asset centre for a single asset of any
# rotation (rotation is symmetric around the asset's origin).
var _world_center := Vector2.ZERO
# [{thing, pos, scale}]
var _item_states := []
# Once a modifier is detected during a drag, we hide DD's native transform
# box and own the transform. On release we refresh and re-show.
var _box_hidden := false

# ── Snappy mod detection (lazy, cached) ────────────────────────────────────
var _snappy_ref = null
var _snappy_searched := false

const SELECTABLE_WALL := 1
const SELECTABLE_PATHWAY := 5
const SELECTABLE_PATTERN_SHAPE := 7
# Diagnostic logging — set false once stable
const LOG := false

# Track Shift state explicitly per frame so path/pattern geometry restore
# logic doesn't ping-pong on diagonal-mouse moments where sx ≈ sy.
var _shift_held_last := false

# Recorded {Line2D node → was_visible} entries for dashed selection
# indicators we hid during a Shift drag. Restored at _end_drag.
var _dashed_hidden := []


func initialize() -> void:
	_select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[SelectionResize] Initialized")


# ── Input listener ─────────────────────────────────────────────────────────

func _install_input_listener() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -101
func _input(event) -> void:
	if handler != null:
		if handler._on_input(event):
			get_tree().set_input_as_handled()
"""
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "SelectionResizeListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _input_listener)


func _on_input(event) -> bool:
	if not (event is InputEventMouseButton):
		return false
	if event.button_index != BUTTON_LEFT:
		return false
	if event.pressed:
		return _try_begin_drag()
	# Release: not consumed (DD shouldn't be expecting it anyway if we
	# consumed the press; harmless either way).
	return false


# ── Begin / end ────────────────────────────────────────────────────────────

func _try_begin_drag() -> bool:
	if _drag_active:
		return false
	if _select_tool == null:
		return false

	# Don't fight Free Transform mod
	if _g.ModMapData is Dictionary and _g.ModMapData.get("_free_transform_active", false):
		return false

	# SelectTool must be active and visible
	var tools = _g.Editor.get("Toolset")
	if tools != null:
		var panels = tools.get("ToolPanels")
		if panels != null and panels.has("SelectTool"):
			if not panels["SelectTool"].visible:
				return false

	var raw = _select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return false

	if not _select_tool.has_method("GetSelectionRect"):
		if LOG: print("[SelectionResize] no GetSelectionRect method")
		return false
	var rect = _select_tool.GetSelectionRect()
	if not (rect is Rect2):
		return false
	var tl: Vector2 = rect.position
	var br: Vector2 = rect.position + rect.size
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return false

	if _g.WorldUI == null:
		return false
	var mouse = _g.WorldUI.MousePosition

	# Confirm we're on a handle. Trust DD's transformCorner (matches the
	# FDIAGSIZE-cursor hit zone exactly). Fall back to AABB-corner distance
	# if it isn't reported (e.g. just before DD's hover detection updates).
	var on_handle := false
	var dd_corner = _select_tool.get("transformCorner")
	if LOG: print("[SelectionResize] dd_corner=", dd_corner)
	if dd_corner != null and int(dd_corner) >= 0 and int(dd_corner) <= 3:
		on_handle = true
	else:
		# Fallback: AABB corner distance — only correct for non-rotated
		# selections, but acceptable as a fallback path.
		var corners_aabb = [tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)]
		var nearest_d = INF
		for c in corners_aabb:
			var d = mouse.distance_to(c)
			if d < nearest_d:
				nearest_d = d
		var zoom = 1.0
		var cam = _g.Editor.get("Camera") if _g.Editor else null
		if cam and is_instance_valid(cam) and cam is Camera2D:
			zoom = max(cam.zoom.x, 0.001)
		# DD's own handle hit zone is generous — we've seen click distances
		# of ~42 world units register as on-handle. 35 px screen tolerance
		# (then * zoom for world units) covers most realistic clicks while
		# staying narrower than half the smaller box dimension so mid-edge
		# clicks on small selections don't false-positive.
		var minor = min(rect.size.x, rect.size.y)
		var tol = min(35.0 * zoom, minor * 0.4)
		on_handle = nearest_d <= tol
		if LOG: print("[SelectionResize] fallback dist check: nearest_d=", nearest_d, " tol=", tol, " on_handle=", on_handle)
	if not on_handle:
		if LOG: print("[SelectionResize] mousedown ignored: not on a handle (mouse=", mouse, ")")
		return false

	# Snapshot
	_pre_mouse = mouse
	_world_center = (tl + br) * 0.5
	# Exact AABB corner position — pick the one nearest the click. The
	# click could be anywhere in the handle hit zone (a square around
	# the corner), but our scale math needs the corner itself as the
	# reference, otherwise a click offset turns into an immediate
	# non-1.0 scale at frame 0.
	var corners_aabb = [tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)]
	var nearest_d_sq = INF
	_pre_corner = mouse
	for c in corners_aabb:
		var d_sq = (mouse - c).length_squared()
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			_pre_corner = c
	_item_states.clear()
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if not (thing is Node2D):
			continue
		var t = _select_tool.GetSelectableType(thing)
		if t == SELECTABLE_WALL:
			continue
		var entry = {
			"thing": thing,
			"pos":   thing.global_position,
			"rot":   thing.global_rotation,
			"scale": thing.scale,
			"type":  t,
		}
		# Capture path / pattern LOCAL geometry for Shift-mode geometry
		# deformation. We never deform geometry under Alt-only / no-mod
		# (those rely on node.scale), but we restore geometry on each
		# non-Shift frame from this snapshot in case the user toggles
		# Shift on then off mid-drag.
		if t == SELECTABLE_PATHWAY:
			var ep = thing.get("EditPoints")
			if ep != null:
				var pts = []
				for p in ep:
					pts.append(p)
				entry["path_local_pts"] = pts
			entry["line_children"] = _snap_line2d_children(thing)
		elif t == SELECTABLE_PATTERN_SHAPE:
			var poly = thing.get("polygon")
			if poly != null and poly.size() > 0:
				var pts = []
				for p in poly:
					pts.append(p)
				entry["pattern_local_pts"] = pts
			entry["line_children"] = _snap_line2d_children(thing)
		_item_states.append(entry)

	if _item_states.empty():
		if LOG: print("[SelectionResize] no Node2D items in selection")
		return false

	_drag_active = true
	# Mark our drag as active in ModMapData so alt_deselect can skip
	# its handle_alt_click() when Alt is held during our drag — without
	# this, Alt+resize loses the selection because alt_deselect treats
	# the click as an Alt+click-deselect on the asset under the cursor.
	if _g.ModMapData != null:
		_g.ModMapData["_selection_resize_active"] = true
	if LOG: print("[SelectionResize] drag begin: items=", _item_states.size(), " pre_mouse=", _pre_mouse, " center=", _world_center)

	# If a modifier is already held at mousedown, own this drag from frame
	# 1: hide DD's box and consume the event so DD doesn't start a parallel
	# action (e.g. shift+click → rubber-band, alt+click → alt_deselect).
	var alt_held = Input.is_key_pressed(KEY_ALT)
	var shift_held = Input.is_key_pressed(KEY_SHIFT)
	if alt_held or shift_held:
		_hide_box()
		return true
	return false


func _end_drag() -> void:
	if LOG and _drag_active:
		print("[SelectionResize] drag end")
	# If we took ownership of the drag (any modifier was pressed → box
	# was hidden), build and push a single custom record that bundles
	# transform AND geometry changes. One Ctrl+Z reverts everything.
	# Done BEFORE restoring the box so DD's own RecordTransforms on
	# subsequent native scales doesn't get confused by our mid-drag
	# transform changes (we cleared initialRelativeTransforms in
	# _restore_box anyway).
	if _box_hidden:
		var rec = _build_group_record("Selection Resize")
		if rec != null:
			_push_history_record(rec)
	if _box_hidden:
		_restore_box()
	_restore_dashed_selection_children()
	_drag_active = false
	_item_states.clear()
	_shift_held_last = false
	# Clear the cooperation flag so alt_deselect resumes normal behavior.
	if _g != null and _g.ModMapData != null:
		_g.ModMapData["_selection_resize_active"] = false


func _hide_box() -> void:
	if _box_hidden:
		return
	if _select_tool == null:
		return
	# We do NOT call SavePreTransforms / RecordTransforms here anymore —
	# DD's native flow only captures position/rotation/scale, which
	# misses the EditPoints (paths) and polygon (patterns) changes we
	# make under Shift. Instead, _item_states already holds our pre-
	# snapshot (set in _try_begin_drag), and _end_drag pushes a single
	# custom GroupRecord covering BOTH transform AND geometry — letting
	# the user undo the whole operation in one Ctrl+Z.
	_select_tool.EnableTransformBox(false)
	_box_hidden = true
	if LOG:
		print("[SelectionResize] native box hidden")


func _restore_box() -> void:
	if not _box_hidden:
		return
	_box_hidden = false
	if _select_tool == null:
		return
	# Clear DD's stale per-item relative-transform cache. If we don't,
	# the next native (non-modifier) scale uses snapshots from before our
	# changes and computes wrong deltas — sometimes flipping items 180°.
	var irt = _select_tool.get("initialRelativeTransforms")
	if irt != null:
		irt.clear()
	# Refresh the visible box bounds and re-show it.
	if _select_tool.has_method("GetSelectionRect"):
		var rect = _select_tool.GetSelectionRect()
		if rect is Rect2:
			_select_tool.boxBegin = rect.position
			_select_tool.boxEnd = rect.position + rect.size
	_select_tool.EnableTransformBox(true)
	if _select_tool.has_method("GetTransformMode"):
		_select_tool.GetTransformMode()
	if LOG:
		print("[SelectionResize] native box restored")


# ── Per-frame ──────────────────────────────────────────────────────────────

func update(_delta) -> void:
	if not _drag_active:
		return

	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		_end_drag()
		return

	var alt = Input.is_key_pressed(KEY_ALT)
	var shift = Input.is_key_pressed(KEY_SHIFT)
	# "Snap Resize" mod-settings toggle: when OFF, Shift behaves as if
	# not held (uniform scale, no aspect-ratio unlock, no grid snap).
	# Lets users disable this feature without uninstalling the mod.
	if shift and not _is_snap_resize_enabled():
		shift = false
	# Shift on a single non-deformable asset has no useful effect — there's
	# no geometry to deform on a regular object/light, and a single-axis
	# scale on a single asset is just a weird reposition. We strip Shift
	# in that case so DD's native scale (or our Alt branch) handles it.
	# Single paths and patterns keep Shift (deformation of their geometry
	# IS useful). Walls are already excluded from _item_states.
	var effective_shift = shift
	if shift and _item_states.size() == 1:
		var only_type = _item_states[0].get("type", -1)
		if only_type != SELECTABLE_PATTERN_SHAPE and only_type != SELECTABLE_PATHWAY:
			effective_shift = false
	# Hand control back to DD's native scale only when no modifier has
	# ever been pressed during this drag (i.e. the box is still showing).
	# Once we've hidden the box for a Shift / Alt frame, we keep owning
	# the drag for the rest of it — otherwise releasing Shift mid-drag
	# would leave assets stuck in their last deformed state because DD's
	# native scale wouldn't run (box is still hidden).
	if not alt and not effective_shift and not _box_hidden:
		return

	# First time a modifier is detected during this drag, hide DD's box so
	# it stops fighting our transforms. Restored on drag end.
	if not _box_hidden:
		_hide_box()

	# Shift→no-Shift transition mid-drag: restore path/pattern geometry
	# (and dashed indicators) to their pre-drag shape so the user's
	# continuing drag scales them uniformly from a clean starting state.
	# Without this, paths/patterns stay frozen in whatever non-uniform
	# deformation they had on the last Shift frame.
	if _shift_held_last and not effective_shift:
		for st in _item_states:
			var thing = st["thing"]
			if not is_instance_valid(thing):
				continue
			var t = st.get("type", -1)
			if t == SELECTABLE_PATHWAY and st.has("path_local_pts"):
				_restore_path_geometry(thing, st["path_local_pts"])
			elif t == SELECTABLE_PATTERN_SHAPE and st.has("pattern_local_pts"):
				_restore_pattern_geometry(thing, st["pattern_local_pts"], st.get("line_children", {}))
		_restore_dashed_selection_children()

	# When Shift transitions ON for the first time during this drag, hide
	# the dashed selection indicators on paths and patterns — DD repaints
	# them in ways that desync from our geometry deformation.
	if effective_shift and not _shift_held_last:
		_hide_dashed_for_paths_and_patterns()
	_shift_held_last = effective_shift

	if _g.WorldUI == null:
		return
	var cur_mouse = _g.WorldUI.MousePosition

	# Anchor point for the scale: opposite corner by default, box center
	# under Alt. _world_center is the AABB center. _pre_corner is the
	# exact dragged corner (from the selection rect, not the click pos)
	# so reflecting it through center lands us on the actual opposite
	# corner — without this, off-center clicks within the handle hit
	# zone would offset the anchor and bias the scale.
	var anchor: Vector2
	if alt:
		anchor = _world_center
	else:
		anchor = 2.0 * _world_center - _pre_corner

	# Corner target: where the dragged corner should be this frame.
	# Track via mouse delta from the click, NOT the absolute mouse
	# position, so a click offset within the handle hit zone produces
	# zero scale change at frame 0.
	var corner_target = _pre_corner + (cur_mouse - _pre_mouse)
	# Snap to grid only under Shift AND only when DD's Snap To Grid is
	# enabled — Shift alone unlocks the aspect ratio without forcing
	# a snap.
	if effective_shift and _snap_is_enabled():
		corner_target = _snap_pos(corner_target)

	var anchor_to_handle = _pre_corner - anchor

	if effective_shift:
		# Non-uniform per-axis scale. Solve sx, sy independently so the
		# dragged corner lands on corner_target on BOTH axes (when snap
		# is on, that means a grid point on each).
		var sx = 1.0
		var sy = 1.0
		if abs(anchor_to_handle.x) > 0.001:
			sx = (corner_target.x - anchor.x) / anchor_to_handle.x
		if abs(anchor_to_handle.y) > 0.001:
			sy = (corner_target.y - anchor.y) / anchor_to_handle.y
		# Clamp away from zero to avoid degenerate flips.
		if abs(sx) < 0.01:
			sx = 0.01 if sx >= 0.0 else -0.01
		if abs(sy) < 0.01:
			sy = 0.01 if sy >= 0.0 else -0.01

		# Build a Transform2D representing the same scale-around-anchor
		# operation, used by the pattern's world-anchored geometry helper.
		var W = Transform2D(0.0, anchor) \
			* Transform2D.IDENTITY.scaled(Vector2(sx, sy)) \
			* Transform2D(0.0, -anchor)

		for st in _item_states:
			var thing = st["thing"]
			if not is_instance_valid(thing):
				continue
			var ip: Vector2 = st["pos"]
			var ic: Vector2 = st["scale"]
			var t = st.get("type", -1)
			# Scale displacement from anchor non-uniformly per axis.
			var disp = ip - anchor
			var new_pos = anchor + Vector2(disp.x * sx, disp.y * sy)
			if t == SELECTABLE_PATHWAY:
				# Path: deform EditPoints, keep node scale unchanged so
				# line width / texture density stays constant. Position
				# follows the stretched box.
				thing.global_position = new_pos
				thing.scale = ic
				if st.has("path_local_pts"):
					_apply_scale_to_path(thing, st["path_local_pts"], st.get("line_children", {}), W)
			elif t == SELECTABLE_PATTERN_SHAPE:
				# Pattern: world-anchored. Keep pattern.global_position
				# at its drag-start value (NOT at new_pos), absorb the
				# entire transform into the polygon vertices. This keeps
				# tile world positions and pixel sizes constant; the
				# polygon shape changes around the texture.
				thing.global_position = ip
				thing.scale = ic
				if st.has("pattern_local_pts"):
					_apply_world_anchored_pattern(thing, st["pattern_local_pts"], st.get("line_children", {}), W)
			else:
				# Other Node2D: only reposition, no scale change.
				thing.global_position = new_pos
				thing.scale = ic
	else:
		# Alt-only (no Shift) → uniform centered scale (texture follows).
		# Mirror of the original behavior: project the dragged handle
		# onto the (anchor → original handle) axis to get a single R.
		var orig_len = anchor_to_handle.length()
		var R := 1.0
		if orig_len > 0.001:
			var dir = anchor_to_handle / orig_len
			var proj = (corner_target - anchor).dot(dir)
			if proj < 1.0:
				proj = 1.0
			R = proj / orig_len
		if R < 0.01:
			R = 0.01
		var r = Vector2(R, R)

		for st in _item_states:
			var thing = st["thing"]
			if not is_instance_valid(thing):
				continue
			var ip: Vector2 = st["pos"]
			var ic: Vector2 = st["scale"]
			var t = st.get("type", -1)
			thing.global_position = anchor + (ip - anchor) * r
			thing.scale = ic * r
			# If a previous frame in this drag deformed the geometry
			# under Shift, restore it now so the rendered shape matches
			# the (pristine) snapshot under the new uniform scale.
			if t == SELECTABLE_PATHWAY and st.has("path_local_pts"):
				_restore_path_geometry(thing, st["path_local_pts"])
			elif t == SELECTABLE_PATTERN_SHAPE and st.has("pattern_local_pts"):
				_restore_pattern_geometry(thing, st["pattern_local_pts"], st.get("line_children", {}))

	# Note: native transform box is hidden during this phase; it will be
	# refreshed and re-shown on drag end via _restore_box().


# ── Geometry helpers (paths / patterns) ────────────────────────────────────
#
# These mirror the equivalents in DragSelectWalls.gd. We keep duplicates here
# rather than sharing a module: selection_resize and DragSelectWalls activate
# in mutually exclusive selection scenarios, and lifting them to a shared
# helper is more refactor than this incremental change warrants.

# Snapshot every Line2D in `node`'s subtree (recursive). Used to capture
# path/pattern dashed-line and outline children at drag start.
func _snap_line2d_children(node) -> Dictionary:
	var result = {}
	if node == null or not is_instance_valid(node):
		return result
	_snap_line2d_recurse(node, result)
	return result


func _snap_line2d_recurse(parent, result: Dictionary) -> void:
	for child in parent.get_children():
		if child is Line2D:
			var pts = []
			for p in child.points:
				pts.append(p)
			result[child] = pts
		if child.get_child_count() > 0:
			_snap_line2d_recurse(child, result)


# Hide every dashed-texture (dotted_line.png) Line2D descendant of every
# selected path / pattern. Restored at _end_drag.
func _hide_dashed_for_paths_and_patterns() -> void:
	_dashed_hidden = []
	for st in _item_states:
		var t = st.get("type", -1)
		if t != SELECTABLE_PATHWAY and t != SELECTABLE_PATTERN_SHAPE:
			continue
		var thing = st["thing"]
		if not is_instance_valid(thing):
			continue
		_hide_dashed_recurse(thing)


func _hide_dashed_recurse(node) -> void:
	for child in node.get_children():
		if child is Line2D:
			var tex = child.texture
			if tex != null and "resource_path" in tex:
				var rp = str(tex.resource_path)
				if rp.find("dotted_line") != -1:
					_dashed_hidden.append({"node": child, "was_visible": child.visible})
					child.visible = false
		if child.get_child_count() > 0:
			_hide_dashed_recurse(child)


# Restore previously-hidden dashed indicators. Before unhiding, copy each
# parent's current points (path) or polygon (pattern) into the dashed
# child so it shows the post-drag shape immediately.
func _restore_dashed_selection_children() -> void:
	for entry in _dashed_hidden:
		var node = entry["node"]
		if node != null and is_instance_valid(node):
			var parent = node.get_parent()
			if parent != null and is_instance_valid(parent):
				if parent is Line2D:
					node.points = parent.points
				elif parent is Polygon2D:
					var poly = parent.polygon
					var pts = PoolVector2Array()
					for p in poly:
						pts.append(p)
					if pts.size() > 0:
						pts.append(pts[0])
					node.points = pts
			node.visible = entry["was_visible"]
	_dashed_hidden = []


# Apply a world-space Transform2D W to a Pathway by deforming its
# EditPoints. node.scale is left untouched (caller has already set
# global_position to the new world location), so line width and texture
# density stay constant.
func _apply_scale_to_path(path, local_pts: Array, line_children: Dictionary, W: Transform2D) -> void:
	if not path.has_method("SetEditPoints"):
		return
	var pool = PoolVector2Array()
	for lp in local_pts:
		# DD's SetEditPoints expects WORLD coords; it stores
		#   stored_local = world_pt - path.global_position
		# so we feed (current_global_position + W.basis_xform(local)).
		pool.append(path.global_position + W.basis_xform(lp))
	path.call("SetEditPoints", pool)
	if path.has_method("Smooth"):
		path.call("Smooth")
	# Deform Line2D children (e.g. dashed indicator if not hidden) so
	# they track the new shape.
	for child in line_children:
		if not is_instance_valid(child):
			continue
		var lpts = PoolVector2Array()
		for p in line_children[child]:
			lpts.append(W.basis_xform(p))
		child.points = lpts


# Restore a Pathway's EditPoints to their pre-drag local coords.
func _restore_path_geometry(path, orig_local_pts: Array) -> void:
	if not path.has_method("SetEditPoints"):
		return
	var pool = PoolVector2Array()
	for lp in orig_local_pts:
		pool.append(path.global_position + lp)
	path.call("SetEditPoints", pool)
	if path.has_method("Smooth"):
		path.call("Smooth")


# Apply W to a PatternShape using the world-anchored approach: the
# pattern's global_position is held at its drag-start value (caller
# responsibility), and the entire W transform is encoded in the polygon
# vertices via inv(pattern.xform) ∘ W ∘ pattern.xform. This keeps the
# pattern's texture mapping stable in world coords (tiles stay put,
# tile sizes stay constant) while the polygon shape stretches around it.
func _apply_world_anchored_pattern(pattern, local_pts: Array, line_children: Dictionary, W: Transform2D) -> void:
	var xform_now = pattern.global_transform
	var T = xform_now.affine_inverse() * W * xform_now
	var new_poly = PoolVector2Array()
	for lp in local_pts:
		new_poly.append(T.xform(lp))
	pattern.polygon = new_poly
	if "uv" in pattern:
		pattern.uv = PoolVector2Array()
	# Rebuild the Outline (Line2D) child explicitly from the new polygon
	# (closed loop).
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in new_poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts
	# Other Line2D children: same local-frame transform.
	for child in line_children:
		if not is_instance_valid(child):
			continue
		if child == outline:
			continue
		var lpts2 = PoolVector2Array()
		for p in line_children[child]:
			lpts2.append(T.xform(p))
		child.points = lpts2


# Restore a PatternShape's polygon to its pre-drag local coords.
func _restore_pattern_geometry(pattern, orig_local_pts: Array, line_children: Dictionary) -> void:
	var orig_poly = PoolVector2Array()
	for p in orig_local_pts:
		orig_poly.append(p)
	pattern.polygon = orig_poly
	if "uv" in pattern:
		pattern.uv = PoolVector2Array()
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in orig_poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts
	# Restore other Line2D children to their original points.
	for child in line_children:
		if not is_instance_valid(child):
			continue
		if child == outline:
			continue
		var lpts2 = PoolVector2Array()
		for p in line_children[child]:
			lpts2.append(p)
		child.points = lpts2


# ── Snap-state ─────────────────────────────────────────────────────────────

# Mod-settings toggle "Snap Resize" (id: snap_resize_shift). When OFF,
# Shift+resize falls back to plain uniform scale — no aspect-ratio
# unlock, no grid snap. Default: ON (fail-open if mod_settings absent).
func _is_snap_resize_enabled() -> bool:
	if _g == null or _g.ModMapData == null:
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("snap_resize_shift")


func _snap_is_enabled() -> bool:
	# Master: DD's "Snap to Grid" toggle. When that is OFF, we never
	# snap — regardless of whether Custom Snap Mod is enabled. Custom
	# Snap only chooses WHICH points we snap to (in _snap_pos), not
	# whether we snap at all.
	if _g.Editor == null:
		return false
	return bool(_g.Editor.get("IsSnapping"))


# ── Snap ───────────────────────────────────────────────────────────────────

func _snap_pos(pos: Vector2) -> Vector2:
	var snappy = _get_snappy_mod()
	if snappy and snappy.has_method("get_snapped_position") and snappy.get("custom_snap_enabled"):
		return snappy.get_snapped_position(pos)

	var world_ui = _g.WorldUI
	if world_ui == null:
		return pos
	var cell = world_ui.CellSize
	if not (cell is Vector2) or cell.x <= 0:
		return pos
	var step = cell.x * 0.5
	if world_ui.get("UseHalfSnap"):
		step = step * 0.5
	return Vector2(stepify(pos.x, step), stepify(pos.y, step))


func _get_snappy_mod():
	if _snappy_ref != null:
		return _snappy_ref
	if _snappy_searched:
		return null
	_snappy_searched = true

	var api = _g.get("API")
	if api and typeof(api) == TYPE_OBJECT:
		var s = api.get("snappy_mod")
		if s and s.has_method("get_snapped_position"):
			_snappy_ref = s
			return s

	var toolset = _g.Editor.get("Toolset")
	if toolset:
		var toolbars = toolset.get("Toolbars")
		if toolbars and toolbars is Dictionary:
			for key in toolbars.keys():
				var toolbar = toolbars[key]
				if toolbar is Node:
					var found = _find_snappy_from_panel(toolbar)
					if found:
						_snappy_ref = found
						return found
	return null


func _find_snappy_from_panel(node) -> Object:
	if node == null or not is_instance_valid(node) or not (node is Node):
		return null
	if node is BaseButton:
		for sig_name in ["pressed", "toggled"]:
			var connections = node.get_signal_connection_list(sig_name)
			for conn in connections:
				var target = conn.get("target")
				if target and target.has_method("get_snapped_position"):
					return target
	for child in node.get_children():
		var found = _find_snappy_from_panel(child)
		if found:
			return found
	return null


# ── Undo / redo ────────────────────────────────────────────────────────────
#
# Custom history record bundling transform AND geometry changes for the
# whole selection in ONE step. Replaces DD's native SavePreTransforms /
# RecordTransforms flow (which only captures pos/rot/scale and would miss
# our path EditPoints / pattern polygon edits made under Shift).

class GroupResizeRecord:
	extends Reference
	var owner_mod
	var label: String = "Selection Resize"
	# Each entry: {
	#   thing, type,
	#   pre_pos, pre_rot, pre_scale,
	#   post_pos, post_rot, post_scale,
	#   pre_path_local_pts (optional, paths only),
	#   post_path_local_pts (optional, paths only),
	#   pre_pattern_local_pts (optional, patterns only),
	#   post_pattern_local_pts (optional, patterns only),
	# }
	var entries: Array = []

	func undo():
		_apply(true)

	func redo():
		_apply(false)

	func _apply(use_pre: bool) -> void:
		if owner_mod == null:
			return
		for e in entries:
			var thing = e.get("thing")
			if thing == null or not is_instance_valid(thing):
				continue
			var pos
			var rot
			var sc
			if use_pre:
				pos = e.get("pre_pos")
				rot = e.get("pre_rot")
				sc = e.get("pre_scale")
			else:
				pos = e.get("post_pos")
				rot = e.get("post_rot")
				sc = e.get("post_scale")
			if pos != null:
				thing.global_position = pos
			if rot != null:
				thing.global_rotation = rot
			if sc != null:
				thing.scale = sc
			# Per-type geometry restore.
			var t = e.get("type", -1)
			if t == 5:  # SELECTABLE_PATHWAY
				var pts_key = "pre_path_local_pts" if use_pre else "post_path_local_pts"
				var pts = e.get(pts_key)
				if pts != null:
					owner_mod._write_editpoints_to_path(thing, pts)
			elif t == 7:  # SELECTABLE_PATTERN_SHAPE
				var pts_key2 = "pre_pattern_local_pts" if use_pre else "post_pattern_local_pts"
				var pts2 = e.get(pts_key2)
				if pts2 != null:
					owner_mod._write_polygon_to_pattern(thing, pts2)


# Build a record from _item_states (pre-state) + the current node state
# (post-state). Returns null if nothing actually changed.
func _build_group_record(label: String):
	var rec = GroupResizeRecord.new()
	rec.owner_mod = self
	rec.label = label
	for st in _item_states:
		var thing = st.get("thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var entry = {
			"thing": thing,
			"type": st.get("type", -1),
			"pre_pos": st.get("pos"),
			"pre_rot": st.get("rot"),
			"pre_scale": st.get("scale"),
			"post_pos": thing.global_position,
			"post_rot": thing.global_rotation,
			"post_scale": thing.scale,
		}
		# Geometry pre/post for paths and patterns.
		if st.get("type", -1) == SELECTABLE_PATHWAY and st.has("path_local_pts"):
			entry["pre_path_local_pts"] = st["path_local_pts"]
			# Capture post EditPoints in LOCAL coords. DD stores them
			# global-position-relative, so we read EditPoints directly.
			var ep = thing.get("EditPoints")
			if ep != null:
				var post_pts = []
				for p in ep:
					post_pts.append(p)
				entry["post_path_local_pts"] = post_pts
		elif st.get("type", -1) == SELECTABLE_PATTERN_SHAPE and st.has("pattern_local_pts"):
			entry["pre_pattern_local_pts"] = st["pattern_local_pts"]
			var poly = thing.get("polygon")
			if poly != null:
				var post_pts2 = []
				for p in poly:
					post_pts2.append(p)
				entry["post_pattern_local_pts"] = post_pts2
		rec.entries.append(entry)
	if rec.entries.empty():
		return null
	return rec


# Used by GroupResizeRecord on undo/redo — write a points array as the
# path's EditPoints (in LOCAL coords). Mirrors what _restore_path_geometry
# does, but takes the points to write as a parameter instead of restoring
# from a fixed snapshot.
func _write_editpoints_to_path(path, local_pts: Array) -> void:
	if not path.has_method("SetEditPoints"):
		return
	var pool = PoolVector2Array()
	for lp in local_pts:
		# SetEditPoints expects WORLD coords; it stores
		#   stored_local = world_pt - path.global_position
		# so we feed (current global_position + local).
		pool.append(path.global_position + lp)
	path.call("SetEditPoints", pool)
	if path.has_method("Smooth"):
		path.call("Smooth")


# Used by GroupResizeRecord — write a polygon array (LOCAL coords) onto
# the pattern, also rebuilding its Outline child like the live drag
# helpers do. Same shape as _restore_pattern_geometry but parameterised.
func _write_polygon_to_pattern(pattern, local_pts: Array) -> void:
	var poly = PoolVector2Array()
	for p in local_pts:
		poly.append(p)
	pattern.polygon = poly
	if "uv" in pattern:
		pattern.uv = PoolVector2Array()
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts


func _push_history_record(record) -> void:
	if record == null:
		return
	if _g == null or _g.Editor == null:
		return
	var history = _g.Editor.get("History")
	if history == null:
		return
	if history.has_method("CreateCustomRecord"):
		history.CreateCustomRecord(record)
		return
	if history.has_method("Record"):
		history.Record(record)
