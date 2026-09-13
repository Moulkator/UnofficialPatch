# scatter_transform.gd
# Scatter Tool: manual rotation / scale override for the asset in hand.
#
# Vanilla ScatterTool rolls a random rotation and a random scale for every
# preview it builds (Next() -> Global.Random.NextFloat between the Min/Max
# Rotation and Min/Max Scale sliders) and gives no way to adjust the object
# currently held by the cursor. This mod brings the ObjectTool bindings to
# the ScatterTool preview:
#
#   wheel              rotate by +/-15 deg
#   Z + wheel          rotate by +/-5 deg   (fine)
#   Shift + Z + wheel  rotate by +/-1 deg   (precision)
#   Alt + wheel        scale  by +/-0.1
#   right click        rotate by +90 deg
#
# Scope: the override is written straight onto the live preview node, so it
# only affects the asset in hand. ScatterTool._Update() only rewrites
# GlobalPosition, never rotation or scale, so the value sticks until the
# object is stamped. As soon as ScatterTool builds its next preview (after a
# stamp, or when the texture pool changes) the random values take over
# again -- randomness stays the default behaviour, the override is a
# one-shot bypass for the current asset.
#
# Modifier map (nothing else is ever consumed):
#   - Ctrl + wheel  -> DD's zoom (and zoom_unlock). Left alone.
#   - Shift + wheel -> reserved for asset cycling. Left alone.
#   - wheel over any UI control -> left alone, so the object library and the
#     tool panel keep scrolling normally.
#
# NB on the _input dispatch order — this is why the mod used to work only
# "most of the time":
#   SceneTree::_call_input_pause() walks the "_input" group in REVERSE tree
#   order and starts every iteration with `if (input_handled) break;`. So
#   set_input_as_handled() does NOT merely stop DD's _unhandled_input: it
#   cancels every _input() callback that has not run yet. Reverse tree order
#   means the node added LAST to the tree is served FIRST.
#   The suite adds listener nodes to the viewport root all session long, some
#   of them lazily (FreeTransformListener, Terrain16Driver, popup layers,
#   dialogs, timers...). Every one of them lands after ours and therefore
#   jumps ahead of us in the queue; the moment one of them consumes a wheel
#   event, our handler stops being called at all — silently, and only from
#   that point on, which is exactly the "no reliable repro" symptom.
#   Fix: keep our listener as the LAST child of root so we are served first,
#   and re-assert that position whenever root's child count changes. Being
#   first is safe here because the guards below are narrow (ScatterTool only,
#   exact modifier combos, cursor over the map): everything else falls
#   through untouched.
#
# NB on the UI guard: we deliberately do NOT use the default
# ui_util.is_mouse_over_ui(). That variant returns true as soon as ANY Popup
# is visible anywhere in the tree, and Godot 3 tooltips ARE Popups (plus the
# popup answer is cached for up to 3 frames). A tooltip lingering over the
# toolbar, or any hidden-but-"visible" WindowDialog, therefore made the wheel
# silently do nothing while the cursor was plainly over the map — the exact
# "works most of the time, sometimes not" symptom. We ask the geometry-only
# variant (ignore_popups = true) and hit-test the popup UNDER the cursor
# separately, so only a popup we would actually be scrolling wins the wheel.

const ROT_STEP_DEG := 15.0
const ROT_STEP_FINE_DEG := 5.0
const ROT_STEP_PRECISE_DEG := 1.0
const ROT_STEP_RIGHT_CLICK_DEG := 90.0
const SCALE_STEP := 0.1
const SCALE_MIN := 0.05
const SCALE_MAX := 20.0

var _g
var ui_util
var input_listener: Node = null

# Keep the listener first in the _input queue (see header). Turn off to test
# the vanilla dispatch order.
const FIRST_IN_INPUT_QUEUE := true
# Flip to true to trace, on every wheel event, either the applied transform
# or the exact guard that swallowed the scroll. Silent when false.
const DEBUG := false

