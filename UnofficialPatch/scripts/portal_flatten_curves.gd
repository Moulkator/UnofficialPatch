# portal_flatten_curves.gd
#
# Adds a "Flatten Curves" toggle to the PortalTool palette.
#
# When ON and the cursor hovers a curved wall area where the current
# portal won't fit natively (DD requires a single straight segment
# >= portal diameter), we compute a chord on the cardinal line
# closest to the cursor and place two NEW points B1, B2 on it,
# separated by the portal diameter. A green overlay previews the new
# wall shape; clicking applies it.
#
# Chord algorithm:
#  1. Cardinal direction `td` = wall's local tangent at the closest
#     segment, snapped to the nearest 45° multiple, then oriented to
#     match the polyline direction.
#  2. Line = the cardinal line closest to the cursor. When
#     Editor.IsSnapping is on, the line is grid-aligned (passes
#     through GetSnappedPosition(cursor)); otherwise it passes through
#     the cursor itself.
#  3. Chord midpoint M = the snapped point (snap on) or the cursor
#     (snap off). B1 = M - td * needed/2, B2 = M + td * needed/2.
#  4. left_seg / right_seg = the wall segments whose td-projection
#     range contains B1 / B2 respectively (found by walking the
#     polyline outward from the cursor's closest segment).
#
# On click, the wall becomes:
#     pts[0..left_seg] + B1 + B2 + pts[right_seg+1..end]
# The short segments pts[left_seg]→B1 and B2→pts[right_seg+1] are the
# connecting "raccords"; they're short because the chord line is right
# next to the cursor (which is itself near the wall).
#
# Mutation path (see _replace_wall):
#   1. wall.Save() snapshots the wall as a Dictionary.
#   2. _build_after_save edits "points" and reindexes each portal entry.
#   3. We free portals first (their tree_exiting cascades into C# code
#      that flags walls_node as "busy setting up children" if they're
#      still attached), then remove + free the old wall.
#   4. walls_node.LoadWall(after_save) recreates a fresh wall + portals.
#
# The mutation is deferred through a Timer (RELOAD_CHECK_INTERVAL):
# walls_node is locked during input dispatch, and DD's own AddPortal
# C# coroutine can keep the wall in a transitional state for several
# frames after the user places a portal. We wait until the wall's
# portal count is stable across two consecutive ticks before flushing.
# We do NOT consume the click: set_input_as_handled() crashes DD's
# PortalTool C#. As a result, the user clicks once on the curve
# (queues the flatten), then clicks again on the now-flat segment to
# place the portal via DD's native code path.
#
# Undo / Redo:
#   A FlattenHistoryRecord (inner class) holds before/after save_data
#   and a WeakRef to the current wall. undo() / redo() re-run the
#   free-and-LoadWall sequence against the captured dict, updating the
#   WeakRef each time so chained undo/redo across the same flatten
#   keeps pointing at the live wall. The portal DD places after the
#   flatten produces its own native history record; the user therefore
#   needs two Ctrl+Z to undo a full "flatten + place" sequence.
#
# Design constraints:
#  - No mutation during hover. The wall is touched exactly once per
#    placement.
#  - No mutation if the cursor's closest segment is already long
#    enough for the portal — DD handles those untouched.
#  - Skip walls that have a portal in the cut range — v1 doesn't try
#    to preserve portals on partially-trimmed segments.
#  - A click while a reload is still pending is rejected (to avoid
#    queueing two replaces on the same wall instance).

var script_class = "tool"
var _g
var ui_util = null  # set by Main.gd after instantiation

# Custom Snap (snappy_mod) integration — looked up lazily the first
# time we need a snapped position. Same pattern as path_fix.gd.
var _snappy_ref = null
var _snappy_searched := false

# References
var _portal_tool = null
var _tool_panel = null
var _toggle_btn = null
var _enabled = false
var _listener = null

# Anchored / Freestanding mode tracking. The PortalTool's "ANCHORED"
# button is misnamed: pressed == FREESTANDING mode. Flatten only makes
# sense in anchored mode (placing a portal ON a wall). We watch the
# button's pressed state and force-disable the toggle + hide the
# button when freestanding is on.
var _anchored_btn = null

# Hover state (purely visual — never touches the wall).
# Indices are SEGMENT indices: left_seg is the segment containing
# left_point, right_seg is the segment containing right_point. The
# segments are stored in polyline order (left_seg <= right_seg).
# left_point and right_point are in wall-local space.
var _hover_wall = null
var _hover_left_seg = -1
var _hover_right_seg = -1
var _hover_left_point = Vector2.ZERO
var _hover_right_point = Vector2.ZERO

# Manual angle offset applied to the cardinal-snapped tangent. The
# user can scroll the mouse wheel while the overlay is visible to
# fine-tune the chord direction in 1° steps. Reset whenever hover
# leaves a valid target.
var _angle_offset_deg = 0.0

# Overlay
var _overlay_line = null

# Preview dimming
var _preview_dimmed = false
var _preview_orig_modulate = null

