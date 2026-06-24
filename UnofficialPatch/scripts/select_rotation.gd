# select_rotation.gd
# Adds a Rotation slider to the SelectTool panel for asset types that lack one:
# - Objects (4)
# - Pathways (5)
# - PatternShapes (7) — shape rotation, distinct from DD's texture rotation
# - Roofs (8)
# - Freestanding Portals (2)
#
# Lights (6) are handled by light_fix.gd.
# Texts are handled by text_transform.gd.
# Walls (1) and wall-mounted Portals (3) are excluded — rotation is meaningless
# for these types; the slider is hidden if any of them is in the selection.
#
# Display modes:
# - Single-asset selection: the slider shows the asset's ABSOLUTE rotation in
#   [-180, 180]. Reset goes to 0deg (asset facing its native orientation).
# - Multi-asset selection: the slider shows the rotation DELTA applied since
#   the current selection was formed. Each asset can have its own base
#   orientation, so an absolute display would be ambiguous; the delta is what
#   the user actually controls via box rotation. Reset returns each asset to
#   its rotation at selection time.

var _g
var ui_util
var rotation_snap = null  # set by Main.gd after both mods are loaded; used to mirror the 45deg snap in our slider/spinbox while Shift is held

var _select_tool = null
var _panel_align = null

# UI elements
var _rot_container = null  # VBoxContainer holding rotation UI
var _rot_label = null
var _rot_hbox = null
var _rot_slider = null
var _rot_spin = null
var _ui_injected = false
var _updating_ui = false
var _prev_node_ids = []  # track selection changes to force a refresh
var _shift_step_active = false  # current state of the slider/spinbox step (1deg vs SHIFT_SNAP_DEG)
# Local fallback for the selection-time rotation snapshot. We normally
# read this from rotation_snap.get_rot_at_selection() so the slider's
# "0deg = no rotation since selection" baseline matches the rotation
# snap's box-relative behavior exactly. If rotation_snap is missing the
# local field is used instead, keeping the slider self-contained.
var _rot_at_selection := 0.0

# Step matching rotation_snap.gd. Kept as a local constant to avoid a hard
# dependency: if rotation_snap is missing, we just never engage the snap step.
const SHIFT_SNAP_DEG := 45.0

# SelectableTypes reference:
# 1=Wall, 2=PortalFree, 3=PortalWall, 4=Object, 5=Pathway, 6=Light, 7=PatternShape, 8=Roof
# We show the slider for any selection that isn't exclusively lights (light_fix handles those).


func initialize():
	_select_tool = _g.Editor.Tools["SelectTool"]
	print("[SelectRotation] Initialized")


func cleanup() -> void:
	if _rot_container != null and is_instance_valid(_rot_container):
		_rot_container.queue_free()
	_rot_container = null
	_rot_label = null
	_rot_hbox = null
	_rot_slider = null
	_rot_spin = null
	_panel_align = null
	_ui_injected = false
	print("[SelectRotation] Cleaned up")


# ==================== SAFE SELECTABLES ====================

func _get_selectables_safe() -> Dictionary:
	var result = {}
	var raw = _select_tool.RawSelectables
	if raw == null:
		return result
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var type = _select_tool.GetSelectableType(thing)
		result[thing] = type
	return result


# ==================== UI INJECTION ====================

func _inject_ui():
	if _ui_injected:
		return

	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		return

	# Find the Align VBoxContainer
	_panel_align = panel.get("Align")
	if _panel_align == null:
		for child in panel.get_children():
			if child is VBoxContainer:
				_panel_align = child
				break
	if _panel_align == null:
		return

	# Create rotation container
	_rot_container = VBoxContainer.new()
	_rot_container.name = "SelectRotationControls"
	_rot_container.visible = false

	_rot_label = Label.new()
	_rot_label.text = "Rotation"
	_rot_container.add_child(_rot_label)

	_rot_hbox = HBoxContainer.new()
	_rot_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_rot_slider = HSlider.new()
	_rot_slider.min_value = -180.0
	_rot_slider.max_value = 180.0
	_rot_slider.step = 1.0
	_rot_slider.value = 0.0
	_rot_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rot_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rot_slider.connect("value_changed", self, "_on_rotation_changed")

	_rot_spin = SpinBox.new()
	_rot_spin.min_value = -180.0
	_rot_spin.max_value = 180.0
	_rot_spin.step = 1.0
	_rot_spin.value = 0.0
	_rot_spin.connect("value_changed", self, "_on_rotation_changed")

	_rot_hbox.add_child(_rot_slider)
	_rot_hbox.add_child(_rot_spin)

	var reset_btn = _make_reset_button("Reset rotation")
	reset_btn.connect("pressed", self, "_on_reset_rotation")
	_rot_hbox.add_child(reset_btn)

	_rot_container.add_child(_rot_hbox)
	_panel_align.add_child(_rot_container)
	# Position above the type-specific contextual containers
	var target_idx = min(14, _panel_align.get_child_count() - 1)
	_panel_align.move_child(_rot_container, target_idx)

	_ui_injected = true
	print("[SelectRotation] UI injected into SelectTool panel at index %d" % target_idx)