var _destroyed := false
var _attach_frame := -100
var _root_child_count := -1
func initialize() -> void:
	_install_input_listener()
	_dbg("initialized")


func update(_delta) -> void:
	# Purely event driven: the override is applied once, on the wheel event.
	# The only per-frame duty is keeping the listener alive: it is attached
	# with call_deferred at init, so if Global.World was not in the tree yet
	# (or the node got freed by a scene change) the mod would stay silently
	# dead for the whole session with no error anywhere. Two cheap checks.
	_ensure_listener()
	_keep_input_priority()


func cleanup() -> void:
	_destroyed = true
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	_dbg("cleaned up")


func _ensure_listener() -> void:
	if _destroyed:
		return
	if input_listener == null or not is_instance_valid(input_listener):
		_install_input_listener()
		return
	if input_listener.is_inside_tree():
		return
	# Not in the tree: either the first call_deferred has not landed yet, or
	# it never found a host. Retry, but leave the pending deferred call room
	# to run so we never queue two add_child for the same node.
	var f = Engine.get_idle_frames()
	if f - _attach_frame < 30:
		return
	_attach_frame = f
	_attach_listener()


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "ScatterTransformListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -90
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	_attach_frame = Engine.get_idle_frames()
	_attach_listener()


# Attach to the viewport root. Global.World is the usual host but it is not
# guaranteed to be in the tree when the suite boots, hence the fallbacks.
func _attach_listener() -> void:
	if input_listener == null or not is_instance_valid(input_listener):
		return
	if input_listener.get_parent() != null:
		return
	var host = null
	for cand in [_g.World, _g.Editor, _g.Camera]:
		if cand is Node and cand.is_inside_tree():
			host = cand
			break
	if host == null:
		return
	var tree = host.get_tree()
	if tree and tree.root:
		tree.root.call_deferred("add_child", input_listener)


# Re-assert our position at the end of root's child list so we stay first in
# the _input dispatch. Only pays a get_child_count() per frame; the move_child
# itself runs a handful of times per session, when something new was attached
# to root. Done from update() (idle frame), never from inside _input.
func _keep_input_priority() -> void:
	if not FIRST_IN_INPUT_QUEUE:
		return
	if input_listener == null or not is_instance_valid(input_listener):
		return
	if not input_listener.is_inside_tree():
		return
	var root = input_listener.get_parent()
	if root == null:
		return
	var count = root.get_child_count()
	if count == _root_child_count:
		return
	_root_child_count = count
	var last = count - 1
	if input_listener.get_index() != last:
		root.move_child(input_listener, last)
		_dbg("listener moved to index %d/%d" % [last, count])


func _dbg(msg: String) -> void:
	if DEBUG:
		print("[ScatterTransform] " + msg)


# ==================== INPUT ====================