# Queue for deferred wall replacements. We never replace the wall
# synchronously during an input event: walls_node is locked while DD
# is dispatching the event, so remove_child / LoadWall crash with
# "Parent node is busy setting up children". Pattern lifted exactly
# from wall_tool_portal_fix.gd's _pending_reload / _deferred_reload_wall:
# scheduled via a 100ms Timer rather than call_deferred or per-frame
# _process counter, because Godot's idle callback can still fire while
# DD is mid-operation on walls_node. The 100ms gap gives DD's C# code
# enough time to fully settle.
var _pending_reload = null
var _pending_reload_tick = 0
var _reload_timer = null
var _last_portal_count = -1
const RELOAD_CHECK_INTERVAL = 0.1

# Tunables
const TICK_INTERVAL = 0.05  # 20 Hz: pure visual, no need for 50 Hz
const GREEN = Color(0.337, 0.918, 0.443, 0.95)
const OVERLAY_WIDTH = 3.0
const OVERLAY_Z = 4096
const DEFAULT_RADIUS = 32.0  # fallback if we can't read the portal radius
const WALL_HOVER_THRESHOLD = 32.0  # pixels in world space
const SNAP_STEP_RAD = PI / 4.0  # 45° — cardinal-angle snap for the chord
const MAX_SEGMENT_SPAN = 30  # limits the exhaustive search around closest_seg
# Multiplier on portal diameter to give DD a small slack when it
# validates that the segment fits the portal. Without margin, DD
# sometimes refuses to place because of sub-pixel rounding.
const CHORD_LENGTH_MULTIPLIER = 1.04


# ─── Init ────────────────────────────────────────────────────────────────────

func initialize():
	_portal_tool = _g.Editor.Tools["PortalTool"]
	if _portal_tool == null:
		print("[FlattenCurves] PortalTool not found")
		return
	var toolset = _g.Editor.get("Toolset")
	if toolset != null and toolset.has_method("GetToolPanel"):
		_tool_panel = toolset.GetToolPanel("PortalTool")
	if _tool_panel == null:
		print("[FlattenCurves] PortalTool panel not found")
		return
	_build_ui()
	_build_listener()
	_build_reload_timer()
	print("[FlattenCurves] Initialized")


# Timer used to defer wall replacements (free + LoadWall). See
# _pending_reload comments above for why a Timer is required.
func _build_reload_timer():
	_reload_timer = Timer.new()
	_reload_timer.wait_time = RELOAD_CHECK_INTERVAL
	_reload_timer.autostart = true
	_reload_timer.connect("timeout", self, "_reload_tick")
	if _g.Editor != null:
		_g.Editor.add_child(_reload_timer)


func _reload_tick():
	if _pending_reload == null or _pending_reload.size() == 0:
		return
	# Check stability of the target wall's portal list. If a portal
	# was added since last tick, DD is mid-way through its AddPortal
	# coroutine (C# async), which leaves the wall in a "busy setting
	# up children" state. We wait until two consecutive ticks see the
	# same portal count.
	var entry = _pending_reload[0]
	var old_wall = entry.get("old_wall")
	if not is_instance_valid(old_wall):
		# Wall is gone — abandon.
		_pending_reload = null
		return
	var portals = old_wall.get("Portals")
	var pcount = 0 if portals == null else portals.size()
	if pcount != _last_portal_count:
		_last_portal_count = pcount
		_pending_reload_tick = 2
		return
	_pending_reload_tick -= 1
	if _pending_reload_tick <= 0:
		_flush_pending_reloads()


func _build_ui():
	var anchored = _find_button_by_text(_tool_panel, "ANCHORED")
	if anchored == null:
		print("[FlattenCurves] ANCHORED button not found")
		return
	_anchored_btn = anchored
	_toggle_btn = CheckButton.new()
	_toggle_btn.text = "Flatten Curves"
	_toggle_btn.connect("toggled", self, "_on_toggled")
	var parent = anchored.get_parent()
	parent.add_child(_toggle_btn)
	parent.move_child(_toggle_btn, anchored.get_index() + 1)
	# Anchored button is misnamed: pressed == freestanding. Watch its
	# state to hide the toggle + force-disable flatten mode whenever
	# freestanding is on.
	if _anchored_btn.has_signal("toggled"):
		_anchored_btn.connect("toggled", self, "_on_anchored_toggled")
	_refresh_anchored_visibility()


# Sync the toggle's visibility / enabled state with the anchored
# button's current state. Called from initialize() and from the
# anchored button's toggled signal.
func _refresh_anchored_visibility() -> void:
	if _toggle_btn == null or not is_instance_valid(_toggle_btn):
		return
	var freestanding = false
	if _anchored_btn != null and is_instance_valid(_anchored_btn):
		freestanding = _anchored_btn.pressed
	_toggle_btn.visible = not freestanding
	if freestanding and _enabled:
		# Force-off when entering freestanding — flatten makes no sense
		# for portals not attached to a wall.
		_toggle_btn.pressed = false  # triggers _on_toggled → _enabled = false


func _on_anchored_toggled(_pressed):
	_refresh_anchored_visibility()


func _find_button_by_text(node, text):
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var found = _find_button_by_text(child, text)
		if found != null:
			return found
	return null


