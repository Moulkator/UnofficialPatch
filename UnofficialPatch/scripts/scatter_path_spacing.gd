# scatter_path_spacing.gd
# Scatter Tool: "Natural Spacing" toggle — spacing measured along the cursor
# path.
#
# Vanilla ScatterTool drops the next asset on mouse motion only when the new
# asset's rect does not intersect any already-dropped asset's rect grown by
# Spread * TileSize. Consequence: zigzags and back-and-forth passes over an
# already-covered area drop NOTHING, because the rects always intersect. This
# mod adds a CheckButton ("Natural Spacing") right under the Spread slider; when
# ON, an asset is dropped every time the cursor has TRAVELED the Spread
# distance along its path (world units), regardless of overlap. Back-and-forth
# and zigzag strokes therefore build up density naturally.
#
# Mechanism
# ---------
# * An _input listener (same last-child-of-root priority pattern as
#   scatter_transform.gd) consumes ONLY the LMB press and the LMB release
#   while a path stroke is active. Consuming the press keeps vanilla
#   ScatterTool.isDrawing false, which neutralizes its whole motion-placement
#   branch for free: mouse-motion events are NOT consumed (pan, WorldUI,
#   other listeners stay untouched). Consuming the release prevents vanilla
#   from recording a ScatterObjects history entry built from its stale
#   private currentStroke list.
# * Motion accumulates world-space distance from WorldUI.MousePosition
#   (already clamped to map bounds). The preview is stamped every time the
#   accumulator reaches
#       Spread * TileSize + half-extents of the previous and next assets
#       projected on the travel direction
#   which reproduces vanilla's edge-to-edge Spread spacing on a straight
#   line (vanilla stops intersecting when the center distance equals
#   (prev_extent + next_extent)/2 + Spread): straight strokes look
#   identical to vanilla, while zigzags and back-and-forth passes still add
#   density since only path length matters, never overlap.
#
# Stamping = Save(copy) + LoadObject round-trip
# ---------------------------------------------
# Master.AddObjectCount() (feeds the "Used" asset counts) is a static C#
# method, unreachable from GDScript. The ONLY reachable code path that
# increments it is Objects.LoadObject(). So instead of stamping the preview
# node directly (vanilla does: clear "preview" meta + AssignNodeID +
# AddToSearchTable, and counts +1 later inside ObjectRecord's ctor at
# mouse-up), we:
#   1. data = preview.Save(true)  -> copy=true: NO node_id in the dict
#   2. prop = Objects.LoadObject(data) -> real prop: +1 count, added to the
#      quick-search table (front), and — because the dict has no node_id —
#      Prop.Load takes the World.AssignNodeID(this) branch, which emits the
#      OnAssignNode signal ON THE PLACED NODE exactly like a vanilla stamp.
#      Third-party mods that hook OnAssignNode (ColourAndModifyThings tints
#      new nodes through it) therefore see our drops as native ones. An
#      earlier revision assigned the id to the PREVIEW before saving: the
#      signal then fired for a node we freed right after, and the real copy
#      went through AssignSpecificNodeID which does NOT emit — CMT tinted a
#      corpse and the placed prop stayed untinted.
#      Second third-party interop: Minor Utils' "Random Mirror" polls the
#      tool's private currentStroke list every frame while LMB is held and
#      flips Mirror on new entries. Our mode keeps that list empty (the
#      press never reaches vanilla), and the marshalled list cannot be
#      written from GDScript — so when Minor Utils' own "Random Mirror"
#      CheckButton (looked up by text in the Scatter panel) is pressed, we
#      apply prop.Mirror = random ourselves at stamp time, BEFORE the record
#      snapshot, so mirroring also survives undo/redo. Their poll then sees
#      an empty stroke and stays a no-op: no double flip.
#   3. record data = prop.Save(false) taken AFTER LoadObject: it carries the
#      real node_id (so redo restores the same id via AssignSpecificNodeID,
#      signal-less like vanilla redo) and whatever DD-serializable state
#      hook mods already applied to the node.
#   4. Under sorting fix-up if needed (move_child(0) + re-add to table back)
#   5. ScatterTool.call("Next", false) -> vanilla builds the next preview:
#      random texture from its private pool, random rotation/scale from the
#      Min/Max sliders, random colorable color, ZIndex/shadow/position. Zero
#      replication of private state on our side. Next(cycle:false) always
#      creates a brand-new Preview and merely re-assigns the C# field, so the
#      freed old node is never dereferenced (checked against the decompile).
#   6. The old preview (never id-registered) is queue_free'd.
#   "Next" is private C#; DD's own UI wires signals to private methods
#   (SetLayer, SetShadow, OnColorPickerVisible...) so the Mono call path
#   reaches them. Guarded by has_method(): if a future DD build hides it,
#   the toggle refuses to start a stroke and vanilla behavior is untouched.
#
# Undo / Redo — one record per stroke
# -----------------------------------
# On release, ONE custom record (library/scatter_path_spacing_record.gd) is
# pushed via History.CreateCustomRecord, mirroring vanilla's one
# ScatterObjects per stroke.
# * Undo = World.DeleteNodeByID(id), exactly like vanilla ObjectRecord's
#   Delete() minus the unreachable Master.AddObjectCount(-1). Prop._ExitTree
#   self-cleans the quick-search table (checked in Prop.cs), so no manual
#   table maintenance — and no detach/reattach: Prop._EnterTree rebuilds
#   Sprite/shadow/widget from scratch, so a Prop must NEVER re-enter the
#   tree; freed-and-recreated is the only sane lifecycle.
# * Redo = CreateObject + prop.Load(data) + AddToSearchTable, i.e.
#   Objects.LoadObject minus its Master.AddObjectCount(+1). Skipping the +1
#   here exactly compensates the -1 we cannot do on undo: the "Used" counts
#   are correct in every settled state and only read high by N while a
#   stroke of N props sits undone (transient, never cumulative).
#
# Level-safety: like ObjectRecord, the record stores the Level.ID at stroke
# time; redo resolves GetLevelByID(id).Objects, undo goes through the global
# id table. The Prop._ExitTree table cleanup targets World.Level (the
# CURRENT level) — the exact same exposure as vanilla ObjectRecord deleting
# cross-level, so we inherit whatever level-switching DD's History performs.

