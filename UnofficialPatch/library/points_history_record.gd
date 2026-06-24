# points_history_record.gd
# Generic history record for mods that mutate an editable points array on
# a Pathway, Wall, or PatternShape (path_curve_edit, wall_curve_edit,
# pattern_curve_edit, arc_draw edit mode).
#
# Design:
# * The record stores the node plus before/after snapshots of its points.
# * Writing the points back is delegated to the mod that created the
#   record, through a "_write_pts" method on main_script. Each mod
#   already has a _write_pts tailored to its node type (path uses
#   SetEditPoints, wall uses set_Points + RemakeLines, pattern uses
#   set_polygon with a local-space transform), so the record doesn't need
#   to know the node type.
#
# This mirrors the interface of library/custom_history_record.gd and
# library/merge_paths_history_record.gd: undo() / redo() methods (lowercase),
# main_script reference, state fields set by the caller before the record
# is handed to Editor.History.CreateCustomRecord().


var main_script = null
var node = null
var points_before = []
var points_after = []


func undo():
	_apply(points_before)


func redo():
	_apply(points_after)


func _apply(pts):
	if main_script == null:
		return
	if node == null or not is_instance_valid(node):
		return
	if not main_script.has_method("_write_pts"):
		return
	main_script._write_pts(node, pts)
