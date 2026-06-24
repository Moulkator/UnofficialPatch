# zoom_unlock.gd
# Unlocks zoom limits beyond DD's default range.
#
# Display: pct = (_cam_ratio / camera.zoom.x) * 100
#   800% = zoomed in (close), 10% = zoomed out (far)

var _g
var ui_util
var input_listener : Node = null
var _process_node  : Node = null

var zoom_min := 0.06
var zoom_max := 200.0
var zoom_step := 0.12

var _scroll_pending     := false
var _scroll_dir         := 0
var _zoom_before        := -1.0
var _consecutive_stalls := 0

var _extended      := false
var _extended_zoom := 1.0
var _stall_zoom    := 1.0

var _zoom_options      = null
var _orig_min_size_x   := -1.0
var _orig_item_texts   := []          # snapshot to restore corrupted items
var _cam_ratio         := 1.0

var _destroyed := false


func initialize() -> void:
	_install_input_listener()
	_install_process_node()
	_zoom_options = _g.Editor.get("ZoomOptions") if _g.Editor else null
	if _zoom_options != null and is_instance_valid(_zoom_options):
		_zoom_options.connect("item_selected", self, "_on_zoom_option_selected")
		_orig_min_size_x = _zoom_options.rect_min_size.x
		_snapshot_item_texts()

	_recompute_cam_ratio()
	# Re-derive once after the first frame in case camera/dropdown weren't
	# fully settled at mod init. A wrong _cam_ratio would scale every extended
	# percentage by the same incorrect factor for the whole session.
	call_deferred("_recompute_cam_ratio")

	print("[ZoomUnlock] Initialized  ratio=%.4f" % _cam_ratio)


func _snapshot_item_texts() -> void:
	_orig_item_texts.clear()
	if _zoom_options == null or not is_instance_valid(_zoom_options):
		return
	for i in range(_zoom_options.get_item_count()):
		var raw = _zoom_options.get_item_text(i)
		var fixed = _normalize_percent(raw)
		_orig_item_texts.append(fixed)
		# Rewrite DD's items too so the labels display correctly even when
		# the mod isn't actively extending (fixes the U+066A glyph issue).
		if fixed != raw:
			_zoom_options.set_item_text(i, fixed)
	# Refresh the button text in case the selected item was just rewritten.
	var sel = _zoom_options.selected
	if sel >= 0 and sel < _zoom_options.get_item_count():
		_zoom_options.text = _zoom_options.get_item_text(sel)


func _normalize_percent(s: String) -> String:
	# DD ships some labels with U+066A (Arabic percent sign) instead of the
	# ASCII '%' (U+0025). Most fonts have the ASCII one but not the Arabic
	# variant, so the latter renders as the missing-glyph diamond.
	return s.replace(char(0x066A), "%")


func _recompute_cam_ratio() -> void:
	if _destroyed:
		return
	# Skip while extended — camera.zoom is past DD's range and doesn't match
	# any ZoomLevel, recomputing here would corrupt the ratio.
	if _extended:
		return
	if _g.Camera == null or not is_instance_valid(_g.Camera):
		return
	if _zoom_options == null or not is_instance_valid(_zoom_options):
		return
	var sel = _zoom_options.selected
	var zl = _g.Editor.get("ZoomLevels") if _g.Editor else null
	if zl == null or sel < 0 or sel >= zl.size():
		return
	var level = float(zl[sel])
	if level <= 0.0001:
		return
	_cam_ratio = _g.Camera.zoom.x / level


func cleanup() -> void:
	_destroyed = true
	_restore_dropdown_width()
	_restore_dropdown_item_texts()
	if _zoom_options != null and is_instance_valid(_zoom_options):
		if _zoom_options.is_connected("item_selected", self, "_on_zoom_option_selected"):
			_zoom_options.disconnect("item_selected", self, "_on_zoom_option_selected")
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	if _process_node != null and is_instance_valid(_process_node):
		_process_node.handler = null
		_process_node.queue_free()
	_process_node = null
	print("[ZoomUnlock] Cleaned up")


