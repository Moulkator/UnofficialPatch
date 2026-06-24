# merge_path.gd
# Merge two selected Pathways that share an endpoint into one,
# mirroring Dungeondraft's vanilla "Merge Walls" behavior.
#
# UI: adds a "Merge Paths" button in the SelectTool pathOptions sub-panel,
# visible only when exactly 2 Pathways are selected and their endpoints
# coincide (within ENDPOINT_TOLERANCE world units).
#
# Undo / Redo: uses DD's built-in library/custom_history_record.gd
# (same mechanism as SplitPath and the third-party MergePaths mod).
# DD's record recognizes the "merge_list / save_path_1_points /
# save_path_2" shape of history_data and handles both directions
# internally — no custom record script needed.
#
# Critical detail (learnt the hard way): BEFORE calling SetEditPoints
# with world points, the pathway's transform must be normalized to
# identity — in particular path.position must be reset to Vector2.ZERO.
# Without that, SetEditPoints stores the points relative to the old
# node position and the whole path visually jumps away from the cursor.

var _g
var _select_tool = null
var _select_panel = null
var _merge_btn = null

var _poll_accum := 0.0
var _last_visible := false

# Runtime detection of third-party MergePaths mod. The Main.gd guard often
# misses it because that mod's start() runs AFTER UnofficialPatch's — the
# _Lib registry isn't yet populated at check time. So we do a delayed
# runtime check here too.
var _disabled := false
var _third_party_check_elapsed := 0.0
var _third_party_check_done := false
var _third_party_btn = null  # Button node from the third-party mod, if present — we force it hidden

const POLL_INTERVAL := 0.1
const ENDPOINT_TOLERANCE := 8.0
const SELECTABLE_PATHWAY := 5  # DD SelectableTypes enum
const THIRD_PARTY_CHECK_DELAY := 1.0  # seconds after init

enum EndMatchType {
	NO_MATCH,
	A_START_B_START,
	A_START_B_END,
	A_END_B_START,
	A_END_B_END
}

# --- logging -----------------------------------------------------------------
const ENABLE_LOGGING := true
const LOGGING_LEVEL := 1

func outputlog(msg, level := 0) -> void:
	if ENABLE_LOGGING and level <= LOGGING_LEVEL:
		printraw("(%d) <MergePath>: " % OS.get_ticks_msec())
		print(msg)


#########################################################################################################
##
## INITIALIZATION
##
#########################################################################################################

func initialize() -> void:
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	# Button creation is DEFERRED to the first update() tick, after we've
	# had a chance to detect the third-party MergePaths mod. Creating the
	# button here and destroying/disabling it later caused crashes in
	# testing — probably because UIScaler's deep-scan (see log: "Deep
	# scan: 452 scalers") registers the widget into its scale table, and
	# when we mutate it later the iteration trips. Never creating the
	# button in the first place sidesteps all that.
	if _select_panel == null:
		outputlog("WARNING: SelectTool panel not found", 0)
	else:
		outputlog("Initialized; button creation deferred pending third-party check")


func _create_merge_button() -> void:
	# Same container as DD's vanilla "Merge Walls" button (SelectTool panel's
	# Align VBox). Button visibility is fully driven by our polling.
	if _select_panel == null or not is_instance_valid(_select_panel):
		return
	var parent = _select_panel.get("Align")
	if parent == null:
		parent = _select_panel.find_node("Align", true, false)
	if parent == null:
		outputlog("WARNING: Could not find a container to hold Merge Paths button", 0)
		return

	var btn = Button.new()
	btn.text = "Merge Paths"
	btn.hint_tooltip = "Merge two selected paths that share an endpoint into a single path."
	btn.visible = false
	btn.connect("pressed", self, "_on_merge_pressed")
	parent.add_child(btn)

	# Place the button before any hidden VBoxContainer option-panels (same
	# convention as wall_allow_light's select-side button).
	var final_idx = parent.get_child_count()
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		if child is VBoxContainer and not child.visible:
			final_idx = i
			break
	parent.move_child(btn, final_idx)
	_merge_btn = btn
	outputlog("Merge Paths button added")


#########################################################################################################
##
## VISIBILITY POLLING (called by Main.gd update())
##
#########################################################################################################

func update(delta: float) -> void:
	if _disabled:
		return

	# Startup gate: wait for MergePaths.start() to have had time to create
	# its own button, so we can find it and hide it below. Our own button
	# creation is also deferred until now — not because we might not create
	# it (we always do), but to avoid any weird interaction with UIScaler's
	# early deep-scan of widgets.
	if not _third_party_check_done:
		_third_party_check_elapsed += delta
		if _third_party_check_elapsed < THIRD_PARTY_CHECK_DELAY:
			return
		_third_party_check_done = true
		_third_party_btn = _find_third_party_button()
		if _third_party_btn != null:
			outputlog("Third-party MergePaths detected; its button will be kept hidden", 0)
		# Always create OUR button — we're the authoritative implementation.
		_create_merge_button()
		if _merge_btn == null:
			_disabled = true
			return

	# Force-hide the third-party button every tick. MergePaths re-enables
	# its visibility from its own update() on selection changes, so a one-
	# shot hide isn't enough. Setting .visible = false on a widget we
	# don't own is a standard, safe Godot operation (unlike queue_free or
	# disconnect which caused earlier crashes).
	if _third_party_btn != null and is_instance_valid(_third_party_btn):
		if _third_party_btn.visible:
			_third_party_btn.visible = false

	if _merge_btn == null or not is_instance_valid(_merge_btn):
		return
	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL:
		return
	_poll_accum = 0.0
	_refresh_visibility()


