# Mod to test lib functions
var script_class = "tool"

var backspace_split_action = "backspace_split_action"
var last_vertices_size = 0
var store_vertices_size = 0
var frame_count = 0
const MIN_FRAME = 12
# Max distance (world px) between the cursor and the path centre line
const MAX_SPLIT_DISTANCE = 60.0
# Frames to wait after the key press before splitting. If the vertex count
# changed meanwhile, Dungeondraft deleted a vertex and the split is cancelled.
const SPLIT_DELAY_FRAMES = 2
var _pending_frames = 0
var _pending_size = 0
var _pending_mouse = Vector2.ZERO
const COMBINED_DATA_STORE = "UchideshiNodeData"

# Logging Functions
const ENABLE_LOGGING = true
const LOGGING_LEVEL = 2

#########################################################################################################
##
## UTILITY FUNCTIONS
##
#########################################################################################################

func outputlog(msg,level=0):
	if ENABLE_LOGGING:
		if level <= LOGGING_LEVEL:
			printraw("(%d) <SplitPath>: " % OS.get_ticks_msec())
			print(msg)
	else:
		pass

#########################################################################################################
##
## SPLIT PATH FUNCTIONS
##
#########################################################################################################

# Function to find the split index: the index of the edit point that starts
# the segment under the cursor. Returns -1 when the cursor is too far.
func _find_split_index(pathway, mouseposition):

	outputlog("_find_split_index",2)

	if mouseposition == null:
		return -1

	var pts = pathway.GlobalEditPoints
	var num = pts.size()
	if num < 2:
		return -1

	# Accept anything on the visible width of the path, with a minimum margin
	var max_distance = max(MAX_SPLIT_DISTANCE, pathway.width * 0.5 * abs(pathway.scale.x))

	# First try the rendered (smoothed) curve, which is what the user sees
	var result = _find_segment_on_curve(pathway, pts, mouseposition)
	# Otherwise fall back on the straight segments between the edit points
	if result == null:
		result = _find_segment_on_chords(pathway, pts, mouseposition)

	outputlog("split_index: " + str(result[0]) + " smallest_distance: " + str(result[1]))

	if result[0] < 0 || result[1] > max_distance:
		return -1
	return result[0]

# Nearest segment measured on the straight lines between the edit points,
# including the closing segment of a loop. Returns [index, distance].
func _find_segment_on_chords(pathway, pts, mouseposition) -> Array:

	var num = pts.size()
	var edges = num if pathway.Loop else num - 1
	var best_index = -1
	var best_distance = INF

	for _i in edges:
		var closest = Geometry.get_closest_point_to_segment_2d(mouseposition, pts[_i], pts[(_i + 1) % num])
		var distance = closest.distance_to(mouseposition)
		if distance < best_distance:
			best_distance = distance
			best_index = _i

	return [best_index, best_distance]

# Nearest segment measured on the rendered curve. Each rendered point is
# attributed to an edit segment by walking the curve and advancing whenever
# it passes through the next edit point. Returns [index, distance], or null
# if the rendered points can not be matched to the edit points.
func _find_segment_on_curve(pathway, pts, mouseposition):

	var curve = pathway.points
	var num = pts.size()
	if curve.size() < 2:
		return null

	var xform = pathway.global_transform
	var previous = xform.xform(curve[0])
	if previous.distance_to(pts[0]) > 1.0:
		return null

	var edit_index = 0
	var best_index = -1
	var best_distance = INF

	for _k in range(1, curve.size()):
		var current = xform.xform(curve[_k])
		var distance = Geometry.get_closest_point_to_segment_2d(mouseposition, previous, current).distance_to(mouseposition)
		if distance < best_distance:
			best_distance = distance
			best_index = edit_index
		if edit_index + 1 < num && current.distance_to(pts[edit_index + 1]) <= 1.0:
			edit_index += 1
		previous = current

	# Every edit point must have been met, otherwise the mapping is unreliable
	if edit_index != num - 1:
		return null
	# An open path has no segment starting at its last point
	if best_index > num - 2 && not pathway.Loop:
		best_index = num - 2

	return [best_index, best_distance]

