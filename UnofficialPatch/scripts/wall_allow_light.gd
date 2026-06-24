# WallBlockLight.gd
# Toggle BlockLight on walls via SelectTool, WallTool, FloorShapeTool

var _g

var _select_tool = null
var _select_panel = null
var _select_bl_button = null

var _wall_tool = null
var _wall_bl_button = null
var _floor_tool = null
var _floor_bl_button = null
var _next_wall_allow_light = false  # Mode: next walls created will allow light
var _known_wall_ids = {}  # instance_id -> true, to detect new walls

var _timer = null
var _light_blocked = {}  # fingerprint (string) -> true (means "allow light")
var _user_toggling = false

const CHECK_INTERVAL = 0.15
const FAST_CHECK_INTERVAL = 0.03  # Faster polling when allow light mode is on
const SAVE_PATH = "user://UnofficialPatch/fixwallbug_blocklight.json"


# Equivalent to SelectTool.Selectables but hand-rolled from RawSelectables.
# The C# property Selectables calls ToDictionary() internally, which throws
# ArgumentException ("same key") if RawSelectables contains two entries
# pointing at the same Thing — a state DD can leave us in after certain
# undo/redo sequences. Walking RawSelectables ourselves and dedupping is
# safe in that case. Same workaround exists in light_fix.gd.
func _get_selectables_safe() -> Dictionary:
	var result: Dictionary = {}
	if _select_tool == null:
		return result
	var raw = _select_tool.get("RawSelectables")
	if raw == null:
		return result
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if result.has(thing):
			continue
		var type = -1
		if _select_tool.has_method("GetSelectableType"):
			type = _select_tool.call("GetSelectableType", thing)
		result[thing] = type
	return result


func initialize():
	
	# Wall Tool
	_wall_tool = _g.Editor.Tools["WallTool"]
	var wall_ep = _wall_tool.get("EditPoints")
	if wall_ep != null:
		_wall_bl_button = _create_tool_bl_button(wall_ep, "_on_bl_toggled_tool")
	
	# Floor Shape Tool
	_floor_tool = _g.Editor.Tools["FloorShapeTool"]
	var floor_ep = _floor_tool.get("EditPoints")
	if floor_ep != null:
		_floor_bl_button = _create_tool_bl_button(floor_ep, "_on_bl_toggled_tool")
	
	# Select Tool
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if _select_panel != null:
		_select_bl_button = _create_select_bl_button()
		print("[WBL] Added select button via ToolPanel")
	else:
		print("[WBL] WARNING: Could not get SelectTool panel")
	
	# Timer for polling
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	_g.Editor.add_child(_timer)
	
	# Load saved data
	_load_data()
	var apply_timer = Timer.new()
	apply_timer.wait_time = 1.0
	apply_timer.one_shot = true
	apply_timer.connect("timeout", self, "_apply_saved_data")
	_g.Editor.add_child(apply_timer)
	apply_timer.start()
	
	print("[WBL] initialized, wall_btn=" + str(_wall_bl_button != null) + " floor_btn=" + str(_floor_bl_button != null) + " select_btn=" + str(_select_bl_button != null))

func _create_tool_bl_button(ep_button, callback):
	if ep_button == null:
		return null
	var parent = ep_button.get_parent()
	if parent == null:
		return null
	var btn = CheckButton.new()
	btn.text = "Allow Light"
	btn.hint_tooltip = "When enabled, newly created walls will allow light to pass through."
	btn.pressed = false
	btn.visible = false
	btn.connect("toggled", self, callback)
	parent.add_child(btn)
	# Place after EP button
	var idx = ep_button.get_index()
	parent.move_child(btn, idx + 1)
	return btn

func _create_select_bl_button():
	if _select_panel == null:
		return null
	# On récupère le conteneur directement sans passer par CreateButton
	# (CreateButton avec icône vide "" provoque ImageLoader::load_image('') -> erreur)
	var parent = _select_panel.get("Align")
	if parent == null:
		parent = _select_panel.find_node("Align", true, false)
	if parent == null:
		return null
	var btn = CheckButton.new()
	btn.text = "Allow Light"
	btn.hint_tooltip = "When enabled, selected wall(s) allow light to pass through."
	btn.pressed = false
	btn.connect("toggled", self, "_on_bl_toggled_select")
	parent.add_child(btn)
	# Place before hidden option panels
	var final_idx = parent.get_child_count()
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		if child is VBoxContainer and not child.visible:
			final_idx = i
			break
	parent.move_child(btn, final_idx)
	return btn