# Narrow, inert detection: single-level scan of the SelectTool panel's
# pathOptions container (where the third-party parents its button).
# Returns the Button node if found, else null.
func _find_third_party_button():
	if _select_panel == null or not is_instance_valid(_select_panel):
		return null
	var path_options = _select_panel.get("pathOptions")
	if path_options == null or not is_instance_valid(path_options):
		return null
	for child in path_options.get_children():
		if child is Button and child.text == "Merge Paths":
			return child
	return null


func _refresh_visibility() -> void:
	var show := false
	if _g.Editor.ActiveToolName == "SelectTool":
		var paths = _get_selected_paths()
		if paths.size() == 2:
			show = _find_endpoint_match(paths[0], paths[1]) != EndMatchType.NO_MATCH
	if show != _last_visible:
		_merge_btn.visible = show
		_last_visible = show


func _get_selected_paths() -> Array:
	# Returns the 2 selected pathways, but only if the selection is PURELY
	# pathways. Mirrors DD's "MergeWalls is incompatible with mixed types"
	# rule for its pathway equivalent.
	var paths := []
	var selected = _select_tool.Selected
	if selected == null:
		return paths
	for node in selected:
		if node == null or not is_instance_valid(node):
			continue
		if _select_tool.GetSelectableType(node) != SELECTABLE_PATHWAY:
			return []  # mixed selection -> no merge
		paths.append(node)
	return paths


#########################################################################################################
##
## ENDPOINT MATCHING
##
#########################################################################################################

func _find_endpoint_match(path_a, path_b) -> int:
	if path_a == null or path_b == null:
		return EndMatchType.NO_MATCH
	var a_pts = path_a.GlobalEditPoints
	var b_pts = path_b.GlobalEditPoints
	if a_pts == null or b_pts == null:
		return EndMatchType.NO_MATCH
	if a_pts.size() < 2 or b_pts.size() < 2:
		return EndMatchType.NO_MATCH

	var a_start = a_pts[0]
	var a_end = a_pts[a_pts.size() - 1]
	var b_start = b_pts[0]
	var b_end = b_pts[b_pts.size() - 1]

	# Skip self-closing loops (their two "endpoints" are the same point —
	# merging is ambiguous). Matches DD's wall-merge restriction.
	if a_start.distance_to(a_end) < ENDPOINT_TOLERANCE:
		return EndMatchType.NO_MATCH
	if b_start.distance_to(b_end) < ENDPOINT_TOLERANCE:
		return EndMatchType.NO_MATCH

	# Prefer end-to-start (most natural pen-down continuation).
	if a_end.distance_to(b_start) < ENDPOINT_TOLERANCE:
		return EndMatchType.A_END_B_START
	if a_start.distance_to(b_end) < ENDPOINT_TOLERANCE:
		return EndMatchType.A_START_B_END
	if a_end.distance_to(b_end) < ENDPOINT_TOLERANCE:
		return EndMatchType.A_END_B_END
	if a_start.distance_to(b_start) < ENDPOINT_TOLERANCE:
		return EndMatchType.A_START_B_START
	return EndMatchType.NO_MATCH


# Build a single point list by concatenating, reversing as needed, then
# dropping the duplicated shared endpoint.
func _build_merged_points(a_pts, b_pts, match_type) -> Array:
	var pts1 := []
	for p in a_pts:
		pts1.append(p)
	var pts2 := []
	for p in b_pts:
		pts2.append(p)

	# Normalize to "last point of pts1 == first point of pts2" by reversing.
	if match_type == EndMatchType.A_START_B_START or match_type == EndMatchType.A_START_B_END:
		pts1.invert()
	if match_type == EndMatchType.A_START_B_END or match_type == EndMatchType.A_END_B_END:
		pts2.invert()

	var merged := []
	for p in pts1:
		merged.append(p)
	merged.remove(merged.size() - 1)  # drop shared point (last of pts1 / first of pts2)
	for p in pts2:
		merged.append(p)
	return merged


#########################################################################################################
##
## MERGE OPERATION
##
#########################################################################################################

