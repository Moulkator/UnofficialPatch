var _g  # injected by UnofficialPatch
var _pending_emitter = null
var _input_listener = null  # the emitter Node, used as Node arg for ui_util.is_mouse_over_ui
var ui_util = null          # set externally by Main.gd, used to skip box manipulation when over a UI panel
#########################################################################################################
##
## DragSelectWalls MOD
## - Real-time wall highlighting during drag selection
## - Walls added to DD's existing selection after DD finishes
## - Group transform: walls follow DD items when the transform box is moved,
##   rotated or scaled. Walls' Points (and portal/sprite positions) are
##   transformed; wall texture / sprite scale is intentionally NOT changed,
##   so a "scale" only moves wall points closer/further from the pivot.
## - Transform box expansion: when walls + non-walls are selected, the
##   transform box is expanded to wrap an AABB we compute ourselves
##   (walls' Points + non-wall positions/Pathway-Points) — DD's
##   GetSelectionRect is unreliable after rotations / item moves.
##
#########################################################################################################

var script_class = "tool"

var select_tool = null

# --- Drag-select state ---
var _was_drawing := false
var _last_box_begin = Vector2.ZERO
var _last_box_end = Vector2.ZERO
var _highlighted_walls := []
var _highlighted_portals := []
var _deferred_frames := -1
var _deferred_box_start = Vector2.ZERO
var _deferred_box_end = Vector2.ZERO
# Shift+Alt drag-select box → deselect (remove from selection) instead
# of adding. Mirrors alt_deselect.gd's Shift+Alt box-deselect combo,
# which only handles native assets and never touches walls/portals.
# _drag_deselect_sampled is refreshed each drawing frame; _deferred_deselect
# latches the intent at drag end for the deferred selection pass.
var _drag_deselect_sampled := false
var _deferred_deselect := false

# --- Group-transform state ---
var _transforming := false
var _ref_item = null              # A non-wall DD item we track for delta
var _drag_mode := 0               # 0=none, 1=Move, 2=Rotate, 3=Scale
var _ref_pre_pos := Vector2.ZERO  # Ref item's global_position at drag start
var _ref_pre_rot := 0.0           # Ref item's global_rotation at drag start
var _ref_pre_scale := Vector2.ONE # Ref item's global_scale at drag start
var _pivot := Vector2.ZERO        # World-space pivot for rotate/scale
var _move_walls := []             # Walls being transformed
var _move_snapshots := {}         # {wall: {pts, portals, portal_rots, children}}

# --- Visual overlay + custom interaction state ---
# DD's GetSelectionRect bug: for mixed wall+prop selections after a prop
# move, DD's box wraps only the wall. We replace DD's box entirely with
# our own that:
#   - draws the correct AABB outline + corner/edge handles
#   - hides DD's native box (EnableTransformBox(false)) while active
#   - intercepts mouse events on its handles for move / rotate / scale
var _overlay = null
var _last_combined: Rect2 = Rect2()  # axis-aligned world AABB of the (possibly rotated) box; .center == _box_pos
var _dd_box_hidden_by_us: bool = false
# True once we've re-issued EnableTransformBox(false) for the current DD
# transform (transformMode > 0). Reset as soon as the transform ends.
var _dd_box_hidden_during_tm: bool = false
var _mouse_world: Vector2 = Vector2.ZERO

# Locked box state — the box rotates with the content during transforms,
# instead of being recomputed as a fresh AABB every frame. This matches
# DD's native transform-box behavior: the box only "snaps" to a fresh
# axis-aligned AABB when the SELECTION changes (different items chosen).
# As long as the same items remain selected, the box's _pos / _rotation /
# _half_size are updated by the transform itself, never recomputed from
# the items' AABB.
var _box_pos: Vector2 = Vector2.ZERO        # world position of the box center
var _box_rotation: float = 0.0              # box rotation, radians (0 = axis-aligned)
var _box_half_size: Vector2 = Vector2.ZERO  # half-width / half-height in box-local frame
var _box_initialized: bool = false          # false when the box needs to re-fit to a fresh AABB
# Geometry watchdog. The locked box only re-fits on a SELECTION change, so
# anything that edits the selected walls WITHOUT going through our transform
# API (wall_move's click-drag, curve edit, undo/redo, ...) used to leave the
# box stranded at the old location. We hash the walls' geometry each frame
# and re-fit when it moves under us. Our OWN edits all funnel through
# _apply_transform_to_wall, which stamps _geo_owned_frame — those are ignored
# so a move / rotate / scale of ours keeps the locked box (and its rotation).
var _wall_geo_sig: int = 0
var _geo_owned_frame: int = -1000
# Instant drag de DD (clic-glisser direct sur un asset, sans passer par la
# transform box) : CheckForInstantDrag remplit movableThings avec TOUS les
# membres du groupe via GetGrouped(), walls compris, puis les deplace en
# ecrivant Thing.Position. Or un Wall ne porte pas sa geometrie dans sa
# position : ses Points sont en coordonnees monde et le node reste a
# l'origine. Le rendu suit (les Line2D enfants sont en local) mais les Points
# ne bougent pas — donc la box reste en arriere, et surtout Wall.Save()
# n'ecrit pas la position du node : le deplacement serait perdu au rechargement.
# On convertit donc la translation du node en vraie geometrie a chaque frame.
var _dd_pos_drag_snaps: Dictionary = {}   # wall -> snapshot pre-drag
var _dd_pos_drag_active: bool = false
var _dd_drag_delta: Dictionary = {}      # wall -> derniere translation totale lue
# Diagnostic temporaire (a retirer une fois le drag valide).
var _dd_diag_done: bool = false
var _dd_diag_frames: int = 0
var _dd_diag_last_pos: Vector2 = Vector2.ZERO
var _dd_diag_last_pt: Vector2 = Vector2.ZERO
# Le bake de l'instant drag ne tourne plus dans _process mais dans
# frame_pre_draw (cf. on_frame_pre_draw). _dd_bake_ok est la porte ouverte
# par _on_process_impl pour la frame courante ; _dd_dbg_proc_pos memorise la
# position du node telle que _process la voyait, pour comparer avec celle lue
# juste avant le rendu et prouver l'ordre d'execution.
var _dd_bake_ok: bool = false
var _dd_dbg_proc_pos: Vector2 = Vector2.ZERO
var _last_selection_set: Dictionary = {}    # set of selected Thing.get_instance_id() — used to detect selection change

# Custom-interaction drag state. _ci_mode: 0=none 1=move 2=rotate 3=scale.
# For scale, _ci_corner is the grabbed corner (0=TL,1=TR,2=BR,3=BL).
# Scale is uniform — we project the mouse vector onto the diagonal so
# the box keeps its initial aspect ratio. For rotate, _ci_initial_angle
# / _ci_last_angle / _ci_total_rot track the cumulative rotation across
# frames, with each frame's delta wrapped to [-PI, PI] so crossing the
# ±180° boundary doesn't cause a 360° jump.
var _ci_mode: int = 0
var _ci_corner: int = -1
var _ci_drag_start_world: Vector2 = Vector2.ZERO
var _ci_initial_rect: Rect2 = Rect2()
var _ci_initial_angle: float = 0.0
var _ci_last_angle: float = 0.0     # mouse angle from pivot at previous frame
var _ci_total_rot: float = 0.0      # accumulated rotation in radians
var _ci_pivot: Vector2 = Vector2.ZERO
# Pivot actually used for the current scale frame. Equal to _ci_pivot
# (opposite corner) by default, switches to box center while Alt is
# held during a scale drag. Captured by _custom_compute_W and read by
# _custom_apply_W to keep the box state in sync with the items.
var _ci_effective_pivot: Vector2 = Vector2.ZERO
# Signed box-local-frame scale factors for the current scale frame.
# Stashed by _custom_compute_W and read by _custom_apply_W so the box
# state (half-size, position) updates correctly even under non-uniform
# Shift+drag where extracting them from W's basis lengths is ambiguous
# on a rotated box.
var _ci_scale_sx: float = 1.0
var _ci_scale_sy: float = 1.0
# Whether Shift was held this frame during a scale drag. Tracked
# explicitly (not derived from sx vs sy) because the user can hold
# Shift while the mouse happens to lie on the diagonal, making sx ≈ sy
# by coincidence — which would otherwise make _custom_apply_W's
# uniform-vs-non-uniform branch flip intermittently.
var _ci_shift_held: bool = false
var _ci_things: Array = []  # [{thing, type, snap}, ...]
var _ci_tt = null           # instance text_transform si des textes suivent ce drag
var _last_tt_sig := 0       # signature de la sélection de textes (re-fit de la box)
# List of {node, was_visible} for dashed selection-indicator children
# we hid during the drag; restored when the drag ends. Identified by
# their `dotted_line.png` texture path. Hiding them avoids a desync
# between the dashed line and the deformed path/pattern shape under
# non-uniform scale, which can be exacerbated by other mods (path_fix
# in particular calls SetEditPoints / Smooth-related logic on its own).
var _ci_dashed_hidden: Array = []
# Box state snapshot at drag start — lets us apply absolute-from-start
# transforms each frame (no numerical drift via incremental update of
# the box state itself).
var _ci_box_pos_initial: Vector2 = Vector2.ZERO
var _ci_box_rotation_initial: float = 0.0
var _ci_box_half_size_initial: Vector2 = Vector2.ZERO
var _ci_box_corner_initial: Vector2 = Vector2.ZERO  # initial world position of the dragged corner (scale only)

const OVERLAY_COLOR = Color(0.18, 0.62, 1.0, 0.95)
# Wall drag-highlight tints: blue while the box will SELECT walls,
# red while a Shift+Alt box will REMOVE them from the selection.
const HIGHLIGHT_SELECT_COLOR = Color(0.5, 0.7, 1.0, 1.0)
const HIGHLIGHT_DESELECT_COLOR = Color(1.0, 0.5, 0.5, 1.0)
const OVERLAY_WIDTH = 2.0
const HANDLE_SCREEN_PX = 23.0   # default handle visual size (DD's handle_round.png is 23x23)
const HANDLE_LINE_WIDTH = 2.0   # thickness of the white square outline at zoom=1
const HANDLE_ZOOM_BLEND = 0.5   # matches free_transform's sqrt(zoom) handle scaling
const CORNER_HIT_RADIUS_PX = 23.0   # scale hit zone half-side around each corner — square 46x46 zone in screen pixels (per DD UX)
const ROTATE_BAND_PX = 64.0         # rotate hit zone radius around the entire box (per DD UX, beyond resize)
# Snap angle for Shift+drag rotation in our custom box. Matches
# rotation_snap.gd's SNAP_DEG so user gets consistent feel between
# native (Shift+rotate-handle drag) and custom-overlay rotate drag.
const CUSTOM_ROTATE_SNAP_DEG = 45.0

# Debug: draw translucent yellow squares for the corner scale zones and
# a translucent cyan halo for the rotate band. Set to true to re-enable
# for future hit-zone tuning.
const DEBUG_DRAW_ZONES = false

# Discovered at runtime: DD's own handle size (in pixels at zoom=1) read
# from handle_round.png's natural dimensions. Used to size our overlay
# handles so they match DD's actual hit zones. Falls back to
# HANDLE_SCREEN_PX if the texture can't be loaded.
var _dd_handle_px: float = 0.0
var _handle_size_loaded := false

# DD's cursor textures, loaded from its icons/ folder. The only way to
# get a VISIBLE cursor change while the mouse hovers a Control (which
# DD's world is) is via Input.set_custom_mouse_cursor with an image —
# Input.set_default_cursor_shape is documented to be ignored over
# Controls. DD ships these textures so they're already "native".
var _cursor_tex_move = null         # drag-cursor-icon.png   (hand)
var _cursor_tex_scale_nwse = null   # resize-nwse.png        (\)
var _cursor_tex_scale_nesw = null   # resize-nesw.png        (/)
var _cursor_tex_rotate = null       # rotate.png             (rotate)

const MIN_DISTANCE = 25
const SELECTABLE_WALL = 1
# Mirrored from group_assets.gd — IDs >= this are custom (user-created) groups.
const CUSTOM_GROUP_MIN_ID = 10000
# DD's SelectableType enum: 0=Invalid, 1=Wall, 2=PortalFree, 3=PortalWall,
# 4=Object, 5=Pathway, 6=Light, 7=PatternShape, 8=Roof
const SELECTABLE_PORTAL_FREE = 2
const SELECTABLE_PORTAL_WALL = 3
const SELECTABLE_PATHWAY = 5
const SELECTABLE_PATTERN_SHAPE = 7

const ENABLE_LOGGING = false
const LOGGING_LEVEL = 0

#########################################################################################################
##
## UTILITY
##
#########################################################################################################

func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= LOGGING_LEVEL:
		printraw("(%d) <DragSelectWalls>: " % OS.get_ticks_msec())
		print(msg)

static func _normalize_box(a: Vector2, b: Vector2) -> Array:
	return [
		Vector2(min(a.x, b.x), min(a.y, b.y)),
		Vector2(max(a.x, b.x), max(a.y, b.y)),
	]

#########################################################################################################
##
## FILTER CHECKS
##
#########################################################################################################

func is_wall_filter_active() -> bool:
	var filters_menu: PopupMenu = _g.Editor.Toolset.GetToolPanel("SelectTool").filterMenu
	for _i in filters_menu.get_item_count():
		if filters_menu.get_item_text(_i) == "Walls":
			return filters_menu.is_item_checked(_i)
	return false

func is_locked_layer_filter_active() -> bool:
	var filters_menu: PopupMenu = _g.Editor.Toolset.GetToolPanel("SelectTool").layersFilterMenu
	for _i in filters_menu.get_item_count():
		if filters_menu.get_item_metadata(_i) == 9999:
			return filters_menu.is_item_checked(_i)
	return false


# True when a wall or wall portal must not be box-pickable: invisible in the
# scene tree (layer hidden by a third-party mod like Hide Layers) or rejected
# by SelectTool's LAYER filter (public C# IsObjectLayerFiltered). DD's own
# SelectThingsInsideBox applies this filter to everything it box-selects;
# the walls and wall portals we add here must obey it too.
func _layer_pick_blocked(thing) -> bool:
	if thing == null or not is_instance_valid(thing):
		return true
	if thing is CanvasItem and not thing.is_visible_in_tree():
		return true
	if select_tool != null and select_tool.has_method("IsObjectLayerFiltered") and select_tool.IsObjectLayerFiltered(thing):
		return true
	return false

#########################################################################################################
##
## WALL-IN-BOX TEST
##
#########################################################################################################

func is_wall_in_box(wall, start: Vector2, end: Vector2) -> bool:
	var pts = wall.Points
	if pts == null or pts.size() == 0:
		return false
	for point in pts:
		if point.x > end.x or point.x < start.x or point.y > end.y or point.y < start.y:
			return false
	return true

#########################################################################################################
##
## HIGHLIGHT DURING DRAG-SELECT
##
#########################################################################################################

func _update_highlights() -> void:
	if not is_locked_layer_filter_active() or not is_wall_filter_active():
		_clear_highlights()
		return

	var box = _normalize_box(select_tool.boxBegin, select_tool.boxEnd)
	if box[0].distance_to(box[1]) < MIN_DISTANCE:
		_clear_highlights()
		return

	var level = _g.World.GetCurrentLevel()
	if level == null:
		return

	# Shift+Alt drag → we'll REMOVE walls in the box, so tint them red and
	# restrict the highlight to walls actually in the current selection
	# (the only ones a removal affects). Otherwise, blue "will-select" tint.
	var deselect = Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT)
	var selected_walls := {}
	if deselect:
		var sel = select_tool.get("Selected")
		if sel != null:
			for node in sel:
				if node != null and is_instance_valid(node):
					selected_walls[node] = true

	var walls_in_box := []
	for wall in level.Walls.get_children():
		if not is_wall_in_box(wall, box[0], box[1]):
			continue
		if deselect and not selected_walls.has(wall):
			continue
		# Layer filter / visibility: never paint a "will select" highlight on
		# a wall the commit below would skip. Deselect mode stays allowed.
		if not deselect and _layer_pick_blocked(wall):
			continue
		walls_in_box.append(wall)

	for wall in _highlighted_walls:
		if is_instance_valid(wall) and not (wall in walls_in_box):
			_unhighlight_wall(wall)
	# Re-apply the tint every frame (not just on entry) so it flips live
	# when the user presses / releases Shift+Alt mid-drag.
	for wall in walls_in_box:
		_set_wall_highlight(wall, deselect)
	_highlighted_walls = walls_in_box


func _set_wall_highlight(wall, deselect: bool) -> void:
	var col = HIGHLIGHT_DESELECT_COLOR if deselect else HIGHLIGHT_SELECT_COLOR
	for child in wall.get_children():
		if child is Line2D:
			child.modulate = col

func _unhighlight_wall(wall) -> void:
	for child in wall.get_children():
		if child is Line2D:
			child.modulate = Color(1.0, 1.0, 1.0, 1.0)

func _clear_highlights() -> void:
	for wall in _highlighted_walls:
		if is_instance_valid(wall):
			_unhighlight_wall(wall)
	_highlighted_walls = []

#########################################################################################################
##
## PORTAL HIGHLIGHT DURING DRAG-SELECT
##
##  Live feedback while the box is being dragged: wall portals whose world
##  center enters the box light up in the blue SELECT color, mirroring the wall
##  drag highlight and matching how they look once committed. DD skips
##  HighlightThingAtPoint while drawing, so we own this feedback entirely — no
##  conflict with DD's native hover. We drive Portal.Select() as a purely visual
##  flag (it does not touch the tool's real selection), and never touch portals
##  already in the real selection, so their committed box stays intact.
##
#########################################################################################################

func _update_portal_highlights() -> void:
	if not _is_portal_filter_active():
		_clear_portal_highlights()
		return
	# In Shift+Alt (deselect) mode we don't paint a transient blue "will
	# select" highlight — it would be misleading. Portals already in the
	# real selection keep their own blue box; removal happens on release.
	if Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT):
		_clear_portal_highlights()
		return
	var box = _normalize_box(select_tool.boxBegin, select_tool.boxEnd)
	if box[0].distance_to(box[1]) < MIN_DISTANCE:
		_clear_portal_highlights()
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.get("Walls")
	if walls_node == null:
		return
	# We draw the drag-time feedback in the blue SELECT color, not the yellow
	# HIGHLIGHT color, to match how the portals look once the selection is
	# committed (and to match the wall drag-highlight). Portal._Draw uses the
	# blue SelectionSelectColor when isSelected is set, so we drive Select() as a
	# purely visual flag here — it does NOT add the portal to the tool's real
	# selection (that still happens in the deferred _add_portals_to_selection).
	# Portals already in the real selection are left untouched (already blue).
	var already = select_tool.Selected
	var want := []
	for wall in walls_node.get_children():
		if wall == null or not is_instance_valid(wall):
			continue
		var portals = wall.get("Portals")
		if portals == null:
			continue
		for portal in portals:
			if not _is_portal_in_box(portal, box[0], box[1]):
				continue
			if already != null and already.has(portal):
				continue
			# Layer filter / visibility (parity with the deferred commit)
			if _layer_pick_blocked(portal):
				continue
			want.append(portal)
	for portal in _highlighted_portals:
		if is_instance_valid(portal) and not (portal in want):
			if portal.has_method("Select"):
				portal.Select(false)
	for portal in want:
		if not (portal in _highlighted_portals):
			if portal.has_method("Select"):
				portal.Select(true)
	_highlighted_portals = want