func _on_zoom_option_selected(_idx: int) -> void:
	if _extended:
		_extended = false
		_scroll_pending = false
		_consecutive_stalls = 0
		_restore_dropdown_width()
		_restore_dropdown_item_texts()
		var camera = _g.Camera
		if camera:
			_zoom_before = camera.zoom.x
	# Always clear cache: a stale entry from a previous extended session can
	# leak into the next first _do_zoom and teleport the camera back there.
	_invalidate_zoom_cache()
	# User-initiated selection is a known-good state to re-derive the ratio.
	call_deferred("_recompute_cam_ratio")


func _install_input_listener() -> void:
	var ls = GDScript.new()
	ls.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -200
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	ls.reload()
	input_listener = Node.new()
	input_listener.name = "ZoomUnlockListener"
	input_listener.set_script(ls)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", input_listener)


func _install_process_node() -> void:
	var ps = GDScript.new()
	ps.source_code = """extends Node
var handler = null
func _process(_d):
	if handler != null:
		handler._on_process()
"""
	ps.reload()
	_process_node = Node.new()
	_process_node.name = "ZoomUnlockProcess"
	_process_node.set_script(ps)
	_process_node.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", _process_node)


func _on_process() -> void:
	if _destroyed:
		return
	var camera = _g.Camera
	if camera == null:
		return

	if _extended and not _scroll_pending:
		if abs(camera.zoom.x - _extended_zoom) > 0.001:
			camera.call("SetRawZoom", _extended_zoom)
		_force_dropdown_text(_extended_zoom)

	if not _scroll_pending:
		return
	_scroll_pending = false

	var zoom_after = camera.zoom.x

	if _extended:
		var factor = (1.0 - zoom_step) if _scroll_dir < 0 else (1.0 + zoom_step)
		var new_zoom = clamp(_extended_zoom * factor, zoom_min, zoom_max)

		var crossing_back = false
		if _scroll_dir < 0 and _stall_zoom < _extended_zoom and new_zoom <= _stall_zoom:
			crossing_back = true
		elif _scroll_dir > 0 and _stall_zoom > _extended_zoom and new_zoom >= _stall_zoom:
			crossing_back = true

		if crossing_back:
			_extended = false
			_consecutive_stalls = 0
			_restore_dropdown_width()
			_restore_dropdown_item_texts()
			camera.call("SetRawZoom", _stall_zoom)
			_zoom_before = _stall_zoom
			_invalidate_zoom_cache()
			return

		if abs(new_zoom - _extended_zoom) < 0.0001:
			# Camera clamped at zoom_min/zoom_max: this input made no change,
			# but _on_input still populated the cache. Invalidate so it can't
			# leak into a later transition (issue 2 root cause).
			_invalidate_zoom_cache()
			return

		_do_zoom(camera, _extended_zoom, new_zoom)
		return

	if abs(zoom_after - _zoom_before) < 0.0001:
		_consecutive_stalls += 1
		if _consecutive_stalls >= 2:
			var factor = (1.0 - zoom_step) if _scroll_dir < 0 else (1.0 + zoom_step)
			var new_zoom = clamp(zoom_after * factor, zoom_min, zoom_max)
			if abs(new_zoom - zoom_after) < 0.0001:
				return
			_stall_zoom = zoom_after
			_do_zoom(camera, zoom_after, new_zoom)
	else:
		_consecutive_stalls = 0
		_zoom_before = zoom_after