const MIN_SPACING_TILE_FRACTION := 0.0625
# Keep the listener first in the _input queue (see scatter_transform.gd
# header for the reverse-dispatch-order rationale).
const FIRST_IN_INPUT_QUEUE := true
const DEBUG := false

var _g
var ui_util

var input_listener: Node = null
var _destroyed := false
var _attach_frame := -100
var _root_child_count := -1

# Toggle button state ("Natural Spacing" CheckButton in the Scatter panel).
# Natural Spacing is ON by default; the CheckButton reflects and controls it.
var _toggle_btn = null
var _btn_frame := -100
var _enabled := true

# Stroke state.
var _stroke_active := false
var _stroke_entries := []      # [{prop, id, data, under, child_index}]
var _stroke_level_id := 0
var _accum := 0.0
var _last_pos := Vector2.ZERO
var _last_stamp_pos := Vector2.ZERO
var _prev_size := Vector2.ZERO   # global rect size of the last stamped asset

var _RecordScript = null
var _warned_no_next := false

# Minor Utils interop: cached reference to THEIR "Random Mirror" CheckButton
# in the Scatter panel (null if Minor Utils is absent).
var _mu_mirror_btn = null
var _mu_btn_frame := -100

# [DIAG] instrumentation — printed once per distinct reason/state change.
var _diag_last := {}


func _diag(key: String, msg: String) -> void:
	if _diag_last.get(key, "") == msg:
		return
	_diag_last[key] = msg
	printerr("[DIAG][SPS] " + msg)


func initialize() -> void:
	_install_input_listener()
	print("[ScatterPathSpacing] Initialized.")
	printerr("[DIAG][SPS] diagnostic build active")


func update(_delta) -> void:
	_ensure_listener()
	_keep_input_priority()
	_ensure_toggle()
	# Safety net: if the release was missed (focus loss, another listener
	# consumed it, tool switched via hotkey mid-drag), close the stroke so
	# the record is created and the state can't go stale.
	if _stroke_active:
		if not Input.is_mouse_button_pressed(BUTTON_LEFT) or _active_tool_name() != "ScatterTool":
			_finalize_stroke()


