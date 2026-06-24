# drop_fix.gd
# v15: Track the *current* level's Objects node, not the first level we find.
#      On multi-level maps, the prop is added to the active level — picking
#      the wrong one means we never see the count change and we time out.

var _g

var _known_obj_count = 0
var _map_ready = false
var _startup_frames = 0
var _last_objects_id = -1
var _last_world_id = -1

var _correct_world_pos = Vector2.ZERO
var _waiting_for_new = false
var _wait_frames = 0

# Multi-drop tracking
var _drop_count = 0
var _fixed_count = 0


func initialize():
	var tree = null
	if _g.World and is_instance_valid(_g.World) and _g.World.is_inside_tree():
		tree = _g.World.get_tree()
	elif _g.Editor and is_instance_valid(_g.Editor):
		tree = _g.Editor.get_tree()
	
	if tree and not tree.is_connected("files_dropped", self, "_on_files_dropped"):
		tree.connect("files_dropped", self, "_on_files_dropped")


func _on_files_dropped(files: PoolStringArray, _screen: int):
	# Guard: ignore signals if our World ref is stale (e.g. old instance
	# left over after Reload Mods). Without this, the dead instance also
	# processes the drop and the logs become very noisy.
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	
	var img_count = 0
	for i in range(files.size()):
		var ext = files[i].get_extension().to_lower()
		if ext == "webp" or ext == "png" or ext == "jpg" or ext == "jpeg":
			img_count += 1
	
	if img_count == 0:
		return
	
	_waiting_for_new = true
	_wait_frames = 0
	_drop_count = img_count
	_fixed_count = 0
	
	# Capture mouse position
	_correct_world_pos = Vector2.ZERO
	var screen_pos = Vector2.ZERO
	if _g.World is CanvasItem:
		var viewport = _g.World.get_viewport()
		if viewport:
			screen_pos = viewport.get_mouse_position()
			var ct = _g.World.get_canvas_transform()
			_correct_world_pos = ct.affine_inverse().xform(screen_pos)
	
	# IMPORTANT: on some maps the engine places the prop *before* this
	# signal fires (texture-load latency, etc.). In that case live count
	# is already > known. Fix those props now instead of waiting for the
	# next update() — by then known may have been bumped without a fix.
	var objects = _find_objects_node()
	if objects and objects.get_child_count() > _known_obj_count:
		_fix_new_objects(objects)


func _find_objects_node():
	if not _g.World or not is_instance_valid(_g.World):
		return null
	if not _g.World.is_inside_tree():
		return null
	# Preferred: ask the World for the current level. On multi-level maps,
	# only this level receives the dropped prop.
	var level = _g.World.get("Level")
	if level == null and _g.World.has_method("GetCurrentLevel"):
		level = _g.World.GetCurrentLevel()
	if level and is_instance_valid(level) and level.has_node("Objects"):
		var obj_node = level.get_node("Objects")
		if is_instance_valid(obj_node):
			return obj_node
	# Fallback: scan World children (single-level maps, or if Level is null)
	var count = _g.World.get_child_count()
	for i in range(count):
		var child = _g.World.get_child(i)
		if not is_instance_valid(child):
			continue
		if child.has_node("Objects"):
			var obj_node = child.get_node("Objects")
			if is_instance_valid(obj_node):
				return obj_node
	return null


func update(_delta):
	if not _g.World or not is_instance_valid(_g.World):
		_reset_state()
		return
	if not _g.World.is_inside_tree():
		_reset_state()
		return
	
	var world_id = _g.World.get_instance_id()
	if world_id != _last_world_id:
		_last_world_id = world_id
		_reset_tracking()
		return
	
	if not _map_ready:
		_startup_frames += 1
		if _startup_frames > 60:
			_map_ready = true
			_startup_frames = 0
			var objects = _find_objects_node()
			if objects:
				_last_objects_id = objects.get_instance_id()
				_known_obj_count = objects.get_child_count()
		return
	
	var objects = _find_objects_node()
	if objects == null:
		return
	
	var obj_id = objects.get_instance_id()
	if obj_id != _last_objects_id:
		_last_objects_id = obj_id
		_known_obj_count = objects.get_child_count()
		if _waiting_for_new:
			_fix_new_objects(objects)
		return
	
	var current_count = objects.get_child_count()
	if current_count > _known_obj_count and _waiting_for_new:
		_fix_new_objects(objects)
	_known_obj_count = current_count
	
	if _waiting_for_new:
		_wait_frames += 1
		if _wait_frames > 120:
			_waiting_for_new = false


func _fix_new_objects(objects):
	var current_count = objects.get_child_count()
	var new_count = current_count - _known_obj_count
	if new_count <= 0:
		return
	
	for i in range(new_count):
		var idx = _known_obj_count + i
		if idx >= current_count:
			break
		var child = objects.get_child(idx)
		if not is_instance_valid(child) or not (child is Node2D):
			continue
		
		var offset = _get_grid_offset(_fixed_count, _drop_count)
		_apply_fix(child, offset)
		_fixed_count += 1
	
	_known_obj_count = current_count
	
	if _fixed_count >= _drop_count:
		_waiting_for_new = false


func _apply_fix(child: Node2D, offset: Vector2):
	var old_pos = child.position
	var dd_snapped = (int(old_pos.x) % 256 == 0) and (int(old_pos.y) % 256 == 0)
	
	var center = _correct_world_pos + offset
	var target_pos
	if dd_snapped:
		target_pos = Vector2(stepify(center.x, 256), stepify(center.y, 256))
	else:
		target_pos = center
	
	if old_pos != target_pos:
		child.position = target_pos
	
	# Force shadow OFF
	if child.get_child_count() >= 1:
		var shadow = child.get_child(0)
		if is_instance_valid(shadow) and shadow is Sprite:
			if shadow.visible:
				shadow.visible = false
	if child.has_method("UpdateShadow"):
		child.call("UpdateShadow")


func _get_grid_offset(index: int, total: int) -> Vector2:
	if total <= 1:
		return Vector2.ZERO
	var spacing = 512
	var cols = int(ceil(sqrt(float(total))))
	var row = index / cols
	var col = index % cols
	var total_rows = int(ceil(float(total) / cols))
	var x_off = (col - (cols - 1) / 2.0) * spacing
	var y_off = (row - (total_rows - 1) / 2.0) * spacing
	return Vector2(x_off, y_off)


func _reset_state():
	_map_ready = false
	_startup_frames = 0
	_last_world_id = -1
	_reset_tracking()


func _reset_tracking():
	_map_ready = false
	_startup_frames = 0
	_known_obj_count = 0
	_last_objects_id = -1
	_waiting_for_new = false
	_drop_count = 0
	_fixed_count = 0