func _build_listener():
	_listener = Node.new()
	_listener.name = "FlattenCurvesListener"
	var listener_script = GDScript.new()
	# Listener attached to the tree root with high priority so we
	# receive mouse wheel events before DD's camera-zoom handler can
	# absorb them. Modeled on light_tool_fix.gd.
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -100
func _process(delta):
	if handler != null:
		handler._on_process(delta)
func _input(event):
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	_listener.set_script(listener_script)
	_listener.handler = self
	if _g.World != null and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree != null and tree.root != null:
			tree.root.call_deferred("add_child", _listener)
		else:
			_g.World.call_deferred("add_child", _listener)


func _on_toggled(pressed):
	_enabled = pressed
	if not pressed:
		_clear_hover()


# ─── Per-frame: hover detection (no wall mutation) ───────────────────────────

var _tick_accum = 0.0

func _on_process(delta):
	_tick_accum += delta
	if _tick_accum < TICK_INTERVAL:
		return
	_tick_accum = 0.0

	if not _enabled or not _is_portal_tool_active():
		_clear_hover()
		return

	# Don't show the green overlay if:
	# • mouse is over UI / popup (blocks interaction with the editor),
	# • freestanding mode is active (flatten irrelevant),
	# • DD is already showing the portal preview (a valid placement
	#   spot — the wall has a long-enough straight segment under the
	#   cursor, our chord would be redundant and visually confusing).
	if _is_mouse_over_ui():
		_clear_hover()
		return
	if _is_freestanding():
		_clear_hover()
		return
	if _dd_has_valid_placement():
		_clear_hover()
		return

	var cursor = _get_cursor_world()
	if cursor == null:
		_clear_hover()
		return

	var target = _find_flatten_target(cursor)
	if target == null:
		_clear_hover()
		return

	# Same target as last tick? Nothing to do.
	if _hover_wall == target.wall \
			and _hover_left_seg == target.left_seg \
			and _hover_right_seg == target.right_seg \
			and _hover_left_point == target.left_point \
			and _hover_right_point == target.right_point:
		return

	_hover_wall = target.wall
	_hover_left_seg = target.left_seg
	_hover_right_seg = target.right_seg
	_hover_left_point = target.left_point
	_hover_right_point = target.right_point
	_show_overlay()
	_dim_preview()


# True when the mouse is over a UI panel or popup. ui_util is supplied
# by Main.gd; if it's missing we can't tell, so we return false (the
# user just loses overlay suppression — clicks are still gated by
# _hover_wall etc.).
func _is_mouse_over_ui() -> bool:
	if ui_util == null or _listener == null:
		return false
	return ui_util.is_mouse_over_ui(_listener)


# True when DD's PortalTool has located a valid placement spot at
# the current cursor. The C# property `foundLocation` (documented in
# the modding API) is set by DD whenever its own placement check
# succeeds — i.e. there's a wall segment under the cursor where the
# native portal placement would work. In that case our chord overlay
# is redundant and visually confusing, so we hide it.
func _dd_has_valid_placement() -> bool:
	if _portal_tool == null:
		return false
	var v = _portal_tool.get("foundLocation")
	return v == true


# True when PortalTool is in freestanding mode (placing portals not
# attached to any wall). Flatten makes no sense in this mode.
# `Freestanding` is the documented PortalTool property; we still also
# watch the ANCHORED button (whose `pressed` state mirrors this same
# flag) to hide the toggle UI and force-disable the mod when entering
# freestanding from the panel.
func _is_freestanding() -> bool:
	if _portal_tool == null:
		return false
	var v = _portal_tool.get("Freestanding")
	return v == true


# Public: True when the user is currently hovering a valid flatten
# target (i.e. the green overlay is shown). Other mods (asset_cycle)
# query this to suppress their own shift+wheel handling while the
# user is fine-tuning a chord with the mouse wheel.
func has_active_hover() -> bool:
	return _enabled and _hover_wall != null and is_instance_valid(_hover_wall)


# Resolve a world position to its snapped equivalent. Returns null if
# no snap source is available (caller should treat that as "snap off").
#
# Custom Snap (snappy_mod) wins over DD's native grid when:
#   • it's detected (via Global.API or a toolbar scan)
#   • its tool is enabled (custom_snap_enabled)
#   • its custom grid is enabled (custom_grid_enabled)
# In any other case we fall back to DD's WorldUI.GetSnappedPosition.
# Note: snappy_mod's own get_snapped_position() already falls back to
# the native grid when custom_snap_enabled is off, but we gate on
# custom_grid_enabled here too because users may want Custom Snap's
# offsets without its grid (in which case we follow snappy_mod's own
# combined-state convention — see line 820 of snappy_mod.gd).
func _get_snapped_position(world_pos):
	var snappy = _get_snappy_mod()
	if snappy != null \
			and snappy.get("custom_snap_enabled") == true \
			and snappy.get("custom_grid_enabled") == true:
		return snappy.get_snapped_position(world_pos)
	if _g.WorldUI != null and _g.WorldUI.has_method("GetSnappedPosition"):
		return _g.WorldUI.GetSnappedPosition(world_pos)
	return null