func _clear_portal_highlights() -> void:
	# Only clears the purely-visual Select flag we set during the drag; portals
	# genuinely in the tool selection were never in _highlighted_portals, so
	# their real selection box is untouched.
	for portal in _highlighted_portals:
		if is_instance_valid(portal) and portal.has_method("Select"):
			portal.Select(false)
	_highlighted_portals = []

#########################################################################################################
##
## WALL ADDITION (deferred after DD finishes drag-select)
##
#########################################################################################################

func _add_walls_to_selection() -> void:
	if not is_locked_layer_filter_active() or not is_wall_filter_active():
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	# Shift+Alt drag → remove walls in the box from the selection instead
	# of adding them (mirrors alt_deselect.gd's native box-deselect).
	if _deferred_deselect:
		_deselect_walls_in_box(level)
		return
	var added = 0
	for wall in level.Walls.get_children():
		if is_wall_in_box(wall, _deferred_box_start, _deferred_box_end):
			# Layer filter / visibility (parity with DD's own box-select)
			if _layer_pick_blocked(wall):
				continue
			select_tool.SelectThing(wall, true)
			added += 1
	if added > 0:
		outputlog("Added %d wall(s) to selection" % added)
		# SelectThing() doesn't refresh the SelectTool panel — per API doc
		# we must call OnSelect(type) ourselves so the wall edit controls
		# appear. Only do so when the selection is exclusively walls, to
		# avoid overriding a panel already showing controls for a mixed
		# selection (e.g. an object that was selected before the drag).
		var only_walls = true
		var raw = select_tool.RawSelectables
		if raw != null:
			for s in raw:
				if s != null and s.Type != SELECTABLE_WALL:
					only_walls = false
					break
		if only_walls:
			var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
			if panel != null and panel.has_method("OnSelect"):
				panel.OnSelect(SELECTABLE_WALL)

#########################################################################################################
##
## PORTAL ADDITION (deferred after DD finishes drag-select)
##
##  DD's SelectThingsInsideBox already box-selects FREESTANDING portals
##  (World.Level.Portals, tested on portal.Position). What it never touches are
##  WALL portals: those live in each wall's own Portals array (their parent is
##  the wall, not level.Portals), so vanilla can only pick them by clicking.
##  That's the gap we fill here — after DD finishes its box, we add every wall
##  portal whose world center falls inside the box.
##
##  We box-test on portal.global_position (world), NOT portal.position, because
##  a wall portal's position is local to its parent wall. SelectThing routes
##  through GetSelectableType(), which returns PortalWall for a non-freestanding
##  portal, so the selection gets the correct type.
##
#########################################################################################################

# True if the SelectTool "Portals" type filter is enabled. Filter reaches
# GDScript only as a copy, but reading it is fine (we never write it here).
func _is_portal_filter_active() -> bool:
	var filter = select_tool.get("Filter")
	if typeof(filter) != TYPE_DICTIONARY:
		return true
	if not filter.has("Portals"):
		return true
	return bool(filter["Portals"])


func _is_portal_in_box(portal, start: Vector2, end: Vector2) -> bool:
	if portal == null or not is_instance_valid(portal) or not (portal is Node2D):
		return false
	var p = portal.global_position
	return p.x >= start.x and p.x <= end.x and p.y >= start.y and p.y <= end.y


func _add_portals_to_selection() -> void:
	if not _is_portal_filter_active():
		return
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.get("Walls")
	if walls_node == null:
		return
	# Shift+Alt drag → remove wall portals in the box instead of adding.
	if _deferred_deselect:
		_deselect_portals_in_box(walls_node)
		return
	# Snapshot the current selection once (Selected rebuilds a List each read),
	# so we can skip wall portals DD may already hold without O(n^2) property hits.
	var already = select_tool.Selected
	var added = 0
	for wall in walls_node.get_children():
		if wall == null or not is_instance_valid(wall):
			continue
		var portals = wall.get("Portals")
		if portals == null:
			continue
		for portal in portals:
			if not _is_portal_in_box(portal, _deferred_box_start, _deferred_box_end):
				continue
			if already != null and already.has(portal):
				continue
			# Layer filter / visibility (parity with DD's own box-select,
			# which applies IsObjectLayerFiltered to freestanding portals)
			if _layer_pick_blocked(portal):
				continue
			select_tool.SelectThing(portal, true)
			added += 1
	if added == 0:
		return
	outputlog("Added %d wall portal(s) to selection" % added)
	# Refresh the panel only when the selection is exclusively portals, so we
	# don't override controls already shown for a mixed selection (e.g. an
	# object selected before the drag).
	var only_portals = true
	var raw = select_tool.RawSelectables
	if raw != null:
		for s in raw:
			if s == null:
				continue
			if s.Type != SELECTABLE_PORTAL_FREE and s.Type != SELECTABLE_PORTAL_WALL:
				only_portals = false
				break
	if only_portals:
		var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
		if panel != null and panel.has_method("OnSelect"):
			panel.OnSelect(SELECTABLE_PORTAL_WALL)

#########################################################################################################
##
## BOX DESELECT (Shift+Alt drag) — remove walls / wall portals in the box
##
##  Runs in the same deferred pass as the add functions, a couple frames after
##  alt_deselect.gd has already box-removed the native assets. We only touch
##  Things already in the selection so a Shift+Alt drag over empty space (or
##  over unselected walls) is a no-op.
##
#########################################################################################################

# DD's own SelectThingsInsideBox applies the layer filter but never tests
# VISIBILITY: with a container hidden by a third-party mod like Hide Layers
# (e.g. level.Portals invisible), hidden freestanding portals — and any other
# hidden things — still get box-selected by DD. Runs once after DD's box has
# committed: drop every selected thing that is not visible in the scene tree,
# then refit or close the transform box.
func _remove_hidden_from_selection(adjust_box := true) -> void:
	if select_tool == null:
		return
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return
	var to_remove = []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if thing is CanvasItem and not thing.is_visible_in_tree():
			to_remove.append(thing)
	if to_remove.empty():
		return
	for thing in to_remove:
		select_tool.SelectThing(thing, false)
	outputlog("Removed %d hidden thing(s) from box selection" % to_remove.size())
	# Pendant le tracé de la box (adjust_box=false), ne pas toucher la
	# transform box : elle est cachée tant que isDrawing est vrai.
	if adjust_box and select_tool.has_method("EnableTransformBox"):
		select_tool.call("EnableTransformBox", to_remove.size() < raw.size())


func _deselect_walls_in_box(level) -> void:
	var selected_walls := {}
	var sel = select_tool.get("Selected")
	if sel != null:
		for node in sel:
			if node != null and is_instance_valid(node):
				selected_walls[node] = true
	var removed = 0
	for wall in level.Walls.get_children():
		if not selected_walls.has(wall):
			continue
		if is_wall_in_box(wall, _deferred_box_start, _deferred_box_end):
			# Reset transformMode before shrinking the selection to avoid
			# DD's ApplyTransforms crash (same guard alt_deselect.gd uses).
			select_tool.transformMode = 0
			select_tool.SelectThing(wall, false)
			removed += 1
	if removed == 0:
		return
	outputlog("Removed %d wall(s) from selection" % removed)
	_refresh_panel_after_deselect()


func _deselect_portals_in_box(walls_node) -> void:
	var selected := {}
	var sel = select_tool.get("Selected")
	if sel != null:
		for node in sel:
			if node != null and is_instance_valid(node):
				selected[node] = true
	var removed = 0
	for wall in walls_node.get_children():
		if wall == null or not is_instance_valid(wall):
			continue
		var portals = wall.get("Portals")
		if portals == null:
			continue
		for portal in portals:
			if not selected.has(portal):
				continue
			if _is_portal_in_box(portal, _deferred_box_start, _deferred_box_end):
				select_tool.transformMode = 0
				select_tool.SelectThing(portal, false)
				removed += 1
	if removed == 0:
		return
	outputlog("Removed %d wall portal(s) from selection" % removed)
	_refresh_panel_after_deselect()


# Shared cleanup after a box-deselect removed walls / portals: prune stale
# initialRelativeTransforms entries, disable the box when nothing remains,
# and refresh the panel for the remaining (uniform-type) selection.
func _refresh_panel_after_deselect() -> void:
	var irt = select_tool.get("initialRelativeTransforms")
	if irt != null:
		var valid := {}
		for s in select_tool.RawSelectables:
			valid[s] = true
		var to_remove := []
		for key in irt.keys():
			if not valid.has(key):
				to_remove.append(key)
		for key in to_remove:
			irt.erase(key)
	var sel = select_tool.get("Selected")
	var remaining = 0
	if sel != null:
		remaining = sel.size()
	if remaining == 0:
		select_tool.EnableTransformBox(false)
		select_tool.DeselectAll()
		return
	# Determine a uniform selection type; OnSelect(0) on a mixed selection
	# is a no-op, so we leave the panel as-is in that case.
	var raw = select_tool.RawSelectables
	var uniform_type := -1
	if raw != null:
		for s in raw:
			if s == null:
				continue
			if uniform_type == -1:
				uniform_type = s.Type
			elif s.Type != uniform_type:
				uniform_type = 0
				break
	if uniform_type > 0:
		var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
		if panel != null and panel.has_method("OnSelect"):
			panel.OnSelect(uniform_type)

#########################################################################################################
##
## GROUP TRANSFORM — walls follow DD items for move / rotate / scale
##
##  We snapshot the ref item's pre-drag pos/rot/scale, the pivot for scale,
##  and walls' state. Each frame we build a world-space transform W and
##  apply W.xform(p) to every wall point / Line2D point / portal /
##  sprite end-cap position.
##
##  W is computed differently per mode because DD's behavior is asymmetric:
##
##   - Move:   DD updates ref's global_position. W = T(delta).
##   - Rotate: DD updates ref's pos+rot faithfully → W = cur_T * pre_T.inv
##             implicitly captures DD's actual pivot (whatever it is).
##   - Scale:  DD updates ref's global_scale but NOT global_position, so
##             cur_T * pre_T.inv would yield a wrong pivot. Use an explicit
##             pivot computed from the box's grabbed corner at drag start.
##
##  By design we DO NOT scale the wall texture nor the sprite end-caps'
##  scale: only positions move. For rotation, child Node2D and portal
##  rotations are offset by W.get_rotation() so they stay aligned.
##
#########################################################################################################

# Find selected walls and a reference DD item to track.
func _get_selected_walls_and_ref():
	var walls := []
	var ref = null
	var raw = select_tool.RawSelectables
	if raw == null:
		return [walls, ref]
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			walls.append(s.Thing)
		elif ref == null and s.Thing is Node2D:
			ref = s.Thing
	return [walls, ref]


# Compute the world-space pivot from the box state at drag start, given the
# transform mode. For Move, pivot is unused. For Rotate, pivot is box center.
# For Scale, pivot is the corner OPPOSITE to the handle the user grabbed.
func _compute_pivot(tm: int) -> Vector2:
	var bb = select_tool.boxBegin
	var be = select_tool.boxEnd
	var min_p = Vector2(min(bb.x, be.x), min(bb.y, be.y))
	var max_p = Vector2(max(bb.x, be.x), max(bb.y, be.y))
	var center = (min_p + max_p) * 0.5
	if tm == 2:
		return center
	if tm == 3:
		var corner_id = select_tool.transformCorner
		# -1 means edge handle / nowhere near a corner — fall back to center.
		if corner_id < 0:
			return center
		# transformCorner: 0=TL, 1=TR, 2=BR, 3=BL (clockwise from top-left).
		# Pivot for scale is the opposite corner: (corner_id + 2) % 4.
		var corners = [
			min_p,                          # 0 TL
			Vector2(max_p.x, min_p.y),      # 1 TR
			max_p,                          # 2 BR
			Vector2(min_p.x, max_p.y),      # 3 BL
		]
		return corners[(corner_id + 2) % 4]
	return center


# Snapshot a wall's Points, portals (pos+rot), and visual children (pos+rot).
func _snapshot_wall(wall) -> Dictionary:
	var snap = {}

	# Points
	var pts = []
	var raw_pts = wall.Points
	if raw_pts != null:
		for p in raw_pts:
			pts.append(p)
	snap["pts"] = pts

	# Portals: position + rotation
	# Portals: position + rotation + Direction + WallDistance + Radius.
	# Radius determines the wall hole width (Begin/End are recomputed
	# from position + Direction * ±Radius). DD recalculates Radius when
	# the wall is scaled, so we snapshot and restore it ourselves to
	# keep the hole the same physical size as before.
	var portal_pos = {}
	var portal_rot = {}
	var portal_dir = {}
	var portal_wall_dist = {}
	var portal_radius = {}
	var portals = wall.Portals
	if portals != null:
		for portal in portals:
			if is_instance_valid(portal):
				portal_pos[portal] = portal.position
				portal_rot[portal] = portal.rotation
				if "Direction" in portal:
					portal_dir[portal] = portal.Direction
				if "WallDistance" in portal:
					portal_wall_dist[portal] = portal.WallDistance
				if "Radius" in portal:
					portal_radius[portal] = portal.Radius
	snap["portals"] = portal_pos
	snap["portal_rots"] = portal_rot
	snap["portal_dirs"] = portal_dir
	snap["portal_wall_dists"] = portal_wall_dist
	snap["portal_radii"] = portal_radius

	# Visual children: Line2D.points, Node2D position+rotation
	var children = {}
	for child in wall.get_children():
		if child is Line2D:
			var lpts = []
			for p in child.points:
				lpts.append(p)
			children[child] = {"points": lpts}
			for sub in child.get_children():
				if sub is Node2D:
					children[sub] = {"position": sub.position, "rotation": sub.rotation}
		elif child is Node2D:
			for sub in child.get_children():
				if sub is Line2D:
					var lpts = []
					for p in sub.points:
						lpts.append(p)
					children[sub] = {"points": lpts}
	snap["children"] = children

	return snap


# Apply a world-space Transform2D W to a wall using its pre-drag snapshot.
# Note: we only move / rotate positions. We never scale wall thickness
# nor sprite end-cap scale (per design — texture stays unchanged).
# remake_lines : les appelants qui appliquent la transformation à chaque
# frame (drag des handles FT) passent false et déclenchent un unique
# RemakeLines au commit — même optimisation que notre _ci_mode.
func _apply_transform_to_wall(wall, snap: Dictionary, W: Transform2D, remake_lines := true) -> void:
	# get_rotation() returns a spurious non-zero angle for a NON-UNIFORM
	# scale applied around a rotated frame, because the basis (still
	# symmetric, no actual rotation) projects onto a non-axis vector.
	# Detect "pure scale" via symmetry of the basis (W.x.y == W.y.x) and
	# zero out the rotation in that case so wall children / portals
	# don't drift.
	var w_rot: float
	if abs(W.x.y - W.y.x) < 0.0001:
		w_rot = 0.0
	else:
		w_rot = W.get_rotation()

	# 1. Wall.Points
	var new_pts = []
	for p in snap["pts"]:
		new_pts.append(W.xform(p))
	_set_wall_points(wall, new_pts)

	# 2. Visual children
	for node in snap["children"]:
		if not is_instance_valid(node):
			continue
		var orig = snap["children"][node]
		if orig.has("points"):
			var lpts = PoolVector2Array()
			for p in orig["points"]:
				lpts.append(W.xform(p))
			node.points = lpts
		elif orig.has("position"):
			node.position = W.xform(orig["position"])
			if orig.has("rotation"):
				node.rotation = orig["rotation"] + w_rot

	# 3. Portals: update visual position/rotation/Direction (these don't
	#    auto-follow when we modify Points). Do NOT touch Radius or
	#    WallDistance — DD's hole size is driven directly by Radius
	#    (no wall-scale multiplier), so any compensation we do produces
	#    the WRONG visual result. Leave them alone, the hole stays
	#    constant naturally.
	# Empirical note: writing WallDistance/WallPointIndex here ALSO
	# breaks walls on the second save/reload cycle (walls disappear
	# visually). DD seems to recompute these properties internally; our
	# writes accumulate stale state across snapshots. So we only update
	# portal.position/rotation/Direction and let DD persist the rest.
	var pos_map = snap["portals"]
	var rot_map = snap.get("portal_rots", {})
	var dir_map = snap.get("portal_dirs", {})
	for portal in pos_map:
		if not is_instance_valid(portal):
			continue
		portal.position = W.xform(pos_map[portal])
		if rot_map.has(portal):
			portal.rotation = rot_map[portal] + w_rot
		if dir_map.has(portal) and "Direction" in portal:
			# Direction is a unit facing vector. W.basis_xform applies
			# rotation AND scale; we only want the rotation. Normalize
			# to strip the scale (otherwise DD picks up a stretched
			# direction vector and the portal sprite is rendered
			# deformed after subsequent reloads).
			var dir_transformed = W.basis_xform(dir_map[portal])
			if dir_transformed.length() > 0.001:
				portal.Direction = dir_transformed.normalized()
			else:
				portal.Direction = dir_map[portal]

	# 4. Refresh visuals — but only when NOT in an active interactive
	# drag. During a drag we apply transforms 60 times per second, and
	# RemakeLines() is expensive (especially for walls with portals).
	# We trigger a single RemakeLines at the end of the drag instead.
	if remake_lines and _ci_mode == 0:
		if wall.has_method("RemakeLines"):
			wall.RemakeLines()
		elif wall.has_method("RemakeLinesWhenAllPortalsReady"):
			wall.RemakeLinesWhenAllPortalsReady()

	# 5. Claim this geometry change so the watchdog in _update_overlay
	#    doesn't mistake it for an external edit and re-fit the box.
	_geo_owned_frame = Engine.get_frames_drawn()


# Snapshot the `points` arrays of every Line2D in `node`'s subtree
# (direct children AND deeper descendants). The dashed selection
# indicator on Pathways may not be a direct child — it's often a
# Line2D nested under an intermediate Node2D — so we recurse.
func _snap_line2d_children(node) -> Dictionary:
	var result = {}
	if node == null or not is_instance_valid(node):
		return result
	_snap_line2d_recurse(node, result)
	return result


func _snap_line2d_recurse(parent, result: Dictionary) -> void:
	for child in parent.get_children():
		if child is Line2D:
			var pts = []
			for p in child.points:
				pts.append(p)
			result[child] = pts
		if child.get_child_count() > 0:
			_snap_line2d_recurse(child, result)


# Recursively find Line2D descendants whose texture is the dotted-line
# selection indicator (dotted_line.png) and hide them. Each hidden node
# is recorded with its prior visibility state in _ci_dashed_hidden so
# it can be restored at drag end. Identifying by texture is robust
# across DD versions and avoids tying us to specific node names.
func _hide_dashed_selection_children(root) -> void:
	if root == null or not is_instance_valid(root):
		return
	_hide_dashed_recurse(root)