func _on_input(event) -> void:
	if _destroyed:
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return
	if not event.control:
		return
	if ui_util != null and ui_util.is_mouse_over_ui(input_listener):
		return

	var camera = _g.Camera
	if camera == null or not is_instance_valid(camera):
		return

	var dir = -1 if event.button_index == BUTTON_WHEEL_UP else 1

	if dir != _scroll_dir:
		_scroll_dir = dir
		_consecutive_stalls = 0
		if not _extended:
			_zoom_before = camera.zoom.x
			return

	if not _extended:
		if not _scroll_pending:
			_zoom_before = camera.zoom.x
	_scroll_pending = true

	if _extended:
		_cache_mouse_for_zoom(camera)
		input_listener.get_tree().set_input_as_handled()


var _cached_mouse_screen := Vector2.ZERO
var _cached_vp_size      := Vector2.ZERO


func _cache_mouse_for_zoom(camera: Camera2D) -> void:
	# Only cache mouse + viewport. Camera position MUST stay live in _do_zoom
	# otherwise a stale value teleports the camera back to a previous spot.
	var viewport = camera.get_viewport()
	if viewport:
		_cached_mouse_screen = viewport.get_mouse_position()
		_cached_vp_size = viewport.size


func _invalidate_zoom_cache() -> void:
	_cached_mouse_screen = Vector2.ZERO
	_cached_vp_size = Vector2.ZERO


func _do_zoom(camera: Camera2D, from_zoom: float, to_zoom: float) -> void:
	var viewport = camera.get_viewport()
	if viewport:
		var mouse_screen : Vector2
		var vp_size : Vector2
		if _cached_vp_size.length() > 0:
			mouse_screen = _cached_mouse_screen
			vp_size = _cached_vp_size
		else:
			mouse_screen = viewport.get_mouse_position()
			vp_size = viewport.size
		var offset = mouse_screen - vp_size * 0.5
		# Always live — caching this is what caused the teleport bug.
		var cam_pos = camera.global_position
		var world_pt = cam_pos + offset * from_zoom
		camera.call("SetRawZoom", to_zoom)
		camera.global_position = world_pt - offset * to_zoom
	else:
		camera.call("SetRawZoom", to_zoom)

	_extended = true
	_extended_zoom = to_zoom
	_zoom_before = to_zoom
	_force_dropdown_text(to_zoom)
	_cached_vp_size = Vector2.ZERO


func _zoom_to_label(raw_zoom: float) -> String:
	# pct = (_cam_ratio / raw) * 100
	# raw small (0.5) -> big % (800%) = zoomed in
	# raw big (40) -> small % (10%) = zoomed out
	var pct = (_cam_ratio / raw_zoom) * 100.0 if raw_zoom > 0.0001 else 99999.0
	if pct >= 10.0:
		return "%d%%" % int(round(pct))
	elif pct >= 1.0:
		return "%.1f%%" % pct
	else:
		return "%.2f%%" % pct


func _force_dropdown_text(raw_zoom: float) -> void:
	if _zoom_options == null or not is_instance_valid(_zoom_options):
		return
	var label = _zoom_to_label(raw_zoom)
	_zoom_options.text = label
	var idx = _zoom_options.selected
	if idx >= 0 and idx < _zoom_options.get_item_count():
		_zoom_options.set_item_text(idx, label)
	var font = _zoom_options.get_font("font")
	if font:
		var needed = font.get_string_size(label + "  ").x + 28
		if needed > _zoom_options.rect_min_size.x:
			_zoom_options.rect_min_size.x = needed


func _restore_dropdown_width() -> void:
	if _orig_min_size_x >= 0 and _zoom_options != null and is_instance_valid(_zoom_options):
		_zoom_options.rect_min_size.x = _orig_min_size_x


func _restore_dropdown_item_texts() -> void:
	# _force_dropdown_text rewrites the selected item's label so it shows in
	# the button. Without restore, that label persists in the popup forever
	# after the first extension and the user sees wrong values for that item.
	if _zoom_options == null or not is_instance_valid(_zoom_options):
		return
	if _orig_item_texts.empty():
		return
	var n = min(_orig_item_texts.size(), _zoom_options.get_item_count())
	for i in range(n):
		_zoom_options.set_item_text(i, _orig_item_texts[i])