# Locate the Custom Snap (snappy_mod) instance, caching the result.
# Pattern lifted from path_fix.gd: prefer Global.API.snappy_mod (the
# clean registration channel exposed by snappy_mod via _Lib), fall
# back to scanning the editor's toolbars for a node with the
# get_snapped_position method (catches setups where _Lib isn't
# loaded).
func _get_snappy_mod():
	if _snappy_ref != null:
		return _snappy_ref
	if _snappy_searched:
		return null
	_snappy_searched = true

	var api = _g.get("API")
	if api != null and typeof(api) == TYPE_OBJECT:
		var s = api.get("snappy_mod")
		if s != null and s.has_method("get_snapped_position"):
			_snappy_ref = s
			return s

	var toolset = _g.Editor.get("Toolset")
	if toolset != null:
		var toolbars = toolset.get("Toolbars")
		if toolbars != null and toolbars is Dictionary:
			for key in toolbars.keys():
				var toolbar = toolbars[key]
				if toolbar is Node:
					var found = _find_snappy_from_panel(toolbar)
					if found != null:
						_snappy_ref = found
						return found
	return null


func _find_snappy_from_panel(node):
	if node == null or not is_instance_valid(node) or not (node is Node):
		return null
	if node is BaseButton:
		for sig_name in ["pressed", "toggled"]:
			var connections = node.get_signal_connection_list(sig_name)
			for conn in connections:
				var target = conn.get("target")
				if target != null and target.has_method("get_snapped_position"):
					return target
	for child in node.get_children():
		var found = _find_snappy_from_panel(child)
		if found != null:
			return found
	return null


# ─── Input: intercept click in green zone, flatten and propagate ─────────────

func _on_input(event):
	if not _enabled:
		return
	if not (event is InputEventMouseButton):
		return
	if not _is_portal_tool_active():
		return

	# Mouse wheel — fine-tune chord angle while the overlay is
	# visible. Step is 1° normally, 5° with Shift. Ctrl+wheel is
	# camera zoom — we never intercept it.
	#
	# We do NOT consume wheel events: set_input_as_handled() on a
	# wheel crashes DD's PortalTool C# handler. Instead, asset_cycle
	# coordinates with us via has_active_hover() and skips its own
	# shift+wheel handling while we have a live chord.
	if event.button_index == BUTTON_WHEEL_UP \
			or event.button_index == BUTTON_WHEEL_DOWN:
		if Input.is_key_pressed(KEY_CONTROL):
			return
		# Only process the release half — DD fires the wheel as both
		# press and release on the same notch, and we'd otherwise
		# double-count.
		if event.pressed:
			return
		if _hover_wall != null and is_instance_valid(_hover_wall):
			var step = 5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
			var delta = step if event.button_index == BUTTON_WHEEL_UP else -step
			_angle_offset_deg += delta
			# Force re-evaluation on the next tick so the overlay
			# updates immediately rather than waiting for cursor move.
			_tick_accum = TICK_INTERVAL
		return

	if event.button_index != BUTTON_LEFT or not event.pressed:
		return
	if _hover_wall == null or not is_instance_valid(_hover_wall):
		return
	if _hover_left_seg < 0 or _hover_right_seg < 0:
		return
	# Defensive: same gates as the hover loop. _hover_wall is normally
	# cleared by _on_process when these conditions fire, but the click
	# could land on the same frame the user moved over a popup.
	if _is_mouse_over_ui():
		return
	if _is_freestanding():
		return
	if _dd_has_valid_placement():
		return

	# Reject clicks while a reload is pending. If the user clicks again
	# before the timer has flushed the previous flatten, we'd queue two
	# replaces against the same wall instance — the second one would
	# crash with "Parent node is busy" when remove_child/free are
	# called on the already-freed node.
	if _pending_reload != null and _pending_reload.size() > 0:
		return

	# Queue the flatten. We do NOT consume the click:
	# set_input_as_handled() crashes DD's PortalTool C# code. So DD
	# sees the same click — its handler tries to place a portal on
	# the still-curved wall and fails silently (vanilla behavior).
	# ~200ms later, the timer flattens the wall. The user's NEXT
	# click on the now-flat segment places the portal via DD's path.
	_apply_flatten()