func cleanup() -> void:
	_destroyed = true
	if _stroke_active:
		_finalize_stroke()
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.queue_free()
	_toggle_btn = null


# ==================== INPUT LISTENER (scatter_transform pattern) ============

func _ensure_listener() -> void:
	if _destroyed:
		return
	if input_listener == null or not is_instance_valid(input_listener):
		_install_input_listener()
		return
	if input_listener.is_inside_tree():
		return
	var f = Engine.get_idle_frames()
	if f - _attach_frame < 30:
		return
	_attach_frame = f
	_attach_listener()


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "ScatterPathSpacingListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -90
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	_attach_frame = Engine.get_idle_frames()
	_attach_listener()


func _attach_listener() -> void:
	if input_listener == null or not is_instance_valid(input_listener):
		return
	if input_listener.get_parent() != null:
		return
	var host = null
	for cand in [_g.World, _g.Editor, _g.Camera]:
		if cand is Node and cand.is_inside_tree():
			host = cand
			break
	if host == null:
		return
	var tree = host.get_tree()
	if tree and tree.root:
		tree.root.call_deferred("add_child", input_listener)


func _keep_input_priority() -> void:
	if not FIRST_IN_INPUT_QUEUE:
		return
	if input_listener == null or not is_instance_valid(input_listener):
		return
	if not input_listener.is_inside_tree():
		return
	var root = input_listener.get_parent()
	if root == null:
		return
	var count = root.get_child_count()
	if count == _root_child_count:
		return
	_root_child_count = count
	var last = count - 1
	if input_listener.get_index() != last:
		root.move_child(input_listener, last)


func _dbg(msg: String) -> void:
	if DEBUG:
		print("[ScatterPathSpacing] " + msg)


# ==================== INPUT =================================================

func _on_input(event) -> void:
	if _destroyed or input_listener == null or not is_instance_valid(input_listener):
		return

	if _stroke_active:
		if event is InputEventMouseMotion:
			_on_stroke_motion()
			# NOT consumed: pan, WorldUI and every other consumer keep
			# working. Vanilla's motion branch is inert (isDrawing false).
			return
		if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
			_finalize_stroke()
			# Consumed: vanilla's release branch would push a ScatterObjects
			# record built from its stale private currentStroke.
			input_listener.get_tree().set_input_as_handled()
		return

	if not (event is InputEventMouseButton):
		return
	if event.button_index != BUTTON_LEFT or not event.pressed:
		return
	if not _enabled:
		_diag("press", "press: ignored, toggle is OFF")
		return
	# Ctrl+LMB is vanilla's early-out; leave it alone.
	if event.control or Input.is_key_pressed(KEY_CONTROL):
		_diag("press", "press: ignored, Ctrl held")
		return
	if _active_tool_name() != "ScatterTool":
		_diag("press", "press: ignored, active tool = '%s'" % _active_tool_name())
		return
	# UI guard: geometry-only variant + explicit popup hit-test, same
	# rationale as scatter_transform.gd (tooltips are Popups in Godot 3).
	if ui_util != null:
		if ui_util.is_mouse_over_popup(input_listener):
			_diag("press", "press: ignored, popup under cursor")
			return
		if ui_util.is_mouse_over_ui(input_listener, true):
			_diag("press", "press: ignored, cursor over UI")
			return
	if _g.World == null or not is_instance_valid(_g.World):
		_diag("press", "press: ignored, World invalid")
		return
	_diag("press", "press: guards passed, starting stroke")

	if _begin_stroke():
		# Consumed: vanilla never sees the press, so isDrawing stays false
		# and its motion-placement branch is fully disabled for this stroke.
		input_listener.get_tree().set_input_as_handled()


# ==================== STROKE ================================================

