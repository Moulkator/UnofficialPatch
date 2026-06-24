# undo_lib.gd
# ─────────────────────────────────────────────────────────────────────────────
# Shared undo helpers for UnofficialPatch sub-modules.
#
# LEVEL 1 (this file) — Transform-based undo.
# Wraps DD's SelectTool.SavePreTransforms() / RecordTransforms() sandwich,
# which is how DD's native undo captures position / rotation / scale of
# currently-selected nodes. Any mod action that only mutates these on
# already-selected nodes can get Ctrl+Z support by wrapping its code
# between begin_transform() and commit_transform().
#
# Usage from any sub-module:
#
#     var undo = _g.ModMapData.get("_undo_lib")
#     if undo != null and undo.begin_transform():
#         # ... mutation on currently-selected nodes ...
#         undo.commit_transform()
#     else:
#         # fallback: mutation without undo
#         # ...
#
# Notes:
# * The CALLER is responsible for ensuring the right nodes are in
#   SelectTool.Selected BEFORE calling begin_transform() — DD records
#   whatever is currently selected.
# * begin_transform() returns false if SelectTool isn't ready or the
#   SavePre/Record methods aren't exposed (e.g. older DD build). On
#   false, the caller should still perform its mutation; it just
#   won't be undoable via Ctrl+Z.
# * Level 2 (snapshot-based undo for non-transform properties) and
#   level 3 (callback-based undo for external state) will be added
#   as separate methods on this same handle.
# ─────────────────────────────────────────────────────────────────────────────

var _g
var _select_tool = null
var _in_transform = false

# Level 2 state: property snapshots captured at begin_property_snapshot,
# consumed at commit_property_snapshot. Array of {ref, props} entries.
# Nested begin calls are refused (same rationale as transforms).
var _prop_snapshot: Array = []
var _in_prop_snapshot = false

# Lazy-loaded Record script for level 2.
var _PropRecordScript = null


func initialize() -> void:
	# Register in ModMapData so any sub-module can grab a reference
	# without a direct cross-import. Same convention as _ttf_handler.
	_g.ModMapData["_undo_lib"] = self
	print("[UndoLib] Ready (level 1 — transforms, level 2 — properties)")


# ─── internal ────────────────────────────────────────────────────────────────

func _get_select_tool():
	# Cached, with a freshness check (the Editor can rebuild tools on map
	# open/close in some corner cases, invalidating the cached ref).
	if _select_tool != null and is_instance_valid(_select_tool):
		return _select_tool
	if _g == null or _g.Editor == null:
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null:
		return null
	if not (tools is Dictionary) or not tools.has("SelectTool"):
		return null
	_select_tool = tools["SelectTool"]
	return _select_tool


# ─── LEVEL 1 API: transform undo ─────────────────────────────────────────────

# Begin a transform-undo block.
#
# The caller must ensure its target nodes are already selected in
# SelectTool BEFORE calling this — DD's SavePre captures the transform
# state of the current selection.
#
# Returns true if the pre-snapshot was taken successfully. On false, the
# caller should still perform its mutation; it just won't be undoable.
func begin_transform() -> bool:
	if _in_transform:
		# DD's SavePre/Record don't stack — a second SavePre would clobber
		# the first snapshot, producing a broken record on commit. Warn
		# and refuse rather than create a corrupt history entry.
		print("[UndoLib] WARNING: nested begin_transform(); inner call skipped")
		return false

	var st = _get_select_tool()
	if st == null or not st.has_method("SavePreTransforms"):
		return false

	st.SavePreTransforms()
	_in_transform = true
	return true


# Commit the block started by begin_transform(). Creates the DD history
# entry that Ctrl+Z will roll back.
#
# Returns true on success. Safe no-op (with warning) if called without
# a matching begin_transform().
func commit_transform() -> bool:
	if not _in_transform:
		print("[UndoLib] WARNING: commit_transform() without begin_transform(); skipped")
		return false

	_in_transform = false  # reset early so a failure still releases the flag

	var st = _get_select_tool()
	if st == null or not st.has_method("RecordTransforms"):
		return false

	st.RecordTransforms()
	return true


# Abandon a started block without creating a history entry.
# Use this if your mutation decided to bail out between begin and commit.
#
# Note: DD has no explicit "discard SavePre" API; the stored snapshot
# will simply get overwritten by the next SavePre call, or ignored if
# no Record ever comes. We just clear our own nesting flag.
func cancel_transform() -> void:
	_in_transform = false


# ─── LEVEL 2 API: arbitrary property undo ────────────────────────────────────
#
# For properties outside Transform2D (e.g. a Light's texture_scale or
# shadow_enabled). We snapshot the listed properties on the given nodes,
# the caller mutates them, and commit writes a custom history record
# that stores before/after values. Ctrl+Z / Ctrl+Y then restore them.
#
# Usage:
#
#     var lights = [...]  # the nodes we're about to mutate
#     if undo.begin_property_snapshot(lights, ["texture_scale"]):
#         for l in lights:
#             l.texture_scale = new_value
#         undo.commit_property_snapshot()
#
# For sliders with a drag arc, call begin_property_snapshot on
# drag_started, mutate on value_changed, and commit on drag_ended.
# That way a whole drag becomes a single undo entry, not 50.

