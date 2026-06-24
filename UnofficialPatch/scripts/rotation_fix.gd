# rotation_fix.gd
# Fixes rotation step sizes and adds precision mode:
# - Normal scroll: 15deg (instead of 30deg in SelectTool)
# - Z + scroll: 5deg (instead of 10deg in SelectTool)
# - Shift + Z + scroll: 1deg (precision mode)
#
# Supported tools: SelectTool, ObjectTool, PortalTool

var _g
var select_tool
var ui_util
var input_listener: Node
var drag_select_walls = null  # Optional, injected by Main.gd; rotates walls in sync

const SELECTABLE_WALL = 1


# Lit le toggle "1° Rotation" (SHIFT + Z + MOUSEWHEEL) du Settings panel :
# OFF = pas de step de 1°, on retombe sur 5° (Z seul) ou 15° (rien) selon
# les autres modificateurs.
func _is_one_deg_rotation_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("one_deg_rotation")

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[RotationFix] Initialized")


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "RotationFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	# High priority: process before DD's own tools to intercept Shift+Z
	process_priority = -100
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	# Add to scene tree root to intercept events early
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", input_listener)


func _on_input(event) -> void:
	if not (event is InputEventMouseButton):
		return

	# Only scroll wheel
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return

	if not event.pressed:
		return

	# Don't intercept Ctrl+scroll (zoom)
	if Input.is_key_pressed(KEY_CONTROL):
		return

	var shift_held = Input.is_key_pressed(KEY_SHIFT)
	var z_held = Input.is_key_pressed(KEY_Z)

	# Determine which tool is active
	var active_tool = _g.Editor.ActiveToolName

	# --- SelectTool ---
	if active_tool == "SelectTool":
		_handle_select_tool(event, shift_held, z_held)
		return

	# --- ObjectTool / PortalTool ---
	if active_tool == "ObjectTool" or active_tool == "PortalTool":
		if shift_held and z_held:
			_handle_range_tool(event, active_tool, 1.0)
			return
		# For PortalTool: also handle normal scroll (15deg) and Z+scroll (5deg)
		# because DD defaults everything to 5deg for portals
		if active_tool == "PortalTool" and not shift_held:
			if z_held:
				_handle_range_tool(event, active_tool, 5.0)
			else:
				_handle_range_tool(event, active_tool, 15.0)
		return