func _on_input(event) -> void:
	if _destroyed or input_listener == null or not is_instance_valid(input_listener):
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var right_click: bool = event.button_index == BUTTON_RIGHT
	if not right_click and event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return
	# Ctrl belongs to the zoom. Bail out before touching anything else.
	if not right_click and (event.control or Input.is_key_pressed(KEY_CONTROL)):
		return
	var tool_name = _active_tool_name()
	if tool_name != "ScatterTool":
		_dbg("input ignored: active tool is '%s'" % tool_name)
		return
	# Never steal the wheel from a UI control (object library, sliders, ...).
	# See the header note: geometry-only test, plus an explicit hit-test of
	# the popup under the cursor. A popup visible ELSEWHERE (tooltip, terrain
	# window, ...) must not disable the tool.
	if ui_util == null:
		_dbg("WARNING: ui_util is null, UI guard skipped entirely")
	else:
		if ui_util.is_mouse_over_popup(input_listener):
			_dbg("wheel ignored: a popup is under the cursor")
			return
		if ui_util.is_mouse_over_ui(input_listener, true):
			_dbg("wheel ignored: cursor is over a UI surface")
			return

	var preview = _get_preview()
	if preview == null:
		_dbg("wheel ignored: ScatterTool has no usable Preview")
		return

	# Right click: quarter turn, no modifier handling. Consumed so DD's
	# ScatterTool never sees the click; right_click_util polls the raw mouse
	# state and only shows its menu in SelectTool, so it is unaffected.
	if right_click:
		_rotate_preview(preview, true, ROT_STEP_RIGHT_CLICK_DEG)
		_dbg("right click: rot=%.1f deg" % rad2deg(preview.global_rotation))
		input_listener.get_tree().set_input_as_handled()
		return

	var up: bool = event.button_index == BUTTON_WHEEL_UP
	var alt: bool = event.alt or Input.is_key_pressed(KEY_ALT)
	var shift: bool = event.shift or Input.is_key_pressed(KEY_SHIFT)
	var z: bool = Input.is_key_pressed(KEY_Z)

	if alt and not shift and not z:
		_scale_preview(preview, up)
	elif shift and z and not alt:
		_rotate_preview(preview, up, ROT_STEP_PRECISE_DEG)
	elif z and not shift and not alt:
		_rotate_preview(preview, up, ROT_STEP_FINE_DEG)
	elif not shift and not alt and not z:
		_rotate_preview(preview, up, ROT_STEP_DEG)
	else:
		# Shift alone (asset cycling) and any other combination: not ours.
		_dbg("wheel ignored: modifier combo not ours (alt=%s shift=%s z=%s)" % [alt, shift, z])
		return

	_dbg("applied: rot=%.1f deg scale=%.2f" % [rad2deg(preview.global_rotation), preview.scale.x])
	input_listener.get_tree().set_input_as_handled()


# ==================== PREVIEW ACCESS ====================

func _get_preview():
	if not _uu_editor_reachable():
		return null
	var tools = _g.Editor.Tools
	if tools == null or not tools.has("ScatterTool"):
		return null
	var st = tools["ScatterTool"]
	if st == null:
		return null
	# ScatterTool.Preview is null between Disable() and the next Enable(),
	# and its Texture is null while no asset is selected in the library.
	var preview = st.get("Preview")
	if preview == null or not is_instance_valid(preview):
		return null
	if preview.get("Texture") == null:
		return null
	return preview


func _rotate_preview(preview, up: bool, step_deg: float) -> void:
	var step = deg2rad(step_deg)
	var target = preview.global_rotation + (step if up else -step)
	preview.global_rotation = wrapf(target, -PI, PI)


func _scale_preview(preview, up: bool) -> void:
	# ScatterTool writes a uniform Scale (not GlobalScale), so we mirror that.
	var current: float = preview.scale.x
	var target: float = clamp(current + (SCALE_STEP if up else -SCALE_STEP), SCALE_MIN, SCALE_MAX)
	preview.scale = Vector2(target, target)


# ==================== SHARED EDITOR STATE ====================
# Same contract as the other submods: read the per-frame snapshot published
# by Main.gd instead of marshalling ActiveToolName across the interop
# boundary, and memoize the _g.Editor reachability check once per tick.

var _uu_ed_frame := -1
var _uu_ed_ok := false


func _active_tool_name() -> String:
	if not _uu_editor_reachable():
		return ""
	if Engine.has_meta("_uu_editor_state"):
		var s = Engine.get_meta("_uu_editor_state")
		if s is Dictionary:
			var v = s.get("active_tool_name")
			if v is String:
				return "%s" % v
	return str(_g.Editor.ActiveToolName)


func _uu_editor_reachable() -> bool:
	var f = Engine.get_idle_frames()
	if f == _uu_ed_frame:
		return _uu_ed_ok
	_uu_ed_frame = f
	_uu_ed_ok = _g != null and _g.Editor != null
	return _uu_ed_ok
