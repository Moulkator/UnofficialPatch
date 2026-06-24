# rotation_snap.gd
# Snap the SelectTool's rotation handle to 45deg increments while Shift is
# held during the drag. The snap is BOX-relative: it locks the rotation
# applied since the current selection was formed (= the visible box
# rotation) to multiples of SNAP_DEG, so the box visibly lands on clean
# 0deg / 45deg / 90deg / ... orientations and the slider in
# select_rotation.gd shows matching clean values.
#
# Bows out when the Free Transform mod is active (it has its own handles).
#
# Why hybrid (visible-rotation + mouse-tracked) snap detection
# -----------------------------------------------------------
# Two different signals serve two different needs:
#
# 1) When Shift is FIRST pressed (lock engage), the user expects the snap
#    to be the multiple-of-45 closest to the asset's CURRENT visible
#    rotation. Reading that visible rotation straight from ref.rotation
#    is the most direct way to get it -- it's exactly what the user sees
#    on screen and what the slider would display.
#
# 2) Once the lock is set, deciding when to switch to a different snap
#    needs to be robust against DD's internal state changes. Tracking
#    drag progress via the mouse cursor's angle around the box center
#    is immune to those state changes: the cursor's position has
#    nothing to do with DD's drag math, so it never drifts.
#
# So: lock engage uses the visible rotation. Lock-switch hysteresis uses
# the mouse-anchored cumulative drag.
#
# How the snap is applied each frame
# ---------------------------------
# Given the locked snap target _locked_snap_delta:
#   1) Compute the rotation needed to put the asset at
#      _rot_at_selection + _locked_snap_delta given its current rotation.
#   2) Call RotateTransformBox(correction) for the immediate visual.
#   3) Pre-multiply every entry of initialRelativeTransforms by the same
#      rotation so DD's next-frame recompute reproduces the corrected
#      state on its own (otherwise DD undoes the correction).
#
# Correction is recomputed from scratch each frame (no running
# accumulator that could desync from reality), so any drift caused by
# DD resetting some internal state is corrected on the very next frame.
#
# Note on property access
# ----------------------
# We use direct property access on _select_tool (e.g. _select_tool.transformMode)
# rather than _select_tool.get("transformMode"). Calling Object.get() on a
# script-level var that's initialised to null appears to choke DD's
# GDScript parser at load time -- direct access is safe and equivalent.
#
# Public API
# - is_snap_active(): used by select_rotation.gd to switch its
#   slider/spinbox step between 1deg and SNAP_DEG when Shift is held.
# - get_rot_at_selection(): exposes the selection-time rotation snapshot
#   so the slider's "0deg = no rotation since selection" baseline matches
#   ours exactly.

var _g
var ui_util  # kept for API symmetry with the rest of the patch; unused here

var _select_tool = null

const SNAP_DEG = 45.0
# Floating-point tolerance: skip RotateTransformBox calls whose effective
# correction is below this, to avoid spurious work on jitter-free frames.
const APPLY_EPS_DEG = 0.001
# Hysteresis: how many degrees PAST the half-step boundary the user must
# drag before we let the lock jump to the next snap. Big enough to swallow
# typical mouse jitter, small enough that a deliberate drag past the
# midpoint still feels responsive.
const HYSTERESIS_DEG = 2.0

# Selection tracking. _rot_at_selection is the reference asset's rotation
# (degrees) at the moment the current selection was formed; it is the
# baseline that "delta since selection = box rotation" is measured from.
var _prev_selection_ids := []
var _rot_at_selection := 0.0

# Mouse-based drag tracking. _drag_active flips on at the first frame
# transformMode == Rotate is observed; on that frame we capture the
# initial cursor angle around the box center, and on subsequent frames
# we accumulate per-frame deltas (each wrapped to [-180, 180]) into
# _drag_user_total. That gives us a clean cumulative drag angle that
# isn't affected by DD's internal state.
var _drag_active := false
var _drag_box_center := Vector2.ZERO
var _drag_last_mouse_angle_rad := 0.0  # radians, raw atan2 output
var _drag_user_total := 0.0  # degrees, cumulative since drag start