func _on_merge_pressed() -> void:
	var paths = _get_selected_paths()
	if paths.size() != 2:
		return
	var match_type = _find_endpoint_match(paths[0], paths[1])
	if match_type == EndMatchType.NO_MATCH:
		outputlog("No shared endpoint; skip")
		return

	# Clear the transform box before modifying node positions — otherwise
	# the old box geometry lingers and DD recomputes it with stale data.
	_select_tool.ClearTransformSelection()

	# Create the history record BEFORE mutation so it captures pre-merge state.
	_create_history(paths[0], paths[1])

	# Do the merge.
	_do_merge(paths[0], paths[1], match_type)

	# Intentionally DO NOT re-select the merged path. Re-selecting via
	# SelectThing + OnFinishSelection triggers DD's instant-drag mode on
	# the new transform box when the merged path is flat (straight line) —
	# its GlobalRect has a zero dimension, which DD reads as "cursor is
	# inside" and starts following the mouse without a click. The
	# third-party MergePaths mod skips the re-select for this same reason;
	# user just clicks the merged path manually if they need to keep
	# working on it.


func _do_merge(path_a, path_b, match_type) -> void:
	outputlog("Merging paths: type=" + str(match_type))
	var merged_points = _build_merged_points(path_a.GlobalEditPoints, path_b.GlobalEditPoints, match_type)
	_update_path_to_new_global_points(path_a, merged_points)
	# Proper DD-side deletion: removes node, disposes resources, drops references.
	_g.World.DeleteNodeByID(path_b.get_meta("node_id"))


# Replace the pathway's points with new ones in world space.
#
# CRITICAL: before SetEditPoints we must bring the node's transform to
# identity (rotation = 0, position = (0,0)) otherwise DD stores the
# points relative to the old transform and the visual jumps away.
#
# The scale/mirror handling is borrowed from the third-party MergePaths
# mod by uchideshi34 — if the path was mirrored, invert the point list
# and normalize scale signs. Non-mirror scale != 1 is left untouched
# (DD's own merge quirk; in practice paths are scale 1).
func _update_path_to_new_global_points(path, new_points) -> void:
	if path.scale.sign().x != path.scale.sign().y:
		new_points.invert()
		path.scale.x = abs(path.scale.sign().x)
		path.scale.y = abs(path.scale.sign().y)
	path.rotation = 0.0
	path.position = Vector2.ZERO
	path.SetEditPoints(new_points)
	path.Smooth()


#########################################################################################################
##
## UNDO / REDO
##
## Uses library/merge_paths_history_record.gd (the third-party MergePaths mod's
## record, shipped with our library folder). That record calls back into:
##   main_script.update_path_to_new_global_points(path, points)   on undo
##   main_script.merge_paths(list)                                on redo
## We expose thin public wrappers under those names (see below), which
## delegate to the mod's existing private implementation.
##
## Historical bug (pre-fix): merge_path used to load custom_history_record.gd
## which is SplitPath's record, not ours. DD silently fell through on undo
## because none of the fields it reads (old_path_node_id, etc.) were set.
##
#########################################################################################################

# Record class loaded once, lazily, on first merge.
var _MergePathsRecordScript = null


func _load_record_script() -> void:
	if _MergePathsRecordScript != null:
		return
	# Script.InstanceReference() only resolves DD's built-in library files;
	# our own library/ files need the ResourceLoader path.
	_MergePathsRecordScript = ResourceLoader.load(
		_g.Root + "library/merge_paths_history_record.gd", "GDScript", true)
	if _MergePathsRecordScript == null:
		outputlog("library/merge_paths_history_record.gd could not be loaded; undo disabled", 0)


func _create_history(path_a, path_b) -> void:
	_load_record_script()
	if _MergePathsRecordScript == null:
		return
	var record_script = _MergePathsRecordScript.new()
	if record_script == null:
		outputlog("could not instantiate merge_paths_history_record; undo disabled", 0)
		return

	# This history_data shape matches what merge_paths_history_record.gd
	# reads in its undo() / redo() methods.
	var history_data = {
		"merge_list": [path_a, path_b],
		"save_path_1_points": path_a.GlobalEditPoints,
		"save_path_2": path_b.Save(true),
		"level": _g.World.GetCurrentLevel()
	}
	record_script.history_data = history_data.duplicate(true)
	record_script.main_script = self
	_g.Editor.History.CreateCustomRecord(record_script)


# ─── Record callbacks ────────────────────────────────────────────────────────
# Public names expected by library/merge_paths_history_record.gd.
# Undo needs to restore path_a's original points; redo re-runs the merge.

func update_path_to_new_global_points(path, new_points) -> void:
	_update_path_to_new_global_points(path, new_points)


func merge_paths(merge_list) -> void:
	if merge_list == null or merge_list.size() < 2:
		return
	var a = merge_list[0]
	var b = merge_list[1]
	if a == null or b == null or not is_instance_valid(a) or not is_instance_valid(b):
		return
	var match_type = _find_endpoint_match(a, b)
	if match_type == EndMatchType.NO_MATCH:
		return
	_do_merge(a, b, match_type)