# Function to split a path into two
func _split_path(pathway, mouseposition, history_record):

	outputlog("_split_path: " + str(pathway),2)
	outputlog("mouseposition: " + str(mouseposition),2)

	# Error check
	if pathway == null:
		return

	var num = pathway.GlobalEditPoints.size()
	var path_dictionary
	var old_path_points = []
	var new_pathway = null
	var store_previous_path_points = []
	var split_index

	# If there are only two vertices then do nothing
	if pathway.GlobalEditPoints.size() < 3:
		return

	# If we are redoing a custom record then we know the split index otherwise we need to find it
	if history_record == null:
		split_index = _find_split_index(pathway, mouseposition)
	else:
		split_index = history_record.split_index
	
	# If we have found a valid split point then according to the latest value
	# Also validate that the pathway size is the same as it was a few frames ago which avoids the problem with deleting vertices
	if split_index > -1 && split_index < pathway.GlobalEditPoints.size() && (history_record != null || last_vertices_size == pathway.GlobalEditPoints.size()):
		# Store the existing path edit points for the history record.
		# Force a deep copy into a plain Array to freeze the snapshot — the
		# record's undo() rebuilds a PoolVector2Array from this on demand.
		store_previous_path_points = []
		for p in pathway.GlobalEditPoints:
			store_previous_path_points.append(p)
		
		# Get the dictionary of the current pathway
		path_dictionary = pathway.Save(true)
		# If the path is a loop, then we are simply breaking the loop
		if pathway.Loop:
			# Set the new path loop status to false
			pathway.Loop = false
			# Shuffle the path vertices to start at split_index + 1
			for _i in num:
				old_path_points.append(pathway.GlobalEditPoints[(_i + 1 + split_index) % num])
			# Update the simplified way
			simplified_path_set_global_points(pathway, old_path_points)
			
		# For non-looping paths
		else:
			# Check if the split is actually on the first or last edge, in which case, just delete the first or last vertex
			if split_index == 0 || split_index >= num - 2:
				# Copy the edit points
				for _i in num:
					old_path_points.append(pathway.GlobalEditPoints[_i])
				# Remove the relevant vertex
				if split_index == 0:
					old_path_points.remove(0)
				else:
					old_path_points.remove(num - 1)
				# Set the new edit points
				simplified_path_set_global_points(pathway, old_path_points)
			else:
				# Split the path in two 
				new_pathway = split_path_in_two(pathway, split_index)

		create_update_custom_history(pathway, new_pathway, store_previous_path_points, split_index, path_dictionary["loop"], history_record)

# Function to split a path in two
func split_path_in_two(pathway: Node2D, split_index: int):

	outputlog("split_path_in_two",2)

	var old_path_points = []
	var new_path_points = []
	var total_points = pathway.GlobalEditPoints.size()

	# For each point in the Edit points list, allocate them to old or new paths
	for _i in total_points:
		# Check whether this the original
		if _i <= split_index:
			old_path_points.append(pathway.GlobalEditPoints[_i])
		# Or the new path
		else:
			new_path_points.append(pathway.GlobalEditPoints[_i])

	# Calculate length ratio for transition scaling
	var old_length = _calc_polyline_length(old_path_points)
	var new_length = _calc_polyline_length(new_path_points)
	var total_length = old_length + new_length
	var new_ratio = new_length / total_length if total_length > 0.0 else 0.5
	var old_ratio = old_length / total_length if total_length > 0.0 else 0.5

	# Make a new pathway with scaled transitions
	var new_pathway = make_new_pathway(new_path_points, pathway, pathway.get_index(), new_ratio)

	# Set the old pathway with the old path points
	simplified_path_set_global_points(pathway, old_path_points)
	
	return new_pathway

# Calculate total length of a polyline
func _calc_polyline_length(points: Array) -> float:
	var length = 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	return length

# Scale the transitions of a path by a ratio
func _scale_path_transitions(pathway, ratio: float):
	var path_dict = pathway.Save(false)
	var fade_in_val = path_dict.get("fade_in", 0.0)
	var fade_out_val = path_dict.get("fade_out", 0.0)
	var grow_val = path_dict.get("grow", 0.0)
	var shrink_val = path_dict.get("shrink", 0.0)
	if fade_in_val > 0.0:
		pathway.FadeIn = fade_in_val * ratio
	if fade_out_val > 0.0:
		pathway.FadeOut = fade_out_val * ratio
	if grow_val > 0.0:
		pathway.Grow = grow_val * ratio
	if shrink_val > 0.0:
		pathway.Shrink = shrink_val * ratio

# Take pathway and update its global points, removing rotation, scale & mirror.
func simplified_path_set_global_points(pathway: Line2D, points):

	# Set the old pathway with the old path points
	if (!pathway.scale.x < 0) != (!pathway.scale.y < 0):
		points.invert()
	pathway.SetEditPoints(points)
	pathway.rotation = 0.0
	pathway.SetWidthScale(float(pathway.Width) / pathway.get_texture().get_height() * abs(pathway.scale.x))
	pathway.scale = Vector2(1.0,1.0)