func _tick():
	var active_tool = _g.Editor.ActiveToolName
	
	# Wall tool button - mode toggle
	if _wall_bl_button != null:
		_wall_bl_button.visible = (active_tool == "WallTool")
	# Floor tool button - mode toggle
	if _floor_bl_button != null:
		_floor_bl_button.visible = (active_tool == "FloorShapeTool")
	
	# Detect newly created walls and auto-apply if mode is on
	if _next_wall_allow_light and (active_tool == "WallTool" or active_tool == "FloorShapeTool"):
		_check_for_new_walls()
	
	# Select tool button: show only when wall is selected
	if active_tool == "SelectTool":
		_update_select_button()
	elif _select_bl_button != null:
		_select_bl_button.visible = false
	
	# Re-apply light masks (Set() may reset them)
	_reapply_light_masks()

func _check_for_new_walls():
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	# Collect all current wall instance IDs
	var current_ids = {}
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		current_ids[wall.get_instance_id()] = wall
	# Find new walls (IDs we haven't seen before)
	for wid in current_ids:
		if not _known_wall_ids.has(wid):
			var wall = current_ids[wid]
			var occluders = []
			_collect_occluders(wall, occluders)
			var fp = _wall_fingerprint(wall)
			print("[WBL] New wall detected id=" + str(wid) + " type=" + str(wall.Type) + " pts=" + str(wall.Points.size()) + " occluders=" + str(occluders.size()) + " fp=" + fp)
			if occluders.size() > 0:
				_set_wall_light(wall, true)
				_save_data()
				print("[WBL] Auto-applied AllowLight")
			else:
				# Occluder not yet created — don't add to known, retry next tick
				print("[WBL] No occluder yet, will retry")
				continue
		_known_wall_ids[wid] = true
	# Clean up IDs that no longer exist
	var to_remove = []
	for wid in _known_wall_ids:
		if not current_ids.has(wid):
			to_remove.append(wid)
	for wid in to_remove:
		_known_wall_ids.erase(wid)

func _on_bl_toggled_tool(pressed):
	_next_wall_allow_light = pressed
	print("[WBL] Next walls allow light mode: " + str(pressed))
	if pressed:
		_init_wall_counts()
		_timer.wait_time = FAST_CHECK_INTERVAL
	else:
		_timer.wait_time = CHECK_INTERVAL

func _init_wall_counts():
	_known_wall_ids.clear()
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		_known_wall_ids[wall.get_instance_id()] = true

func _update_select_button():
	if _select_bl_button == null or _select_tool == null:
		return
	if _user_toggling:
		return
	var selectables = _get_selectables_safe()
	if selectables == null or selectables.size() == 0:
		_select_bl_button.visible = false
		return
	# Find first wall in selection
	var first_wall = null
	for item in selectables:
		var type = selectables[item]
		if type == 1:  # Wall
			first_wall = item
			break
	_select_bl_button.visible = (first_wall != null)
	if first_wall != null:
		var fp = _wall_fingerprint(first_wall)
		var is_allow = _light_blocked.has(fp)
		if _select_bl_button.pressed != is_allow:
			_select_bl_button.disconnect("toggled", self, "_on_bl_toggled_select")
			_select_bl_button.pressed = is_allow
			_select_bl_button.connect("toggled", self, "_on_bl_toggled_select")

func _on_bl_toggled_select(pressed):
	if _select_tool == null:
		return
	_user_toggling = true
	var selectables = _get_selectables_safe()
	if selectables == null:
		_user_toggling = false
		return
	
	# Capture each affected wall's state BEFORE mutation. We key by
	# fingerprint (same identity the mod itself uses) so we can re-find
	# the walls at undo/redo time even after sessions/reselections.
	var walls: Array = []
	for item in selectables:
		if selectables[item] == 1:  # Wall
			walls.append(item)
	
	var before_states := _capture_allow_light_states(walls)
	
	var count = 0
	for wall in walls:
		_set_wall_light(wall, pressed)
		count += 1
	print("[WBL] Toggled AllowLight=" + str(pressed) + " on " + str(count) + " wall(s)")
	_save_data()
	
	var after_states := _capture_allow_light_states(walls)
	_record_allow_light_change(before_states, after_states)
	
	_user_toggling = false


func _capture_allow_light_states(walls: Array) -> Array:
	# For each wall, record its fingerprint and whether it's currently
	# in the "allow light" set. The fingerprint is what this mod already
	# uses as the wall's stable identity.
	var out: Array = []
	for wall in walls:
		if not is_instance_valid(wall):
			continue
		var fp = _wall_fingerprint(wall)
		if fp == "":
			continue
		out.append({
			"fingerprint": fp,
			"allow_light": _light_blocked.has(fp),
		})
	return out