func _handle_select_tool(event, shift_held, z_held) -> void:
	# Don't intercept Shift+scroll when lights are selected (light_fix handles style cycling)
	# BUT allow Shift+Z through (precision rotation takes priority)
	if shift_held and not z_held:
		var st = _g.Editor.Tools["SelectTool"]
		var sels = st.Selectables
		if sels and sels.size() > 0:
			var all_lights = true
			for node in sels:
				if node == null or not is_instance_valid(node) or sels[node] != 6:
					all_lights = false
					break
			if all_lights:
				return

	# Only when SelectTool panel is visible
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if not (panel and panel is CanvasItem and panel.is_visible_in_tree()):
		return

	# Don't intercept in menus/popups/panels
	if ui_util.is_mouse_over_ui(input_listener):
		return

	# Only when something is selected
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return

	# Determine step size:
	# Shift + Z + scroll = 1deg (precision) — gated by "1° Rotation" toggle
	# Z + scroll = 5deg
	# scroll = 15deg
	var step = 15.0
	if z_held and shift_held and _is_one_deg_rotation_enabled():
		step = 1.0
	elif z_held:
		step = 5.0

	# Direction
	if event.button_index == BUTTON_WHEEL_DOWN:
		step = -step

	print("[RotationFix] wheel rotate: step=%.2f° z=%s shift=%s" % [step, z_held, shift_held])

	# --- Pivot strategy ---
	# When walls + non-walls are mixed, DragSelectWalls maintains the
	# combined AABB of the selection and shows it as our custom box.
	# Users expect the wheel-rotation to spin everything around the
	# CENTER of that visible box (not the weighted centroid of items).
	#
	# We compute math-equivalent rotation around target_pivot like this:
	#  1. Let DD rotate non-walls around its own pivot (DD_pivot).
	#  2. Rotate walls around target_pivot (= our overlay center).
	#  3. Translate ONLY non-walls by a constant delta to convert their
	#     "rotation around DD_pivot" into "rotation around target_pivot":
	#       delta = (target_pivot - DD_pivot) - R(θ)(target_pivot - DD_pivot)
	#     (Derived from R(θ,A)(x) - R(θ,B)(x) = (I-R(θ))(A-B), constant.)
	#
	# When the overlay isn't active (pure non-walls, or pure walls), we
	# fall back to the older "centroid drift compensation" behavior so
	# nothing regresses for those cases.
	var has_target_pivot := false
	var target_pivot := Vector2.ZERO
	if drag_select_walls != null:
		var combined = drag_select_walls._last_combined
		if combined != null and combined.size.x > 0.0 and combined.size.y > 0.0:
			target_pivot = combined.position + combined.size * 0.5
			has_target_pivot = true
			print("[rot] target_pivot from overlay box: %s (rect %s)" % [str(target_pivot), str(combined)])
		else:
			print("[rot] no target_pivot — overlay rect empty (size=%s)" % str(combined.size if combined != null else Vector2.ZERO))
	else:
		print("[rot] no target_pivot — drag_select_walls is null")
	
	# When the DragSelectWalls overlay isn't active (selection has no
	# walls), check if Free Transform is active. FT can move/scale/skew
	# assets in ways that leave node.position far from the visual
	# center — DD's RotateTransformBox uses node.position to compute
	# its pivot, so the resulting rotation orbits around the wrong
	# point. Reading FT's _selection_aabb gives us the true visual box
	# and a correct pivot.
	var ft_pivot_active := false
	var ft_pivot := Vector2.ZERO
	var ft = _g.ModMapData.get("_free_transform") if _g.ModMapData != null else null
	if not has_target_pivot and ft != null and ft.get("_enabled") == true \
			and ft.has_method("_selection_aabb"):
		var ft_aabb: Rect2 = ft.call("_selection_aabb")
		if ft_aabb.size.x > 0.0 and ft_aabb.size.y > 0.0:
			ft_pivot = ft_aabb.position + ft_aabb.size * 0.5
			ft_pivot_active = true
			print("[rot] ft_pivot from FT visual aabb: %s" % str(ft_pivot))

	var pre_centroid = _compute_centroid()  # only used for fallback path

	# Overlay active → unified rotation in a single record (one Ctrl+Z).
	# DragSelectWalls rotates BOTH walls and non-walls around target_pivot
	# itself, then pushes one GroupTransformRecord. We don't call
	# RotateTransformBox at all in this branch (it would push a separate
	# DD record, requiring two Ctrl+Z to undo).
	if has_target_pivot:
		print("[rot] unified rotate_selection_around(%.2f°, %s)" % [step, str(target_pivot)])
		drag_select_walls.rotate_selection_around(step, target_pivot)
		input_listener.get_tree().set_input_as_handled()
		return

	# FT pivot path: rotate non-walls around the visual AABB center
	# rather than DD's broken pivot. We don't call RotateTransformBox
	# in this branch because it would push a separate DD record AND
	# pivot around the wrong point.
	if ft_pivot_active:
		print("[rot] FT-aware rotate around %s" % str(ft_pivot))
		_rotate_non_walls_around(ft_pivot, step)
		input_listener.get_tree().set_input_as_handled()
		return
	
	# --- Wall-only selection fast path ---
	# Quand RawSelectables ne contient QUE des walls (solo wall ou multi-walls
	# sans aucun asset DD-natif), DD's RotateTransformBox ne rotate rien
	# (DD ne touche pas aux walls) et le pivot derive du witness/box est
	# inutilisable (pas de witness, boxBegin/End peuvent etre stales).
	# On route directement vers DragSelectWalls.apply_rotation_around avec
	# le centre de l'AABB des walls comme pivot.
	if drag_select_walls != null and drag_select_walls.has_method("apply_rotation_around"):
		var only_walls := true
		for s in raw:
			if s == null or s.Thing == null or not is_instance_valid(s.Thing):
				continue
			if s.Type != SELECTABLE_WALL:
				only_walls = false
				break
		if only_walls:
			# Pivot : centre _last_combined si dispo (case solo non-flat
			# wall ou multi-walls), sinon AABB calcule a la volee a partir
			# des Points C# du wall (case solo flat wall).
			var wall_pivot := Vector2.ZERO
			var combined: Rect2 = drag_select_walls._last_combined
			if combined.size.x > 0.0 and combined.size.y > 0.0:
				wall_pivot = combined.position + combined.size * 0.5
			else:
				var aabb_initialized := false
				var minp := Vector2.ZERO
				var maxp := Vector2.ZERO
				for s in raw:
					if s == null or s.Thing == null or not is_instance_valid(s.Thing):
						continue
					if s.Type != SELECTABLE_WALL:
						continue
					var pts = s.Thing.get("Points")
					if pts == null:
						continue
					for p in pts:
						if not aabb_initialized:
							minp = p
							maxp = p
							aabb_initialized = true
						else:
							minp.x = min(minp.x, p.x)
							minp.y = min(minp.y, p.y)
							maxp.x = max(maxp.x, p.x)
							maxp.y = max(maxp.y, p.y)
				if aabb_initialized:
					wall_pivot = (minp + maxp) * 0.5
			drag_select_walls.apply_rotation_around(step, wall_pivot)
			input_listener.get_tree().set_input_as_handled()
			return

	# Find a non-wall "witness" item to determine the actual pivot DD uses.
	var witness = _find_non_wall_witness()
	var before_pos = Vector2.ZERO
	if witness != null:
		before_pos = witness.global_position

	# Apply DD's rotation (non-walls)
	select_tool.RotateTransformBox(step)

	# Derive the actual pivot from how the witness item moved.
	var pivot_dd: Vector2
	if witness != null and is_instance_valid(witness):
		pivot_dd = _derive_pivot_from_rotation(before_pos, witness.global_position, step)
		print("[rot] pivot_dd derived from witness: %s (witness moved %s -> %s, step=%.2f°)" % [str(pivot_dd), str(before_pos), str(witness.global_position), step])
	else:
		var bb = select_tool.boxBegin
		var be = select_tool.boxEnd
		pivot_dd = (bb + be) * 0.5
		print("[rot] pivot_dd from box midpoint (no witness): %s" % str(pivot_dd))

	# Rotate walls around the appropriate pivot.
	var walls_pivot = target_pivot if has_target_pivot else pivot_dd
	if drag_select_walls != null and drag_select_walls.has_method("apply_rotation_around"):
		drag_select_walls.apply_rotation_around(step, walls_pivot)

	if has_target_pivot:
		# Direct compensation: translate non-walls by constant delta to
		# convert their rotation-around-DD_pivot into rotation-around-
		# target_pivot. Walls were already rotated around target_pivot,
		# so they need no extra translation.
		var v = target_pivot - pivot_dd
		var rad = deg2rad(step)
		var delta = v - v.rotated(rad)
		print("[rot] step=%.2f° v=(%s) delta=(%s) (target=%s, dd=%s)" % [step, str(v), str(delta), str(target_pivot), str(pivot_dd)])
		if delta.length() > 0.001:
			_translate_non_walls(delta)
		# Update the locked box: rotate it by `step` around target_pivot
		# (which equals _box_pos, so only _box_rotation changes — box
		# stays anchored). This replaces the old "AABB drift compensation"
		# loop that translated everything to keep the visual box at
		# target_pivot: with a locked box that's no longer needed because
		# the box doesn't get re-AABB'd from the items' positions.
		if drag_select_walls != null and drag_select_walls.has_method("box_rotate"):
			drag_select_walls.box_rotate(rad, target_pivot)
			print("[rot] box_rotate(%.2f rad, %s) — box now at rotation %s" % [rad, str(target_pivot), str(drag_select_walls._box_rotation)])
	else:
		# No overlay active: rely on DD's native rotation around the
		# selection's bounding-box center.
		#
		# Previous versions tried to keep the "ensemble centroid" stable
		# by translating everything by -drift after DD's rotation. That
		# only worked for types whose `global_position` IS the visible
		# center (objects, portals, lights). For paths (Type 5), patterns
		# (Type 7), and roofs (Type 8), the geometry lives in `points` /
		# `polygon` while `global_position` sits at an extremity or zero,
		# so translating it back undid DD's compensation and rotated them
		# around the wrong pivot — paths around an endpoint, roofs off
		# screen, patterns rendered transparent because the absolute
		# polygon and the parent transform fell out of sync. For mixed
		# selections, forcing rotation around the centroid (avg position)
		# also placed assets outside the visible box. DD's box-AABB-center
		# rotation matches user expectations across every type, so we
		# just don't compensate.
		pass

	# Consume event so DD doesn't apply its own 30deg/10deg rotation
	input_listener.get_tree().set_input_as_handled()