func _apply_flatten() -> void:
	var wall = _hover_wall
	var left_seg = _hover_left_seg
	var right_seg = _hover_right_seg
	var left_point = _hover_left_point
	var right_point = _hover_right_point
	if not is_instance_valid(wall):
		_clear_hover()
		return
	var pts = wall.get("Points")
	if pts == null:
		_clear_hover()
		return
	if left_seg < 0 or right_seg < 0 or right_seg >= pts.size() - 1 \
			or left_seg + 1 >= pts.size():
		_clear_hover()
		return

	# Build the new polyline:
	#   pts[0..left_seg] + B1 + B2 + pts[right_seg+1..end]
	var new_pool = PoolVector2Array()
	for i in range(left_seg + 1):
		new_pool.append(pts[i])
	new_pool.append(left_point)
	new_pool.append(right_point)
	for i in range(right_seg + 1, pts.size()):
		new_pool.append(pts[i])

	# Build before/after save_data dicts synchronously. The actual
	# wall replacement (free + LoadWall) is queued for the timer:
	# walls_node is locked during input dispatch.
	var walls_node = wall.get_parent()
	if walls_node == null or not wall.has_method("Save") \
			or not walls_node.has_method("LoadWall"):
		_clear_hover()
		return
	var before_save = wall.Save()
	if before_save == null:
		_clear_hover()
		return
	var is_loop = wall.get("Loop")
	if is_loop == null:
		is_loop = false
	var after_save = _build_after_save(before_save, new_pool, is_loop)
	if after_save == null or after_save.size() == 0:
		_clear_hover()
		return

	# Queue the reload. The Timer's _reload_tick waits until the wall's
	# portal count has been stable for two consecutive ticks (~200ms)
	# before flushing — this absorbs the lag of DD's AddPortal C#
	# coroutine that keeps the wall in a transitional state after a
	# user-placed portal.
	if _pending_reload == null:
		_pending_reload = []
	_pending_reload.append({
		"walls_node": walls_node,
		"old_wall": wall,
		"before_save": before_save,
		"after_save": after_save,
	})
	var portals_now = wall.get("Portals")
	_last_portal_count = 0 if portals_now == null else portals_now.size()
	_pending_reload_tick = 2

	_clear_hover()


func _flush_pending_reloads() -> void:
	var reloads = _pending_reload
	_pending_reload = null
	if reloads == null:
		return
	for entry in reloads:
		# Defer each replace via call_deferred for an extra safety margin:
		# walls_node may still be busy from DD's portal placement even
		# after the stability check passed. call_deferred runs the
		# replace on the next idle frame.
		call_deferred("_deferred_replace_one", entry)


func _deferred_replace_one(entry: Dictionary) -> void:
	var walls_node = entry["walls_node"]
	var old_wall = entry["old_wall"]
	if not is_instance_valid(walls_node):
		return
	if not is_instance_valid(old_wall):
		return
	var new_wall = _replace_wall(walls_node, old_wall, entry["after_save"])
	if new_wall == null:
		return
	_record_flatten(walls_node, new_wall,
			entry["before_save"], entry["after_save"])


# ─── Wall save_data manipulation ─────────────────────────────────────────────


# Returns a new save_data dict with the requested points and with every
# portal entry's point_index / wall_distance / direction / rotation
# recomputed against `new_pool`. Position fields stay as-is — the
# portals' physical locations don't move during a flatten.
#
# We do NOT add the new portal here. DD's PortalTool will place it
# itself on the user's next click after the wall is flattened.
# Synthesizing a portal entry into save_data crashes DD's C# code
# during LoadWall hydration (the texture field expects a typed
# C# reference we can't reliably forge from GDScript).
func _build_after_save(before_save: Dictionary, new_pool: PoolVector2Array,
		is_loop: bool) -> Dictionary:
	if new_pool.size() < 2:
		return Dictionary()
	var after_save = before_save.duplicate(true)
	after_save["points"] = var2str(new_pool)

	var portals_save = after_save.get("portals", [])
	var updated: Array = []
	for entry in portals_save:
		if typeof(entry) != TYPE_DICTIONARY:
			updated.append(entry)
			continue
		var pd: Dictionary = entry.duplicate()
		var pos = _deserialize_vec2(pd.get("position", null))
		if pos == null:
			updated.append(pd)
			continue
		var proj = _project_on_polyline(pos, new_pool, is_loop)
		var sdv: Vector2 = proj["direction"]
		pd["point_index"] = proj["index"]
		pd["wall_distance"] = float(proj["index"]) + proj["frac"]
		pd["direction"] = var2str(sdv)
		pd["rotation"] = atan2(sdv.y, sdv.x)
		updated.append(pd)
	after_save["portals"] = updated
	return after_save