func begin_property_snapshot(nodes: Array, prop_names: Array) -> bool:
	if _in_prop_snapshot:
		print("[UndoLib] WARNING: nested begin_property_snapshot(); inner call skipped")
		return false
	if nodes.empty() or prop_names.empty():
		return false

	_prop_snapshot = []
	for node in nodes:
		if node == null or not is_instance_valid(node):
			continue
		var entry = {"ref": weakref(node), "props": {}}
		for prop_name in prop_names:
			var before = node.get(prop_name)
			# Only record properties that exist on this node. `get()`
			# returns null both for missing and genuinely-null props;
			# we keep going since set() in undo/redo will no-op on
			# unknown props anyway.
			entry["props"][prop_name] = {"before": before, "after": null}
		_prop_snapshot.append(entry)

	if _prop_snapshot.empty():
		return false

	_in_prop_snapshot = true
	return true


func commit_property_snapshot() -> bool:
	if not _in_prop_snapshot:
		print("[UndoLib] WARNING: commit_property_snapshot() without begin; skipped")
		return false

	_in_prop_snapshot = false

	# Capture "after" values now that the caller has mutated.
	var meaningful_entries := []
	for entry in _prop_snapshot:
		var node = entry["ref"].get_ref()
		if node == null or not is_instance_valid(node):
			continue
		var has_change := false
		for prop_name in entry["props"]:
			var after = node.get(prop_name)
			entry["props"][prop_name]["after"] = after
			if not _value_equal(entry["props"][prop_name]["before"], after):
				has_change = true
		if has_change:
			meaningful_entries.append(entry)

	_prop_snapshot = []

	if meaningful_entries.empty():
		# Nothing actually changed (drag ended on the same value). Don't
		# create a pointless record.
		return false

	_load_prop_record_script()
	if _PropRecordScript == null:
		return false

	var history = _g.Editor.get("History")
	if history == null or not history.has_method("CreateCustomRecord"):
		return false

	var record = _PropRecordScript.new()
	record.entries = meaningful_entries
	history.CreateCustomRecord(record)
	return true


func cancel_property_snapshot() -> void:
	_prop_snapshot = []
	_in_prop_snapshot = false


func _load_prop_record_script() -> void:
	if _PropRecordScript != null:
		return
	_PropRecordScript = ResourceLoader.load(
		_g.Root + "library/property_history_record.gd", "GDScript", true)
	if _PropRecordScript == null:
		print("[UndoLib] WARN: library/property_history_record.gd not found")


func _value_equal(a, b) -> bool:
	# Floats need approximate comparison to avoid false positives from
	# slider steps that pass through the same int-ish value via slightly
	# different float paths.
	if typeof(a) == TYPE_REAL and typeof(b) == TYPE_REAL:
		return abs(a - b) < 1e-6
	return a == b


# ─── LEVEL 3 API: callback-based undo ────────────────────────────────────────
#
# For actions that can't be captured as simple property writes (e.g. calls
# to SetOptions/SetOutline, node creation, anything involving methods with
# multiple coupled parameters). The caller provides two callbacks that
# know how to undo and redo the action.
#
# The record stores the callbacks and their arguments — nothing else. The
# caller is responsible for capturing the "before" state before calling
# record_callback(), and the "after" state is implicit in whatever the
# callback does.
#
# Usage:
#
#     var before_texture = shape.texture
#     var before_color = shape.color
#     var before_rot = shape.rotation
#     # ... user-driven mutation happens ...
#     shape.SetOptions(new_texture, new_color, new_rot)
#     undo.record_callback(
#         self, "_restore_pattern", [shape, before_texture, before_color, before_rot],
#         self, "_restore_pattern", [shape, new_texture, new_color, new_rot])
#
# The caller's _restore_pattern() method does the SetOptions() work.

func record_callback(undo_target, undo_method: String, undo_args: Array,
					  redo_target, redo_method: String, redo_args: Array) -> bool:
	_load_callback_record_script()
	if _CallbackRecordScript == null:
		return false
	var history = _g.Editor.get("History")
	if history == null or not history.has_method("CreateCustomRecord"):
		return false
	
	var record = _CallbackRecordScript.new()
	record.undo_target = undo_target
	record.undo_method = undo_method
	record.undo_args = undo_args
	record.redo_target = redo_target
	record.redo_method = redo_method
	record.redo_args = redo_args
	history.CreateCustomRecord(record)
	return true


var _CallbackRecordScript = null

func _load_callback_record_script() -> void:
	if _CallbackRecordScript != null:
		return
	_CallbackRecordScript = ResourceLoader.load(
		_g.Root + "library/callback_history_record.gd", "GDScript", true)
	if _CallbackRecordScript == null:
		print("[UndoLib] WARN: library/callback_history_record.gd not found")