# Finds the first non-wall Node2D in the current selection.
# Used as a witness to recover DD's actual rotation pivot from observation.
func _find_non_wall_witness():
	var raw = select_tool.RawSelectables
	if raw == null:
		return null
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		# 1 = Wall (we want anything else)
		if s.Type != 1 and s.Thing is Node2D:
			return s.Thing
	return null


# Computes the centroid of the current selection in world space.
# Walls contribute their AABB center (computed from Points), non-walls
# their global_position. Used to detect ensemble drift after a wheel rotate.
func _compute_centroid() -> Vector2:
	var sum = Vector2.ZERO
	var count = 0
	var raw = select_tool.RawSelectables
	if raw == null:
		return Vector2.ZERO
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == 1:
			# Wall — use AABB center of Points
			var pts = s.Thing.Points
			if pts != null and pts.size() > 0:
				var minp = pts[0]
				var maxp = pts[0]
				for p in pts:
					if p.x < minp.x: minp.x = p.x
					if p.y < minp.y: minp.y = p.y
					if p.x > maxp.x: maxp.x = p.x
					if p.y > maxp.y: maxp.y = p.y
				sum += (minp + maxp) * 0.5
				count += 1
		elif s.Thing is Node2D:
			sum += s.Thing.global_position
			count += 1
	if count == 0:
		return Vector2.ZERO
	return sum / count