# ==================== ICON / RESET HELPERS ====================

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	image.load(_g.Root + icon_path)
	if scale != 1.0:
		var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
		image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _make_reset_button(tooltip: String) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	btn.icon = _load_icon("icons/reset.png", 0.5)
	return btn


# ==================== UI CALLBACKS ====================

func _on_rotation_changed(value):
	if _updating_ui:
		return
	_updating_ui = true

	# Sync slider ↔ spinbox
	if _rot_slider.value != value:
		_rot_slider.value = value
	if _rot_spin.value != value:
		_rot_spin.value = value

	# Compute the delta to apply so the displayed value `value` becomes the
	# new state. The meaning of `value` depends on the display mode:
	# - single-asset: `value` is the desired ABSOLUTE rotation
	# - multi-asset: `value` is the desired delta from the selection baseline
	# In both cases, we wrap the delta to [-180, 180] so we always apply the
	# shortest equivalent rotation (matters for very large accumulated deltas).
	var selectables = _get_selectables_safe()
	if selectables.size() > 0:
		var first_node = _first_valid_node(selectables)
		if first_node != null:
			var delta_to_apply: float
			if selectables.size() == 1:
				delta_to_apply = _wrap_180(value - first_node.rotation_degrees)
			else:
				var current_delta = _wrap_180(first_node.rotation_degrees - _get_rot_baseline())
				delta_to_apply = _wrap_180(value - current_delta)
			if abs(delta_to_apply) > 0.01:
				_apply_rotation_delta(selectables, delta_to_apply)

	_updating_ui = false


func _on_reset_rotation():
	# Reset target depends on display mode:
	# - single-asset: rotate back to 0deg absolute (asset's native orientation)
	# - multi-asset: rotate back to each asset's rotation at selection time
	#   (i.e. "undo all rotations done since this selection was made")
	_updating_ui = true
	_rot_slider.value = 0.0
	_rot_spin.value = 0.0

	var selectables = _get_selectables_safe()
	if selectables.size() > 0:
		var first_node = _first_valid_node(selectables)
		if first_node != null:
			var delta_to_apply: float
			if selectables.size() == 1:
				delta_to_apply = _wrap_180(0.0 - first_node.rotation_degrees)
			else:
				delta_to_apply = _wrap_180(_get_rot_baseline() - first_node.rotation_degrees)
			if abs(delta_to_apply) > 0.01:
				_apply_rotation_delta(selectables, delta_to_apply)

	_updating_ui = false


