# export_snap_crop.gd
# Adds a "Snap to Grid" ON/OFF toggle next to Crop / Reset Crop in the Export
# window, plus the "S" keyboard shortcut while the window is open, so you can
# enable/disable grid snapping right before or during a crop drag (the crop
# uses WorldUI.SnappedPosition, which reads Editor.IsSnapping live).
#
# Wiring: Editor.IsSnapping has a private C# setter, so it cannot be written
# from GDScript. Instead we drive the native floatbar CheckBox
# (Editor.SnapToggle, public): setting its `pressed` emits "toggled", which
# runs DD's _on_SnapToggle_toggled -> IsSnapping = value, and keeps the
# floatbar button visually in sync after the window closes.
#
# The "S" shortcut needs a live _input() while the modal window is open:
# modal popups block GUI/shortcut routing but not Node._input, so a small
# listener Node on tree.root does the job (input listener pattern). Ctrl/Alt/
# Meta combos are ignored (Ctrl+S = save) and so is typing in a LineEdit
# (the PPI SpinBox field).
#
# Main.update() does not run while the modal Export window is open, so the
# pressed-state sync runs on a Timer parented to _g.Editor (pattern of
# wall_tool_portal_fix.gd / export_brightness_fix.gd), with the usual
# Engine-meta guards against node accumulation across mod generations.

var _g

const BUTTON_NAME = "UP_ExportSnapToggle"
const TIMER_META = "up_esc_timer"
const LISTENER_META = "up_esc_listener"
const SEP_META = "up_esc_sep_orig"
const ROW_SEPARATION = 16
const CHECK_INTERVAL = 0.1

var _button = null
var _timer = null
var _listener = null
var _sep_parent = null
var _destroyed = false


class SnapKeyListener extends Node:
	var owner_mod = null

	func _ready() -> void:
		set_process_input(true)

	func _input(event) -> void:
		if owner_mod != null:
			owner_mod._on_key_input(event)


func initialize() -> void:
	_inject_button()
	# Cross-session guards: _g.Editor and tree.root persist across map
	# reloads, so nodes added by a previous mod generation keep living
	# forever. Free the previous ones before adding ours.
	if Engine.has_meta(TIMER_META):
		var _old_t = Engine.get_meta(TIMER_META)
		if is_instance_valid(_old_t):
			_old_t.queue_free()
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	Engine.set_meta(TIMER_META, _timer)
	_g.Editor.call_deferred("add_child", _timer)

	if Engine.has_meta(LISTENER_META):
		var _old_l = Engine.get_meta(LISTENER_META)
		if is_instance_valid(_old_l):
			_old_l.queue_free()
	_listener = SnapKeyListener.new()
	_listener.owner_mod = self
	Engine.set_meta(LISTENER_META, _listener)
	var tree = _get_tree()
	if tree != null:
		tree.root.call_deferred("add_child", _listener)


func cleanup() -> void:
	_destroyed = true
	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
	if Engine.has_meta(TIMER_META) and Engine.get_meta(TIMER_META) == _timer:
		Engine.remove_meta(TIMER_META)
	_timer = null
	if _listener != null and is_instance_valid(_listener):
		_listener.owner_mod = null
		_listener.queue_free()
	if Engine.has_meta(LISTENER_META) and Engine.get_meta(LISTENER_META) == _listener:
		Engine.remove_meta(LISTENER_META)
	_listener = null
	if _button != null and is_instance_valid(_button):
		var parent = _button.get_parent()
		if parent != null:
			parent.remove_child(_button)
		_button.queue_free()
	_button = null
	if _sep_parent != null and is_instance_valid(_sep_parent) and Engine.has_meta(SEP_META):
		_sep_parent.add_constant_override("separation", int(Engine.get_meta(SEP_META)))
		Engine.remove_meta(SEP_META)
	_sep_parent = null


