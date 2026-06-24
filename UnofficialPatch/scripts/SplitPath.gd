# Mod to test lib functions
var script_class = "tool"

var backspace_split_action = "backspace_split_action"
var last_vertices_size = 0
var store_vertices_size = 0
var frame_count = 0
const MIN_FRAME = 12
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

# Function to find the split index
func _find_split_index(pathway, mouseposition):

	outputlog("_find_split_index",2)

	# Check if the mouseposition is null
	if mouseposition == null:
		return -1

	var smallest_distance = 9999.0
	var distance = 99999.0
	var split_index = -1
	var projected_loc: Vector2
	var num = pathway.GlobalEditPoints.size()
	var relative_edge: Vector2
	var projection_onto_edge: Vector2
	var minimum_distance_from_mouseposition = 50
	var minimum_distance_from_edge = 20

	# For each point on the path, look for the vertex before the split point
	for _i in num-1:
		# Project the mouse position onto the edge between this vertex and the next one, this should be the yellow dot when the distance is the smallest

		# Find the vector describing edge between this vertex and the next vertex
		relative_edge = pathway.GlobalEditPoints[(_i + 1) % num] - pathway.GlobalEditPoints[_i]

		# Find the projection of the mouseposition onto that vector relative to this vertex
		projection_onto_edge = (mouseposition - pathway.GlobalEditPoints[_i]).project(relative_edge)
		# Find the projection in world space, ie by adding back the current vertex vector
		projected_loc = projection_onto_edge + pathway.GlobalEditPoints[_i]
		# Find the distance between the projected point and the actual mouse position, note this is the distance that the mouse point is away from extended edge between the vertices
		distance = (projected_loc - mouseposition).length()

		# Check whether the projection is actually on the line between this vertex and the next one. Note we are checking the length and whether the angle is 0 or PI.
		if projection_onto_edge.length() <=  relative_edge.length() && abs(projection_onto_edge.angle_to(relative_edge)) < 0.01:
			
			# Check whether the distance is the smallest one, noting it is a combination of the projection and the distance that gives us the right value
			if distance < smallest_distance:
				# Update the smallest distance and the split_index reference
				smallest_distance = distance
				split_index = _i
	
	outputlog("split_index: " + str(split_index) + " smallest_distance: " + str(smallest_distance))
	# If split_index is -1 (which it should never be) or if the distance is greater than 20 pixels.
	# Note this condition exists because the backspace action also deletes a vertex and the mod can not determine this as the vertex is gone at the time of execution
	if split_index < 0 || smallest_distance > 60:
		return -1

	if pathway.GlobalEditPoints[split_index].distance_to(mouseposition) > minimum_distance_from_mouseposition:
		if pathway.GlobalEditPoints[(split_index + 1) % num].distance_to(mouseposition) > minimum_distance_from_mouseposition:
			return split_index
	return -1

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
	if split_index > -1 && split_index < pathway.GlobalEditPoints.size() && last_vertices_size == pathway.GlobalEditPoints.size():
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
			if split_index == 0 || split_index == num - 1:
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

# this method is automatically called every frame. delta is a float in seconds. can be removed from script.
func update(delta: float):

	# If we are in the path tool
	if Global.Editor.ActiveToolName == "PathTool":
		# If EditPoints is active
		if Global.Editor.Tools["PathTool"].get_EditPoints().pressed:
			# If we are editing a path
			if Global.WorldUI.Vertices != null:
				# If the vertices size is not the same as the stored version
				if Global.WorldUI.Vertices.size() != store_vertices_size:
					# Set the store value to current vertices size
					store_vertices_size = Global.WorldUI.Vertices.size()
					frame_count = 0
				else:
					# Increment frame count
					frame_count += 1
				
				# If the frame count has reached a certain value then write the store_vertices into the last_vertices_size value
				if frame_count > MIN_FRAME && last_vertices_size != store_vertices_size:
					outputlog("writing new last vertices value: " + str(store_vertices_size))
					# Write it into the last vertices size
					last_vertices_size = store_vertices_size
					
				# Check for a key press of backspace, noting just pressed is a bit quirky
				if Input.is_action_just_pressed(backspace_split_action):

					# Split the path, finding the path using the vertices which is inefficient
					_split_path(find_pathway_from_vertices(), Global.WorldUI.MousePosition, null)

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