func _hide_dashed_recurse(node) -> void:
	for child in node.get_children():
		if child is Line2D:
			var tex = child.texture
			if tex != null and "resource_path" in tex:
				var rp = str(tex.resource_path)
				if rp.find("dotted_line") != -1:
					_ci_dashed_hidden.append({"node": child, "was_visible": child.visible})
					child.visible = false
		if child.get_child_count() > 0:
			_hide_dashed_recurse(child)


# Restore dashed indicators hidden by _hide_dashed_selection_children.
# Called from _end_custom_drag after the final geometry update. Before
# unhiding, we copy the parent path's `points` into the dashed child so
# it shows the post-drag shape immediately (DD only refreshes its
# selection overlays on mouse hover / re-select otherwise, which would
# make the dashed line appear briefly at its old position).
func _restore_dashed_selection_children() -> void:
	for entry in _ci_dashed_hidden:
		var node = entry["node"]
		if node != null and is_instance_valid(node):
			# Sync points to the parent path/pattern. The dashed
			# Line2D is a direct child of a Line2D (path) or
			# Polygon2D (pattern) and mirrors its shape.
			var parent = node.get_parent()
			if parent != null and is_instance_valid(parent):
				if parent is Line2D:
					# Path case: copy the parent's points 1:1.
					node.points = parent.points
				elif parent is Polygon2D:
					# Pattern case: build a closed polyline from the
					# polygon (append first point to close the loop).
					var poly = parent.polygon
					var pts = PoolVector2Array()
					for p in poly:
						pts.append(p)
					if pts.size() > 0:
						pts.append(pts[0])
					node.points = pts
			node.visible = entry["was_visible"]
	_ci_dashed_hidden = []


# Deform every snapshotted Line2D child by W.basis_xform (so points stay
# in the parent's LOCAL frame — since the parent's global_position is
# already moved by W.xform, only the linear part needs to apply to the
# child points). `exclude` lets the caller skip a specific child it has
# already handled itself (e.g. the pattern's Outline, rebuilt from the
# new polygon to guarantee correct loop closure).
func _deform_line2d_children(children: Dictionary, W: Transform2D, exclude = null) -> void:
	for child in children:
		if not is_instance_valid(child):
			continue
		if child == exclude:
			continue
		var lpts = PoolVector2Array()
		for p in children[child]:
			lpts.append(W.basis_xform(p))
		child.points = lpts


# Restore a Pathway's EditPoints to their pre-drag local coords (with
# global_position translated to W.xform(snap.pos) by the caller). Used
# by the uniform-scale branch when a prior Shift frame deformed the
# geometry — we must reset before applying node-level scale, otherwise
# the deformed points + node.scale compound into an unintended shape.
func _restore_path_geometry(path, orig_local_pts: Array) -> void:
	if not path.has_method("SetEditPoints"):
		return
	var pool = PoolVector2Array()
	for lp in orig_local_pts:
		pool.append(path.global_position + lp)
	path.call("SetEditPoints", pool)
	if path.has_method("Smooth"):
		path.call("Smooth")


# Restore a PatternShape's polygon to its pre-drag local coords. Mirrors
# _restore_path_geometry: used by the uniform-scale branch to undo any
# prior Shift-frame deformation. Also resets dashed/outline children
# so they match the restored shape.
func _restore_pattern_geometry(pattern, orig_local_pts: Array, line_children: Dictionary) -> void:
	var orig_poly = PoolVector2Array()
	for p in orig_local_pts:
		orig_poly.append(p)
	pattern.polygon = orig_poly
	if "uv" in pattern:
		pattern.uv = PoolVector2Array()
	# Rebuild outline from the restored polygon.
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in orig_poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts
	# Restore Line2D child point arrays from snapshot (identity W).
	_deform_line2d_children(line_children, Transform2D.IDENTITY, outline)


# Apply a world-space Transform2D W to a Pathway's centerline. We deform
# the EditPoints (the path's control points) but never touch
# global_scale, so the path's line width and texture density stay
# constant. Caller is expected to have already updated path.global_position
# to W.xform(snap.pos) — this routine then puts each point at the
# matching world position via SetEditPoints (which DD interprets as
# "world coords, converted to local by subtracting global_position").
#
# Deformation: new_local = W.basis_xform(old_local). This works because
# W is affine and the translation part cancels when both the node's
# global_position and each world point are W-transformed equally.
# Assumes the path node's basis is identity (typical case). If the
# path was rotated / scaled prior, results may drift.
#
# `line_children` holds {Line2D → original points} captured at drag
# start. We deform those AFTER Smooth() so that for closed (loop) paths
# — where Smooth() also rebuilds the dashed selection child Line2D —
# our W.basis_xform deformation has the final word and isn't overwritten.
func _apply_scale_to_path(path, local_pts: Array, line_children: Dictionary, W: Transform2D) -> void:
	if not path.has_method("SetEditPoints"):
		return
	var pool = PoolVector2Array()
	for lp in local_pts:
		# DD's SetEditPoints expects WORLD coords; it stores
		#   stored_local = world_pt - path.global_position
		# so we feed (current_global_position + new_local).
		pool.append(path.global_position + W.basis_xform(lp))
	path.call("SetEditPoints", pool)
	if path.has_method("Smooth"):
		path.call("Smooth")
	_deform_line2d_children(line_children, W)


# Apply a world-space Transform2D W to a PatternShape using the WORLD-
# ANCHORED approach. The caller has set pattern.global_position to
# orig_pos (NOT W.xform(orig_pos)), so the pattern's local origin in
# world space is unchanged. We encode the entire W transform — basis
# AND translation — into the polygon vertices, so each world vertex
# ends up at W.xform(orig_world_vertex) as expected. Tile mapping is
# anchored to local polygon coords by DD's shader, and since local
# (0,0) maps to world orig_pos (constant), each tile (i, j) is
# rendered at world orig_pos + (i*textureSize, j*textureSize) — the
# SAME world position as before the drag, with the SAME size in
# screen pixels. The polygon shape changes around the texture,
# clipping more or less of the world-anchored tile grid.
#
# Caveats:
#   - This only works correctly when the pattern's basis (rotation,
#     scale) is identity at drag start. With non-identity basis the
#     local→world mapping is more complex.
#   - At drag end, the pattern.position has stayed at orig_pos but
#     the polygon now has translation baked in. That's a valid
#     persistent state; DD treats polygon as authoritative.
func _apply_world_anchored_pattern(pattern, local_pts: Array, line_children: Dictionary, orig_pos: Vector2, W: Transform2D) -> void:
	# Compose the world transform W into the pattern's LOCAL coord
	# system. Each polygon vertex in `local_pts` represents a position
	# expressed in pattern-local at drag start. To deform under W
	# correctly when pattern.global_scale or rotation isn't identity:
	#   world_old = pattern.xform(local)
	#   world_new = W.xform(world_old)
	#   local_new = inv(pattern.xform).xform(world_new)
	# i.e. local_new = (inv(pattern.xform) * W * pattern.xform).xform(local)
	# This handles both the basis (scale/rotation) and translation
	# parts of W in the pattern's local frame, which is essential when
	# the pattern was previously resized (its scale ≠ 1) — passing
	# world-space dt directly into local coords would otherwise leave
	# the pattern offset by a factor of snap.scale.
	var xform_now = pattern.global_transform
	var T = xform_now.affine_inverse() * W * xform_now
	var new_poly = PoolVector2Array()
	for lp in local_pts:
		new_poly.append(T.xform(lp))
	pattern.polygon = new_poly
	# Clear any custom UV array — DD's pattern shader uses local
	# VERTEX for UV and a stale uv array would break that.
	if "uv" in pattern:
		pattern.uv = PoolVector2Array()
	# Rebuild the Outline (Line2D) child explicitly from the new
	# polygon (closed loop).
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in new_poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts
	# Deform other Line2D children (selection indicator etc.) — same
	# local-frame transform as the polygon.
	for child in line_children:
		if not is_instance_valid(child):
			continue
		if child == outline:
			continue
		var lpts2 = PoolVector2Array()
		for p in line_children[child]:
			lpts2.append(T.xform(p))
		child.points = lpts2



# DD does not expose its internal HistoryRecord system to the modding API,
# so wall geometry edits made via wall.Points cannot use the same path as
# DD's native undo. Instead, we register a custom action with Godot's
# UndoRedo (Editor.UndoRedo) — capturing pre/post snapshots and writing
# either back when the user presses Ctrl+Z / Ctrl+Y.

# Public — used as both do/undo callback. Restores `wall` to the state
# captured in `snap` (Points, Color, Texture, Loop, Shadow, Type, Joint,
# NormalizeUV, child Line2D points, child Node2D positions, portals).
func _restore_wall_state(wall, snap: Dictionary) -> void:
	if wall == null or not is_instance_valid(wall):
		return
	# Set Points directly (NOT wall.Set()) for transform undo. wall.Set()
	# reinitializes the wall and detaches portals — fine for full
	# style/texture undo but breaks portal undo for moves/rotates/scales.
	# We only fall back to Set() if we have to (snap has style fields
	# AND the caller explicitly asked for a style restore — currently
	# nobody does, so we always use the safe Points-only path).
	var pts = []
	for p in snap.get("pts", []):
		pts.append(p)
	_set_wall_points(wall, pts)
	# Children (Line2D / Node2D)
	for node in snap.get("children", {}):
		if not is_instance_valid(node):
			continue
		var orig = snap["children"][node]
		if orig.has("points"):
			var lpts = PoolVector2Array()
			for p in orig["points"]:
				lpts.append(p)
			node.points = lpts
		elif orig.has("position"):
			node.position = orig["position"]
			if orig.has("rotation"):
				node.rotation = orig["rotation"]
	# Portals — restore position, rotation, Direction, WallDistance,
	# Radius. See _snapshot_wall for why we don't touch Begin/End.
	var pos_map = snap.get("portals", {})
	var rot_map = snap.get("portal_rots", {})
	var dir_map = snap.get("portal_dirs", {})
	var wd_map = snap.get("portal_wall_dists", {})
	var radius_map = snap.get("portal_radii", {})
	for portal in pos_map:
		if is_instance_valid(portal):
			portal.position = pos_map[portal]
			if rot_map.has(portal):
				portal.rotation = rot_map[portal]
			if dir_map.has(portal) and "Direction" in portal:
				portal.Direction = dir_map[portal]
			if wd_map.has(portal) and "WallDistance" in portal:
				portal.WallDistance = wd_map[portal]
			if radius_map.has(portal) and "Radius" in portal:
				portal.Radius = radius_map[portal]
	if wall.has_method("RemakeLines"):
		wall.RemakeLines()
	elif wall.has_method("RemakeLinesWhenAllPortalsReady"):
		wall.RemakeLinesWhenAllPortalsReady()


# Capture a full snapshot for undo/redo purposes — superset of
# _snapshot_wall (which is geometry-only). Adds Color / Texture / Loop /
# Shadow / Type / Joint / NormalizeUV so we can re-Set() the wall.
func _capture_wall_snapshot(wall) -> Dictionary:
	var snap = _snapshot_wall(wall)
	if "Color" in wall:
		snap["color"] = wall.Color
	if "Texture" in wall:
		snap["texture"] = wall.Texture
	if "Loop" in wall:
		snap["loop"] = wall.Loop
	if "HasShadow" in wall:
		snap["shadow"] = wall.HasShadow
	if "Type" in wall:
		snap["type"] = wall.Type
	if "Joint" in wall:
		snap["joint"] = wall.Joint
	if "NormalizeUV" in wall:
		snap["normalize_uv"] = wall.NormalizeUV
	return snap


# A single history record that covers a transform applied to a mixed
# selection (walls + non-walls). Unifying both into one record means the
# user only needs ONE Ctrl+Z to undo a transform, instead of two
# (one for walls + one for DD's own RecordTransforms which would handle
# the non-walls separately).
class GroupTransformRecord:
	extends Reference
	var owner_mod
	# Each wall entry: {wall, pre_snap, post_snap}
	var wall_entries: Array = []
	# Each non-wall entry: {node, pre_pos, pre_rot, pre_scale,
	#                        post_pos, post_rot, post_scale}
	var non_wall_entries: Array = []
	var label: String = "Transform"

	func undo():
		if owner_mod == null:
			return
		for e in wall_entries:
			owner_mod._restore_wall_state(e.wall, e.pre_snap)
		for e in non_wall_entries:
			if not is_instance_valid(e.node):
				continue
			e.node.global_position = e.pre_pos
			e.node.global_rotation = e.pre_rot
			e.node.global_scale = e.pre_scale

	func redo():
		if owner_mod == null:
			return
		for e in wall_entries:
			owner_mod._restore_wall_state(e.wall, e.post_snap)
		for e in non_wall_entries:
			if not is_instance_valid(e.node):
				continue
			e.node.global_position = e.post_pos
			e.node.global_rotation = e.post_rot
			e.node.global_scale = e.post_scale


# Resolve DD's history container. Tries several attribute names to be
# resilient across DD versions. Cached after first success.
var _history_obj = null


func _list_method_names(obj) -> Array:
	var names := []
	if obj == null:
		return names
	for entry in obj.get_method_list():
		names.append(entry.name)
	return names


func _get_history():
	if _history_obj != null:
		return _history_obj
	if _g.Editor == null:
		return null
	var h = _g.Editor.get("History")
	if h != null and h.has_method("Record"):
		_history_obj = h
		return _history_obj
	if h != null:
		outputlog("History container found but no Record method. Methods: " + str(_list_method_names(h)))
	return null


# Build a GroupTransformRecord from _ci_things' pre snapshots and the
# post-state of each thing right now. Caller invokes this AFTER the
# transform is applied. Returns null if there's nothing to record.
func _build_group_record_from_ci_things(label: String):
	var record = GroupTransformRecord.new()
	record.owner_mod = self
	record.label = label
	for entry in _ci_things:
		var thing = entry.thing
		if not is_instance_valid(thing):
			continue
		var snap = entry.snap
		if entry.type == SELECTABLE_WALL:
			var pre = snap.get("wall_undo_pre", null)
			if pre == null:
				continue
			var post = _capture_wall_snapshot(thing)
			record.wall_entries.append({"wall": thing, "pre_snap": pre, "post_snap": post})
		elif thing is Node2D:
			# pre_pos/rot/scale stored from drag start (snap.pos/rot/scale).
			record.non_wall_entries.append({
				"node": thing,
				"pre_pos": snap.pos,
				"pre_rot": snap.rot,
				"pre_scale": snap.scale,
				"post_pos": thing.global_position,
				"post_rot": thing.global_rotation,
				"post_scale": thing.global_scale,
			})
	if record.wall_entries.size() == 0 and record.non_wall_entries.size() == 0:
		return null
	return record


# Push a record into DD's History. Tries CreateCustomRecord first
# (DD's preferred wrapping), falls back to direct Record(record).
func _push_history_record(record) -> void:
	if record == null:
		return
	var history = _get_history()
	if history == null:
		outputlog("History not available, skipping undo for: " + str(record.label))
		return
	var idx_before = history.get_LastIndex() if history.has_method("get_LastIndex") else -999
	# CreateCustomRecord wraps our Reference into DD's internal record
	# format AND pushes it to the history in one call. Calling Record()
	# afterwards would push a SECOND time (LastIndex jumped by 2 instead
	# of 1, so undo had to pass through a no-op DD record between each
	# of our records).
	if history.has_method("CreateCustomRecord"):
		history.CreateCustomRecord(record)
		var idx_after = history.get_LastIndex() if history.has_method("get_LastIndex") else -999
		outputlog("[hist] PUSH '%s': LastIndex %s -> %s (delta=%s)" % [str(record.label), str(idx_before), str(idx_after), str(idx_after - idx_before)])
		return
	history.Record(record)
	var idx_after2 = history.get_LastIndex() if history.has_method("get_LastIndex") else -999
	outputlog("[hist] PUSH '%s' (raw): LastIndex %s -> %s (delta=%s)" % [str(record.label), str(idx_before), str(idx_after2), str(idx_after2 - idx_before)])


# Diagnostic helper — log the current history index with a label.
# Used to detect when DD pushes records on its own (e.g. on selection).
func _log_history_index(label: String) -> void:
	var history = _get_history()
	if history == null:
		return
	var li = history.get_LastIndex() if history.has_method("get_LastIndex") else -999
	var ri = history.get_RedactIndex() if history.has_method("get_RedactIndex") else -999
	outputlog("[hist] %s: LastIndex=%s RedactIndex=%s" % [label, str(li), str(ri)])


# Walls-only convenience for callers that don't have a _ci_things array
# (e.g. apply_rotation_around / wheel rotate).
func _register_walls_undo(action_name: String, entries: Array) -> void:
	if entries.size() == 0:
		return
	var record = GroupTransformRecord.new()
	record.owner_mod = self
	record.label = action_name
	record.wall_entries = entries
	_push_history_record(record)


# ==========================================================================


func _start_group_transform() -> void:
	var result = _get_selected_walls_and_ref()
	_move_walls = result[0]
	_ref_item = result[1]

	if _move_walls.size() == 0 or _ref_item == null:
		_move_walls = []
		_ref_item = null
		return

	var tm = select_tool.transformMode
	_drag_mode = tm
	_ref_pre_pos = _ref_item.global_position
	_ref_pre_rot = _ref_item.global_rotation
	_ref_pre_scale = _ref_item.global_scale
	_pivot = _compute_pivot(tm)

	_move_snapshots = {}
	for wall in _move_walls:
		_move_snapshots[wall] = _snapshot_wall(wall)

	_transforming = true
	outputlog("Group transform started: %d wall(s), mode=%d, pivot=%s" % [_move_walls.size(), tm, str(_pivot)])


func _update_group_transform() -> void:
	if _ref_item == null or not is_instance_valid(_ref_item):
		_end_group_transform()
		return

	var W: Transform2D
	match _drag_mode:
		1:  # Move: simple translate by ref item's position delta
			W = Transform2D(0.0, _ref_item.global_position - _ref_pre_pos)
		2:
			# Rotate: derive W implicitly from ref item's transform change.
			# DD updates the ref item's global_position AND global_rotation
			# faithfully during a rotate drag, so cur_T * pre_T.inv yields
			# the world-space transform that includes DD's actual pivot —
			# whatever it is. No need to compute the pivot explicitly.
			var pre_T = Transform2D(_ref_pre_rot, _ref_pre_pos).scaled(_ref_pre_scale)
			var cur_T = Transform2D(_ref_item.global_rotation, _ref_item.global_position).scaled(_ref_item.global_scale)
			W = cur_T * pre_T.affine_inverse()
		3:
			# Scale: explicit pivot. DD updates global_scale but NOT
			# global_position during a scale drag, so cur_T * pre_T.inv
			# would scale around the wrong point (ref's pre_pos). Use
			# the box-derived pivot captured at drag start instead.
			var sx = 1.0 if _ref_pre_scale.x == 0.0 else _ref_item.global_scale.x / _ref_pre_scale.x
			var sy = 1.0 if _ref_pre_scale.y == 0.0 else _ref_item.global_scale.y / _ref_pre_scale.y
			var s_t = Transform2D.IDENTITY.scaled(Vector2(sx, sy))
			W = Transform2D(0.0, _pivot) * s_t * Transform2D(0.0, -_pivot)
		_:
			return

	for wall in _move_walls:
		if is_instance_valid(wall) and _move_snapshots.has(wall):
			_apply_transform_to_wall(wall, _move_snapshots[wall], W)