func _record_allow_light_change(before: Array, after: Array) -> void:
	if before.empty() or after.empty() or before.size() != after.size():
		return
	# Only create a record if something actually changed.
	var changed := false
	for i in range(before.size()):
		if before[i]["allow_light"] != after[i]["allow_light"]:
			changed = true
			break
	if not changed:
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_allow_light_states", [before],
		self, "_restore_allow_light_states", [after])


func _restore_allow_light_states(states: Array) -> void:
	# Replay each captured state on undo/redo: re-find the wall by
	# fingerprint, apply the masks, and sync the mod's persistent dict.
	_user_toggling = true
	for entry in states:
		var wall = _find_wall_by_fingerprint(entry["fingerprint"])
		if wall == null:
			continue
		_set_wall_light(wall, entry["allow_light"])
	_save_data()
	_user_toggling = false


func _find_wall_by_fingerprint(fp: String):
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	var walls_node = level.Walls
	if walls_node == null:
		return null
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall) or not wall.has_method("Set"):
			continue
		if _wall_fingerprint(wall) == fp:
			return wall
	return null


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")

func _wall_fingerprint(wall):
	# Create a stable identifier based on wall geometry + texture
	var pts = wall.Points
	if pts == null or pts.size() == 0:
		return ""
	var parts = []
	for p in pts:
		parts.append(str(int(p.x)) + "," + str(int(p.y)))
	var tex = wall.get("Texture")
	var tex_path = ""
	if tex != null:
		tex_path = tex.resource_path
	return tex_path + "|" + PoolStringArray(parts).join(";")

func _set_wall_light(wall, allow):
	# allow=true -> light passes through (light_mask=0)
	# allow=false -> light blocked (light_mask=2, default)
	var occluders = []
	_collect_occluders(wall, occluders)
	var target_mask = 0 if allow else 2
	for occ in occluders:
		occ.light_mask = target_mask
	# Track by fingerprint
	var fp = _wall_fingerprint(wall)
	if fp != "":
		if allow:
			_light_blocked[fp] = true
		else:
			_light_blocked.erase(fp)
	print("[WBL]   wall fp=" + fp + " occluders=" + str(occluders.size()) + " mask=" + str(target_mask))

func _reapply_light_masks():
	if _light_blocked.empty():
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	var fixed = 0
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall):
			continue
		if not wall.has_method("Set"):
			continue
		var fp = _wall_fingerprint(wall)
		if fp == "" or not _light_blocked.has(fp):
			continue
		var occluders = []
		_collect_occluders(wall, occluders)
		for occ in occluders:
			if occ.light_mask != 0:
				occ.light_mask = 0
				fixed += 1
	if fixed > 0:
		print("[WBL] _reapply fixed " + str(fixed) + " occluder(s)")

func _collect_occluders(node, result):
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child.get_class() == "LightOccluder2D":
			result.append(child)
		if child.get_child_count() > 0:
			_collect_occluders(child, result)

func _save_data():
	var data = {}
	for fp in _light_blocked:
		data[fp] = true
	var file = File.new()
	var err = file.open(SAVE_PATH, File.WRITE)
	if err == OK:
		file.store_string(JSON.print(data))
		file.close()
		print("[WBL] Saved " + str(data.size()) + " wall(s) to " + SAVE_PATH)
	else:
		print("[WBL] ERROR saving: " + str(err))

func _load_data():
	var file = File.new()
	if not file.file_exists(SAVE_PATH):
		return
	var err = file.open(SAVE_PATH, File.READ)
	if err != OK:
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		return
	var data = parsed.result
	if data is Dictionary:
		for fp in data:
			_light_blocked[fp] = true
		print("[WBL] Loaded " + str(_light_blocked.size()) + " wall(s) from " + SAVE_PATH)

func _apply_saved_data():
	if _light_blocked.empty():
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.Walls
	if walls_node == null:
		return
	var applied = 0
	for i in range(walls_node.get_child_count()):
		var wall = walls_node.get_child(i)
		if not is_instance_valid(wall):
			continue
		if not wall.has_method("Set"):
			continue
		var fp = _wall_fingerprint(wall)
		if fp == "" or not _light_blocked.has(fp):
			continue
		var occluders = []
		_collect_occluders(wall, occluders)
		for occ in occluders:
			occ.light_mask = 0
		applied += 1
	print("[WBL] Applied saved data: " + str(applied) + "/" + str(_light_blocked.size()) + " walls found")