# Translates every selected item by `delta` in world space.
# Walls go through DragSelectWalls.translate_wall; non-walls via
# global_position. Used to compensate ensemble drift.
func _translate_selection(delta: Vector2) -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == 1:
			if drag_select_walls != null and drag_select_walls.has_method("translate_wall"):
				drag_select_walls.translate_wall(s.Thing, delta)
		elif s.Thing is Node2D:
			s.Thing.global_position += delta


# Translates ONLY non-wall selectables by `delta`. Used to convert DD's
# "rotation around DD_pivot" into "rotation around target_pivot": walls
# are rotated around target_pivot directly (so untouched here), and
# non-walls just need a constant translation.
func _translate_non_walls(delta: Vector2) -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == 1:
			continue  # wall — skip
		if s.Thing is Node2D:
			s.Thing.global_position += delta


# Recovers the rotation pivot from a single point's before / after position
# given the rotation angle in degrees. Math: the pivot lies on the
# perpendicular bisector of the chord (before, after), at distance
# |chord|/2 / tan(θ/2) from its midpoint.
static func _derive_pivot_from_rotation(before: Vector2, after: Vector2, degrees: float) -> Vector2:
	var rad = deg2rad(degrees)
	if abs(rad) < 0.0001:
		return before  # No real rotation: pivot is undefined; pick anything safe.
	var chord = after - before
	var chord_len = chord.length()
	if chord_len < 0.001:
		# Witness is essentially at the pivot (or no movement detected).
		return before
	var mid = (before + after) * 0.5
	var perp = chord.rotated(PI * 0.5).normalized()
	var dist = (chord_len * 0.5) / tan(rad * 0.5)
	return mid + perp * dist


func _handle_range_tool(event, tool_name, step_size) -> void:
	# Don't intercept in menus/popups/panels
	if ui_util.is_mouse_over_ui(input_listener):
		return

	var tool = _g.Editor.Tools[tool_name]
	if tool == null:
		return

	var rotation_range = tool.get("Rotation")
	if not (rotation_range and rotation_range is Range):
		return

	var step = step_size
	if event.button_index == BUTTON_WHEEL_DOWN:
		step = -step

	var new_val = rotation_range.value + step

	# Wrap around: allow scrolling past -180 <-> +180
	var min_val = rotation_range.min_value
	var max_val = rotation_range.max_value
	var range_span = max_val - min_val
	if range_span > 0:
		if new_val > max_val:
			new_val = min_val + (new_val - max_val)
		elif new_val < min_val:
			new_val = max_val - (min_val - new_val)

	rotation_range.value = new_val

	# Consume event so DD doesn't apply its own rotation step
	input_listener.get_tree().set_input_as_handled()