func _begin_stroke() -> bool:
	var st = _get_scatter_tool()
	if st == null:
		_diag("begin", "begin: ScatterTool not reachable")
		return false
	printerr("[DIAG][SPS] begin: has_method(Next)=%s" % str(st.has_method("Next")))
	if not st.has_method("Next"):
		# Capability gate BEFORE any mutation: without Next() we cannot
		# rebuild the preview after a stamp, so fall through to vanilla.
		if not _warned_no_next:
			_warned_no_next = true
			printerr("[ScatterPathSpacing] ScatterTool.Next() is not callable in this DD build; Path Spacing disabled, vanilla behavior kept.")
		return false
	if _get_preview(st) == null:
		_diag("begin", "begin: no usable Preview (null or no Texture)")
		return false
	var ui = _get_world_ui()
	if ui == null:
		_diag("begin", "begin: WorldUI not reachable")
		return false

	_stroke_entries = []
	_stroke_level_id = int(_g.World.Level.ID)
	_last_pos = ui.MousePosition
	_last_stamp_pos = _last_pos
	_accum = 0.0
	_prev_size = _preview_rect_size(st)

	if not _stamp(st):
		return false
	_stroke_active = true
	_dbg("stroke started (level %d)" % _stroke_level_id)
	return true


func _on_stroke_motion() -> void:
	var ui = _get_world_ui()
	if ui == null:
		_finalize_stroke()
		return
	var pos: Vector2 = ui.MousePosition
	_accum += pos.distance_to(_last_pos)
	_last_pos = pos

	var st = _get_scatter_tool()
	if st == null:
		_finalize_stroke()
		return
	var spacing = _spacing(st, pos)
	if _accum >= spacing:
		printerr("[DIAG][SPS] motion: accum=%.1f >= spacing=%.1f, stamping" % [_accum, spacing])
		if _stamp(st):
			# Carry the remainder so drops stay evenly spaced along the path.
			_accum = max(_accum - spacing, 0.0)
		else:
			# No usable preview right now (e.g. selection emptied mid-drag):
			# keep stroking, retry on later motion.
			_accum = 0.0


func _finalize_stroke() -> void:
	_stroke_active = false
	printerr("[DIAG][SPS] finalize: %d entries" % _stroke_entries.size())
	if _stroke_entries.empty():
		return
	var entries = _stroke_entries
	_stroke_entries = []

	# Capture child indices at stroke end, like ObjectRecord does at ctor
	# time (mouse-up), so redo restores the exact z-order among siblings.
	for e in entries:
		var prop = e["prop"]
		if prop != null and is_instance_valid(prop) and prop.is_inside_tree():
			e["child_index"] = prop.get_index()

	if not _uu_editor_reachable():
		return
	var history = _g.Editor.get("History")
	if history == null or not history.has_method("CreateCustomRecord"):
		printerr("[ScatterPathSpacing] History.CreateCustomRecord unavailable; stroke not undoable.")
		return
	_load_record_script()
	if _RecordScript == null:
		return
	var record = _RecordScript.new()
	record.main_script = self
	record.level_id = _stroke_level_id
	record.entries = entries
	history.CreateCustomRecord(record)
	_dbg("stroke recorded: %d objects" % entries.size())


