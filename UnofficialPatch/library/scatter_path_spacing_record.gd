extends Reference

# scatter_path_spacing_record.gd
# One-per-stroke history record for scatter_path_spacing.gd, handed to DD's
# History.CreateCustomRecord(). Mirrors the interface of the other library
# records (callback/points/merge_paths): lowercase undo()/redo(), a
# main_script reference, and state fields filled by the caller.
#
# Undo frees the props via World.DeleteNodeByID (vanilla ObjectRecord's
# path); redo recreates them via CreateObject + Prop.Load(data), i.e.
# LoadObject minus Master.AddObjectCount(+1), which exactly compensates the
# -1 that is unreachable on undo (see the main script's header). The record
# therefore holds no node references — only ids and Save() dictionaries —
# and needs no PREDELETE cleanup.

var main_script = null
var level_id := 0
# Array of {id, data, under, child_index} dictionaries ("prop" is present
# transiently during the stroke, unused here).
var entries: Array = []


func undo() -> void:
	if main_script != null and main_script.has_method("_record_undo"):
		main_script._record_undo(self)


func redo() -> void:
	if main_script != null and main_script.has_method("_record_redo"):
		main_script._record_redo(self)
