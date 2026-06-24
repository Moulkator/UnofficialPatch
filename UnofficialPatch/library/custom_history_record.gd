extends Reference

# Custom History Record for Split Path actions.
#
# Reworked to use direct node references via weakref (`WeakRef`) instead
# of DD's node_id system. Reason: earlier version crashed at
# `Global.World.HasNodeID()` with ids that looked like defaults (0 and 1).
# Whether those ids were valid or not, bypassing them removes one failure
# mode entirely. WeakRef prevents us from keeping freed nodes alive, and
# `get_ref()` + `is_instance_valid()` give us safe checks.
#
# Fields kept for back-compat with SplitPath.create_update_custom_history:
#   - old_path_node_id / new_path_node_id: unused by undo/redo now but
#     still set by the caller (SplitPath.gd line 329-331). Left as-is to
#     avoid having to patch SplitPath again.
#   - split_index, wasloop: used on redo.
#   - old_path_editpoints: restored to the old pathway on undo.
#   - main_script: reference to SplitPath instance, used by redo.

var old_path_node_id = -1
var old_path_editpoints = []
var split_index = -1
var wasloop = false
var new_path_node_id = -1
var main_script = null

# Direct references set by SplitPath after instancing the record.
var _old_path_ref: WeakRef = null
var _new_path_ref: WeakRef = null


func set_paths(old_path, new_path) -> void:
	if old_path != null:
		_old_path_ref = weakref(old_path)
	if new_path != null:
		_new_path_ref = weakref(new_path)


func _resolve_old() -> Node:
	if _old_path_ref == null:
		return null
	var n = _old_path_ref.get_ref()
	if n == null or not is_instance_valid(n):
		return null
	return n


func _resolve_new() -> Node:
	if _new_path_ref == null:
		return null
	var n = _new_path_ref.get_ref()
	if n == null or not is_instance_valid(n):
		return null
	return n


func undo():
	print("[CustomHistoryRecord] undo() START wasloop=", wasloop,
		" old_editpoints.size=", old_path_editpoints.size())
	
	var old_pathway = _resolve_old()
	var new_pathway = _resolve_new()
	print("[CustomHistoryRecord] old_pathway=", old_pathway, " new_pathway=", new_pathway)
	
	if old_pathway == null:
		print("[CustomHistoryRecord] old_pathway is null/freed - abort undo")
		return
	
	# Convert the stored edit points (Array of Vector2) to PoolVector2Array
	# because SetEditPoints expects Vector2[] in Godot 3 parlance.
	var pool = PoolVector2Array()
	for p in old_path_editpoints:
		pool.append(p)
	
	if wasloop:
		print("[CustomHistoryRecord] branch: wasloop, restoring Loop=true")
		old_pathway.Loop = true
		old_pathway.SetEditPoints(pool)
		print("[CustomHistoryRecord] wasloop branch done")
		return
	
	# Normal split: restore the old pathway's points, then remove the new one.
	print("[CustomHistoryRecord] branch: normal split")
	print("[CustomHistoryRecord] calling SetEditPoints with ", pool.size(), " points")
	old_pathway.SetEditPoints(pool)
	print("[CustomHistoryRecord] SetEditPoints done")
	
	if new_pathway != null:
		print("[CustomHistoryRecord] removing new_pathway from tree")
		var parent = new_pathway.get_parent()
		if parent != null:
			parent.remove_child(new_pathway)
		new_pathway.queue_free()
		_new_path_ref = null
		print("[CustomHistoryRecord] new_pathway removed")
	
	print("[CustomHistoryRecord] undo() END")


func redo():
	print("[CustomHistoryRecord] redo() START")
	var old_pathway = _resolve_old()
	if old_pathway == null:
		print("[CustomHistoryRecord] old_pathway is null/freed - abort redo")
		return
	main_script._split_path(old_pathway, Global.WorldUI.MousePosition, self)
	print("[CustomHistoryRecord] redo() END")