# Function to make a new path based on a list of points, a definition and an index of location
func make_new_pathway(points: Array, pathway: Node2D, index: int, length_ratio: float = 1.0):

	outputlog("make_new_pathway",2)

	var path_dictionary = pathway.Save(false)

	# Scale transitions proportionally to the new path's share of the original length
	var scaled_fade_in = path_dictionary["fade_in"] * length_ratio
	var scaled_fade_out = path_dictionary["fade_out"] * length_ratio
	var scaled_grow = path_dictionary["grow"] * length_ratio
	var scaled_shrink = path_dictionary["shrink"] * length_ratio

	print("<SplitPath> Original transitions: fade_in=" + str(path_dictionary["fade_in"]) + " fade_out=" + str(path_dictionary["fade_out"]) + " grow=" + str(path_dictionary["grow"]) + " shrink=" + str(path_dictionary["shrink"]))
	print("<SplitPath> length_ratio=" + str(length_ratio) + " scaled: fade_in=" + str(scaled_fade_in) + " fade_out=" + str(scaled_fade_out) + " grow=" + str(scaled_grow) + " shrink=" + str(scaled_shrink))

	# Make a new pathway with scaled transition parameters
	var new_pathway = Global.World.GetCurrentLevel().Pathways.CreatePath(pathway.get_texture(), path_dictionary["layer"], 1, scaled_fade_in, scaled_fade_out, scaled_grow, scaled_shrink)
	Global.World.AssignNodeID(new_pathway)
	new_pathway.set_meta("preview", false)
	# Load the same data as the old pathway
	new_pathway.SetBlockLight(pathway.BlockLight)
	new_pathway.SetWidthScale(float(pathway.Width) / pathway.get_texture().get_height() * abs(pathway.scale.x))
	# Preserve the smoothness setting from the original path
	new_pathway.Smoothness = pathway.Smoothness

	# If the original pathway was mirrored the replicate this by inverting the points and drawing the other way
	if (!pathway.scale.x < 0) != (!pathway.scale.y < 0):
		points.invert()
	
	new_pathway.SetEditPoints(points)
	new_pathway.Smooth()
	# Move the new path to the 
	Global.World.GetCurrentLevel().Pathways.move_child(new_pathway, index + 1)

	# If _lib is installed and there is custom data for the original path
	if has_data(pathway.get_meta("node_id")) && Engine.has_signal("_lib_register_mod"):
		# Set the custom data noting we are skipping all the error checking as has_data has that covered
		Global.ModMapData[COMBINED_DATA_STORE]["data"]["node-id-"+str(new_pathway.get_meta("node_id"))] = get_data(pathway.get_meta("node_id")).duplicate(true)
		if Global.get("API") != null and Global.API.get("ModSignalingApi") != null:
			Global.API.ModSignalingApi.emit_signal("refresh_node_combined_shader", new_pathway)

	return new_pathway
		
# Function to return the pathway node by matching against the Vertices record
func find_pathway_from_vertices():

	outputlog("find_pathway_from_vertices",2)

	# Error check
	if Global.WorldUI.Vertices == null:
		return null

	# Set up a candidate list
	var list = Global.World.GetCurrentLevel().Pathways.get_children()
	var _j: int

	# Check each vertex in turn as they may be multple paths with the same starting vertices. assume this more efficient than matching the entire array
	for _i in Global.WorldUI.Vertices.size():
		_j = 0
		# Check the remaining list
		while _j < list.size():
			# If the list path does not matches the relevant point
			if list[_j].GlobalEditPoints[_i] != Global.WorldUI.Vertices[_i]:
				# remove that path from the candidate list
				list.remove(_j)
			else:
				# Otherwise go to the next path
				_j += 1
		# If there is only one path the choose that one. Noting that it is possible for multiple identical paths to exist in which case this algorithm would fail
		if list.size() == 1:
			outputlog("found pathway")
			return list[0]
		# If somehow we have eliminated all of the them then return null (and do nothing)
		elif list.size() == 0:
			return null
	
	return null

# Record class loaded once, lazily, on first split.
var _CustomHistoryRecordScript = null


func _load_record_script() -> void:
	if _CustomHistoryRecordScript != null:
		return
	# Script.InstanceReference() only resolves DD's built-in library files;
	# our own library/ files need the ResourceLoader path.
	_CustomHistoryRecordScript = ResourceLoader.load(
		Global.Root + "library/custom_history_record.gd", "GDScript", true)
	if _CustomHistoryRecordScript == null:
		outputlog("library/custom_history_record.gd could not be loaded; undo disabled", 0)