# Instant drag de DD (clic-glisser direct sur un asset). DD remplit
# movableThings avec tout le groupe — walls compris — et ecrit chaque frame :
#     movableThings[i].Position = preMovePositions[i] + firstItemDelta
# Pour un wall c'est un non-sens : sa geometrie vit dans Points (coordonnees
# monde) et son node reste a l'origine. Le rendu suit (Line2D enfants en
# local) mais les Points ne bougent pas — box en arriere, et Wall.Save()
# n'ecrivant pas la position du node, le deplacement serait perdu au reload.
#
# La cle : preMovePositions vaut ZERO pour un wall, donc `wall.position` est
# exactement la translation TOTALE depuis le debut du drag. On repart donc du
# snapshot pris au debut et on lui applique cette translation absolue — rien
# ne s'accumule, et l'ordre d'execution entre DD et nous n'a plus d'importance.
# Sur une frame sans mouvement DD ne reecrit rien : la derniere valeur lue est
# reutilisee, sinon le wall reviendrait au snapshot le temps d'une frame.
#
# (Mesurer la translation sur un item non-wall du groupe ne marchait pas : sa
# position de reference ne peut etre capturee qu'a la premiere frame ou l'on
# voit manualAction, apres que DD a deja applique un premier increment — d'ou
# un decalage constant, le wall « sur un autre plan ».)
#
# L'undo de DD ne couvre pas ces walls : son MoveRecord compare
# preMovePositions[i] a Position, toutes deux nulles ici. D'ou notre record.
func _bake_dd_position_drag() -> void:
	if _transforming or _ci_mode > 0:
		_dd_drag_stop(false)
		return
	if select_tool == null:
		return
	var ma = select_tool.get("manualAction")
	if not _dd_diag_done:
		_dd_diag_done = true
		print("[DSW-DIAG] manualAction lisible=%s valeur=%s" % [str(ma != null), str(ma)])
	if ma == null or int(ma) != 1:   # ManualAction.MoveThing
		_dd_drag_stop(true)
		return
	if _dd_diag_frames < 40:
		var wl: Array = _get_selection_split()[0]
		if wl.size() > 0 and is_instance_valid(wl[0]):
			var w0 = wl[0]
			var wpos = w0.position
			var p0 = Vector2.ZERO
			var raw0 = w0.get("Points")
			if raw0 != null and raw0.size() > 0:
				p0 = raw0[0]
			# Une ligne seulement quand quelque chose bouge : sinon les frames
			# immobiles du debut consommaient tout le budget de trace.
			if wpos != _dd_diag_last_pos or p0 != _dd_diag_last_pt:
				_dd_diag_frames += 1
				_dd_diag_last_pos = wpos
				_dd_diag_last_pt = p0
				var ref_node = _dd_diag_ref_asset()
				var rpos = ref_node.global_position if ref_node != null else Vector2.ZERO
				print("[DSW-DIAG] pos_proc=%s pos_draw=%s pts[0]=%s asset=%s" % [str(_dd_dbg_proc_pos), str(wpos), str(p0), str(rpos)])

	var walls: Array = _get_selection_split()[0]
	if walls.size() == 0:
		_dd_drag_stop(true)
		return

	if not _dd_pos_drag_active:
		_dd_diag_frames = 0
		_dd_diag_last_pos = Vector2.ZERO
		_dd_diag_last_pt = Vector2.ZERO
		_dd_pos_drag_snaps = {}
		_dd_drag_delta = {}
		for wall in walls:
			if is_instance_valid(wall):
				_dd_pos_drag_snaps[wall] = _snapshot_wall(wall)
		_dd_pos_drag_active = true

	for wall in _dd_pos_drag_snaps.keys():
		if not is_instance_valid(wall):
			continue
		# Espace de coordonnees : `position` est LOCAL au parent. Les Points,
		# eux, sont traites comme du monde partout dans ce mod. Si le conteneur
		# Walls (ou Objects, d'ou vient firstItemDelta) porte une echelle, le
		# meme delta numerique ne represente pas la meme distance monde — le
		# wall se deplace alors d'un facteur different des assets, exactement
		# le symptome « sur un autre plan ». On convertit donc explicitement.
		var d = wall.position
		var wparent = wall.get_parent()
		if d != Vector2.ZERO and wparent != null and is_instance_valid(wparent):
			d = wparent.global_transform.basis_xform(d)
		if d != Vector2.ZERO:
			_dd_drag_delta[wall] = d
			# Remise a zero : la position du node ferait double emploi avec la
			# geometrie qu'on vient de deplacer.
			wall.position = Vector2.ZERO
		else:
			d = _dd_drag_delta.get(wall, Vector2.ZERO)
		if d == Vector2.ZERO:
			continue
		# remake_lines = false : RemakeLines() libere les Line2D enfants et en
		# recree d'autres. Fait depuis frame_pre_draw, la liste d'affichage de
		# la frame est deja constituee : les anciens noeuds ont disparu et les
		# nouveaux ne seront rendus qu'a la frame suivante — le wall clignote
		# hors ecran pendant tout le drag. On se contente donc de translater
		# les points des Line2D existants (le snapshot les garde valides tant
		# qu'on ne remake pas) et on remake une seule fois au relachement.
		_apply_transform_to_wall(wall, _dd_pos_drag_snaps[wall], Transform2D(0.0, d), false)


# Entree appelee par l'emitter sur le signal frame_pre_draw de VisualServer.
# Ce signal est emis juste avant VisualServer.draw(), donc APRES la phase
# input de la frame (que DD passe par process_events ou par le flush des
# evenements accumules) et APRES tous les _process. C'est le seul endroit ou
# l'on est certain de lire la derniere valeur ecrite par DD dans
# Thing.Position, de la remettre a zero, et que le rendu de la frame utilise
# bien la geometrie qu'on vient de calculer.
func on_frame_pre_draw() -> void:
	if not _dd_bake_ok:
		return
	if _g == null or select_tool == null or not is_instance_valid(select_tool):
		return
	_bake_dd_position_drag()


# Position du node du premier wall suivi par le bake, ou ZERO hors drag.
# Sert uniquement au diagnostic d'ordre d'execution.
func _dd_first_wall_position() -> Vector2:
	if not _dd_pos_drag_active:
		return Vector2.ZERO
	for wall in _dd_pos_drag_snaps.keys():
		if is_instance_valid(wall):
			return wall.position
	return Vector2.ZERO


func _dd_diag_ref_asset():
	if select_tool == null:
		return null
	var raw = select_tool.RawSelectables
	if raw == null:
		return null
	for sel in raw:
		if sel == null:
			continue
		var thing = sel.get("Thing")
		if thing == null or not is_instance_valid(thing) or not (thing is Node2D):
			continue
		if int(sel.get("Type")) == SELECTABLE_WALL:
			continue
		return thing
	return null


func _dd_drag_stop(record: bool) -> void:
	if not _dd_pos_drag_active:
		return
	_dd_pos_drag_active = false
	# Passe finale. DD reecrit la position du node APRES notre bake dans la
	# frame (son _ContentInput tourne apres notre update) : au relachement,
	# cette derniere ecriture n'est plus jamais consommee. Le node gardait donc
	# la translation complete EN PLUS de la geometrie deja deplacee — le wall
	# restait a snapshot + 2 x delta, ce fameux « autre plan ».
	for wall in _dd_pos_drag_snaps.keys():
		if not is_instance_valid(wall):
			continue
		var d = wall.position
		if d != Vector2.ZERO:
			var wparent = wall.get_parent()
			if wparent != null and is_instance_valid(wparent):
				d = wparent.global_transform.basis_xform(d)
			_dd_drag_delta[wall] = d
			wall.position = Vector2.ZERO
		else:
			d = _dd_drag_delta.get(wall, Vector2.ZERO)
		if d != Vector2.ZERO:
			_apply_transform_to_wall(wall, _dd_pos_drag_snaps[wall], Transform2D(0.0, d), false)
		# Passe unique de reconstruction, differee : _dd_drag_stop peut etre
		# appele depuis frame_pre_draw, et un RemakeLines() a ce moment ferait
		# disparaitre le wall pour une frame. call_deferred le repousse a la
		# frame suivante, avant son rendu.
		if wall.has_method("RemakeLines"):
			wall.call_deferred("RemakeLines")
		elif wall.has_method("RemakeLinesWhenAllPortalsReady"):
			wall.call_deferred("RemakeLinesWhenAllPortalsReady")
	var entries := []
	if record:
		for wall in _dd_pos_drag_snaps.keys():
			if not is_instance_valid(wall):
				continue
			entries.append({
				"wall": wall,
				"pre_snap": _dd_pos_drag_snaps[wall],
				"post_snap": _snapshot_wall(wall),
			})
	_dd_pos_drag_snaps = {}
	_dd_drag_delta = {}
	if entries.size() > 0:
		_register_walls_undo("Move Walls", entries)


func _end_group_transform() -> void:
	_transforming = false
	_drag_mode = 0
	_move_walls = []
	_ref_item = null
	_move_snapshots = {}
	_pivot = Vector2.ZERO


# Public method — meant to be called externally (e.g. by rotation_fix.gd)
# right AFTER `select_tool.RotateTransformBox(degrees)` so the walls in the
# current selection rotate the same way.
#
# Caller is responsible for capturing the box center BEFORE calling
# RotateTransformBox (DD may shift boxBegin/boxEnd as a side effect),
# and passing it as `pivot`.
# Public — rotate walls AND non-walls of the current selection around
# `pivot` (world space), and push a SINGLE unified GroupTransformRecord
# covering both. Used by rotation_fix for wheel rotations when our
# overlay is active, so the user only needs ONE Ctrl+Z to revert
# (otherwise DD's RotateTransformBox pushes its own record on top of
# our walls record → 2 Ctrl+Z).
func rotate_selection_around(degrees: float, pivot: Vector2) -> void:
	if select_tool == null or _g.Editor == null:
		return
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var rad = deg2rad(degrees)
	var W = Transform2D(0.0, pivot) * Transform2D(rad, Vector2.ZERO) * Transform2D(0.0, -pivot)
	# Build wall ID set so portals attached to a selected wall can be
	# skipped (their wall transforms them; double-touching pushes a
	# DD record).
	var selected_wall_ids := {}
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			selected_wall_ids[s.Thing.get_instance_id()] = true
	var record = GroupTransformRecord.new()
	record.owner_mod = self
	record.label = "Rotate (wheel)"
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			var pre = _capture_wall_snapshot(s.Thing)
			var snap = _snapshot_wall(s.Thing)
			_apply_transform_to_wall(s.Thing, snap, W)
			var post = _capture_wall_snapshot(s.Thing)
			record.wall_entries.append({"wall": s.Thing, "pre_snap": pre, "post_snap": post})
		elif s.Thing is Node2D:
			if s.Type == SELECTABLE_PORTAL_WALL:
				var parent = s.Thing.get_parent() if s.Thing.has_method("get_parent") else null
				if parent != null and selected_wall_ids.has(parent.get_instance_id()):
					continue
			var node = s.Thing
			var pre_pos = node.global_position
			var pre_rot = node.global_rotation
			var pre_scale = node.global_scale
			node.global_position = W.xform(pre_pos)
			node.global_rotation = pre_rot + rad
			record.non_wall_entries.append({
				"node": node,
				"pre_pos": pre_pos,
				"pre_rot": pre_rot,
				"pre_scale": pre_scale,
				"post_pos": node.global_position,
				"post_rot": node.global_rotation,
				"post_scale": node.global_scale,
			})
	# Keep the locked overlay box rotated with the content (when active).
	if _box_initialized:
		box_rotate(rad, pivot)
	# Textes sélectionnés (text_transform) : rotation identique, commit immédiat.
	var tt_rot = _tt_mixed()
	if tt_rot != null and tt_rot.has_method("dsw_apply_instant_W"):
		tt_rot.dsw_apply_instant_W(W)
	if record.wall_entries.size() > 0 or record.non_wall_entries.size() > 0:
		_push_history_record(record)


func apply_rotation_around(degrees: float, pivot: Vector2) -> void:
	if select_tool == null:
		return
	# Skip if user is mid-drag (we don't want to interfere with interactive
	# transforms — those are handled by _update_group_transform).
	if _transforming:
		return
	var split = _get_selection_split()
	var walls: Array = split[0]
	if walls.size() == 0:
		return

	var rad = deg2rad(degrees)
	var W = Transform2D(0.0, pivot) * Transform2D(rad, Vector2.ZERO) * Transform2D(0.0, -pivot)

	# Capture pre snapshots, transform, then capture post snapshots and
	# push a single undo action that restores ALL walls in lockstep
	# (one Ctrl+Z reverts the whole rotation).
	var entries := []
	for wall in walls:
		if not is_instance_valid(wall):
			continue
		var pre = _capture_wall_snapshot(wall)
		var snap = _snapshot_wall(wall)
		_apply_transform_to_wall(wall, snap, W)
		var post = _capture_wall_snapshot(wall)
		entries.append({"wall": wall, "pre_snap": pre, "post_snap": post})
	if entries.size() > 0:
		_register_walls_undo("Rotate walls (wheel)", entries)

	# Force the polling block to re-fit the box on the next frame.
	outputlog("apply_rotation_around: %d wall(s) by %.2f° around %s" % [walls.size(), degrees, str(pivot)], 1)


# Public method — translate a single wall by a world-space delta vector.
# Used by rotation_fix.gd to compensate for centroid drift after a wheel
# rotate (DD rotates non-walls around the box AABB center, which isn't
# necessarily the ensemble centroid; we translate everything by -drift to
# anchor the centroid in place).
# NOTE: this does NOT push its own undo action — the caller is expected
# to either bundle these translations into a larger action via the public
# helpers (_capture_wall_snapshot / _register_walls_undo), or accept
# that the small drift compensation isn't separately undoable. With the
# locked box model rotation_fix no longer calls this for walls, so this
# is effectively dead code kept for compatibility.
func translate_wall(wall, delta: Vector2) -> void:
	if not is_instance_valid(wall) or _transforming:
		return
	var snap = _snapshot_wall(wall)
	var W = Transform2D(0.0, delta)
	_apply_transform_to_wall(wall, snap, W)


#########################################################################################################
##
## BOX EXPANSION — wrap selected walls' AABB when mixed with non-wall items
##
#########################################################################################################

# Cheap hash of the selected walls' geometry. Samples the first, middle and
# last point of each wall (plus its point count and identity) — enough to
# catch any translation, rotation or scale, and most local edits, without
# walking long polylines every frame. Coordinates are quantised to 1/8 unit
# so float jitter doesn't produce spurious re-fits.
func _walls_geo_signature(walls: Array) -> int:
	var h := 0
	for wall in walls:
		if not is_instance_valid(wall):
			continue
		h = (h * 31 + wall.get_instance_id()) & 0x3FFFFFFF
		# Filet de securite : si un chemin externe translate le node au lieu
		# des Points, la box doit quand meme bouger (cf. _bake_dd_position_drag).
		h = _hash_point(h, wall.position)
		var pts = wall.get("Points")
		if pts == null:
			continue
		var n: int = pts.size()
		h = (h * 31 + n) & 0x3FFFFFFF
		if n == 0:
			continue
		h = _hash_point(h, pts[0])
		if n > 2:
			h = _hash_point(h, pts[n / 2])
		if n > 1:
			h = _hash_point(h, pts[n - 1])
	return h


func _hash_point(h: int, p: Vector2) -> int:
	h = (h * 31 + int(round(p.x * 8.0))) & 0x3FFFFFFF
	h = (h * 31 + int(round(p.y * 8.0))) & 0x3FFFFFFF
	return h


# ── Wall.Points ↔ Wall.pointsClosed ────────────────────────────────────────
# DD keeps a second copy of a LOOPED wall's outline in the private
# `pointsClosed` array (Points + Points[0] appended). It is built only by
# Wall.Set() and shifted by Wall.Offset() — RemakeLines() does NOT rebuild
# it. PortalTool.FindBestLocation() → Wall.FindPortalSpot() reads
# `Loop ? pointsClosed : Points`, so once we write Points directly the
# PortalTool keeps snapping new portals onto the wall's OLD outline.
# Every direct Points write must go through this helper. Godot's Mono
# property bridge reaches private auto-properties, so we can write the
# cache back ourselves; non-looped walls need nothing.
func _set_wall_points(wall, pts) -> void:
	wall.set("Points", pts)
	if wall.get("Loop") != true:
		return
	if pts == null or pts.size() < 2:
		return
	var closed := PoolVector2Array()
	for p in pts:
		closed.append(p)
	closed.append(pts[0])
	wall.set("pointsClosed", closed)
	# One-shot sanity check: if the private property turns out to be
	# unreachable, say so once instead of silently leaving portals
	# snapping to stale geometry.
	if not Engine.has_meta("_up_pointsclosed_checked"):
		Engine.set_meta("_up_pointsclosed_checked", true)
		var back = wall.get("pointsClosed")
		if back == null or back.size() != closed.size():
			printerr("[UnofficialPatch] Wall.pointsClosed is not writable from GDScript; ")
			printerr("[UnofficialPatch] portals may snap to stale geometry on looped walls.")


# AABB of all given walls' Points. Returns Rect2() if no point found.
func _compute_walls_aabb(walls: Array) -> Rect2:
	var has := false
	var minp = Vector2(INF, INF)
	var maxp = Vector2(-INF, -INF)
	for wall in walls:
		if not is_instance_valid(wall):
			continue
		var pts = wall.Points
		if pts == null or pts.size() == 0:
			continue
		# Offset du node : nul en temps normal (les Points sont en monde),
		# non nul le temps d'un instant drag de DD.
		var wpos = wall.position
		# Les Points ne decrivent que l'AXE du mur ; le ruban dessine deborde
		# de la moitie de la largeur du Line2D de chaque cote. Sans cette
		# marge la box passe a l'interieur du mur : cliquer sur une partie qui
		# depasse tombe HORS de la box.
		var ht: float = _wall_half_thickness(wall)
		var n: int = pts.size()
		var loop: bool = wall.get("Loop") == true
		for i in range(n):
			var p = pts[i] + wpos
			var e: float = _wall_point_extent(pts, i, n, loop, ht)
			if p.x - e < minp.x: minp.x = p.x - e
			if p.y - e < minp.y: minp.y = p.y - e
			if p.x + e > maxp.x: maxp.x = p.x + e
			if p.y + e > maxp.y: maxp.y = p.y + e
			has = true
	if not has:
		return Rect2()
	return Rect2(minp, maxp - minp)