func _get_tree():
	if _g == null:
		return null
	if _g.World != null and is_instance_valid(_g.World):
		return _g.World.get_tree()
	if _g.Editor != null and is_instance_valid(_g.Editor):
		return _g.Editor.get_tree()
	return null


func _get_export_window():
	if _g == null or _g.Editor == null:
		return null
	var windows = _g.Editor.Windows
	if windows == null or not windows.has("Export"):
		return null
	return windows["Export"]


func _is_snapping() -> bool:
	if _g == null or _g.Editor == null:
		return false
	return _g.Editor.get("IsSnapping") == true


func _inject_button() -> void:
	var win = _get_export_window()
	if win == null:
		return
	# Idempotence across mod generations: the Export window persists, so a
	# button injected by a previous instance may still be in the tree.
	# remove_child before queue_free so the node name is released immediately.
	var old = win.find_node(BUTTON_NAME, true, false)
	if old != null:
		var old_parent = old.get_parent()
		if old_parent != null:
			old_parent.remove_child(old)
		old.queue_free()
	var reset_btn = win.find_node("ResetCropButton", true, false)
	if reset_btn == null:
		print("[UnofficialPatch] ExportSnapCrop: ResetCropButton not found, toggle not injected.")
		return
	var parent = reset_btn.get_parent()
	if parent == null:
		return
	# Space out the Crop / Reset Crop / Snap row: widen the HBox separation.
	# The original value is stored once in Engine meta so a later mod
	# generation (which would read our 16 as "original") still restores
	# the true vanilla value on cleanup.
	if parent is BoxContainer:
		if not Engine.has_meta(SEP_META):
			Engine.set_meta(SEP_META, parent.get_constant("separation"))
		parent.add_constant_override("separation", ROW_SEPARATION)
		_sep_parent = parent
	var btn = CheckButton.new()
	btn.name = BUTTON_NAME
	btn.text = "Snap to Grid"
	btn.hint_tooltip = "Toggle grid snapping for the crop selection. (S)"
	btn.pressed = _is_snapping()
	btn.focus_mode = Control.FOCUS_NONE
	parent.add_child(btn)
	parent.move_child(btn, reset_btn.get_index() + 1)
	btn.connect("toggled", self, "_on_toggled")
	_button = btn


func _tick() -> void:
	if _destroyed:
		return
	var win = _get_export_window()
	if win == null or not win.visible:
		return
	# Self-heal: covers the case where the Export window did not exist yet
	# when initialize() ran (injection then happens on first open).
	if _button == null or not is_instance_valid(_button):
		_inject_button()
		if _button == null:
			return
	# Mirror the editor state (also picks up the state current at window
	# open). Same value -> no "toggled" emission -> no feedback loop.
	if _button.pressed != _is_snapping():
		_button.pressed = _is_snapping()


func _on_toggled(state: bool) -> void:
	if _g == null or _g.Editor == null:
		return
	var snap_toggle = _g.Editor.get("SnapToggle")
	if snap_toggle == null or not is_instance_valid(snap_toggle):
		return
	# Setting `pressed` emits "toggled" on the native CheckBox, which runs
	# DD's _on_SnapToggle_toggled and updates Editor.IsSnapping. If the
	# value is already equal, nothing is emitted (harmless).
	if snap_toggle.pressed != state:
		snap_toggle.pressed = state


func _on_key_input(event) -> void:
	if _destroyed:
		return
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	if event.scancode != KEY_S:
		return
	# Leave Ctrl+S / Cmd+S / Alt+S combos alone.
	if event.control or event.command or event.alt or event.meta:
		return
	var win = _get_export_window()
	if win == null or not win.visible:
		return
	if _button == null or not is_instance_valid(_button):
		return
	# Don't hijack "s" typed into a text field (e.g. the PPI SpinBox).
	var focus = _button.get_focus_owner()
	if focus != null and focus is LineEdit:
		return
	# Flipping `pressed` emits "toggled" -> _on_toggled does the real work.
	_button.pressed = not _button.pressed
