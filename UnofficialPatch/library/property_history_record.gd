extends Reference

# Property History Record.
#
# Generic history entry for "some properties on some nodes changed from X
# to Y". Used when the mutation is NOT covered by DD's SavePre/Record
# transforms sandwich (those only handle position/rotation/scale).
#
# Typical use case: a light's `texture_scale` (range slider) or
# `shadow_enabled` (shadow toggle). Both live outside Transform2D, so
# they need this fallback record.
#
# Filled in by undo_lib.begin_property_snapshot / commit_property_snapshot.
# Stored shape:
#   entries = [
#     { "ref": WeakRef(node), "props": { "prop_name": {"before": X, "after": Y}, ... } },
#     ...
#   ]
# WeakRef is used so a deleted node doesn't keep us alive; on undo/redo
# we just skip freed nodes rather than erroring.

var entries: Array = []


func undo() -> void:
	for entry in entries:
		var node = entry["ref"].get_ref()
		if node == null or not is_instance_valid(node):
			continue
		for prop_name in entry["props"]:
			node.set(prop_name, entry["props"][prop_name]["before"])


func redo() -> void:
	for entry in entries:
		var node = entry["ref"].get_ref()
		if node == null or not is_instance_valid(node):
			continue
		for prop_name in entry["props"]:
			node.set(prop_name, entry["props"][prop_name]["after"])
