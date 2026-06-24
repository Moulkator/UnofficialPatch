# terrain_undo_record.gd
# Custom history record for TerrainSquareBrush paints.
#
# Passed to Editor.History.CreateCustomRecord(). DD's C# History class
# exposes Undo / Redo / Record / Clear / CreateCustomRecord — PascalCase —
# so we assume it invokes Undo() / Redo() on this record in the same way
# the built-in library/custom_history_record.gd is called. If DD uses a
# different convention (undo/redo lowercase, on_undo/on_redo, apply/revert,
# etc.), the prints inside these methods will stay silent and we'll know
# to try another shape.
#
# Stores pre- and post-paint splat images + a reference to the Terrain.
# RestoreSplat / RestoreSplat2 are the API-documented undo-path methods —
# DD's native brush uses the same ones for its own undo.
#
# Note: no "extends Reference" — DD auto-parses every .gd in the mod folder
# and prepends boilerplate, which breaks a top-level `extends`. GDScript
# defaults to Reference anyway, so this script still behaves as a Reference.


var terrain = null
var before_splat = null
var after_splat  = null
var before_splat2 = null
var after_splat2  = null


func Undo() -> void:
	print("[TerrainUndoRecord] Undo()")
	_apply(before_splat, before_splat2)


func Redo() -> void:
	print("[TerrainUndoRecord] Redo()")
	_apply(after_splat, after_splat2)


# Also expose lowercase variants just in case DD calls those instead —
# harmless if it doesn't, and saves a round-trip diagnostic if it does.
func undo() -> void:
	print("[TerrainUndoRecord] undo() [lowercase]")
	_apply(before_splat, before_splat2)


func redo() -> void:
	print("[TerrainUndoRecord] redo() [lowercase]")
	_apply(after_splat, after_splat2)


func _apply(splat, splat2) -> void:
	if terrain == null or not is_instance_valid(terrain):
		print("[TerrainUndoRecord]   terrain gone, skip")
		return
	if splat == null:
		print("[TerrainUndoRecord]   no splat image to restore, skip")
		return
	if splat2 != null and terrain.has_method("RestoreSplat2"):
		terrain.RestoreSplat2(splat, splat2)
	elif terrain.has_method("RestoreSplat"):
		terrain.RestoreSplat(splat)
	else:
		print("[TerrainUndoRecord]   terrain has no RestoreSplat method")