# Debordement du ruban dessine autour du point d'index `i`, en pixels monde.
# Sur un segment droit c'est la demi-largeur. A une jonction c'est la longueur
# d'onglet ht / sin(angle / 2) : plus l'angle est aigu, plus la pointe part
# loin — un mur triangulaire depasse largement de l'AABB de ses Points. On
# plafonne a 4 x ht, DD biseautant les jonctions (LineJointMode.Bevel), et
# parce qu'un angle quasi nul ferait exploser la box.
func _wall_point_extent(pts, i: int, n: int, loop: bool, ht: float) -> float:
	if n < 3:
		return ht
	var has_prev: bool = i > 0 or loop
	var has_next: bool = i < n - 1 or loop
	if not has_prev or not has_next:
		return ht
	var prev: Vector2 = pts[(i - 1 + n) % n]
	var nxt: Vector2 = pts[(i + 1) % n]
	var d0: Vector2 = pts[i] - prev
	var d1: Vector2 = nxt - pts[i]
	if d0.length() < 0.001 or d1.length() < 0.001:
		return ht
	var cosv: float = clamp(-d0.normalized().dot(d1.normalized()), -1.0, 1.0)
	var half_angle: float = acos(cosv) * 0.5
	var sn: float = sin(half_angle)
	if sn < 0.001:
		return ht * 4.0
	return min(ht / sn, ht * 4.0)


# Demi-epaisseur rendue d'un wall, en pixels monde. Wall.AddLine() cree les
# Line2D du mur en ENFANTS DIRECTS et leur donne Width = Texture.GetHeight() ;
# les Line2D d'ombre, deux fois plus larges, vivent sous le noeud `shadows`.
# On ne regarde donc que les enfants directs, sinon la box doublerait.
func _wall_half_thickness(wall) -> float:
	if wall == null or not is_instance_valid(wall):
		return 0.0
	var w := 0.0
	for i in range(wall.get_child_count()):
		var child = wall.get_child(i)
		if child is Line2D and child.width > w:
			w = child.width
	return w * 0.5


# Splits the current selection into [walls_array, has_non_wall_bool].
func _get_selection_split() -> Array:
	var walls := []
	var has_non_wall := false
	var raw = select_tool.RawSelectables
	if raw == null:
		return [walls, has_non_wall]
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			walls.append(s.Thing)
		else:
			has_non_wall = true
	return [walls, has_non_wall]


# Visual AABB of a single non-wall Node2D in world space.
# Strategy (per type, prefer DD-maintained world-space properties):
#  - Object/Prop (4)        → node.SelectRect (LOCAL — must be transformed
#                             via node.global_transform to reach world)
#  - Roof (8)               → node.GlobalRect (already world-space per API)
#  - Pathway/PatternShape   → node.GlobalEditPoints (already world-space)
#  - Otherwise              → find a Sprite (via Prop.Sprite property,
#                             then child search) and compute the rotated
#                             AABB from sprite.global_position.
# Note: the Prop API doc just says "Rect2 SelectRect" without specifying
# its coord-system, but observation confirms it's local relative to the
# prop's origin (e.g. (-68,-68,135,136) for a 136px sprite centered on
# its local origin). Transform every corner by node.global_transform
# and take the AABB to land in world coords.
func _node_world_aabb(node: Node2D, type_id: int) -> Rect2:
	if node == null or not is_instance_valid(node):
		return Rect2()

	# Object/Prop (4) — DD's auto-updated SelectRect (local). Transform to world.
	if type_id == 4 and "SelectRect" in node:
		var sr = node.SelectRect
		if sr is Rect2 and (sr.size.x > 0.0 or sr.size.y > 0.0):
			var t = node.global_transform
			var p0 = t.xform(sr.position)
			var p1 = t.xform(Vector2(sr.position.x + sr.size.x, sr.position.y))
			var p2 = t.xform(sr.position + sr.size)
			var p3 = t.xform(Vector2(sr.position.x, sr.position.y + sr.size.y))
			var minp = p0
			var maxp = p0
			for p in [p1, p2, p3]:
				if p.x < minp.x: minp.x = p.x
				if p.y < minp.y: minp.y = p.y
				if p.x > maxp.x: maxp.x = p.x
				if p.y > maxp.y: maxp.y = p.y
			return Rect2(minp, maxp - minp)

	# Roof (8) — DD's world-space GlobalRect.
	if type_id == 8 and "GlobalRect" in node:
		var gr = node.GlobalRect
		if gr is Rect2 and (gr.size.x > 0.0 or gr.size.y > 0.0):
			return gr

	# Pathway (5) / PatternShape (7) — both expose a world-space
	# GlobalRect. Prefer it (cheap, accurate). If absent or empty,
	# fall back to per-type point arrays:
	#  - Pathway:      GlobalEditPoints
	#  - PatternShape: GlobalPolygon
	if type_id == 5 or type_id == 7:
		if "GlobalRect" in node:
			var gr2 = node.GlobalRect
			if gr2 is Rect2 and (gr2.size.x > 0.0 or gr2.size.y > 0.0):
				return gr2
		var gpts = null
		if type_id == 5 and "GlobalEditPoints" in node:
			gpts = node.GlobalEditPoints
		elif type_id == 7 and "GlobalPolygon" in node:
			gpts = node.GlobalPolygon
		if gpts != null and gpts.size() > 0:
			var minp = gpts[0]
			var maxp = gpts[0]
			for p in gpts:
				if p.x < minp.x: minp.x = p.x
				if p.y < minp.y: minp.y = p.y
				if p.x > maxp.x: maxp.x = p.x
				if p.y > maxp.y: maxp.y = p.y
			return Rect2(minp, maxp - minp)

	# Sprite-based fallback: try Prop's Sprite property first, then child.
	var sprite: Sprite = null
	if node is Sprite:
		sprite = node
	elif "Sprite" in node:
		var sp = node.Sprite
		if sp is Sprite:
			sprite = sp
	if sprite == null:
		for child in node.get_children():
			if child is Sprite and child.texture != null:
				sprite = child
				break

	if sprite != null and sprite.texture != null:
		var pos = sprite.global_position
		var tex_size = sprite.texture.get_size()
		var sc = sprite.global_scale
		var w = tex_size.x * abs(sc.x)
		var h = tex_size.y * abs(sc.y)
		var rot = sprite.global_rotation
		var c = abs(cos(rot))
		var s = abs(sin(rot))
		var aabb_w = w * c + h * s
		var aabb_h = w * s + h * c
		var half = Vector2(aabb_w * 0.5, aabb_h * 0.5)
		return Rect2(pos - half, half * 2.0)

	# No sprite: use position only.
	return Rect2(node.global_position, Vector2.ZERO)


# Computes the AABB of all non-wall items in the selection.
# Why we don't trust GetSelectionRect: empirically it returns stale or
# wrong rects after rotations / item moves.
# Returns Rect2() when there's no non-wall item.
func _compute_non_walls_aabb() -> Rect2:
	var has := false
	var minp = Vector2(INF, INF)
	var maxp = Vector2(-INF, -INF)
	var raw = select_tool.RawSelectables
	if raw == null:
		return Rect2()
	# Collect wall IDs to skip portals attached to a selected wall (the
	# wall already encompasses them and double-counting them shifts the
	# AABB center toward the portal).
	var selected_wall_ids := {}
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			selected_wall_ids[s.Thing.get_instance_id()] = true
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			continue
		if s.Type == SELECTABLE_PORTAL_WALL:
			var parent = s.Thing.get_parent() if s.Thing.has_method("get_parent") else null
			if parent != null and selected_wall_ids.has(parent.get_instance_id()):
				continue
		var node = s.Thing
		if not (node is Node2D):
			continue

		var aabb = _node_world_aabb(node, s.Type)
		var p_min = aabb.position
		var p_max = aabb.position + aabb.size

		if not has:
			minp = p_min
			maxp = p_max
			has = true
		else:
			if p_min.x < minp.x: minp.x = p_min.x
			if p_min.y < minp.y: minp.y = p_min.y
			if p_max.x > maxp.x: maxp.x = p_max.x
			if p_max.y > maxp.y: maxp.y = p_max.y
	if not has:
		return Rect2()
	return Rect2(minp, maxp - minp)


# Visual overlay with corner handles
#
# DD's transform-box rendering uses an internal C# rect cache for the
# selection that we can't influence from GDScript: for mixed wall+prop
# selections after the prop has been moved, DD's box only wraps the
# wall(s). We replace DD's box with our own — outline + 4 corner
# handles — and hide DD's native box while ours is active. Our overlay
# is interactive: mouse events on the handles drive move / rotate /
# scale of the whole selection (walls + non-walls).
#
# Parent: _g.World (NOT level.Objects). DD's SelectThingsInsideBox
# iterates level.Objects and casts each child to Prop — adding a plain
# Node2D there triggers an InvalidCastException every frame. _g.World
# is a generic container; free_transform.gd uses the same approach.
func _ensure_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		return
	if _g.World == null:
		return
	# Inline GDScript that performs the actual drawing. Receives an array
	# of the 4 box corners in world space (TL, TR, BR, BL in box-local
	# sense, transformed via box rotation). The corner squares are
	# axis-aligned in world space (DD's native handles don't rotate with
	# the box either).
	var src = "extends Node2D\n" \
		+ "var corners: Array = []  # 4 Vector2 in world space, TL/TR/BR/BL local order\n" \
		+ "var line_color: Color = Color(0.18, 0.62, 1.0, 0.95)\n" \
		+ "var handle_color: Color = Color(1, 1, 1, 1)\n" \
		+ "var line_width: float = 2.0\n" \
		+ "var handle_size: float = 16.0\n" \
		+ "var handle_line_width: float = 2.0\n" \
		+ "var debug_corner_r: float = 0.0\n" \
		+ "var debug_rotate_r: float = 0.0\n" \
		+ "func _draw():\n" \
		+ "\tif corners.size() < 4:\n" \
		+ "\t\treturn\n" \
		+ "\tif debug_corner_r > 0.0:\n" \
		+ "\t\t# Debug zones are drawn axis-aligned for simplicity (unrotated). The rotate halo uses the AABB of the rotated box.\n" \
		+ "\t\tvar minp = corners[0]\n" \
		+ "\t\tvar maxp = corners[0]\n" \
		+ "\t\tfor c in corners:\n" \
		+ "\t\t\tif c.x < minp.x: minp.x = c.x\n" \
		+ "\t\t\tif c.y < minp.y: minp.y = c.y\n" \
		+ "\t\t\tif c.x > maxp.x: maxp.x = c.x\n" \
		+ "\t\t\tif c.y > maxp.y: maxp.y = c.y\n" \
		+ "\t\tvar outer = Rect2(minp - Vector2(debug_rotate_r, debug_rotate_r), (maxp - minp) + Vector2(debug_rotate_r * 2.0, debug_rotate_r * 2.0))\n" \
		+ "\t\tdraw_rect(outer, Color(0.0, 0.7, 1.0, 0.10), true)\n" \
		+ "\t\tfor c in corners:\n" \
		+ "\t\t\tvar zr = Rect2(c - Vector2(debug_corner_r, debug_corner_r), Vector2(debug_corner_r * 2.0, debug_corner_r * 2.0))\n" \
		+ "\t\t\tdraw_rect(zr, Color(1.0, 1.0, 0.0, 0.25), true)\n" \
		+ "\tvar pts = PoolVector2Array([corners[0], corners[1], corners[2], corners[3], corners[0]])\n" \
		+ "\tdraw_polyline(pts, line_color, line_width, true)\n" \
		+ "\tvar hh = handle_size * 0.5\n" \
		+ "\tfor c in corners:\n" \
		+ "\t\tvar hr = Rect2(c - Vector2(hh, hh), Vector2(handle_size, handle_size))\n" \
		+ "\t\tdraw_rect(hr, handle_color, false, handle_line_width, true)\n" \
		+ "func set_state(c: Array, hs: float, hlw: float, dcr: float = 0.0, drr: float = 0.0):\n" \
		+ "\tcorners = c\n" \
		+ "\thandle_size = hs\n" \
		+ "\thandle_line_width = hlw\n" \
		+ "\tdebug_corner_r = dcr\n" \
		+ "\tdebug_rotate_r = drr\n" \
		+ "\tupdate()\n" \
		+ "func clear_state():\n" \
		+ "\tcorners = []\n" \
		+ "\tupdate()\n"
	var script = GDScript.new()
	script.source_code = src
	script.reload()
	_overlay = Node2D.new()
	_overlay.name = "DragSelectWallsOverlay"
	_overlay.z_index = 1000
	_overlay.set_script(script)
	_overlay.line_color = OVERLAY_COLOR
	_overlay.line_width = OVERLAY_WIDTH
	_g.World.add_child(_overlay)


# Returns the current world-to-screen scale (camera zoom factor).
# Used to keep our handles a constant on-screen size at any zoom.
func _get_world_to_screen_scale() -> float:
	if _g.World == null:
		return 1.0
	var viewport = _g.World.get_viewport()
	if viewport == null:
		return 1.0
	return viewport.canvas_transform.x.length()


# --- Snap helpers ---------------------------------------------------------
# Mirror clipboard_fix's snap integration:
#   - Prefer Snappy ("snappy_mod" Custom Snap) if loaded
#   - Fall back to DD's native WorldUI.GetSnappedPosition
# The mouse-distance heuristic for "is snap on" is approximate but
# matches what clipboard_fix uses, so behavior is consistent between the
# two mods.

# Returns the GDScript instance of the Snappy mod (Custom Snap) if it's
# loaded and exposes a get_snapped_position method, else null.
func _snap_get_custom_snap_api():
	var editor = _g.Editor if _g else null
	if editor == null or not ("Tools" in editor):
		return null
	var tools = editor.Tools
	if not tools.has("snappy_mod"):
		return null
	var snappy_tool = tools["snappy_mod"]
	if snappy_tool == null:
		return null
	if not snappy_tool.has_method("get_ScriptInstance"):
		return null
	var script_instance = snappy_tool.get_ScriptInstance()
	if script_instance == null:
		return null
	if not script_instance.has_method("get_snapped_position"):
		return null
	return script_instance


func _snap_get_snapped_position(pos: Vector2) -> Vector2:
	# Use Custom Snap's points only if its own enable toggle is ON;
	# otherwise fall back to DD's native grid. (The fact that we got
	# here at all means DD's IsSnapping is ON — gated by _snap_is_enabled.)
	var custom = _snap_get_custom_snap_api()
	if custom != null and "custom_snap_enabled" in custom and custom.custom_snap_enabled:
		return custom.get_snapped_position(pos)
	if _g.WorldUI != null and _g.WorldUI.has_method("GetSnappedPosition"):
		return _g.WorldUI.GetSnappedPosition(pos)
	return pos


func _snap_is_enabled() -> bool:
	# Master: DD's "Snap to Grid" toggle. When that is OFF, we never
	# snap — regardless of whether Custom Snap Mod is enabled. Custom
	# Snap only chooses WHICH points we snap to (in
	# _snap_get_snapped_position), not whether we snap at all.
	return _g.Editor != null and bool(_g.Editor.IsSnapping)


# Lit le toggle "Move, Transform and Copy Walls" du panel mod_settings.
# Quand OFF : on garde le drag-select des walls (sa raison d'etre) mais
# on n'expose plus la transform box custom ni le move/rotate/scale des
# walls. La fonction est tolerante : si mod_settings n'est pas dispo,
# on retourne true (= comportement complet par defaut).
func _is_wall_transform_enabled() -> bool:
	if _g == null or _g.ModMapData == null:
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("wall_move_transform")


# Vrai quand Free Transform est actif. La custom transform box des walls
# est alors coupée (overlay + interactions) : c'est la box verte de FT qui
# englobe les walls (visuel seul, transfos walls via la symétrie du menu
# FT). Le drag-select et l'ajout différé des walls restent actifs.
func _is_ft_active() -> bool:
	if _g == null or not (_g.ModMapData is Dictionary):
		return false
	return bool(_g.ModMapData.get("_free_transform_active", false))


# Mod-settings toggle "Snap Resize" (id: snap_resize_shift). When OFF,
# Shift+resize falls back to plain uniform scale — no aspect-ratio
# unlock, no grid snap. Used by both DragSelectWalls (custom box) and
# selection_resize (no-wall selections). Default: ON (fail-open).
func _is_snap_resize_enabled() -> bool:
	if _g == null or _g.ModMapData == null:
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("snap_resize_shift")


# --------------------------------------------------------------------------


# --- Locked box helpers ----------------------------------------------------
# The "box" is defined by _box_pos (center, world), _box_rotation (radians)
# and _box_half_size (half-W, half-H, in box-local frame). The 4 corners
# in world space are pos ± R(rot) * half. Order: TL, TR, BR, BL in local
# sense — when rotation is 0, this matches the standard rect order.

func _box_corners_world() -> Array:
	var c := cos(_box_rotation)
	var s := sin(_box_rotation)
	var hx := _box_half_size.x
	var hy := _box_half_size.y
	# Local TL, TR, BR, BL
	var locals = [Vector2(-hx, -hy), Vector2(hx, -hy), Vector2(hx, hy), Vector2(-hx, hy)]
	var world := []
	for l in locals:
		world.append(_box_pos + Vector2(c * l.x - s * l.y, s * l.x + c * l.y))
	return world


# Axis-aligned world AABB of the (possibly rotated) box. Used for
# _last_combined.
func _box_world_aabb() -> Rect2:
	var corners = _box_corners_world()
	if corners.size() == 0:
		return Rect2()
	var minp: Vector2 = corners[0]
	var maxp: Vector2 = corners[0]
	for v in corners:
		if v.x < minp.x: minp.x = v.x
		if v.y < minp.y: minp.y = v.y
		if v.x > maxp.x: maxp.x = v.x
		if v.y > maxp.y: maxp.y = v.y
	return Rect2(minp, maxp - minp)


# Convert a world-space point to box-local coordinates (rotation undone,
# then translated so box center is at origin).
func _box_world_to_local(world_pos: Vector2) -> Vector2:
	var v = world_pos - _box_pos
	var c := cos(-_box_rotation)
	var s := sin(-_box_rotation)
	return Vector2(c * v.x - s * v.y, s * v.x + c * v.y)


# text_transform (Unofficial Patch) : instance publiée dans ModMapData.
# Renvoie l'instance si des textes sont sélectionnés (bbox non vide) et que
# les hooks dsw_* sont présents, sinon null. Sert à intégrer les textes à la
# box custom : fit de l'AABB + application du même W pendant les drags.
func _tt_mixed():
	if not (_g.ModMapData is Dictionary):
		return null
	var tt = _g.ModMapData.get("_ttf_transform")
	if tt == null or not (tt is Object) or not is_instance_valid(tt):
		return null
	if not tt.has_method("dsw_get_texts_bbox") or not tt.has_method("dsw_apply_W"):
		return null
	var bb = tt.dsw_get_texts_bbox()
	if bb is Rect2 and bb.size != Vector2.ZERO:
		return tt
	return null


# Build a current-selection set keyed by Thing instance ID. Used both
# for change detection and to update _last_selection_set after re-init.
func _build_selection_set() -> Dictionary:
	var d := {}
	if select_tool == null:
		return d
	var raw = select_tool.RawSelectables
	if raw == null:
		return d
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		d[s.Thing.get_instance_id()] = true
	return d