# Free `old_wall` and call walls_node.LoadWall(save_data). Returns the
# new wall node, or null on failure.
#
# Replacement sequence — order matters:
#   1. Probe walls_node with an add/remove of a fresh Node. If
#      walls_node is "busy setting up children" (e.g. mid-way through
#      DD's AddPortal C# coroutine), the probe fails and we bail out
#      rather than crash later.
#   2. Same probe on old_wall itself. The wall has its own children
#      (portals + internal Line2D's) and can also be transitionally
#      busy.
#   3. Detach + free every portal currently on the wall. Their
#      tree_exiting notifications fire when we later remove the wall,
#      and DD's C# side effects on those notifications cascade into
#      "busy" flags on walls_node — which crashes any subsequent
#      operation in the same call stack. LoadWall will recreate all
#      portals from save_data anyway, so we don't need to preserve
#      the live nodes.
#   4. remove_child + free old_wall.
#   5. walls_node.LoadWall(save_data) recreates a fresh wall + portals.
#   6. RemakeLines() so the new wall renders correctly (portal holes
#      cut into the Line2D children).
#
# All probes / aborts return null silently. Callers (mainly
# _deferred_replace_one) bail without recording a history entry or
# touching state further when this returns null.
func _replace_wall(walls_node, old_wall, save_data):
	if walls_node == null or not is_instance_valid(walls_node):
		return null
	# Probe walls_node.
	var probe = Node.new()
	walls_node.add_child(probe)
	if probe.get_parent() != walls_node:
		probe.free()
		return null
	walls_node.remove_child(probe)
	probe.free()

	if old_wall != null and is_instance_valid(old_wall):
		# Probe the wall itself.
		var wprobe = Node.new()
		old_wall.add_child(wprobe)
		if wprobe.get_parent() != old_wall:
			wprobe.free()
			return null
		old_wall.remove_child(wprobe)
		wprobe.free()

		# Detach + free portals BEFORE removing the wall (see comment
		# above). The list is copied because we mutate the wall's
		# child set inside the loop.
		var portals_list = old_wall.get("Portals")
		if portals_list != null:
			var to_remove = []
			for p in portals_list:
				if is_instance_valid(p):
					to_remove.append(p)
			for p in to_remove:
				if p.get_parent() != null:
					p.get_parent().remove_child(p)
				p.free()

		if old_wall.get_parent() == walls_node:
			walls_node.remove_child(old_wall)
			if old_wall.get_parent() != null:
				return null
		old_wall.free()

	walls_node.LoadWall(save_data)
	var new_wall = walls_node.get_child(walls_node.get_child_count() - 1)
	if is_instance_valid(new_wall) and new_wall.has_method("RemakeLines"):
		new_wall.RemakeLines()
	return new_wall


# Project a point onto the polyline and return its closest segment data:
#   { index, frac (clamped to [0.01, 0.99]), direction (unit vector) }
func _project_on_polyline(pos: Vector2, points: PoolVector2Array,
		is_loop: bool) -> Dictionary:
	var n = points.size()
	var num_segs = n if is_loop else max(n - 1, 0)
	var best_i = 0
	var best_t = 0.5
	var best_d2 = INF
	var best_dir = Vector2.RIGHT
	for i in range(num_segs):
		var A = points[i]
		var B = points[(i + 1) % n]
		var seg = B - A
		var len2 = seg.length_squared()
		if len2 < 0.0001:
			continue
		var raw_t = (pos - A).dot(seg) / len2
		var t = clamp(raw_t, 0.0, 1.0)
		var d2 = pos.distance_squared_to(A + seg * t)
		if d2 < best_d2:
			best_d2 = d2
			best_i = i
			best_t = t
			best_dir = seg.normalized()
	return {
		"index": best_i,
		"frac": clamp(best_t, 0.01, 0.99),
		"direction": best_dir,
	}


# Decode a position field from save_data: it may be a var2str'd Vector2
# or already a Vector2.
func _deserialize_vec2(v):
	if v == null:
		return null
	if typeof(v) == TYPE_VECTOR2:
		return v
	if typeof(v) == TYPE_STRING:
		var parsed = str2var(v)
		if typeof(parsed) == TYPE_VECTOR2:
			return parsed
	return null


# ─── Undo / Redo ─────────────────────────────────────────────────────────────
#
# Each flatten records a custom history entry holding the before/after
# save_data dicts and a WeakRef to the current wall. Undo and redo both
# re-run the free-and-LoadWall sequence against the captured dict; the
# WeakRef is updated each time so chained undo/redo across the same
# flatten keeps pointing at the live wall.

# Inner class — DD's History.CreateCustomRecord accepts any Reference
# subclass with `undo()` / `redo()` methods. Matches the pattern in
# custom_history_record.gd.
class FlattenHistoryRecord extends Reference:
	var walls_node = null
	var wall_ref: WeakRef = null
	var before_save = null
	var after_save = null
	var main_script = null

	func _resolve_wall():
		if wall_ref == null:
			return null
		var w = wall_ref.get_ref()
		if w == null or not is_instance_valid(w):
			return null
		return w

	func _apply(save_data):
		if main_script == null:
			return
		if walls_node == null or not is_instance_valid(walls_node):
			return
		var wall = _resolve_wall()
		if wall == null:
			return
		var new_wall = main_script._replace_wall(walls_node, wall, save_data)
		if new_wall != null:
			wall_ref = weakref(new_wall)

	func undo():
		_apply(before_save)

	func redo():
		_apply(after_save)


func _record_flatten(walls_node, wall, before_save, after_save) -> void:
	if _g.Editor == null or _g.Editor.get("History") == null:
		return
	var record = FlattenHistoryRecord.new()
	record.main_script = self
	record.walls_node = walls_node
	record.wall_ref = weakref(wall)
	record.before_save = before_save
	record.after_save = after_save
	_g.Editor.History.CreateCustomRecord(record)


# ─── Find the flatten target ─────────────────────────────────────────────────