# Currently locked snap step, in degrees from _rot_at_selection. Set when
# snap engages (from the asset's visible rotation). Updated when the
# user's mouse-tracked drag moves past the hysteresis threshold from the
# point where the lock was last set.
var _locked_snap_delta := 0.0
# Snapshot of _drag_user_total at the moment _locked_snap_delta was last
# set. Hysteresis on subsequent frames is "has the mouse moved past
# threshold from THIS point?", not "from drag start" -- that way the
# lock can keep stepping forward as the user keeps dragging.
var _drag_at_lock := 0.0
# False until we've initialized _locked_snap_delta for this snap session.
# Reset when the drag ends, the selection changes, or Shift is released.
var _has_lock := false

# Pre-drag box snapshot. DD recomputes boxBegin/boxEnd at release time as
# the AABB of the assets in their new positions, which makes the box
# visibly grow each time the user rotates a multi-asset selection. We
# snapshot the corners at drag start, then keep restoring them every
# frame after release as long as the selection is unchanged and no new
# drag has started -- writing once at release isn't enough because DD's
# own _process keeps recomputing the box later in the frame.
#
# Note: DD's native selection box is rendered as an axis-aligned AABB
# from boxBegin/boxEnd (free_transform.gd works around this by disabling
# the native box and drawing its own). So we can preserve the box SIZE
# but not its visual rotation -- to also have a rotated box, we'd need
# to replicate free_transform's overlay rendering, which is out of scope
# for a snap mod.
var _box_begin_pre_drag := Vector2.ZERO
var _box_end_pre_drag := Vector2.ZERO
var _has_pre_drag_box := false
var _snap_engaged_during_drag := false

# After a snap rotation drag, we keep overwriting boxBegin/boxEnd with
# the pre-drag values every frame until the selection changes or a new
# drag starts -- that way even DD's continuous recompute can't grow the
# box back.
var _persist_box := false
var _persist_box_begin := Vector2.ZERO
var _persist_box_end := Vector2.ZERO


func initialize() -> void:
	_select_tool = _g.Editor.Tools["SelectTool"]
	print("[RotationSnap] Initialized -- snap step %.1fdeg, hysteresis %.1fdeg" % [SNAP_DEG, HYSTERESIS_DEG])


func _is_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("rotation_snap")


# --- Public API -----------------------------------------------------------

# True when the snap behavior should currently apply: SelectTool active,
# Shift held, and Free Transform NOT taking over. Rotation-drag gating
# (transformMode == 2) is intentionally NOT included here -- UI consumers
# (select_rotation.gd) want to mirror the snap step whenever Shift is
# held, not only during an active drag.
func is_snap_active() -> bool:
	if not _is_enabled():
		return false
	if _g.Editor.ActiveToolName != "SelectTool":
		return false
	if _g.ModMapData != null and _g.ModMapData.get("_free_transform_active", false):
		return false
	return Input.is_key_pressed(KEY_SHIFT)


# Reference asset's rotation_degrees at the moment the current selection
# was formed. Used both for our own snap math and exposed for any UI that
# wants to display rotations relative to the selection baseline.
func get_rot_at_selection() -> float:
	return _rot_at_selection


# --- Per-frame snap -------------------------------------------------------