# Stamp the current preview as a real object and let vanilla build the next
# preview. See the header for the Save/Delete/LoadObject rationale.
func _stamp(st) -> bool:
	var preview = _get_preview(st)
	if preview == null:
		return false
	if _g.World == null or not is_instance_valid(_g.World):
		return false
	var level = _g.World.Level
	if level == null or not is_instance_valid(level):
		return false
	var objects = level.get("Objects")
	if objects == null or not is_instance_valid(objects):
		return false

	# Under sorting keeps the preview at the back (index 0) — CreateObject
	# MoveToBack's it. Detecting it from geometry avoids depending on the
	# SortMode enum's numeric values. With a single child the order is
	# meaningless anyway.
	var under: bool = preview.get_index() == 0 and objects.get_child_count() > 1

	printerr("[DIAG][SPS] stamp: pos=%s under=%s" % [str(preview.global_position), str(under)])
	# Save(bool copy = ...) has a C# default parameter: calling it with no
	# args from GDScript mis-resolves (returned the Position Vector2!). The
	# bool MUST be passed explicitly (same convention as SplitPath's
	# pathway.Save(true)). copy=true -> no node_id, so Prop.Load will assign
	# a fresh one via AssignNodeID and emit OnAssignNode on the placed node
	# (ColourAndModifyThings and friends tint through that signal).
	var data = preview.Save(true)
	var prop = objects.LoadObject(data)
	printerr("[DIAG][SPS] stamp: LoadObject -> %s" % str(prop))
	# Rebuild the tool's preview, then dispose the old one (it never got an
	# id, so a plain queue_free is the whole cleanup). Next() first, so the
	# C# Preview field never points at a freed node.
	st.call("Next", false)
	preview.queue_free()
	if prop == null:
		printerr("[ScatterPathSpacing] LoadObject failed; drop skipped.")
		return false
	if under:
		_apply_under_fix(objects, prop)
	if _minor_utils_mirror_enabled():
		prop.Mirror = bool(randi() & 1)
	# Record snapshot AFTER LoadObject: carries the real node_id (stable
	# across undo/redo) plus any DD-serializable state hook mods just
	# applied (e.g. CMT custom colors written through DD's custom_color).
	var id = prop.get_meta("node_id")
	var record_data = prop.Save(false)
	printerr("[DIAG][SPS] stamp: id=%s" % str(id))

	_last_stamp_pos = _last_pos
	_prev_size = _rect_size_of(prop)
	printerr("[DIAG][SPS] stamp: prev_size=%s" % str(_prev_size))

	_stroke_entries.append({
		"id": id,
		"data": record_data,
		"under": under,
		"child_index": prop.get_index(),
		"prop": prop,  # only used to refresh child_index at stroke end
	})
	return true


# LoadObject creates Over-sorted (front of tree + AddFirst in the search
# table); Under mode needs back of tree + AddLast, like vanilla's
# AddToSearchTable(prop, movedToBack: true) on a back-created preview.
func _apply_under_fix(objects, prop) -> void:
	objects.move_child(prop, 0)
	objects.RemoveFromSearchTable(prop)
	objects.AddToSearchTable(prop, true)


# Vanilla-equivalent spacing for the current travel direction. Vanilla drops
# the next asset when its rect stops intersecting the previous rect grown by
# Spread * TileSize, i.e. at a center distance of
#     (prev_extent + next_extent)/2 + Spread * TileSize
# along the travel axis, where extent is the axis-aligned global-rect size
# projected on that axis. Reproducing that here makes straight strokes look
# exactly like vanilla; the difference only shows (intentionally) when the
# path folds back on itself.
func _spacing(st, pos: Vector2) -> float:
	var spread := 0.0
	var spread_node = st.get("Spread")
	if spread_node != null and is_instance_valid(spread_node):
		spread = float(spread_node.value)
	var tile = float(_g.World.TileSize)

	var d: Vector2 = pos - _last_stamp_pos
	if d.length_squared() < 0.000001:
		d = Vector2.RIGHT
	else:
		d = d.normalized()
	var prev_size = _prev_size
	var next_size = _preview_rect_size(st)
	# Zero size = no measurable sprite (should not happen once a texture is
	# set); assume a 1-tile asset rather than collapsing to Spread-only.
	if prev_size == Vector2.ZERO:
		prev_size = Vector2(tile, tile)
	if next_size == Vector2.ZERO:
		next_size = Vector2(tile, tile)
	var ext_prev = 0.5 * (prev_size.x * abs(d.x) + prev_size.y * abs(d.y))
	var ext_next = 0.5 * (next_size.x * abs(d.x) + next_size.y * abs(d.y))
	return max(spread * tile + ext_prev + ext_next, tile * MIN_SPACING_TILE_FRACTION)


func _preview_rect_size(st) -> Vector2:
	var preview = _get_preview(st)
	if preview == null:
		return Vector2.ZERO
	return _rect_size_of(preview)