func _apply_rotation_delta(selectables: Dictionary, delta_deg: float) -> void:
	# Two paths depending on whether Free Transform is currently active:
	#
	# - FT active: DD's RotateTransformBox uses node.global_position as
	#   pivot, but FT can leave that point far from the visual center
	#   (after non-uniform scale, etc.), so the rotation orbits around
	#   the wrong point. We rotate each node manually around the visual
	#   AABB center, then rebuild boxBegin/boxEnd so the box keeps
	#   wrapping the content.
	#
	# - FT inactive: mirror rotation_snap.gd -- RotateTransformBox +
	#   pre-multiply initialRelativeTransforms. The box follows the
	#   rotation natively (visibly rotated during transformMode==2 drags;
	#   recomputed by DD otherwise) without us needing to touch the box
	#   state ourselves.
	#
	# update() already hides the slider for FT distort/shear cases where
	# the manual path would corrupt those side-stores.
	var nodes: Array = []
	for n in selectables:
		if n != null and is_instance_valid(n):
			nodes.append(n)
	if nodes.empty():
		return
	if _select_tool == null:
		return

	var ft = _g.ModMapData.get("_free_transform") if _g.ModMapData != null else null
	var ft_active = ft != null and ft.get("_enabled") == true

	if _select_tool.has_method("SavePreTransforms"):
		_select_tool.call("SavePreTransforms")

	if ft_active:
		var pivot = _compute_rotation_pivot(nodes, ft)
		var rad = deg2rad(delta_deg)
		var ds = _g.ModMapData.get("_ft_distort", {}) if _g.ModMapData != null else {}
		var ss = _g.ModMapData.get("_ft_transforms", {}) if _g.ModMapData != null else {}
		for nd in nodes:
			# Node FT (distort/skew/perspective) : déléguer à FT, qui tourne la
			# base stockée EN LOCKSTEP (sinon nd.rotation += rad désync les
			# coins/shear stockés du visuel).
			var k = ""
			if ft.has_method("_ft_node_key"):
				k = ft.call("_ft_node_key", nd)
			if k != "" and (ds.has(k) or ss.has(k)) and ft.has_method("rotate_ft_node"):
				ft.call("rotate_ft_node", nd, rad, pivot)
				continue
			# 1. Capture the visual center BEFORE rotation.
			var vc_before = _node_visual_center(nd, ft)
			# 2. Where it should land after rotating around the group pivot.
			var vc_target = pivot + (vc_before - pivot).rotated(rad)
			# 3. Rotate the node on its own axis.
			nd.rotation += rad
			# 4. Translate so the visual center hits vc_target.
			var vc_natural = _node_visual_center(nd, ft)
			nd.global_position += (vc_target - vc_natural)
		# Box doesn't auto-update after manual rotation -- rebuild it.
		_refresh_transform_box(nodes, ft)
	else:
		_select_tool.RotateTransformBox(delta_deg)
		# initialRelativeTransforms stores per-Selectable transforms in
		# box-local space (box center at origin), so a rotation around
		# the world-space box center == a rotation around the origin in
		# box-local space == pre-multiplying each entry by
		# Transform2D(angle, ZERO). Without this, DD's next-frame recompute
		# would undo the rotation on any subsequent transform interaction.
		var irt = _select_tool.initialRelativeTransforms
		if irt != null:
			var rot_xform = Transform2D(deg2rad(delta_deg), Vector2.ZERO)
			for key in irt.keys():
				irt[key] = rot_xform * irt[key]

	if _select_tool.has_method("RecordTransforms"):
		_select_tool.call("RecordTransforms")