# Create custom history record for a split path event
func create_update_custom_history(old_path, new_path, old_editpoints: Array, split_index: int, wasloop: bool, history_record):
	var record_script
	outputlog("create_custom_history",2)
	# Create a new record if one is needed or simply update the existing one
	if history_record == null:
		_load_record_script()
		if _CustomHistoryRecordScript == null:
			return
		record_script = _CustomHistoryRecordScript.new()
	else:
		record_script = history_record

	# If this is null for any reason then return to avoid a crash
	if record_script == null:
		return

	record_script.old_path_node_id = old_path.get_meta("node_id")
	if new_path != null:
		record_script.new_path_node_id = new_path.get_meta("node_id")
	record_script.old_path_editpoints = old_editpoints
	record_script.wasloop = wasloop
	record_script.split_index = split_index
	record_script.main_script = self
	# Pass direct node references alongside the legacy node_ids; the record
	# uses the refs internally and ignores the ids.
	if record_script.has_method("set_paths"):
		record_script.set_paths(old_path, new_path)

	# If this is a new action then create a new custom record
	if history_record == null:
		var record = Global.Editor.History.CreateCustomRecord(record_script)	

#########################################################################################################
##
## COMBINED SHADER FUNCTIONS
##
#########################################################################################################

# Function to check if there is a data entry with this node id
func has_data(node_id) -> bool:

	outputlog("has_data: " + str(node_id),3)

	# Error checking if the holding structures have not been created.
	if not Global.ModMapData.has(COMBINED_DATA_STORE):
		outputlog("no COMBINED_DATA_STORE",3)
		return false
	if not Global.ModMapData[COMBINED_DATA_STORE].has("data"):
		outputlog("no COMBINED_DATA_STORE['data']",3)
		return false

	if Global.ModMapData[COMBINED_DATA_STORE]["data"].has("node-id-"+str(node_id)):
		outputlog("has_data: true",3)
		return true
	else:
		return false

# Function to get the colour data from the modmapdata structure
func get_data(node_id):

	if has_data(node_id):
		return Global.ModMapData[COMBINED_DATA_STORE]["data"]["node-id-"+str(node_id)]
	else:
		return null


#########################################################################################################
##
## UPDATE FUNCTIONS
##
#########################################################################################################

# True when a text field has the keyboard focus, so the shortcut must be ignored
func _text_has_focus() -> bool:
	var focus = Global.Editor.Tools["PathTool"].get_EditPoints().get_focus_owner()
	return focus is LineEdit || focus is TextEdit

# True when the path tool is editing the points of a path
func _is_editing_path() -> bool:
	if Global.Editor.ActiveToolName != "PathTool":
		return false
	if not Global.Editor.Tools["PathTool"].get_EditPoints().pressed:
		return false
	return Global.WorldUI.Vertices != null

# this method is automatically called every frame. delta is a float in seconds. can be removed from script.
func update(delta: float):

	if not _is_editing_path():
		_pending_frames = 0
		return

	var vertices_size = Global.WorldUI.Vertices.size()

	# If the vertices size is not the same as the stored version
	if vertices_size != store_vertices_size:
		store_vertices_size = vertices_size
		frame_count = 0
	else:
		frame_count += 1

	# If the frame count has reached a certain value then write the store_vertices into the last_vertices_size value
	if frame_count > MIN_FRAME && last_vertices_size != store_vertices_size:
		outputlog("writing new last vertices value: " + str(store_vertices_size))
		last_vertices_size = store_vertices_size

	# A split is waiting: run it unless Dungeondraft deleted a vertex meanwhile
	if _pending_frames > 0:
		_pending_frames -= 1
		if vertices_size != _pending_size:
			outputlog("vertex deleted, split cancelled")
			_pending_frames = 0
		elif _pending_frames == 0:
			# Split the path, finding the path using the vertices which is inefficient
			_split_path(find_pathway_from_vertices(), _pending_mouse, null)
		return

	# Check for a key press of backspace / delete
	if Input.is_action_just_pressed(backspace_split_action) && not _text_has_focus():
		if vertices_size == last_vertices_size:
			_pending_mouse = Global.WorldUI.MousePosition
			_pending_size = vertices_size
			_pending_frames = SPLIT_DELAY_FRAMES

#########################################################################################################
##
## MAIN FUNCTION
##
#########################################################################################################


# Main Script
func start() -> void:

	outputlog("SplitPath Mod Has been loaded.")

	# Make an input event key for backspace
	var event = InputEventKey.new()
	event.scancode = KEY_BACKSPACE
	event.pressed = true

	# Make an input event key for backspace
	var event_delete = InputEventKey.new()
	event_delete.scancode = KEY_DELETE
	event_delete.pressed = true

	# Check if the action has been registered, noting that this happens on reloads
	if not InputMap.has_action(backspace_split_action):
		# Add the action
		InputMap.add_action(backspace_split_action)
	else:
		# Remove any events from that action
		InputMap.action_erase_events(backspace_split_action)
	
	# Add the backspace event to the action
	InputMap.action_add_event(backspace_split_action, event)
	# Add the backspace event to the action
	InputMap.action_add_event(backspace_split_action, event_delete)


