# scale_unlock.gd
# Allows the ObjectTool's Size slider to exceed its default bounds via
# Alt+Scroll. When Alt+scrolling would push the value past min/max,
# the slider bounds are extended dynamically.
#
# Works by intercepting Alt+scroll BEFORE Dungeondraft processes it
# (priority -101), applying the new value ourselves, and consuming the
# event. DD's native Alt+scroll resize is fully replaced by ours,
# which has no upper/lower cap.
#
# Step sizes:
#   - Within default slider range → use the slider's native step
#   - First 10 units past the limit → step 0.1
#   - Beyond that → step 1.0
#
# Integration with Eyedropper:
#   set_value(val) extends slider bounds if needed.

var _g
var ui_util

var _obj_tool       = null   # ObjectTool reference
var _sc_ctrl        = null   # Scale Range control (HSlider)
var _input_listener = null

var _default_min    := 0.0   # original slider min_value
var _default_max    := 1.0   # original slider max_value
var _default_step   := 0.1   # original slider step
var _inited         := false


func initialize() -> void:
	_install_input_listener()
	print("[ScaleUnlock] Initialized")


# ── Input listener ───────────────────────────────────────────────────────

func _install_input_listener() -> void:
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -101
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "ScaleUnlockListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", _input_listener)


# ── Per-frame update ─────────────────────────────────────────────────────

func update(_delta: float) -> void:
	if not _g or not _g.Editor:
		return
	if _g.Editor.ActiveToolName != "ObjectTool":
		return
	_ensure_init()


# ── Lazy init: grab slider defaults once ─────────────────────────────────

func _ensure_init() -> void:
	if _inited:
		return
	if _obj_tool == null:
		_obj_tool = _g.Editor.Tools.get("ObjectTool")
	if _obj_tool == null:
		return
	_sc_ctrl = _obj_tool.get("Scale")
	if _sc_ctrl == null or not is_instance_valid(_sc_ctrl):
		return
	_default_min  = _sc_ctrl.min_value
	_default_max  = _sc_ctrl.max_value
	_default_step = _sc_ctrl.step if _sc_ctrl.step > 0 else 0.1
	_inited = true
	print("[ScaleUnlock] Slider defaults: min=", _default_min, " max=", _default_max, " step=", _default_step)


# ── Public API for Eyedropper ────────────────────────────────────────────

func set_value(val: float) -> void:
	"""Set an arbitrary scale value, extending slider bounds if needed."""
	_ensure_init()
	if _sc_ctrl == null or not is_instance_valid(_sc_ctrl):
		return
	_apply_value(val)


func restore_bounds() -> void:
	"""Restore slider to default bounds, clamping value."""
	if _sc_ctrl == null or not is_instance_valid(_sc_ctrl):
		return
	_sc_ctrl.min_value = _default_min
	_sc_ctrl.max_value = _default_max


# ── Step size logic ──────────────────────────────────────────────────────

func _get_step(current_value: float) -> float:
	# Within normal slider range
	if current_value <= _default_max and current_value >= _default_min:
		if current_value < 0.5:
			return 0.025  # finest control for small objects
		if current_value <= 1.0:
			return 0.05
		return 0.1
	# Above max: 0.1 for first 10 units, then 1.0
	if current_value > _default_max:
		if current_value < _default_max + 10.0:
			return 0.1
		else:
			return 1.0
	# Below min: 0.01 steps for fine control at small scales
	return 0.01


# Snap to the step grid so up/down movements are reversible.
# Returns the nearest grid line strictly past `current` in `direction`.
func _next_grid(current: float, step: float, direction: float) -> float:
	var snapped = stepify(current, step)
	if direction > 0.0:
		if snapped > current + step * 0.001:
			return stepify(snapped, step)
		return stepify(snapped + step, step)
	else:
		if snapped < current - step * 0.001:
			return stepify(snapped, step)
		return stepify(snapped - step, step)


# ── Apply value + extend bounds ──────────────────────────────────────────

func _apply_value(val: float) -> void:
	# Prevent the slider from re-quantizing our value to its native (coarse)
	# step, which would otherwise snap small decrements back up.
	_sc_ctrl.step = 0.001
	if val > _default_max:
		_sc_ctrl.max_value = val
		_sc_ctrl.min_value = _default_min
	elif val < _default_min:
		_sc_ctrl.min_value = val
		_sc_ctrl.max_value = _default_max
	else:
		_sc_ctrl.min_value = _default_min
		_sc_ctrl.max_value = _default_max
	_sc_ctrl.value = val


# ── Input handling ───────────────────────────────────────────────────────

func _on_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return
	# Only Alt+scroll (no Shift, no Ctrl, no Z)
	if not Input.is_key_pressed(KEY_ALT):
		return
	if Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CONTROL) or Input.is_key_pressed(KEY_Z):
		return
	# Only in ObjectTool
	if not _g.Editor or _g.Editor.ActiveToolName != "ObjectTool":
		return
	# Don't intercept when mouse is over UI panels
	if ui_util and ui_util.is_mouse_over_ui(_input_listener):
		return
	_ensure_init()
	if _sc_ctrl == null or not is_instance_valid(_sc_ctrl):
		return

	var current = _sc_ctrl.value
	var step = _get_step(current)
	var direction = 1.0 if event.button_index == BUTTON_WHEEL_UP else -1.0
	var new_val = _next_grid(current, step, direction)

	if new_val < 0.01:
		new_val = 0.01

	_apply_value(new_val)

	# Consume event so DD doesn't also process it
	_input_listener.get_tree().set_input_as_handled()