# True if the current selection differs from _last_selection_set
# (different cardinality, or any added / removed item).
func _selection_changed() -> bool:
	var current := _build_selection_set()
	if current.size() != _last_selection_set.size():
		return true
	for id in current:
		if not _last_selection_set.has(id):
			return true
	return false


# Public update methods for transforms — these update the locked box
# state in lockstep with the items being moved/scaled/rotated. Callers
# (interactive drag handler, rotation_fix) invoke these so the box
# tracks the content without going through an AABB recompute.

func box_translate(delta: Vector2) -> void:
	if _box_initialized:
		_box_pos += delta


# Rotate the box by `angle_rad` around `pivot` (world space).
# - When `pivot` == `_box_pos` (typical for our handle / wheel rotation),
#   only `_box_rotation` changes; `_box_pos` is invariant.
# - Otherwise, `_box_pos` orbits the pivot too.
func box_rotate(angle_rad: float, pivot: Vector2) -> void:
	if not _box_initialized:
		return
	var v = _box_pos - pivot
	var c := cos(angle_rad)
	var s := sin(angle_rad)
	_box_pos = pivot + Vector2(c * v.x - s * v.y, s * v.x + c * v.y)
	_box_rotation += angle_rad


# Uniform scale of the box around `pivot` (world space). half_size_factor
# is applied to both axes; pos orbits the pivot too. _box_rotation
# unchanged.
func box_scale(factor: float, pivot: Vector2) -> void:
	if not _box_initialized:
		return
	_box_pos = pivot + (_box_pos - pivot) * factor
	_box_half_size *= factor


# --------------------------------------------------------------------------


# Recompute (or preserve) the box state and refresh the overlay rendering.
# Behaviour:
#   - When the SELECTION changes (different items chosen), re-fit the box
#     to a fresh axis-aligned AABB (matches DD's "snap to selection"
#     behavior).
#   - Otherwise, keep the locked _box_pos / _box_rotation / _box_half_size
#     untouched. They are updated only by the transform handlers
#     (box_translate / box_rotate / box_scale).
# _last_combined is computed as the world-axis-aligned AABB of the
# (possibly rotated) box; its .center always equals _box_pos.
func _update_overlay() -> void:
	var split = _get_selection_split()
	var walls: Array = split[0]
	var has_non_wall: bool = split[1]
	var wall_count: int = walls.size()
	# Same gating as _is_custom_active() — overlay only when DD's native
	# transform box would be wrong or unsuitable.
	var should_show: bool = wall_count >= 1
	if not should_show:
		_clear_overlay()
		_last_combined = Rect2()
		_box_initialized = false
		_last_selection_set = {}
		_last_tt_sig = 0
		return
	# Detect selection change → re-fit. We use _selection_changed() (which
	# compares Thing IDs) rather than always recomputing, so the box keeps
	# its rotation/position across move/scale/rotate operations.
	# La sélection de TEXTES (text_transform) déclenche aussi un re-fit : les
	# textes font partie de la box custom mais pas de RawSelectables.
	var tt_fit = _tt_mixed()
	var tt_sig = tt_fit.dsw_get_texts_signature() if (tt_fit != null and tt_fit.has_method("dsw_get_texts_signature")) else 0
	var sel_changed = _selection_changed() or tt_sig != _last_tt_sig
	# Geometry watchdog — see _wall_geo_sig. Only external edits count:
	# ours are stamped by _apply_transform_to_wall (same frame, or the
	# previous one when the edit happened during _input), and interactive
	# drags are excluded outright.
	var geo_sig := _walls_geo_signature(walls)
	var geo_moved: bool = _box_initialized and geo_sig != _wall_geo_sig \
			and _ci_mode == 0 and not _transforming \
			and (Engine.get_frames_drawn() - _geo_owned_frame) > 1
	_wall_geo_sig = geo_sig
	if sel_changed or geo_moved or not _box_initialized:
		var walls_rect: Rect2 = _compute_walls_aabb(walls)
		if walls_rect.size == Vector2.ZERO:
			_clear_overlay()
			_last_combined = Rect2()
			_box_initialized = false
			return
		var combined: Rect2 = walls_rect
		if has_non_wall:
			# Only merge non-walls when present. Rect2().merge() includes
			# (0,0) which would extend the AABB to the world origin.
			var nw_rect: Rect2 = _compute_non_walls_aabb()
			if nw_rect.size != Vector2.ZERO:
				combined = combined.merge(nw_rect)
		# Textes sélectionnés (text_transform) : inclus dans la box custom.
		if tt_fit != null:
			var tt_rect = tt_fit.dsw_get_texts_bbox()
			if tt_rect is Rect2 and tt_rect.size != Vector2.ZERO:
				combined = combined.merge(tt_rect)
		_box_pos = combined.position + combined.size * 0.5
		_box_half_size = combined.size * 0.5
		_box_rotation = 0.0
		_box_initialized = true
		_last_selection_set = _build_selection_set()
		_last_tt_sig = tt_sig
	# Compute world AABB of the (possibly rotated) box for hit testing
	# convenience and external callers that read _last_combined.center.
	_last_combined = _box_world_aabb()
	_ensure_overlay()
	if _overlay != null and is_instance_valid(_overlay) and _overlay.has_method("set_state"):
		# Sync line color with the group color (mauve) when the selection
		# is a pure custom group, default blue otherwise. Updated each
		# frame so it follows live changes from group_assets.gd's color
		# picker.
		_overlay.line_color = _current_overlay_color()
		# Use DD's own handle size if we discovered it; otherwise fall back
		# to our default. Partial-blend zoom scaling: handles stay close to
		# a constant screen size at zoom 1, but shrink a bit when zooming
		# out and grow a bit when zooming in. This matches free_transform's
		# sqrt(zoom) scaling.
		var base_px = _dd_handle_px if _dd_handle_px > 0.0 else HANDLE_SCREEN_PX
		var zoom = _get_world_to_screen_scale()
		var divisor = pow(max(zoom, 0.01), HANDLE_ZOOM_BLEND)
		var hs = base_px / divisor
		var hlw = HANDLE_LINE_WIDTH / divisor
		# Cap a fort zoom : taille ECRAN <= base_px. Le blend partiel laissait
		# les poignees grossir en zoom^(1-blend) -> enormes tres zoome. Les
		# zones de hit sont deja en px ecran, rien d'autre a ajuster.
		if zoom > 1.0:
			hs = min(hs, base_px / zoom)
			hlw = min(hlw, HANDLE_LINE_WIDTH / zoom)
		# Contour : constant en monde (2.0) => epais tres zoome. Cap ecran.
		_overlay.line_width = OVERLAY_WIDTH / max(zoom, 1.0)
		# Hit zone debug values (in world units) — only > 0 when DEBUG enabled
		var dcr = 0.0
		var drr = 0.0
		if DEBUG_DRAW_ZONES:
			dcr = CORNER_HIT_RADIUS_PX / max(zoom, 0.01)
			drr = ROTATE_BAND_PX / max(zoom, 0.01)
		# Pass the (possibly rotated) corners of the locked box.
		_overlay.set_state(_box_corners_world(), hs, hlw, dcr, drr)


func _clear_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay) and _overlay.has_method("clear_state"):
		_overlay.clear_state()


func _destroy_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null


# Lazily load DD's cursor textures from its install dir. We mirror the
# pattern used by path_fix.gd / free_transform.gd: read the PNG with
# Image.load(), wrap in an ImageTexture. Failed loads silently fall back
# to standard cursor shapes.
# Loads DD's handle_round.png once and reads its natural dimensions —
# DD uses this exact texture for its transform-box handles, so the
# pixel size tells us the zone DD considers a "corner / edge midpoint
# hit". We use the larger axis as the canonical size. Also loads DD's
# cursor textures (drag/scale/rotate) which we apply via
# Input.set_custom_mouse_cursor to force a visible cursor change over
# DD's Control nodes (set_default_cursor_shape is ignored on Controls).
# Called once from start() so values are available before the first
# overlay draw.
func _load_handle_size() -> void:
	if _handle_size_loaded:
		return
	_handle_size_loaded = true
	if _g == null or _g.Root == null:
		outputlog("_load_handle_size: _g.Root is null, can't read DD textures", 0)
		return
	var himg = Image.new()
	if himg.load(_g.Root + "icons/handle_round.png") == OK:
		_dd_handle_px = max(himg.get_width(), himg.get_height())
		outputlog("DD handle texture size: %dx%d (using %.0fpx)" % [himg.get_width(), himg.get_height(), _dd_handle_px], 0)
	else:
		outputlog("DD handle_round.png FAILED to load — using fallback %.0fpx" % HANDLE_SCREEN_PX, 0)
	# Cursor textures
	var cursor_files = [
		["icons/drag-cursor-icon.png", "_cursor_tex_move"],
		["icons/resize-nwse.png",      "_cursor_tex_scale_nwse"],
		["icons/resize-nesw.png",      "_cursor_tex_scale_nesw"],
		["icons/drop_cursor.png",      "_cursor_tex_rotate"],
	]
	for pair in cursor_files:
		var img = Image.new()
		var err = img.load(_g.Root + pair[0])
		if err == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img, 0)
			set(pair[1], tex)
			outputlog("Cursor texture loaded: %s (%dx%d)" % [pair[0], img.get_width(), img.get_height()], 0)
		else:
			outputlog("Cursor texture FAILED: %s (err %d)" % [pair[0], err], 0)


# Tracks the current cursor shape and logs whenever it changes. Useful
# to discover what shape DD uses in different zones (move, scale corner,
# rotate, etc.) — hover the mouse over a normal DD selection (no walls
# in selection so our overlay doesn't take over) and read the log to see
# which CURSOR_* constants DD is calling Input.set_default_cursor_shape
# with. We can then map our zones to match.
var _last_cursor_shape: int = -1
var _last_set_cursor_shape: int = -1  # last shape WE set (separate from _last_cursor_shape which is what's currently active)
var _we_have_active_custom: bool = false  # true when our custom CURSOR_ARROW is currently set; used to edge-trigger clear so we don't fight DD's cursor every frame

func _log_cursor_shape() -> void:
	var cur = Input.get_current_cursor_shape()
	if cur != _last_cursor_shape:
		_last_cursor_shape = cur
		outputlog("Cursor shape changed to %d (%s)" % [cur, _cursor_shape_name(cur)], 0)


static func _cursor_shape_name(shape: int) -> String:
	match shape:
		Input.CURSOR_ARROW: return "ARROW"
		Input.CURSOR_IBEAM: return "IBEAM"
		Input.CURSOR_POINTING_HAND: return "POINTING_HAND"
		Input.CURSOR_CROSS: return "CROSS"
		Input.CURSOR_WAIT: return "WAIT"
		Input.CURSOR_BUSY: return "BUSY"
		Input.CURSOR_DRAG: return "DRAG"
		Input.CURSOR_CAN_DROP: return "CAN_DROP"
		Input.CURSOR_FORBIDDEN: return "FORBIDDEN"
		Input.CURSOR_VSIZE: return "VSIZE"
		Input.CURSOR_HSIZE: return "HSIZE"
		Input.CURSOR_BDIAGSIZE: return "BDIAGSIZE (\\)"
		Input.CURSOR_FDIAGSIZE: return "FDIAGSIZE (/)"
		Input.CURSOR_MOVE: return "MOVE"
		Input.CURSOR_VSPLIT: return "VSPLIT"
		Input.CURSOR_HSPLIT: return "HSPLIT"
		Input.CURSOR_HELP: return "HELP"
		_: return "UNKNOWN"


# Hit test: which handle / region is `world_pos` inside, given the
# locked box state. The `rect` parameter is kept for backward-compat
# callers but ignored — we test against the rotated box defined by
# _box_pos / _box_rotation / _box_half_size.
# Returns dict {mode: int, corner: int}.
#   mode: 0=none, 1=move, 2=rotate, 3=scale (uniform, ratio-preserved)
#   corner: -1 if not applicable, else 0=TL, 1=TR, 2=BR, 3=BL (box-local)
#
# Implementation: convert world_pos to box-local coordinates (rotation
# undone, then translated so box center is at origin). The hit test
# then runs against an axis-aligned rect of half-size _box_half_size
# centered at origin — same logic as before, but in the box's frame.
func _custom_hit_test(world_pos: Vector2, rect: Rect2) -> Dictionary:
	var none = {"mode": 0, "corner": -1}
	var hx = _box_half_size.x
	var hy = _box_half_size.y
	if hx <= 0.0 or hy <= 0.0:
		return none
	var zoom = _get_world_to_screen_scale()
	# Hit zones at a CONSTANT screen-pixel size (not zoom-blended like
	# the visual handles).
	var corner_r = CORNER_HIT_RADIUS_PX / max(zoom, 0.01)
	var rotate_r = ROTATE_BAND_PX / max(zoom, 0.01)
	# Convert mouse to box-local coords. Rotation is preserved → distances
	# are unchanged, so corner_r / rotate_r are still in the same units.
	var local = _box_world_to_local(world_pos)
	# Local corners (TL, TR, BR, BL).
	var local_corners = [
		Vector2(-hx, -hy),
		Vector2( hx, -hy),
		Vector2( hx,  hy),
		Vector2(-hx,  hy),
	]
	# 1. Within corner_r (square zone) of any corner → scale.
	for i in range(4):
		var c = local_corners[i]
		if abs(local.x - c.x) <= corner_r and abs(local.y - c.y) <= corner_r:
			return {"mode": 3, "corner": i}
	# 2. Inside the (local) box → move.
	if abs(local.x) <= hx and abs(local.y) <= hy:
		return {"mode": 1, "corner": -1}
	# 3. Outside but within rotate_r of any box point → rotate. Chebyshev
	#    so the inflated rotate zone has right-angle corners.
	var dx = max(0.0, abs(local.x) - hx)
	var dy = max(0.0, abs(local.y) - hy)
	if max(dx, dy) <= rotate_r:
		# Closest local corner — used by callers that care (cursor pick).
		var best_d = INF
		var best_i = 0
		for i in range(4):
			var d = local.distance_to(local_corners[i])
			if d < best_d:
				best_d = d
				best_i = i
		return {"mode": 2, "corner": best_i}
	return none


# Convert a screen-space position (e.g. event.position) to world coords
# using the viewport's canvas transform.
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	if _g.World == null:
		return screen_pos
	var viewport = _g.World.get_viewport()
	if viewport == null:
		return screen_pos
	return viewport.canvas_transform.affine_inverse().xform(screen_pos)


# Update the cursor based on current hover (when not actively dragging).
# We try DD's actual cursor textures (loaded from its icons/ dir on first
# use); if loading failed for some reason we fall back to standard
# CURSOR_* shapes — those still match DD's choices per the cursor-log.
#
# Texture mapping (from free_transform.gd / path_fix.gd):
#   move          → drag-cursor-icon.png       (hand)
#   scale TL/BR   → resize-nwse.png            (\ shape)
#   scale TR/BL   → resize-nesw.png            (/ shape)
#   rotate        → rotate.png                 (curved arrow)
# Update the cursor based on current hover (when not actively dragging).
# Uses native Godot CURSOR_* shapes only — these match what DD uses
# natively (per the cursor-shape diagnostic log):
#   inside    → CURSOR_MOVE       (13)
#   TL / BR   → CURSOR_BDIAGSIZE  (11) — \ shape
#   TR / BL   → CURSOR_FDIAGSIZE  (12) — / shape
#   rotate    → CURSOR_CAN_DROP   (7)
#   outside   → CURSOR_ARROW      (0)
func _custom_update_cursor() -> void:
	if _ci_mode != 0:
		return  # cursor is locked to the active drag mode until release

	# Decide whether we want to display OUR cursor this frame, and which.
	# We only ever modify the cursor when we have a real zone hit; outside
	# our zones we leave DD's cursor logic alone (edge-trigger model). This
	# avoids overwriting DD's own ARROW custom on every frame, which would
	# break native transform-box cursors elsewhere in the editor.
	var tex = null
	var shape = Input.CURSOR_ARROW
	var want_custom = false
	if not _mouse_over_ui() and _last_combined.size != Vector2.ZERO:
		var hit = _custom_hit_test(_mouse_world, _last_combined)
		match hit.mode:
			1:  # move
				tex = _cursor_tex_move
				shape = Input.CURSOR_MOVE
				want_custom = true
			2:  # rotate (around perimeter, beyond resize zone)
				tex = _cursor_tex_rotate
				shape = Input.CURSOR_CAN_DROP
				want_custom = true
			3:  # uniform scale (corner)
				if hit.corner == 0 or hit.corner == 2:  # TL or BR → \
					tex = _cursor_tex_scale_nwse
					shape = Input.CURSOR_BDIAGSIZE
					want_custom = true
				elif hit.corner == 1 or hit.corner == 3:  # TR or BL → /
					tex = _cursor_tex_scale_nesw
					shape = Input.CURSOR_FDIAGSIZE
					want_custom = true

	if want_custom and tex != null:
		# DD's world is a Control; CURSOR_ARROW is the active shape over
		# it, so override its custom for ARROW with our zone-specific
		# texture (matches path_fix.gd / light_fix.gd / free_transform.gd).
		Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() * 0.5)
		_we_have_active_custom = true
	elif _we_have_active_custom:
		# Edge: we just left a zone (or hit_test returned nothing). Clear
		# our custom ONCE so DD's normal ARROW (or its own ARROW custom
		# for the native box, etc.) takes over again.
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_we_have_active_custom = false
	# else: do nothing — leave DD's cursor logic alone.

	# Diagnostic — log only when shape choice changes
	if shape != _last_set_cursor_shape:
		_last_set_cursor_shape = shape
		print("[cur] hit.mode=%d → set %s tex=%s want_custom=%s" % [-1 if not want_custom else (1 if shape == Input.CURSOR_MOVE else (2 if shape == Input.CURSOR_CAN_DROP else 3)), _cursor_shape_name(shape), "yes" if tex != null else "no", want_custom])