func update(_delta) -> void:
	# Refresh the selection-time snapshot every frame so we always have a
	# fresh baseline when the user starts a snap drag -- even if no snap
	# is currently engaged. This must run BEFORE select_rotation.update()
	# so the slider can read get_rot_at_selection() with the latest value
	# (Main.gd is responsible for the call order).
	_refresh_selection_snapshot()

	var mode = _select_tool.transformMode

	# Continuous box restoration. After a snap rotation, we keep
	# overwriting boxBegin/boxEnd with the pre-drag values every frame
	# (as long as we're not in a new drag) so DD's per-frame recompute
	# can't grow the box back. The persistence is cancelled when a new
	# drag starts (below) or when the selection changes (in
	# _refresh_selection_snapshot).
	if _persist_box and mode != 2:
		_select_tool.boxBegin = _persist_box_begin
		_select_tool.boxEnd = _persist_box_end

	# Reset all per-drag state whenever a rotation drag isn't active.
	if mode == null or mode != 2:
		# Drag just ended (or wasn't active). If snap was engaged at any
		# point during this drag, ENGAGE persistence: keep restoring the
		# pre-drag box corners every frame from now on.
		if _drag_active and _has_pre_drag_box and _snap_engaged_during_drag:
			_persist_box = true
			_persist_box_begin = _box_begin_pre_drag
			_persist_box_end = _box_end_pre_drag
			_select_tool.boxBegin = _persist_box_begin
			_select_tool.boxEnd = _persist_box_end
			# Toggle EnableTransformBox to force a visual refresh from
			# the new corner values (other mods use this pattern when
			# updating box state).
			_select_tool.EnableTransformBox(false)
			_select_tool.EnableTransformBox(true)
		_drag_active = false
		_has_pre_drag_box = false
		_snap_engaged_during_drag = false
		_drag_user_total = 0.0
		_locked_snap_delta = 0.0
		_drag_at_lock = 0.0
		_has_lock = false
		return

	# First frame of this rotation drag: anchor the mouse-angle baseline
	# AND snapshot the box corners. We capture even when Shift isn't held
	# yet, so a drag started without Shift and engaging snap mid-drag
	# still has the right pre-drag box to restore on release. Also drop
	# any prior persistence -- a new drag is starting, the user is
	# actively interacting again.
	if not _drag_active:
		_drag_active = true
		_persist_box = false
		_box_begin_pre_drag = _select_tool.boxBegin
		_box_end_pre_drag = _select_tool.boxEnd
		_has_pre_drag_box = true
		_snap_engaged_during_drag = false
		_drag_box_center = _get_box_center()
		_drag_last_mouse_angle_rad = _get_current_mouse_angle_rad()
		_drag_user_total = 0.0

	# Always update _drag_user_total, snap-active or not, so when the
	# user presses Shift later in the same drag we have the correct
	# cumulative angle. Per-frame deltas are wrapped to [-pi, pi] before
	# being added, which transparently handles atan2 wraparound.
	var current_mouse_angle_rad = _get_current_mouse_angle_rad()
	var delta_rad = current_mouse_angle_rad - _drag_last_mouse_angle_rad
	while delta_rad > PI:
		delta_rad -= TAU
	while delta_rad < -PI:
		delta_rad += TAU
	_drag_user_total += rad2deg(delta_rad)
	_drag_last_mouse_angle_rad = current_mouse_angle_rad

	if not is_snap_active():
		# Releasing Shift mid-drag: drop the lock so re-pressing Shift
		# picks a fresh nearest snap from the current visible rotation.
		# We do NOT reset _drag_user_total -- the user's cumulative drag
		# is theirs to keep.
		_has_lock = false
		return

	var ref = _pick_reference()
	if ref == null:
		return

	# Lock engage: snap to the multiple of 45deg closest to the asset's
	# CURRENT visible rotation. ref.rotation is the truth on screen -- by
	# computing the snap target from it directly, we guarantee the user
	# gets "snap to nearest from where I am right now" without any
	# dependence on accumulated mouse-tracking, which can drift subtly
	# due to coordinate-transform precision or pivot jitter.
	if not _has_lock:
		var visible_delta = rad2deg(ref.rotation) - _rot_at_selection
		# Wrap to [-180, 180] so "nearest" is symmetric -- without this,
		# a delta of 350deg would round to 360deg instead of -10deg.
		while visible_delta > 180.0:
			visible_delta -= 360.0
		while visible_delta < -180.0:
			visible_delta += 360.0
		_locked_snap_delta = _round_to_snap(visible_delta)
		_drag_at_lock = _drag_user_total
		_has_lock = true
		# Snap is now engaged for this drag -- mark it so we know to
		# restore the pre-drag box on release.
		_snap_engaged_during_drag = true
	else:
		# Already locked. Switch lock to the next snap once the user
		# has dragged past the hysteresis threshold from where we last
		# set the lock -- measured via the cursor, which is immune to
		# DD-driven jumps in the visible rotation.
		var drag_since_lock = _drag_user_total - _drag_at_lock
		var threshold = SNAP_DEG / 2.0 + HYSTERESIS_DEG
		if abs(drag_since_lock) > threshold:
			# Step the lock by however many snap multiples the user
			# has dragged through. Reset _drag_at_lock to the new
			# anchor so subsequent hysteresis is from THIS step, not
			# from drag start.
			var steps = round(drag_since_lock / SNAP_DEG)
			_locked_snap_delta += steps * SNAP_DEG
			_drag_at_lock += steps * SNAP_DEG

	# Compute correction from scratch -- no accumulator to go stale.
	var current_rotation_deg = rad2deg(ref.rotation)
	var desired_rotation_deg = _rot_at_selection + _locked_snap_delta
	var correction_deg = desired_rotation_deg - current_rotation_deg
	# Take the shortest equivalent rotation so we never spin the box
	# the long way round when crossing +-180.
	while correction_deg > 180.0:
		correction_deg -= 360.0
	while correction_deg < -180.0:
		correction_deg += 360.0

	if abs(correction_deg) <= APPLY_EPS_DEG:
		return

	# Apply the rotation to the live transforms first...
	_select_tool.RotateTransformBox(correction_deg)

	# ...then shift DD's drag baseline by the same amount so the next
	# frame's recompute keeps the snap in place. initialRelativeTransforms
	# stores per-Selectable transforms in box-local space (the box center
	# is at the origin of that space), so a rotation around world-space
	# box center == a rotation around the origin in box-local space ==
	# pre-multiplying each entry by Transform2D(angle, ZERO).
	var irt = _select_tool.initialRelativeTransforms
	if irt != null:
		var rot_xform = Transform2D(deg2rad(correction_deg), Vector2.ZERO)
		for key in irt.keys():
			irt[key] = rot_xform * irt[key]