# Rotate every non-wall selectable around the given world-space pivot
# by `step_deg` degrees. Each item pivots its VISUAL CENTER (computed
# via free_transform._prop_aabb when available) — not its Node2D origin
# — so the rotation behaves as the user expects even after FT has
# decoupled origin from visual center (move, non-uniform scale, skew).
func _rotate_non_walls_around(pivot: Vector2, step_deg: float) -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var ft = _g.ModMapData.get("_free_transform") if _g.ModMapData != null else null
	# These FT side-stores tell us which nodes have a non-trivial visual
	# transform (distort corners or a sheared local transform). Rotating
	# the Node2D in place doesn't rotate those stored corners / shears,
	# so the visible image desyncs from the box (corners stay axis-
	# aligned while the node rotates). Until we have a proper fix that
	# rotates those stores in lockstep, skip rotation for affected nodes.
	var distort_store = _g.ModMapData.get("_ft_distort", {})
	var shear_store = _g.ModMapData.get("_ft_transforms", {})
	var rad = deg2rad(step_deg)
	# Wrap with DD's transform record so Ctrl+Z reverts the rotation.
	if select_tool.has_method("SavePreTransforms"):
		select_tool.SavePreTransforms()
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == 1:
			continue  # walls handled separately
		var nd = s.Thing
		if not (nd is Node2D):
			continue
		# Skip nodes with active FT distort or shear — see comment above.
		var key = ""
		if ft != null and ft.has_method("_ft_node_key"):
			key = ft.call("_ft_node_key", nd)
		if key != "" and (distort_store.has(key) or shear_store.has(key)):
			continue
		# 1. Capture the visual center BEFORE the rotation.
		var vc_before = _node_visual_center(nd, ft)
		# 2. Where the visual center should end up after rotating
		#    around the group pivot.
		var vc_target = pivot + (vc_before - pivot).rotated(rad)
		# 3. Apply the node's own rotation delta. This is what makes
		#    the asset spin in place rather than just orbit.
		nd.rotation += rad
		# 4. The offset (origin → visual center) has rotated with the
		#    node. Recompute its current position and translate so the
		#    visual center lands at vc_target.
		var vc_natural = _node_visual_center(nd, ft)
		nd.global_position += (vc_target - vc_natural)
	if select_tool.has_method("RecordTransforms"):
		select_tool.RecordTransforms()
	# Nodes FT (distort/skew/perspective) : sautés ci-dessus pour le record DD,
	# on les tourne maintenant via FT, qui tourne sa base stockée EN LOCKSTEP
	# avec les coins/shears (sinon seule la box tournait, pas l'asset). FT pousse
	# son propre enregistrement d'undo unifié.
	if ft != null and ft.has_method("rotate_ft_node"):
		for s2 in raw:
			if s2 == null or s2.Thing == null or not is_instance_valid(s2.Thing):
				continue
			if s2.Type == 1:
				continue
			var nd2 = s2.Thing
			if not (nd2 is Node2D):
				continue
			var k2 = ""
			if ft.has_method("_ft_node_key"):
				k2 = ft.call("_ft_node_key", nd2)
			if k2 != "" and (distort_store.has(k2) or shear_store.has(k2)):
				ft.call("rotate_ft_node", nd2, rad, pivot)


func _node_visual_center(nd, ft) -> Vector2:
	# Prefer FT's _prop_aabb — it accounts for the per-asset visual
	# offset (origin → sprite center) and any FT-applied skew/distort.
	# Falls back to global_position when FT isn't available.
	if ft != null and ft.has_method("_prop_aabb"):
		var rect: Rect2 = ft.call("_prop_aabb", nd)
		if rect.size.x > 0.0 or rect.size.y > 0.0:
			return rect.position + rect.size * 0.5
	return nd.global_position