# Snapshot every selectable item for the duration of a custom drag.
func _custom_start_drag(world_pos: Vector2, hit: Dictionary) -> void:
	_log_history_index("BEFORE start_drag")
	_ci_mode = hit.mode
	_ci_corner = hit.corner
	_ci_drag_start_world = world_pos
	_log_history_index("start_drag")
	_ci_initial_rect = _last_combined  # kept for any legacy callers; unused below
	# Use the rotated box corners as the source of truth for pivot /
	# initial corner, so scale / rotate operations are correct even when
	# the box is at a non-zero rotation.
	var corners = _box_corners_world()
	# Pivot per mode.
	if _ci_mode == 3 and _ci_corner >= 0:
		_ci_pivot = corners[(_ci_corner + 2) % 4]  # opposite corner
	elif _ci_mode == 2:
		_ci_pivot = _box_pos  # box center
		_ci_initial_angle = (world_pos - _ci_pivot).angle()
		_ci_last_angle = _ci_initial_angle
		_ci_total_rot = 0.0
	else:
		_ci_pivot = _box_pos

	# Snapshot all selected things. First pass: collect the set of wall
	# instance IDs so we can detect which portals belong to a wall that
	# is also being transformed (those portals get moved by the wall's
	# transform automatically — touching them again here would push a
	# second history record on top of ours).
	_ci_things = []
	# Mark our custom drag as active in ModMapData so other mods can
	# bail out (alt_deselect's handle_alt_click(), etc.) instead of
	# triggering native behaviors that fight with our overlay during
	# the drag.
	_g.ModMapData["_drag_select_walls_active"] = true
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var selected_wall_ids := {}
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SELECTABLE_WALL:
			selected_wall_ids[s.Thing.get_instance_id()] = true
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		# Portal attached to a wall that's also selected → its wall will
		# transform it; skip to avoid double work + extra DD records.
		if s.Type == SELECTABLE_PORTAL_WALL:
			var parent = s.Thing.get_parent() if s.Thing.has_method("get_parent") else null
			if parent != null and selected_wall_ids.has(parent.get_instance_id()):
				continue
		var snap = {}
		if s.Thing is Node2D:
			snap["pos"] = s.Thing.global_position
			snap["rot"] = s.Thing.global_rotation
			snap["scale"] = s.Thing.global_scale
		if s.Type == SELECTABLE_WALL:
			snap["wall_snap"] = _snapshot_wall(s.Thing)
			# Full snapshot including style for undo. _snapshot_wall is
			# geometry-only (used to compute transforms incrementally).
			snap["wall_undo_pre"] = _capture_wall_snapshot(s.Thing)
		elif s.Type == SELECTABLE_PATHWAY:
			# Snapshot LOCAL EditPoints; deformation is applied via
			# W.basis_xform on each local point (W's translation cancels
			# out since global_position follows the box stretch). Assumes
			# the path node's basis is identity (typical for paths after
			# any free_transform bake) — otherwise rotation would leak.
			var ep = s.Thing.get("EditPoints")
			if ep != null:
				var pts = []
				for p in ep:
					pts.append(p)
				snap["path_local_pts"] = pts
			# Snapshot Line2D children so they can be deformed alongside
			# the path. The dashed selection indicator child (texture
			# dotted_line.png) is hidden during the drag and restored
			# at the end — see _hide_dashed_selection_children — because
			# DD repaints it from the path's geometry on closed loops in
			# a way that desyncs with our W.basis_xform deformation
			# under non-uniform scale (interaction with path_fix).
			snap["line_children"] = _snap_line2d_children(s.Thing)
		elif s.Type == SELECTABLE_PATTERN_SHAPE:
			# Same convention as paths: snapshot the LOCAL polygon.
			var poly = s.Thing.get("polygon")
			if poly != null and poly.size() > 0:
				var pts = []
				for p in poly:
					pts.append(p)
				snap["pattern_local_pts"] = pts
			snap["line_children"] = _snap_line2d_children(s.Thing)
		_ci_things.append({"thing": s.Thing, "type": s.Type, "snap": snap})

	# Hide the dashed selection-indicator children of paths and patterns
	# during scale drags. Both types deform their internal geometry
	# arrays under Shift (path EditPoints, pattern polygon), and the
	# dashed Line2D children get repainted by DD in ways that desync
	# from our deformation. Restored at end_drag, with points copied
	# from the parent's current geometry so the dashed line shows the
	# post-drag shape immediately on unhide.
	_ci_dashed_hidden = []
	if _ci_mode == 3:
		for entry in _ci_things:
			if entry.type == SELECTABLE_PATHWAY or entry.type == SELECTABLE_PATTERN_SHAPE:
				_hide_dashed_selection_children(entry.thing)

	# Snapshot of box state at drag start, used to compute incremental
	# updates as the mouse moves (so we apply absolute transforms to the
	# initial state rather than accumulating numerical drift).
	_ci_box_pos_initial = _box_pos
	_ci_box_rotation_initial = _box_rotation
	_ci_box_half_size_initial = _box_half_size
	_ci_box_corner_initial = corners[_ci_corner] if _ci_corner >= 0 else Vector2.ZERO

	# We do NOT call select_tool.SavePreTransforms() — DD would push its
	# own history record on RecordTransforms() at the end, on top of our
	# own GroupTransformRecord, requiring two Ctrl+Z to undo. Instead we
	# snapshot pre-state ourselves (already done above via entry.snap)
	# and push a single unified record at end_drag.
	# Keep DD's transformMode at None — we drive the transform ourselves.
	select_tool.transformMode = 0

	# Textes sélectionnés (text_transform) : ils suivent la box custom.
	_ci_tt = _tt_mixed()
	if _ci_tt != null and _ci_tt.has_method("dsw_begin_transform"):
		_ci_tt.dsw_begin_transform()


# Build the world-space transform W from the current mouse position
# given the active drag mode + initial state. Returns identity if nothing
# meaningful to apply (eg drag of zero distance).
#
# For SCALE we deliberately compute a single uniform scale factor that
# preserves the original aspect ratio: project the mouse vector (from
# the pivot/opposite corner) onto the diagonal direction (pivot →
# initial corner) and divide by the diagonal squared length. This gives
# a signed scalar applied to both axes, so the box keeps its shape.
func _custom_compute_W(world_pos: Vector2) -> Transform2D:
	match _ci_mode:
		1:  # move
			# Snap the box center to the grid (or Custom Snap, if loaded).
			# The selection follows whatever effective delta lands the box
			# on a snap point — so the visible box always sits on the grid
			# during drag, and items shift consistently with it.
			var raw_delta = world_pos - _ci_drag_start_world
			var new_center = _ci_box_pos_initial + raw_delta
			if _snap_is_enabled():
				new_center = _snap_get_snapped_position(new_center)
			return Transform2D(0.0, new_center - _ci_box_pos_initial)
		2:  # rotate (around box center)
			# Cumulative tracking: accumulate the per-frame angle delta,
			# wrapped to (-PI, PI), so crossing the ±180° boundary doesn't
			# jump by 360°. This also lets the user wind past a full
			# rotation without the rotation snapping back.
			var current_angle = (world_pos - _ci_pivot).angle()
			var dStep = current_angle - _ci_last_angle
			while dStep > PI:
				dStep -= TAU
			while dStep < -PI:
				dStep += TAU
			_ci_total_rot += dStep
			_ci_last_angle = current_angle
			# Shift held → snap the cumulative rotation to multiples of
			# CUSTOM_ROTATE_SNAP_DEG (default 45°). _ci_total_rot is the
			# cumulative drag angle (no clamp), so big rotations still
			# work — just snap the FINAL applied rotation. Independent of
			# rotation_snap.gd which snaps DD's NATIVE box rotation drag
			# (transformMode == 2, never reached when our overlay is active).
			var applied_rot = _ci_total_rot
			if Input.is_key_pressed(KEY_SHIFT):
				var snap_rad = deg2rad(CUSTOM_ROTATE_SNAP_DEG)
				applied_rot = round(_ci_total_rot / snap_rad) * snap_rad
			return Transform2D(0.0, _ci_pivot) * Transform2D(applied_rot, Vector2.ZERO) * Transform2D(0.0, -_ci_pivot)
		3:  # scale (corner drag)
			# Modifier keys (port of selection_resize.gd's behavior to
			# our locked-box overlay):
			#   Alt   → scale from the BOX CENTER instead of the
			#           opposite corner. Both halves grow / shrink
			#           symmetrically.
			#   Shift → snap the dragged-corner target to the grid and
			#           apply NON-UNIFORM scale so the corner lands on
			#           the snapped point on BOTH axes (X and Y).
			#           Without Shift, scale stays uniform (aspect
			#           ratio preserved via diagonal projection).
			# (Snappy mod honored when present.)
			var alt = Input.is_key_pressed(KEY_ALT)
			var shift = Input.is_key_pressed(KEY_SHIFT)
			# "Snap Resize" mod-settings toggle: when OFF, Shift behaves
			# as if not held (uniform scale, no aspect-ratio unlock, no
			# grid snap). Lets users disable this feature without
			# uninstalling the mod.
			if shift and not _is_snap_resize_enabled():
				shift = false
			# Pivot: opposite corner by default, box center under Alt.
			var pivot = _ci_pivot
			if alt:
				pivot = _ci_box_pos_initial
			# Stash the pivot so _custom_apply_W can use the same one.
			_ci_effective_pivot = pivot
			# Reference vector: pivot → dragged corner (at drag start).
			var vi = _ci_box_corner_initial - pivot
			var vi_len_sq = vi.dot(vi)
			if vi_len_sq <= 0.001:
				_ci_scale_sx = 1.0
				_ci_scale_sy = 1.0
				return Transform2D.IDENTITY
			var corner_target = world_pos
			# Shift always unlocks the aspect ratio (non-uniform scale).
			# Whether the dragged corner is snapped to the grid is gated
			# separately on Snap To Grid being enabled in DD (or the
			# Snappy mod): with snap ON, the corner lands on a grid
			# point in BOTH axes; with snap OFF, the corner follows the
			# mouse freely while still scaling each axis independently.
			# Track Shift state explicitly so apply-time decisions don't
			# depend on the post-math sx/sy values (which can be equal
			# by coincidence even when Shift is held).
			_ci_shift_held = shift
			if shift:
				if _snap_is_enabled():
					corner_target = _snap_get_snapped_position(corner_target)
				# Non-uniform scale: solve sx, sy in the box's LOCAL
				# frame so the dragged corner lands at corner_target
				# in BOTH axes. Box local frame = world rotated by
				# -box_rot; pivot at origin.
				var box_rot = _ci_box_rotation_initial
				var local_vi = vi.rotated(-box_rot)
				var local_target = (corner_target - pivot).rotated(-box_rot)
				var sx = 1.0
				var sy = 1.0
				if abs(local_vi.x) > 0.001:
					sx = local_target.x / local_vi.x
				if abs(local_vi.y) > 0.001:
					sy = local_target.y / local_vi.y
				_ci_scale_sx = sx
				_ci_scale_sy = sy
				# W = T(pivot) · R(box_rot) · S(sx,sy) · R(-box_rot) · T(-pivot)
				return Transform2D(0.0, pivot) \
					* Transform2D(box_rot, Vector2.ZERO) \
					* Transform2D.IDENTITY.scaled(Vector2(sx, sy)) \
					* Transform2D(-box_rot, Vector2.ZERO) \
					* Transform2D(0.0, -pivot)
			# Uniform scale via diagonal projection.
			var s = vi.dot(corner_target - pivot) / vi_len_sq
			_ci_scale_sx = s
			_ci_scale_sy = s
			return Transform2D(0.0, pivot) * Transform2D.IDENTITY.scaled(Vector2(s, s)) * Transform2D(0.0, -pivot)
	return Transform2D.IDENTITY


# Apply transform W to every snapshotted thing AND update the locked box
# state. Uses the drag-start snapshot of the box (_ci_box_*_initial) so
# each frame computes an absolute transform from the start, avoiding
# accumulated drift from frame-by-frame composition.
func _custom_apply_W(W: Transform2D) -> void:
	for entry in _ci_things:
		var thing = entry.thing
		if not is_instance_valid(thing):
			continue
		var type_id = entry.type
		var snap = entry.snap
		if type_id == SELECTABLE_WALL:
			if snap.has("wall_snap"):
				_apply_transform_to_wall(thing, snap.wall_snap, W)
		elif thing is Node2D:
			# Default: position follows the box. The scale branch may
			# override this for patterns under Shift (world-anchored
			# texture trick — keeps pattern.position at snap.pos).
			thing.global_position = W.xform(snap.pos)
			match _ci_mode:
				2:  # rotate
					thing.global_rotation = snap.rot + W.get_rotation()
				3:  # scale — design:
					#   No Shift (W uniform)  → real resize: scale the
					#       node itself (and its descendants) via
					#       global_scale. Geometry arrays (polygon,
					#       EditPoints) are NOT touched, so textures
					#       and line widths follow the canvas transform
					#       naturally — uniform scale on everything.
					#   Shift (W non-uniform) → tracé only:
					#     - Paths: deform EditPoints. Line width stays
					#       constant in pixels (node.scale unchanged),
					#       polyline stretches via geometry.
					#     - Patterns: WORLD-ANCHORED texture approach.
					#       pattern.global_position is held at snap.pos
					#       (NOT W.xform(snap.pos)), and the entire W
					#       transform is encoded into the polygon's
					#       local vertex coords. This keeps the
					#       pattern's local origin at the same world
					#       position as before, so DD's pattern shader
					#       (which samples texture by local VERTEX /
					#       textureSize) renders each tile at the same
					#       world position with the same size in
					#       screen pixels — the polygon just clips
					#       more or less of the world-anchored
					#       texture, instead of stretching the tiles
					#       (node.scale approach) or sliding them
					#       (deform polygon + move pattern.position).
					#     - Assets: only reposition.
					var sx_abs = abs(_ci_scale_sx)
					var sy_abs = abs(_ci_scale_sy)
					if not _ci_shift_held:
						# No Shift — uniform scale on the node. If a
						# prior frame in this drag deformed path
						# EditPoints or pattern polygon under Shift,
						# restore them now so the rendered shape
						# matches the (pristine) snapshot under the
						# new uniform scale.
						thing.global_scale = snap.scale * sx_abs
						if type_id == SELECTABLE_PATHWAY and snap.has("path_local_pts"):
							_restore_path_geometry(thing, snap.path_local_pts)
						elif type_id == SELECTABLE_PATTERN_SHAPE and snap.has("pattern_local_pts"):
							_restore_pattern_geometry(thing, snap.pattern_local_pts, snap.get("line_children", {}))
					else:
						# Shift branch.
						thing.global_scale = snap.scale
						if type_id == SELECTABLE_PATHWAY and snap.has("path_local_pts"):
							_apply_scale_to_path(thing, snap.path_local_pts, snap.get("line_children", {}), W)
						elif type_id == SELECTABLE_PATTERN_SHAPE and snap.has("pattern_local_pts"):
							# Override the default position set above:
							# keep pattern at the original world
							# location so tiles (anchored to local
							# origin → world origin) stay put. The
							# polygon absorbs the entire W transform
							# including its translation component.
							thing.global_position = snap.pos
							_apply_world_anchored_pattern(thing, snap.pattern_local_pts, snap.get("line_children", {}), snap.pos, W)
						# else: other Node2D — only reposition (default
						# global_position above), no scale change.
				# move → only position changed
	# Sync box state. We compute the absolute new state from the drag-
	# start snapshot, NOT from the current state — so each frame is
	# self-correcting. _box_initialized is preserved (still locked).
	match _ci_mode:
		1:  # move — translate _box_pos by W's translation
			_box_pos = _ci_box_pos_initial + W.origin
		2:  # rotate — _box_pos invariant (pivot == box center). Use W's
			# actual rotation (which may have been snapped to 45° by
			# Shift in _custom_compute_W) so the visible box matches
			# what the items got, instead of tracking the raw mouse
			# accumulation _ci_total_rot.
			_box_pos = _ci_box_pos_initial  # stays on pivot
			_box_rotation = _ci_box_rotation_initial + W.get_rotation()
		3:  # scale — non-uniform aware. Read sx, sy stashed by
			# _custom_compute_W for this frame; box rotation unchanged.
			# Position uses W.xform of the initial center directly,
			# which is correct for both uniform and non-uniform W.
			_box_pos = W.xform(_ci_box_pos_initial)
			_box_half_size = Vector2(
				_ci_box_half_size_initial.x * abs(_ci_scale_sx),
				_ci_box_half_size_initial.y * abs(_ci_scale_sy)
			)
			_box_rotation = _ci_box_rotation_initial

	# Textes sélectionnés (text_transform) : même W que le reste de la sélection.
	if _ci_tt != null and is_instance_valid(_ci_tt) and _ci_tt.has_method("dsw_apply_W"):
		_ci_tt.dsw_apply_W(W, _ci_mode, _ci_scale_sx, _ci_scale_sy, _ci_shift_held)


func _custom_drag_motion(world_pos: Vector2) -> void:
	if _ci_mode == 0:
		return
	var W = _custom_compute_W(world_pos)
	_custom_apply_W(W)


func _custom_end_drag() -> void:
	if _ci_mode == 0:
		return
	# RemakeLines was skipped during the drag for performance — call it
	# now once per affected wall so the final visuals (line caps,
	# portal holes, etc) match the new geometry.
	for entry in _ci_things:
		if entry.type != SELECTABLE_WALL:
			continue
		var wall = entry.thing
		if not is_instance_valid(wall):
			continue
		if wall.has_method("RemakeLines"):
			wall.RemakeLines()
		elif wall.has_method("RemakeLinesWhenAllPortalsReady"):
			wall.RemakeLinesWhenAllPortalsReady()
	_log_history_index("end_drag (before push)")
	# Single unified record covering walls + non-walls (one Ctrl+Z
	# reverts everything). We do NOT call RecordTransforms — DD would
	# push its own record on top of ours.
	var action_name := "Transform"
	match _ci_mode:
		1: action_name = "Move"
		2: action_name = "Rotate"
		3: action_name = "Scale"
	var record = _build_group_record_from_ci_things(action_name)
	if record != null:
		_push_history_record(record)
	_log_history_index("end_drag (after push)")
	_ci_mode = 0
	_ci_corner = -1
	_ci_things = []
	# Sync each previously-hidden dashed selection indicator's `points`
	# to match its parent path's current visible points BEFORE making
	# them visible again — otherwise the dashed line would briefly show
	# at its pre-drag position until something (mouse hover) makes DD
	# refresh its selection visuals.
	_restore_dashed_selection_children()
	# Commit des textes suivis (dataOnFocus + persistance + undo côté
	# text_transform, en parallèle de notre GroupTransformRecord).
	if _ci_tt != null and is_instance_valid(_ci_tt) and _ci_tt.has_method("dsw_end_transform"):
		_ci_tt.dsw_end_transform()
	_ci_tt = null
	_g.ModMapData["_drag_select_walls_active"] = false
	# Clear our custom cursor; the next on_process tick will pick the
	# right hover cursor based on where the mouse is.
	if _we_have_active_custom:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_we_have_active_custom = false


# True as soon as the selection holds at least one wall — that is, as soon as
# our overlay is the one responsible for the transform box.
#
# Unlike _is_custom_active(), this deliberately ignores isDrawing. DD turns a
# click into a drag-select whenever its own hit test misses the wall (it
# tolerates 32 px from the AXIS, so the outer edge of a thick wall or the tip
# of a sharp corner does not register), and during that state the overlay is
# hidden — but DD's box must NOT come back, or the user sees two boxes of
# different sizes. Public: wall_move.gd reads it through _dsw_owns_box().
func _selection_owns_box() -> bool:
	if select_tool == null:
		return false
	if _g.Editor == null or _g.Editor.ActiveToolName != "SelectTool":
		return false
	return _get_selection_split()[0].size() >= 1


# True when our custom box should be active (mixed wall+prop selection,
# SelectTool current, not in a drag-select).
func _is_custom_active() -> bool:
	if select_tool == null:
		return false
	if _g.Editor == null or _g.Editor.ActiveToolName != "SelectTool":
		return false
	if select_tool.isDrawing:
		return false
	var split = _get_selection_split()
	var walls: Array = split[0]
	var wall_count: int = walls.size()
	# Our overlay owns every selection that contains at least one wall.
	# DD's native box is unusable in all of those cases:
	#   - 2+ walls only: its box only wraps the first wall
	#   - 1+ walls AND 1+ non-walls: it silently drops the non-walls
	#   - 1 wall on its own: the box is the wall's AABB, so a FLAT wall
	#     gets a degenerate rectangle with no usable rotate handle, and a
	#     diagonal one gets a box far too loose to rotate or scale with.
	# Owning the box also keeps DD from latching transformMode when
	# wall_move force-selects a wall (see _enable_dd_box_if_owned there).
	# Selections without any wall → DD's native box, untouched.
	return wall_count >= 1