# Returns { wall, left_seg, right_seg, left_point, right_point } or null.
#
# Strategy: pick the cardinal line CLOSEST TO THE CURSOR and place two
# new points B1, B2 on it, separated by `needed`, centered on the
# cursor's projection onto the line. The new wall is:
#     pts[0..left_seg] + B1 + B2 + pts[right_seg+1..end]
# where left_seg/right_seg are the wall segments whose td-projection
# range contains B1/B2 respectively. The short segments pts[left_seg]→B1
# and B2→pts[right_seg+1] are the connecting "raccords"; they're short
# because the line is right next to the cursor (which is near the wall).
#
# When DD's Editor.IsSnapping is on, the line is the closest cardinal
# GRID line to the cursor (passing through GetSnappedPosition(cursor)).
# When snap is off, the line passes through the cursor itself (no grid
# constraint).
func _find_flatten_target(cursor_world):
	var radius = _get_portal_radius()
	if radius <= 0.0:
		return null
	var needed = radius * 2.0 * CHORD_LENGTH_MULTIPLIER

	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	var walls_node = level.get("Walls")
	if walls_node == null:
		return null

	var snap_on = false
	var snap_world = cursor_world
	if _g.Editor != null and _g.Editor.get("IsSnapping") == true:
		var snapped = _get_snapped_position(cursor_world)
		if snapped != null:
			snap_on = true
			snap_world = snapped

	var best = null
	var best_score = INF

	for child in walls_node.get_children():
		if not is_instance_valid(child) or not child.has_method("RemakeLines"):
			continue
		var wtype = child.get("Type")
		if wtype == null or wtype != 1:  # only manual walls
			continue
		var pts = child.get("Points")
		if pts == null or pts.size() < 3:
			continue

		var local_cursor = cursor_world - child.global_position

		# Closest segment to cursor — its tangent informs the cardinal
		# direction.
		var closest_seg = -1
		var closest_dist = INF
		for i in range(pts.size() - 1):
			var d = _point_to_segment_distance(local_cursor, pts[i], pts[i + 1])
			if d < closest_dist:
				closest_dist = d
				closest_seg = i

		if closest_seg < 0 or closest_dist > WALL_HOVER_THRESHOLD:
			continue

		# Skip if a single segment already fits the portal — let DD handle it.
		var seg_len = pts[closest_seg].distance_to(pts[closest_seg + 1])
		if seg_len >= needed:
			continue

		# Cardinal direction = closest segment's tangent, snapped to nearest
		# 45° multiple, and oriented to match the polyline direction so
		# walking by increasing index goes in +td. Then apply any
		# user-supplied fine angle offset (mouse wheel, 1° steps).
		var seg_dir = (pts[closest_seg + 1] - pts[closest_seg]).normalized()
		var tangent_angle = atan2(seg_dir.y, seg_dir.x)
		var cardinal_angle = round(tangent_angle / SNAP_STEP_RAD) * SNAP_STEP_RAD
		var td = Vector2(cos(cardinal_angle), sin(cardinal_angle))
		if td.dot(seg_dir) < 0.0:
			td = -td
		if _angle_offset_deg != 0.0:
			td = td.rotated(deg2rad(_angle_offset_deg))

		# Chord midpoint M:
		# - snap on: directly the grid intersection (M = snap_local), so
		#   the green line is centered on the snap point and stops
		#   sliding along the grid as the cursor moves.
		# - snap off: the cursor itself.
		var M
		if snap_on:
			M = snap_world - child.global_position
		else:
			M = local_cursor

		# Place B1, B2 on the line at ±needed/2 from M.
		var half = needed * 0.5
		var B1 = M - td * half
		var B2 = M + td * half

		# Find which wall segments contain B1 and B2 along td. Walk
		# from closest_seg outward in each direction.
		var n_pts = pts.size()
		var b1_td = B1.dot(td)
		var b2_td = B2.dot(td)

		var left_seg = closest_seg
		while left_seg > 0 and pts[left_seg].dot(td) > b1_td:
			left_seg -= 1
		# If we hit pts[0] and B1 is still further out, the wall is too
		# short on this side — abandon.
		if pts[left_seg].dot(td) > b1_td:
			continue

		var right_seg = closest_seg
		while right_seg < n_pts - 2 and pts[right_seg + 1].dot(td) < b2_td:
			right_seg += 1
		if pts[right_seg + 1].dot(td) < b2_td:
			continue

		# Sanity: left_seg should be before right_seg in polyline order
		# (otherwise the mutation logic gets confused).
		if left_seg > right_seg:
			continue

		# Abandon if a portal sits in the cut range.
		if _portal_in_range(child, left_seg, right_seg):
			continue

		# Score by midpoint distance to cursor across walls.
		var score = M.distance_to(local_cursor)
		if score < best_score:
			best_score = score
			best = {
				"wall": child,
				"left_seg": left_seg,
				"right_seg": right_seg,
				"left_point": B1,
				"right_point": B2,
			}

	return best


func _portal_in_range(wall, left_seg, right_seg):
	var portals = wall.get("Portals")
	if portals == null:
		return false
	for portal in portals:
		if not is_instance_valid(portal):
			continue
		var wpi = portal.get("WallPointIndex")
		if wpi != null and wpi >= left_seg and wpi <= right_seg:
			return true
	return false


# ─── Overlay management ──────────────────────────────────────────────────────