# Global-AABB size of a prop's sprite (rotation and scale included) — the
# same measure as the Sprite.GetGlobalRect() vanilla's intersection test
# uses. GetGlobalRect is a DD C# EXTENSION method, so it is NOT callable on
# the instance from GDScript (calling it silently yielded null and the
# fallbacks cascaded to Vector2.ZERO -> Spread-only spacing). Rebuilt here
# from the native Sprite.get_rect() and the global transform: the AABB
# half-size of a transformed rect is |basis_x|*w/2 + |basis_y|*h/2 per axis.
func _rect_size_of(prop) -> Vector2:
	var sprite = prop.get("Sprite")
	if sprite == null or not is_instance_valid(sprite):
		return Vector2.ZERO
	if sprite.texture == null:
		return Vector2.ZERO
	var r: Rect2 = sprite.get_rect()
	var xf: Transform2D = sprite.global_transform
	var bx: Vector2 = xf.x * (r.size.x * 0.5)
	var by: Vector2 = xf.y * (r.size.y * 0.5)
	return Vector2(abs(bx.x) + abs(by.x), abs(bx.y) + abs(by.y)) * 2.0


# ==================== UNDO / REDO (called by the record) ====================

func _record_undo(record) -> void:
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	for i in range(record.entries.size() - 1, -1, -1):
		var e = record.entries[i]
		var id = e["id"]
		if _g.World.has_method("HasNodeID") and not _g.World.HasNodeID(id):
			# Already gone (freed by another record, e.g. a Select delete
			# that was itself redone). Same tolerance as vanilla, which
			# prints "[Error] Failed to undo already deleted object."
			printerr("[DIAG][SPS] undo: id=%s already deleted, skipped" % str(id))
			continue
		var ok = _g.World.DeleteNodeByID(id)
		printerr("[DIAG][SPS] undo: DeleteNodeByID(%s) -> %s" % [str(id), str(ok)])


func _record_redo(record) -> void:
	var objects = _resolve_objects(record.level_id)
	if objects == null:
		printerr("[DIAG][SPS] redo: Objects for level %d unreachable" % record.level_id)
		return
	for e in record.entries:
		var id = e["id"]
		if _g.World.has_method("HasNodeID") and _g.World.HasNodeID(id):
			printerr("[DIAG][SPS] redo: id=%s already present, skipped" % str(id))
			continue
		# LoadObject minus the object count (see header): CreateObject's
		# SortMode arg is irrelevant here because move_child fixes the final
		# tree position either way.
		var prop = objects.CreateObject(0)
		prop.Load(e["data"])
		objects.AddToSearchTable(prop, e["under"])
		objects.move_child(prop, int(min(e["child_index"], objects.get_child_count() - 1)))
		printerr("[DIAG][SPS] redo: recreated id=%s under=%s" % [str(id), str(e["under"])])


func _resolve_objects(level_id: int):
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return null
	if not _g.World.has_method("GetLevelByID"):
		return null
	var level = _g.World.GetLevelByID(level_id)
	if level == null or not is_instance_valid(level):
		return null
	var objects = level.get("Objects")
	if objects == null or not is_instance_valid(objects):
		return null
	return objects


func _load_record_script() -> void:
	if _RecordScript != null:
		return
	_RecordScript = ResourceLoader.load(
		_g.Root + "library/scatter_path_spacing_record.gd", "GDScript", true)
	if _RecordScript == null:
		printerr("[ScatterPathSpacing] library/scatter_path_spacing_record.gd not found")


# ==================== TOGGLE BUTTON =========================================