# If the click is on a different (non-selected) asset highlighted by DD,
# clear our selection so DD picks it up natively — same passthrough
# logic as transform_box_fix.gd, adapted to our custom box. Returns
# true when the caller should NOT intercept the click.
# NOTE: caller is expected to handle modifiers (Shift / Alt / Ctrl)
# before invoking this — we only deal with the no-modifier case.
func _try_passthrough_click() -> bool:
	var highlighted = select_tool.get("highlighted")
	if highlighted == null:
		return false
	var hover_thing = null
	if typeof(highlighted) == TYPE_OBJECT and is_instance_valid(highlighted):
		hover_thing = highlighted.get("Thing")
	if hover_thing == null:
		return false
	if typeof(hover_thing) == TYPE_OBJECT and not is_instance_valid(hover_thing):
		return false
	# Already in the selection → no passthrough, our box handles the move.
	var raw = select_tool.RawSelectables
	if raw != null:
		for s in raw:
			if s == null or not is_instance_valid(s):
				continue
			var t = s.get("Thing")
			if t != null and is_instance_valid(t) and t == hover_thing:
				return false
	# Different asset under the mouse → deselect so DD picks it up.
	select_tool.DeselectAll()
	select_tool.EnableTransformBox(false)
	return true


# True if the current selection is a pure custom group — same logic as
# group_assets.gd's _selection_is_pure_custom_group: every selected
# Thing shares the same prefab_id >= CUSTOM_GROUP_MIN_ID.
func _selection_is_pure_custom_group() -> bool:
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return false
	var custom_gid := -1
	var seen := {}
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if seen.has(s.Thing):
			continue
		seen[s.Thing] = true
		var thing = s.Thing
		if not thing.has_meta("prefab_id"):
			return false
		var pid = thing.get_meta("prefab_id")
		if not (pid is int) or pid < CUSTOM_GROUP_MIN_ID:
			return false
		if custom_gid == -1:
			custom_gid = pid
		elif pid != custom_gid:
			return false
	return custom_gid != -1 and seen.size() >= 2


# Pick the overlay line color: when the selection is a pure custom
# group, use the group color group_assets.gd writes into WorldUI's
# transform stylebox; otherwise use our default blue OVERLAY_COLOR.
func _current_overlay_color() -> Color:
	if not _selection_is_pure_custom_group():
		return OVERLAY_COLOR
	var world_ui = _g.WorldUI
	if world_ui != null and world_ui.transformStyleBox != null:
		var sb = world_ui.transformStyleBox
		if sb.get("border_color") != null:
			var c = sb.border_color
			return Color(c.r, c.g, c.b, OVERLAY_COLOR.a)
		if sb.get("bg_color") != null:
			var c = sb.bg_color
			return Color(c.r, c.g, c.b, OVERLAY_COLOR.a)
	# Fallback to group_assets.gd's default mauve if we can't read it.
	return Color(0.878, 0.686, 1.0, OVERLAY_COLOR.a)


# Alt+click handler — deselect a single asset under the mouse if it's
# part of our current selection. Mirrors alt_deselect.gd's per-asset
# deselect, but invoked directly (we can't rely on alt_deselect's
# polling because DD would replace our multi-selection first when its
# native transform box is hidden by our overlay).
func _try_alt_deselect_one() -> bool:
	var highlighted = select_tool.get("highlighted")
	if highlighted == null:
		return false
	var hover_thing = null
	if typeof(highlighted) == TYPE_OBJECT and is_instance_valid(highlighted):
		hover_thing = highlighted.get("Thing")
	if hover_thing == null:
		return false
	if typeof(hover_thing) == TYPE_OBJECT and not is_instance_valid(hover_thing):
		return false
	# Only deselect if the hovered thing is currently in our selection.
	var raw = select_tool.RawSelectables
	if raw == null:
		return false
	var found := false
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var t = s.get("Thing")
		if t != null and is_instance_valid(t) and t == hover_thing:
			found = true
			break
	if not found:
		return false
	# Reset transformMode and deselect just this one. Mirror alt_deselect.gd's
	# initialRelativeTransforms cleanup so DD doesn't blow up later.
	select_tool.transformMode = 0
	select_tool.SelectThing(hover_thing, false)
	var irt = select_tool.get("initialRelativeTransforms")
	if irt != null:
		var valid = {}
		for s in select_tool.RawSelectables:
			valid[s] = true
		var to_remove = []
		for key in irt.keys():
			if not valid.has(key):
				to_remove.append(key)
		for key in to_remove:
			irt.erase(key)
	# If something remains, refresh DD's selection rect so it stays
	# coherent for any code that reads it (DD itself, other mods).
	# Our custom box recomputes from _last_selection_set on next frame.
	if select_tool.Selected.size() == 0:
		select_tool.EnableTransformBox(false)
	return true


# True if the mouse is currently over a Dungeondraft UI panel / menu.
# We use this to suppress box-manipulation: clicks land on UI, hover
# cursor stays as the OS arrow over panels, etc.
func _mouse_over_ui() -> bool:
	if ui_util == null or _input_listener == null:
		return false
	return ui_util.is_mouse_over_ui(_input_listener)


# Input event handler — invoked by the emitter's _input.
func on_input(event) -> void:
	# Si "Move, Transform and Copy Walls" est OFF, on ne traite aucun
	# input ici : pas de drag sur la custom box, pas de motion tracking
	# de la box. Le drag-select reste gere par DD et notre on_process,
	# qui n'a pas besoin de capturer les inputs ici.
	if not _is_wall_transform_enabled():
		return
	# FT actif : la custom box est remplacée par la box verte de FT, on
	# ne capture donc aucun input ici (pas de drag move/rotate/scale).
	if _is_ft_active():
		return
	if event is InputEventMouseMotion:
		_mouse_world = _screen_to_world(event.position)
		if _ci_mode > 0:
			_custom_drag_motion(_mouse_world)
			# Consume so DD doesn't try to drag-select / instant-drag.
			if _g.World != null:
				_g.World.get_tree().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		var world_pos = _screen_to_world(event.position)
		_mouse_world = world_pos
		if event.pressed:
			if not _is_custom_active():
				return
			# Don't intercept clicks that land on DD's UI panels / menus —
			# they should reach the controls underneath.
			if _mouse_over_ui():
				return
			var hit = _custom_hit_test(world_pos, _last_combined)
			if hit.mode > 0:
				# Modifier handling for clicks inside the move zone (mode 1).
				# Handles (scale corners / rotate band, mode 2/3) always
				# work as handles regardless of modifiers.
				if hit.mode == 1:
					# Ctrl+click anywhere inside box → clear all selection.
					if Input.is_key_pressed(KEY_CONTROL):
						select_tool.transformMode = 0
						select_tool.DeselectAll()
						select_tool.EnableTransformBox(false)
						if _g.World != null:
							_g.World.get_tree().set_input_as_handled()
						return
					# Alt (without Shift) → deselect a single asset directly.
					# We CAN'T just passthrough: DD's transform box is hidden,
					# so DD would treat the click as a fresh single-select
					# (replacing our multi-selection) before alt_deselect.gd
					# could react. We always consume so DD doesn't run its
					# own click logic.
					if Input.is_key_pressed(KEY_ALT) and not Input.is_key_pressed(KEY_SHIFT):
						_try_alt_deselect_one()
						if _g.World != null:
							_g.World.get_tree().set_input_as_handled()
						return
					# Shift (with or without Alt) → passthrough so DD handles
					# additive select and alt_deselect.gd's Shift+Alt
					# drag-deselect-box can run.
					if Input.is_key_pressed(KEY_SHIFT):
						return
					# No modifier: passthrough only when clicking a different
					# (non-selected) asset highlighted by DD.
					if _try_passthrough_click():
						return
				_custom_start_drag(world_pos, hit)
				if _g.World != null:
					_g.World.get_tree().set_input_as_handled()
		else:
			if _ci_mode > 0:
				_custom_end_drag()
				if _g.World != null:
					_g.World.get_tree().set_input_as_handled()


#########################################################################################################
##
## PROCESS — all logic runs here
##
#########################################################################################################

func on_process(_delta):
	# Profiler hook: when Main's F10 profiler is active, accumulate this
	# listener's per-frame cost (it runs outside Main.update's dispatch).
	if _g == null or not (_g.ModMapData is Dictionary) or not _g.ModMapData.get("_prof_dsw_on", false):
		_on_process_impl(_delta)
		return
	var _t0 := OS.get_ticks_usec()
	_on_process_impl(_delta)
	_g.ModMapData["_prof_dsw_usec"] = _g.ModMapData.get("_prof_dsw_usec", 0) + (OS.get_ticks_usec() - _t0)


func _on_process_impl(_delta):
	# Referme la porte du bake : seule la branche nominale ci-dessous la
	# rouvre pour la frame courante.
	_dd_bake_ok = false
	if _g.Editor.ActiveToolName != "SelectTool":
		if _was_drawing:
			_clear_highlights()
			_clear_portal_highlights()
			_was_drawing = false
		if _transforming:
			_end_group_transform()
		if _ci_mode > 0:
			_custom_end_drag()
		_clear_overlay()
		_last_combined = Rect2()
		if _dd_box_hidden_by_us:
			select_tool.EnableTransformBox(true)
			_dd_box_hidden_by_us = false
			_dd_box_hidden_during_tm = false
		if _we_have_active_custom:
			Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
			_we_have_active_custom = false
		return

	var is_drawing = select_tool.isDrawing

	# --- Drag-select: highlight walls during selection ---
	if is_drawing:
		_was_drawing = true
		_last_box_begin = select_tool.boxBegin
		_last_box_end = select_tool.boxEnd
		# Sample the Shift+Alt "deselect" modifier every drawing frame; the
		# last value before mouse release is the intent we latch below.
		_drag_deselect_sampled = Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT)
		_update_highlights()
		_update_portal_highlights()
		# DD re-sélectionne les things cachés à CHAQUE motion de box
		# (SelectThingsInsideBox ne teste pas la visibilité) : purge en
		# continu pour garder la sélection propre pendant le tracé.
		_remove_hidden_from_selection(false)
	elif _was_drawing:
		_was_drawing = false
		_clear_highlights()
		_clear_portal_highlights()
		# Purge sur la frame de release, AVANT le rendu : la passe différée
		# (2 frames plus tard) laissait la transform box flasher une fraction
		# de seconde autour d'un thing caché.
		_remove_hidden_from_selection()
		if _last_box_begin.distance_to(_last_box_end) > MIN_DISTANCE:
			var box = _normalize_box(_last_box_begin, _last_box_end)
			_deferred_box_start = box[0]
			_deferred_box_end = box[1]
			_deferred_frames = 2
			# Latch deselect intent: OR the last sampled value with the
			# current key state (keys may still be held on the release
			# frame even if they lapsed during the final drawing frame).
			_deferred_deselect = _drag_deselect_sampled or (Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT))
		_drag_deselect_sampled = false

	# Deferred wall addition countdown
	if _deferred_frames > 0:
		_deferred_frames -= 1
	elif _deferred_frames == 0:
		_deferred_frames = -1
		_add_walls_to_selection()
		_add_portals_to_selection()
		_remove_hidden_from_selection()
		_deferred_deselect = false

	# Tout ce qui suit (transform de groupe, custom box, cursor) ne doit
	# pas s'executer quand "Move, Transform and Copy Walls" est OFF dans
	# mod_settings : seul le drag-select doit rester. On nettoie d'abord
	# l'etat residuel et on retourne.
	if not _is_wall_transform_enabled() or _is_ft_active():
		if _transforming:
			_end_group_transform()
		if _ci_mode > 0:
			_custom_end_drag()
		_clear_overlay()
		_last_combined = Rect2()
		if _dd_box_hidden_by_us:
			select_tool.EnableTransformBox(true)
			_dd_box_hidden_by_us = false
			_dd_box_hidden_during_tm = false
		if _we_have_active_custom:
			Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
			_we_have_active_custom = false
		return

	# --- Group transform: walls follow DD items for move / rotate / scale ---
	var tm = select_tool.transformMode  # 0=None, 1=Move, 2=Rotate, 3=Scale

	if tm == 0 and _transforming:
		# Drag ended (or mode dropped to None) → finalize first
		_end_group_transform()
	elif tm > 0 and not _transforming and not is_drawing:
		# A transform just started (any mode)
		_start_group_transform()
	elif tm > 0 and _transforming:
		# Transform in progress: re-derive W from ref item and reapply to walls
		_update_group_transform()

	# --- Instant drag de DD : Position du node -> Points ---------------------
	# On ne bake PAS ici : DD ecrit Thing.Position depuis _on_Content_gui_input,
	# dont l'ordre par rapport a notre _process n'est pas garanti. Quand son
	# ecriture tombe apres la notre, le wall est dessine a
	# Points(base + d_precedent) + position(d_courant) : il file devant le
	# reste du prefab — l'effet de "parallaxe". On se contente d'ouvrir la
	# porte, et le bake tourne dans frame_pre_draw, toujours apres la phase
	# input et juste avant le rendu.
	_dd_bake_ok = true
	_dd_dbg_proc_pos = _dd_first_wall_position()

	# --- Box expansion: include walls' AABB in the transform box ---
	# --- Visual overlay update ---
	# We always recompute (even during transforms) so the outline tracks
	# the live combined AABB; we only hide it during a drag-select since
	# DD's drag rect is shown there instead.
	if is_drawing or _dd_pos_drag_active:
		_clear_overlay()
		if _dd_pos_drag_active or _selection_owns_box():
			# Instant drag: DD's own box is stale (it is fitted once, at
			# selection time, and never follows the move) and a plain drag
			# does not need it. Keep it hidden for the whole drag; the
			# selection is dropped on release anyway.
			# Drag-select: same treatment as soon as the selection holds a
			# wall. Restoring DD's box here was showing a SECOND box, fitted
			# on the bare Points (so visibly thinner than ours), for as long
			# as isDrawing stayed true — i.e. the whole time the button was
			# held down after a click DD had turned into a drag-select.
			select_tool.EnableTransformBox(false)
			_dd_box_hidden_by_us = true
			_dd_box_hidden_during_tm = false
		elif _dd_box_hidden_by_us:
			# When the user starts a drag-select, restore DD's box visibility
			# so future selection state goes back to normal. Also clear our
			# ARROW custom (if any) so DD's drag-select cursor isn't masked.
			select_tool.EnableTransformBox(true)
			_dd_box_hidden_by_us = false
			_dd_box_hidden_during_tm = false
		if _we_have_active_custom:
			Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
			_we_have_active_custom = false
	else:
		_update_overlay()
		# Hide DD's native box while the custom one is active. We force
		# this each frame because DD re-enables internally on selection
		# events. Skipping while a transform is in progress avoids
		# fighting DD during its own drags.
		var overlay_owns_box = _is_custom_active()
		var custom_active = overlay_owns_box and tm == 0
		if custom_active:
			select_tool.EnableTransformBox(false)
			_dd_box_hidden_by_us = true
			_dd_box_hidden_during_tm = false
			_custom_update_cursor()
		elif overlay_owns_box and tm > 0:
			# DD latched one of its own transforms even though our overlay
			# owns this selection. It happens on the very first press of a
			# wall_move click-drag: wall_move selects the wall and calls
			# EnableTransformBox(true) (needed so DD keeps a valid box for
			# single FLAT walls), then DD's _ContentInput sees
			# transformBox.Visible and sets transformMode = GetTransformMode().
			# We never got a tm == 0 frame in between, so the box was still
			# visible and stayed stranded at the pre-drag position for the
			# whole drag — the "second box" the user sees.
			# Hiding it now is safe: SelectTool only reads transformBox.Visible
			# when LATCHING a transform (and for wheel-rotate); once
			# transformMode is set, the motion and release paths only test
			# transformMode, so Disable() can't abort the drag.
			# Issued once per transform — re-toggling every frame during a
			# live DD drag is what the original tm == 0 guard avoided.
			if not _dd_box_hidden_during_tm:
				select_tool.EnableTransformBox(false)
				_dd_box_hidden_during_tm = true
				_dd_box_hidden_by_us = true
		elif _dd_box_hidden_by_us:
			select_tool.EnableTransformBox(true)
			_dd_box_hidden_by_us = false
			_dd_box_hidden_during_tm = false
			# Clear our ARROW custom so DD's other transform boxes regain
			# their normal cursor behavior. We DON'T touch
			# set_default_cursor_shape because that interferes with DD's
			# keyboard shortcuts (per eyedropper.gd's note).
			if _we_have_active_custom:
				Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
				_we_have_active_custom = false

	# FINAL FAILSAFE: if our custom is still set but we're not actively
	# managing the cursor (custom_active = false), clear it. Catches edge
	# cases where state transitions don't fire the elif branch (e.g.
	# is_drawing path, _dd_box_hidden_by_us reset elsewhere).
	if _we_have_active_custom and not (_is_custom_active() and select_tool.transformMode == 0 and not is_drawing):
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_we_have_active_custom = false
		print("[cur] FAILSAFE clear: had active custom while overlay inactive")

	# Cursor-shape diagnostics: log when DD (or anyone) changes the
	# cursor. Lets us discover which CURSOR_* shapes DD uses in each
	# zone of its native box, so we can mirror them.
	_log_cursor_shape()

#########################################################################################################
##
## SETUP
##
#########################################################################################################

func set_up_input_capture():
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tif VisualServer.has_signal(\"frame_pre_draw\"):\n\t\tVisualServer.connect(\"frame_pre_draw\", self, \"_on_frame_pre_draw\")\nfunc _on_frame_pre_draw():\n\tif handler != null:\n\t\thandler.on_frame_pre_draw()\nfunc _process(d):\n\tif handler != null:\n\t\thandler.on_process(d)\nfunc _input(e):\n\tif handler != null:\n\t\thandler.on_input(e)\n"
	s.reload()
	var emitter = Node.new()
	emitter.name = "DragSelectWallsEmitter"
	emitter.set_script(s)
	emitter.handler = self
	_input_listener = emitter
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", emitter)

#########################################################################################################
##
## START
##
#########################################################################################################

func start() -> void:
	outputlog("Drag to Select Walls Mod Has been loaded.")
	select_tool = _g.Editor.Tools["SelectTool"]
	_load_handle_size()
	set_up_input_capture()
	# Expose ourselves so other mods (e.g. clipboard_fix) can read the
	# locked box state for things like copy/paste center.
	if _g.ModMapData != null:
		_g.ModMapData["_drag_select_walls"] = self


# Public getter — returns the world center of the locked box if our
# overlay is currently active, otherwise null. Used by clipboard_fix
# to align the copy/paste center with the visible selection box.
func get_selection_center():
	if _box_initialized:
		return _box_pos
	return null