func _show_overlay():
	if _overlay_line == null or not is_instance_valid(_overlay_line):
		_overlay_line = Line2D.new()
		_overlay_line.name = "FlattenCurvesOverlay"
		_overlay_line.width = OVERLAY_WIDTH
		_overlay_line.default_color = GREEN
		_overlay_line.z_index = OVERLAY_Z
		_overlay_line.antialiased = true
		if _g.World != null:
			_g.World.add_child(_overlay_line)
		else:
			return

	if not is_instance_valid(_hover_wall):
		return

	# Show only the chord (straight line from left_point to right_point).
	# Both endpoints lie on existing wall segments, so the splice is
	# smooth — no need to draw connection segments.
	var origin = _hover_wall.global_position
	var pool = PoolVector2Array()
	pool.append(_hover_left_point + origin)
	pool.append(_hover_right_point + origin)
	_overlay_line.points = pool
	_overlay_line.visible = true


func _hide_overlay():
	if _overlay_line != null and is_instance_valid(_overlay_line):
		_overlay_line.queue_free()
	_overlay_line = null


func _clear_hover():
	if _hover_wall != null:
		_hover_wall = null
		_hover_left_seg = -1
		_hover_right_seg = -1
		_hover_left_point = Vector2.ZERO
		_hover_right_point = Vector2.ZERO
	_angle_offset_deg = 0.0
	_hide_overlay()
	_restore_preview()


# ─── Portal preview dimming ──────────────────────────────────────────────────

func _dim_preview():
	if _preview_dimmed:
		return
	var preview = _get_preview_node()
	if preview == null:
		return
	_preview_orig_modulate = preview.get("modulate")
	if _preview_orig_modulate == null:
		return
	var c = Color(_preview_orig_modulate.r, _preview_orig_modulate.g, _preview_orig_modulate.b, 0.35)
	preview.set("modulate", c)
	_preview_dimmed = true


func _restore_preview():
	if not _preview_dimmed:
		return
	var preview = _get_preview_node()
	if preview != null and _preview_orig_modulate != null:
		preview.set("modulate", _preview_orig_modulate)
	_preview_orig_modulate = null
	_preview_dimmed = false


func _get_preview_node():
	if _g.WorldUI == null:
		return null
	var preview = _g.WorldUI.get("Texture")
	if preview != null and is_instance_valid(preview):
		return preview
	return null


# ─── Helpers ─────────────────────────────────────────────────────────────────

func _is_portal_tool_active():
	if _tool_panel == null or not is_instance_valid(_tool_panel):
		return false
	return _tool_panel.visible


func _get_cursor_world():
	if _g.WorldUI != null:
		return _g.WorldUI.get("MousePosition")
	return null


# Tries multiple paths to read the radius of the portal that DD would
# place at the cursor. Falls back to DEFAULT_RADIUS.
var _last_logged_radius = -1.0

func _get_portal_radius():
	var r = _try_read_radius()
	if abs(r - _last_logged_radius) > 0.5:
		_last_logged_radius = r
		print("[FlattenCurves] portal radius resolved to: ", r)
	return r


func _try_read_radius():
	# Path 1: WorldUI preview UITexture might expose Radius.
	var preview = _get_preview_node()
	if preview != null:
		var r = preview.get("Radius")
		if r != null and (typeof(r) == TYPE_REAL or typeof(r) == TYPE_INT) and float(r) > 0.0:
			return float(r)
	# Path 2: PortalTool itself might expose Radius.
	if _portal_tool != null:
		var r = _portal_tool.get("Radius")
		if r != null and (typeof(r) == TYPE_REAL or typeof(r) == TYPE_INT) and float(r) > 0.0:
			return float(r)
		# Some tools store width / size instead.
		for prop_name in ["Width", "Size", "DefaultRadius", "PortalRadius"]:
			var v = _portal_tool.get(prop_name)
			if v != null and (typeof(v) == TYPE_REAL or typeof(v) == TYPE_INT) and float(v) > 0.0:
				return float(v) * 0.5 if prop_name in ["Width", "Size"] else float(v)
	# Path 3: read from any existing portal on the map.
	var level = _g.World.GetCurrentLevel()
	if level != null:
		var walls = level.get("Walls")
		if walls != null:
			for w in walls.get_children():
				if not is_instance_valid(w):
					continue
				var portals = w.get("Portals")
				if portals != null:
					for p in portals:
						if is_instance_valid(p):
							var r = p.get("Radius")
							if r != null and float(r) > 0.0:
								return float(r)
	return DEFAULT_RADIUS


func _point_to_segment_distance(p, a, b):
	var ab = b - a
	var len2 = ab.dot(ab)
	if len2 < 0.0001:
		return p.distance_to(a)
	var t = (p - a).dot(ab) / len2
	t = clamp(t, 0.0, 1.0)
	var proj = a + ab * t
	return p.distance_to(proj)


# ─── Cleanup ─────────────────────────────────────────────────────────────────

func cleanup():
	_clear_hover()
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.queue_free()
	if _listener != null and is_instance_valid(_listener):
		_listener.queue_free()
	if _reload_timer != null and is_instance_valid(_reload_timer):
		_reload_timer.queue_free()