func _compute_rotation_pivot(nodes: Array, ft) -> Vector2:
	# Group pivot = center of the union of per-node visual AABBs.
	# Single node collapses to that node's own visual center.
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for nd in nodes:
		var rect = _node_visual_aabb(nd, ft)
		mn.x = min(mn.x, rect.position.x)
		mn.y = min(mn.y, rect.position.y)
		mx.x = max(mx.x, rect.end.x)
		mx.y = max(mx.y, rect.end.y)
	if mn.x == INF:
		var sum = Vector2.ZERO
		for nd in nodes:
			sum += nd.global_position
		return sum / float(nodes.size())
	return Vector2((mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5)


func _node_visual_aabb(nd: Node2D, ft) -> Rect2:
	if ft != null and ft.has_method("_prop_aabb"):
		var rect: Rect2 = ft.call("_prop_aabb", nd)
		if rect.size.x > 0.0 or rect.size.y > 0.0:
			return rect
	return Rect2(nd.global_position, Vector2.ZERO)


func _node_visual_center(nd: Node2D, ft) -> Vector2:
	var rect = _node_visual_aabb(nd, ft)
	if rect.size.x > 0.0 or rect.size.y > 0.0:
		return rect.position + rect.size * 0.5
	return nd.global_position


# Rebuild boxBegin/boxEnd from the union of per-node visual AABBs and
# force a visual refresh of the transform box. Used by the FT path where
# manual rotation leaves DD's box stale.
func _refresh_transform_box(nodes: Array, ft) -> void:
	if _select_tool == null:
		return
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for nd in nodes:
		if nd == null or not is_instance_valid(nd):
			continue
		var rect = _node_visual_aabb(nd, ft)
		if rect.size.x <= 0.0 and rect.size.y <= 0.0:
			# Zero-size AABB: still extend by the node position.
			mn.x = min(mn.x, rect.position.x)
			mn.y = min(mn.y, rect.position.y)
			mx.x = max(mx.x, rect.position.x)
			mx.y = max(mx.y, rect.position.y)
		else:
			mn.x = min(mn.x, rect.position.x)
			mn.y = min(mn.y, rect.position.y)
			mx.x = max(mx.x, rect.end.x)
			mx.y = max(mx.y, rect.end.y)
	if mn.x == INF:
		return
	_select_tool.boxBegin = mn
	_select_tool.boxEnd = mx
	# Toggle to force DD to re-render the box from the new corners --
	# same pattern used by alt_deselect / rotation_snap when boxBegin/
	# boxEnd are mutated outside a drag.
	if _select_tool.has_method("EnableTransformBox"):
		_select_tool.call("EnableTransformBox", false)
		_select_tool.call("EnableTransformBox", true)


# Returns the selection-time rotation baseline. Reads from rotation_snap
# when available (single source of truth shared with the rotation snap
# behavior), falls back to a local snapshot otherwise so the slider keeps
# working in isolation.
func _get_rot_baseline() -> float:
	if rotation_snap != null and rotation_snap.has_method("get_rot_at_selection"):
		return rotation_snap.get_rot_at_selection()
	return _rot_at_selection


# Wrap an angle in degrees into [-180, 180] so we always apply the
# shortest equivalent rotation (matters for very large accumulated deltas).
func _wrap_180(deg: float) -> float:
	while deg > 180.0:
		deg -= 360.0
	while deg < -180.0:
		deg += 360.0
	return deg


func _first_valid_node(selectables: Dictionary):
	for node in selectables:
		if node != null and is_instance_valid(node):
			return node
	return null


# ==================== UI SYNC ====================

func _sync_ui_from_selection(nodes: Array, force_refresh: bool = false):
	if not _ui_injected or nodes.size() == 0:
		return
	if _updating_ui:
		return

	var first = nodes[0]
	var single = nodes.size() == 1
	var rot: float

	if single:
		# Single-asset mode: show the asset's absolute rotation directly,
		# so a freshly-selected rotated asset doesn't look like "0deg" in
		# the slider. When the rotation snap is engaged (Shift, no Z), we
		# still preview the snap target — but the target is computed
		# relative to the selection-time baseline (same as rotation_snap.gd
		# does), so the displayed value matches what a snap drag would
		# actually produce.
		rot = _wrap_180(first.rotation_degrees)
		if _is_shift_snap_active():
			var baseline = _get_rot_baseline()
			var delta = first.rotation_degrees - baseline
			var snapped_delta = round(delta / SHIFT_SNAP_DEG) * SHIFT_SNAP_DEG
			rot = _wrap_180(baseline + snapped_delta)
	else:
		# Multi-asset mode: display value = delta applied since this
		# selection was formed. Assets can have different base orientations,
		# so an absolute display would be ambiguous — the delta is what the
		# user actually controls via the box rotation. The baseline is
		# shared with rotation_snap so the slider and the snap behavior
		# agree on what counts as "0deg from the box".
		rot = _wrap_180(first.rotation_degrees - _get_rot_baseline())
		if _is_shift_snap_active():
			rot = round(rot / SHIFT_SNAP_DEG) * SHIFT_SNAP_DEG

	# A small threshold prevents micro-updates during normal sync; on a
	# selection change we force a refresh so the slider can never show the
	# previous selection's rotation.
	var threshold = 0.0 if force_refresh else 0.05

	_updating_ui = true

	if force_refresh or abs(_rot_slider.value - rot) > threshold:
		_rot_slider.value = rot
	if force_refresh or abs(_rot_spin.value - rot) > threshold:
		_rot_spin.value = rot

	_updating_ui = false


# True when the SelectTool's rotation snap is engaged AND it can affect
# what the user sees right now (slider should preview snap-aligned values
# and use a 45deg step).
#
# Two exclusions on top of the basic "Shift held" check:
#
# - Shift+Z is the PRECISION rotation gesture (1deg/scroll via rotation_fix),
#   NOT a snap gesture — without the Z exclusion the slider would round
#   Shift+Z+scroll rotations to the nearest 45deg and never reflect the
#   1deg changes the user is actually making.
#
# - transformMode != 2: rotation_snap only does anything during an active
#   rotation drag via the handle (mode 2). Outside that, Shift may be held
#   for unrelated reasons (cycle-asset modifier, dragging-but-not-rotating,
#   user just resting their hand on the key) and the slider has no business
#   switching to snap mode. We only engage once a handle rotation drag is
#   actually in flight.
func _is_shift_snap_active() -> bool:
	if Input.is_key_pressed(KEY_Z):
		return false
	if _select_tool == null or _select_tool.transformMode != 2:
		return false
	if rotation_snap != null and rotation_snap.has_method("is_snap_active"):
		return rotation_snap.is_snap_active()
	if _g.ModMapData != null and _g.ModMapData.get("_free_transform_active", false):
		return false
	return Input.is_key_pressed(KEY_SHIFT)


# Mirrors the snap step into the slider/spinbox UI: while Shift is held the
# step jumps to SHIFT_SNAP_DEG (so dragging the slider or pressing the
# spinbox arrows only stops on snap-aligned angles); released, it falls
# back to 1deg. Tracked via _shift_step_active to avoid redundant writes.
func _apply_shift_snap_step() -> void:
	if _rot_slider == null or _rot_spin == null:
		return
	if not is_instance_valid(_rot_slider) or not is_instance_valid(_rot_spin):
		return

	var want_active = _is_shift_snap_active()
	if want_active == _shift_step_active:
		return
	_shift_step_active = want_active

	var step = SHIFT_SNAP_DEG if want_active else 1.0
	_rot_slider.step = step
	_rot_spin.step = step


# ==================== UPDATE ====================

func update(_delta):
	if _g.Editor.ActiveToolName != "SelectTool":
		_prev_node_ids = []
		if _rot_container != null and is_instance_valid(_rot_container):
			_rot_container.visible = false
		return

	# Inject UI once
	_inject_ui()

	var selectables = _get_selectables_safe()
	if selectables.size() == 0:
		_prev_node_ids = []
		if _rot_container != null and is_instance_valid(_rot_container):
			_rot_container.visible = false
		return

	# Show slider for any selection EXCEPT all-lights (light_fix has its own)
	# Also hide when the selection contains any Wall (1) or wall-mounted Portal (3)
	# — rotation on these types is meaningless and would rotate neighbors in mixed selections.
	# Also hide when any selected node has an FT distort or shear active:
	# rotation_fix skips those (rotating them desyncs the stored corners /
	# shear from the visible asset), so showing the slider would let the
	# user trigger the same broken rotation.
	var distort_store = _g.ModMapData.get("_ft_distort", {}) if _g.ModMapData != null else {}
	var shear_store = _g.ModMapData.get("_ft_transforms", {}) if _g.ModMapData != null else {}
	var ft = _g.ModMapData.get("_free_transform") if _g.ModMapData != null else null
	var all_lights = true
	var only_patterns = true
	var has_wall_or_wallportal = false
	var has_ft_distort_or_shear = false
	var first_node = null
	var valid_nodes: Array = []
	for node in selectables:
		if node == null or not is_instance_valid(node):
			continue
		var t = selectables[node]
		if t != 6:
			all_lights = false
		if t != 7:
			only_patterns = false
		if t == 1 or t == 3:
			has_wall_or_wallportal = true
		# Per-node check for FT side-stores. _ft_node_key is the canonical
		# key shared with free_transform.gd / rotation_fix.gd.
		if ft != null and ft.has_method("_ft_node_key"):
			var key = ft.call("_ft_node_key", node)
			if key != "" and (distort_store.has(key) or shear_store.has(key)):
				has_ft_distort_or_shear = true
		if first_node == null:
			first_node = node
		valid_nodes.append(node)

	# Note : has_ft_distort_or_shear n'est plus une raison de cacher le slider —
	# free_transform expose rotate_ft_node (FT actif) et replie l'édition native
	# dans son store (FT off), donc la rotation de ces assets fonctionne.
	if all_lights or first_node == null or has_wall_or_wallportal:
		_prev_node_ids = []
		if _rot_container != null and is_instance_valid(_rot_container):
			_rot_container.visible = false
		return

	# Label: "Shape Rotation" only when ALL selected are PatternShapes
	if _rot_label != null:
		var lbl = "Shape Rotation" if only_patterns else "Rotation"
		if _rot_label.text != lbl:
			_rot_label.text = lbl

	# Track which nodes are currently selected so we can force a UI refresh
	# the frame the selection changes — without this, the previous selection's
	# rotation could linger in the slider when the new asset's rotation is
	# very close to it.
	var current_ids = []
	for node in selectables:
		if node != null and is_instance_valid(node):
			current_ids.append(node.get_instance_id())
	var selection_changed = (current_ids != _prev_node_ids)
	_prev_node_ids = current_ids

	# Snapshot the reference node's rotation at the moment the selection
	# is formed — but only as a local fallback. When rotation_snap is
	# wired in, _get_rot_baseline() reads from there directly, and that
	# mod's update() (which runs first per Main.gd's ordering) keeps the
	# baseline current. We still update the local field so the slider can
	# work standalone if rotation_snap is ever absent.
	if selection_changed and rotation_snap == null:
		_rot_at_selection = first_node.rotation_degrees

	# Mirror the rotation snap step in the UI before syncing values, so
	# that any displayed value reflects the active snap step right away.
	_apply_shift_snap_step()

	# Sync slider from the selection (force when the selection just changed,
	# so any stale value from the previous selection is overwritten). We
	# pass valid_nodes (not just first_node) so _sync_ui_from_selection can
	# tell single-asset from multi-asset and pick the right display mode.
	_sync_ui_from_selection(valid_nodes, selection_changed)

	# Show controls
	if _rot_container != null and is_instance_valid(_rot_container) and not _rot_container.visible:
		_rot_container.visible = true