func _ensure_toggle() -> void:
	if _destroyed:
		return
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		return
	var f = Engine.get_idle_frames()
	if f - _btn_frame < 30:
		return
	_btn_frame = f
	var st = _get_scatter_tool()
	if st == null:
		_diag("toggle", "toggle: ScatterTool not reachable")
		return
	var spread_node = st.get("Spread")
	if spread_node == null or not is_instance_valid(spread_node):
		_diag("toggle", "toggle: st.Spread is null/invalid")
		return
	if not spread_node.is_inside_tree():
		_diag("toggle", "toggle: Spread node not in tree")
		return
	var row = spread_node.get_parent()
	if row == null:
		_diag("toggle", "toggle: Spread has no parent")
		return
	var parent = row.get_parent()
	if parent == null:
		_diag("toggle", "toggle: Spread row has no parent")
		return
	_diag("toggle", "toggle: inserting after row '%s' in parent '%s' (%s)" % [row.name, parent.name, parent.get_class()])
	# Duplicate-mod guard.
	for child in parent.get_children():
		if child is CheckButton and child.name == "NaturalSpacingButton":
			_toggle_btn = child
			return
	var btn = CheckButton.new()
	btn.name = "NaturalSpacingButton"
	btn.text = "Natural Spacing"
	btn.hint_tooltip = "Drop assets by distance traveled along the cursor path:\nzigzags and back-and-forth passes keep dropping (overlaps\nallowed). Spread stays the edge-to-edge distance, so straight\nstrokes match vanilla. Off = vanilla no-overlap spacing."
	btn.pressed = _enabled
	btn.connect("toggled", self, "_on_toggle")
	parent.add_child(btn)
	parent.move_child(btn, row.get_index() + 1)
	_toggle_btn = btn
	print("[ScatterPathSpacing] 'Natural Spacing' toggle added to the Scatter panel.")
	printerr("[DIAG][SPS] toggle button added, visible=%s, rect=%s" % [str(btn.visible), str(btn.get_global_rect())])


func _on_toggle(pressed: bool) -> void:
	_enabled = pressed
	printerr("[DIAG][SPS] toggle -> %s" % str(pressed))
	if not _enabled and _stroke_active:
		_finalize_stroke()


# ==================== TOOL / PREVIEW ACCESS =================================

func _get_scatter_tool():
	if not _uu_editor_reachable():
		return null
	var tools = _g.Editor.Tools
	if tools == null or not tools.has("ScatterTool"):
		return null
	var st = tools["ScatterTool"]
	if st == null:
		return null
	return st


# True when Minor Utils is installed AND its "Random Mirror" CheckButton in
# the Scatter panel is pressed. The button has no distinctive node name, so
# it is matched by class + text among the panel's Align children (our own
# toggle has a different text and never matches).
func _minor_utils_mirror_enabled() -> bool:
	if _mu_mirror_btn != null and is_instance_valid(_mu_mirror_btn):
		return _mu_mirror_btn.pressed
	var f = Engine.get_idle_frames()
	if f - _mu_btn_frame < 60:
		return false
	_mu_btn_frame = f
	if not _uu_editor_reachable():
		return false
	var toolset = _g.Editor.get("Toolset")
	if toolset == null:
		return false
	var panel = toolset.GetToolPanel("ScatterTool")
	if panel == null or not is_instance_valid(panel):
		return false
	var align = panel.get("Align")
	if align == null or not is_instance_valid(align):
		return false
	for child in align.get_children():
		if child is CheckButton and child.text == "Random Mirror":
			_mu_mirror_btn = child
			return _mu_mirror_btn.pressed
	return false


func _get_preview(st):
	var preview = st.get("Preview")
	if preview == null or not is_instance_valid(preview):
		return null
	if preview.get("Texture") == null:
		return null
	return preview


func _get_world_ui():
	if _g.World == null or not is_instance_valid(_g.World):
		return null
	var ui = _g.World.get("UI")
	if ui == null or not is_instance_valid(ui):
		return null
	return ui


# ==================== SHARED EDITOR STATE ===================================
# Same contract as the other submods: read the per-frame snapshot published
# by Main.gd instead of marshalling ActiveToolName across the interop
# boundary, and memoize the _g.Editor reachability check once per tick.

var _uu_ed_frame := -1
var _uu_ed_ok := false


func _active_tool_name() -> String:
	if not _uu_editor_reachable():
		return ""
	if Engine.has_meta("_uu_editor_state"):
		var s = Engine.get_meta("_uu_editor_state")
		if s is Dictionary:
			var v = s.get("active_tool_name")
			if v is String:
				return "%s" % v
	return str(_g.Editor.ActiveToolName)


func _uu_editor_reachable() -> bool:
	var f = Engine.get_idle_frames()
	if f == _uu_ed_frame:
		return _uu_ed_ok
	_uu_ed_frame = f
	_uu_ed_ok = _g != null and _g.Editor != null
	return _uu_ed_ok
