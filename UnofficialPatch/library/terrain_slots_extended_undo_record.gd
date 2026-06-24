# terrain_slots_extended_undo_record.gd
# History record for extended terrain painting (slots 9-24).
#
# Passed to Editor.History.CreateCustomRecord(). DD calls Undo()/Redo() on it
# (cf. the existing terrain_undo_record.gd). We store the before/after state of
# up to 6 splats: the 2 vanilla splats (restored via RestoreSplat2) + our 4
# splats (splat3..6), restored by the terrain16 driver. Unused splats are null.
#
# No `extends` and no `script_class`: DD auto-parses the mod's .gd files and
# prepends boilerplate, which would break a top-level `extends`.
# GDScript inherits from Reference by default, so this stays a Reference.

var driver = null     # terrain16 module, to restore splat3..6
var terrain = null    # the Terrain (slots 0-7 via RestoreSplat2)

var before1 = null
var before2 = null
var before3 = null
var before4 = null
var before5 = null
var before6 = null
var after1 = null
var after2 = null
var after3 = null
var after4 = null
var after5 = null
var after6 = null


func Undo() -> void:
	_apply(before1, before2, before3, before4, before5, before6)


func Redo() -> void:
	_apply(after1, after2, after3, after4, after5, after6)


# Lowercase variants in case DD calls these.
func undo() -> void:
	_apply(before1, before2, before3, before4, before5, before6)


func redo() -> void:
	_apply(after1, after2, after3, after4, after5, after6)


func _apply(s1, s2, s3, s4, s5, s6) -> void:
	if terrain != null and is_instance_valid(terrain):
		# Slots 0-7: vanilla undo path.
		if s1 != null and s2 != null and terrain.has_method("RestoreSplat2"):
			terrain.RestoreSplat2(s1, s2)
		elif s1 != null and terrain.has_method("RestoreSplat"):
			terrain.RestoreSplat(s1)
	# Slots 8-23: our splats (splat3..6).
	if driver != null and is_instance_valid(driver):
		driver.restore_extra_splats(s3, s4, s5, s6)
