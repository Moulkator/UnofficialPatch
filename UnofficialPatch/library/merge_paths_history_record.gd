extends Reference

# Custom History Record for Split Path actions
var type = "MergePaths"
var history_data = {}
var main_script = null

# Logging Functions
const ENABLE_LOGGING = true
const LOGGING_LEVEL = 0

func outputlog(msg,level=0):
	if ENABLE_LOGGING:
		if level <= LOGGING_LEVEL:
			printraw("(%d) <MergePathsHistory>: " % OS.get_ticks_msec())
			print(msg)
	else:
		pass

func undo():

	outputlog("undo",3)
	if main_script != null && history_data["level"] != null:
		main_script.update_path_to_new_global_points(history_data["merge_list"][0], history_data["save_path_1_points"])
		history_data["merge_list"][1] = history_data["level"].Pathways.LoadPathway(history_data["save_path_2"])

func redo():
	
	outputlog("redo",3)
	if main_script != null:
		main_script.merge_paths(history_data["merge_list"])