# --- Mouse helpers --------------------------------------------------------

func _get_box_center() -> Vector2:
	var rect = _select_tool.GetSelectionRect()
	return rect.position + rect.size * 0.5


func _get_current_mouse_angle_rad() -> float:
	var viewport = _g.World.get_viewport()
	var mouse_screen = viewport.get_mouse_position()
	var canvas_xform = viewport.get_canvas_transform()
	var mouse_world = canvas_xform.affine_inverse().xform(mouse_screen)
	var dir = mouse_world - _drag_box_center
	return atan2(dir.y, dir.x)


func _round_to_snap(deg: float) -> float:
	return round(deg / SNAP_DEG) * SNAP_DEG


# --- Selection tracking ---------------------------------------------------

func _refresh_selection_snapshot() -> void:
	if _g.Editor.ActiveToolName != "SelectTool":
		if _prev_selection_ids.size() > 0:
			_prev_selection_ids = []
			_rot_at_selection = 0.0
			_drag_active = false
			_locked_snap_delta = 0.0
			_drag_at_lock = 0.0
			_has_lock = false
			_persist_box = false
		return

	var raw = _select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		if _prev_selection_ids.size() > 0:
			_prev_selection_ids = []
			_rot_at_selection = 0.0
			_drag_active = false
			_locked_snap_delta = 0.0
			_drag_at_lock = 0.0
			_has_lock = false
			_persist_box = false
		return

	# Build the current selection signature. Use Thing instance_ids so
	# deselect+reselect of the same set is detected as "no change", while
	# a different set (or empty) is correctly flagged.
	var current_ids := []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing != null and is_instance_valid(thing):
			current_ids.append(thing.get_instance_id())

	if current_ids == _prev_selection_ids:
		return

	_prev_selection_ids = current_ids
	# Different selection -> any in-progress drag/lock state is from a
	# previous context and must be discarded. Also drop box persistence
	# since the box belonged to the previous selection.
	_drag_active = false
	_locked_snap_delta = 0.0
	_drag_at_lock = 0.0
	_has_lock = false
	_persist_box = false

	# Snapshot the reference asset's rotation as the new baseline. If we
	# can't pick a rotatable reference (all-walls selection etc.), fall
	# back to 0 -- the snap won't engage on those selections anyway since
	# transformMode never goes to Rotate.
	var ref = _pick_reference()
	if ref != null:
		_rot_at_selection = rad2deg(ref.rotation)
	else:
		_rot_at_selection = 0.0


# Picks a stable rotatable reference from the current selection. Iteration
# order of RawSelectables is consistent for a stable selection, so this
# returns the same node frame after frame; only a selection change can
# pick a different reference.
func _pick_reference():
	var raw = _select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return null
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		var t = _select_tool.GetSelectableType(thing)
		# Skip Walls (1) and PortalWall (3): not rotatable.
		if t == 1 or t == 3:
			continue
		return thing
	return null
