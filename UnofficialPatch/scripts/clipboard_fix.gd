# clipboard_fix.gd
# Sub-mod for BugFixes - Cut, paste-at-cursor, paste-in-place, instant snap
#
# Feature 1: Cut (Ctrl+X) - copies then deletes selection
# Feature 2: Paste at cursor (Ctrl+V) - moves pasted items to cursor position
# Feature 3: Paste in place (Ctrl+Shift+V) - pastes items at their original position
# Feature 4: Wall copy/paste (DD doesn't support it natively)
#   NOTE: Portals are NOT copied due to DD API limitations
# Feature 5: Instant snap at paste - snaps items BEFORE showing them (no visible movement)
# Feature 6: Snap after drag - free movement during drag, snap when released

var _g
var select_tool
var input_listener: Node

var _mouse_world_pos := Vector2.ZERO
var _paste_cursor_target := Vector2.ZERO
var _paste_move_counter := -1
var _paste_hidden_nodes := []
var _restore_previous_tool := ""
var _restore_frames := -1
var _preview_nodes := []
var _copy_center := Vector2.ZERO
var _has_copy_center := false
var _paste_in_place := false

# Wall clipboard
var _wall_clipboard := []
var _has_wall_clipboard := false
var _rebuild_box_frames := -1
var _last_pasted_walls := []

# Drag snap state (from paste_snap_fix)
var _pasted_ids := {}
var _all_known_ids := {}
var _tracked_positions := {}
# Maps node_id -> Vector2 (position at the moment of paste, after the
# cursor snap). Used to relocate nodes after DD's redo recreates them
# at their original spawn position. Never cleared on undo so a later
# Ctrl+Y can find them.
var _paste_positions := {}
# Frames to wait after a Ctrl+Y press before reapplying paste positions.
# DD recreates the nodes asynchronously over a frame or two.
var _redo_relocate_counter := -1
var _drag_active := false
var _snap_disabled := false
var _saved_cell_size := Vector2.ZERO
var _prev_transform_mode := 0

# State pour reconstruire le clipboard quand DD le rend vide sur une selection
# mixte (roofs + autres). Snapshot pris au Ctrl+C, verifie 2 frames apres.
var _post_copy_check_counter := -1
var _post_copy_selection: Array = []
var _rebuilding_clipboard := false  # Garde-fou pendant la reconstruction

# ── Pont "Colour and Modify Things" (CMT) ────────────────────────────────────
# Le mod tiers applique ses teintes HSL aux nodes collés via
# pasteButton.pressed -> CustomDataManager.apply_custom_data_to_pasted_nodes,
# qui ESTIME les node_id collés en comptant a rebours depuis nextNodeID. Cette
# estimation derape sur les grosses selections (nodes auxiliaires qui avancent
# nextNodeID, clipboard reconstruit...), d'ou la couleur appliquee au mauvais
# asset. On neutralise ce chemin et on re-applique nous-memes aux nodes collES
# EXACTS (que DD vient de selectionner), en reutilisant le copied_data_store
# deja rempli par store_copy_data (qu'on laisse branche).
var _cmt_manager = null          # Instance de CustomDataManager du mod tiers
var _cmt_setup_done := false
var _cmt_setup_attempts := 0

# Constants
const SELECTABLE_WALL := 1
const SELECTABLE_PATHWAY := 5
const SELECTABLE_PATTERN_SHAPE := 7
const OFFSNAP_THRESHOLD := 5.0
const TRANSFORM_MODE_NONE := 0
const TRANSFORM_MODE_MOVE := 1


func _tt() -> Object:
	return _g.ModMapData.get("_ttf_transform") if _g.ModMapData.has("_ttf_transform") else null


func _has_text_selection() -> bool:
	var tt = _tt()
	return tt != null and tt._selected_texts.size() > 0


# Get Custom Snap mod instance via ScriptInstance (if available)
func _get_custom_snap_api():
	var editor = _g.Editor if _g else null
	if editor == null or not ("Tools" in editor):
		return null
	
	var tools = editor.Tools
	if not tools.has("snappy_mod"):
		return null
	
	var snappy_tool = tools["snappy_mod"]
	if snappy_tool == null:
		return null
	
	# Get the GDScript instance from the C# wrapper
	if not snappy_tool.has_method("get_ScriptInstance"):
		return null
	
	var script_instance = snappy_tool.get_ScriptInstance()
	if script_instance == null:
		return null
	
	if script_instance.has_method("get_snapped_position"):
		return script_instance
	
	return null


# Get snapped position - uses Custom Snap if available, otherwise DD native
func _get_snapped_position(pos: Vector2) -> Vector2:
	var custom_snap = _get_custom_snap_api()
	if custom_snap != null:
		return custom_snap.get_snapped_position(pos)
	return _g.WorldUI.GetSnappedPosition(pos)


# Check if snap is enabled
func _is_snap_enabled() -> bool:
	# If Custom Snap is available via _Lib, check its state
	var custom_snap = _get_custom_snap_api()
	if custom_snap != null and custom_snap.custom_snap_enabled:
		return true
	# Otherwise check DD native snap
	var snap_pos = _g.WorldUI.SnappedPosition
	var mouse_pos = _g.WorldUI.MousePosition
	return snap_pos.distance_to(mouse_pos) > 1.0


func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	_install_input_listener()
	print("[ClipboardFix] Initialized (with integrated snap)")


# ── Pont "Colour and Modify Things" (CMT) ────────────────────────────────────

# Localise l'instance CustomDataManager du mod tiers via la connexion native du
# pasteButton, puis NEUTRALISE ce chemin (back-count nextNodeID peu fiable).
# Idempotent ; reessaie chaque frame tant que le mod n'a pas branche sa connexion,
# puis abandonne au bout de ~10s si le mod est absent.
func _cmt_try_setup() -> void:
	if _cmt_setup_done:
		return
	_cmt_setup_attempts += 1
	if _cmt_setup_attempts > 600:
		_cmt_setup_done = true  # mod absent : on n'essaie plus
		return
	if _g == null or _g.get("Editor") == null or _g.Editor.get("Toolset") == null:
		return
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel):
		return
	var paste_btn = panel.get("pasteButton")
	if paste_btn == null or not is_instance_valid(paste_btn):
		return
	# Chercher la connexion native du mod tiers sur "pressed".
	for c in paste_btn.get_signal_connection_list("pressed"):
		if c.get("method") == "apply_custom_data_to_pasted_nodes":
			_cmt_manager = c.get("target")
			break
	if _cmt_manager == null or not is_instance_valid(_cmt_manager):
		return  # CMT pas (encore) branche ; on reessaiera au prochain frame
	# Neutraliser le chemin natif fragile (on re-appliquera nous-memes au paste).
	if paste_btn.is_connected("pressed", _cmt_manager, "apply_custom_data_to_pasted_nodes"):
		paste_btn.disconnect("pressed", _cmt_manager, "apply_custom_data_to_pasted_nodes")
	_cmt_setup_done = true
	print("[ClipboardFix] CMT bridge active (native paste recolour neutralised)")


# Re-applique les donnees couleur du mod tiers aux nodes collES EXACTS.
# Reutilise copied_data_store (rempli par store_copy_data, qu'on laisse branche)
# et mappe record[index] -> node[index] par type, l'ordre par node_id croissant
# correspondant a l'ordre de creation = ordre de collage.
func _cmt_apply_to_pasted(nodes: Array) -> void:
	if not _cmt_setup_done or _cmt_manager == null or not is_instance_valid(_cmt_manager):
		return
	if nodes.empty():
		return
	var store = _cmt_manager.get("copied_data_store")
	if store == null or not (store is Dictionary):
		return

	# Grouper les nodes collES par type via le classifieur du mod tiers.
	var by_type := {"objects": [], "paths": [], "pattern_shapes": [], "portals": []}
	for node in nodes:
		if node == null or not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var ntype = _cmt_manager.get_node_type(node)
		if ntype != null and by_type.has(ntype):
			by_type[ntype].append(node)

	# Garde anti-collage etranger : les comptes par type doivent correspondre a
	# la derniere copie (sinon le presse-papiers ne vient pas de notre copie).
	for t in by_type.keys():
		var rec_count = store[t].size() if (store.has(t) and store[t] is Array) else 0
		if rec_count != by_type[t].size():
			return

	# Trier chaque type par node_id croissant (= ordre de creation = collage).
	for t in by_type.keys():
		by_type[t].sort_custom(self, "_cmt_sort_by_node_id")

	# Appliquer record[index] -> node[index].
	var applied := 0
	for t in by_type.keys():
		if not store.has(t) or not (store[t] is Array):
			continue
		for rec in store[t]:
			if not (rec is Dictionary) or not rec.has("index"):
				continue
			var idx = int(rec["index"])
			if idx < 0 or idx >= by_type[t].size():
				continue
			rec["type"] = t
			if _cmt_manager.is_data_default(rec):
				continue
			_cmt_manager.emit_signal("apply_custom_data_to_node", by_type[t][idx], rec)
			applied += 1
	if applied > 0:
		print("[ClipboardFix] CMT bridge: re-applied colour to %d pasted node(s)" % applied)


func _cmt_sort_by_node_id(a, b) -> bool:
	return int(a.get_meta("node_id")) < int(b.get_meta("node_id"))


func _is_paste_under_cursor_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("paste_under_cursor")


func _is_paste_snap_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("paste_snap")


# Lit le toggle "Move, Transform and Copy Walls" du Settings panel.
# OFF = pas de copy/paste de walls (les walls sont skip au copy, le clipboard
# wall reste vide donc rien a paste cote walls).
func _is_wall_move_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("wall_move_transform")


# World position du centre de l'ecran (= la ou DD vanilla pose les items
# au paste). Utilise quand Paste Under Cursor est OFF pour reproduire le
# comportement vanilla (et non un paste-in-place a cote de la source).
func _get_screen_center_world() -> Vector2:
	var camera = _g.Camera
	if camera and camera is Camera2D:
		var viewport = camera.get_viewport()
		if viewport:
			var screen_center = viewport.size * 0.5
			var canvas_xform = camera.get_canvas_transform()
			return canvas_xform.affine_inverse().xform(screen_center)
	return _mouse_world_pos


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "ClipboardFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _process(delta) -> void:\n\tif handler != null:\n\t\thandler._on_process(delta)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


func _on_input(event) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_update_mouse_world_pos()

	if event is InputEventKey and event.pressed and event.control:
		if event.scancode == KEY_X:
			_on_cut()
		elif event.scancode == KEY_C:
			_save_copy_center()
			_snapshot_selection_for_rebuild()
		elif event.scancode == KEY_V:
			if event.shift:
				_on_paste_in_place()
			else:
				_on_paste()
		elif event.scancode == KEY_Y or (event.scancode == KEY_Z and event.shift):
			# Ctrl+Y or Ctrl+Shift+Z: kick off the redo relocator. The
			# counter resets on every press so multiple successive Ctrl+Y
			# in a row keep the relocator active across the whole burst.
			_redo_relocate_counter = 10


func _on_process(_delta) -> void:
	# Tentative de branchement du pont CMT (no-op une fois fait / mod absent).
	if not _cmt_setup_done:
		_cmt_try_setup()

	# Handle paste movement
	if _paste_move_counter > 0:
		_paste_move_counter -= 1
		select_tool.EnableTransformBox(false)
		_hide_pasted_items()
	elif _paste_move_counter == 0:
		_paste_move_counter = -1
		_move_pasted_items_to_cursor()

	# Restore PreviousTool after DD has processed the X key
	if _restore_frames > 0:
		_restore_frames -= 1
	elif _restore_frames == 0:
		_restore_frames = -1
		_g.Editor.Toolset.PreviousTool = _restore_previous_tool

	# Deferred transform box rebuild after paste
	if _rebuild_box_frames > 0:
		_rebuild_box_frames -= 1
	elif _rebuild_box_frames == 0:
		_rebuild_box_frames = -1
		_rebuild_transform_box()
	
	# Handle drag snap for pasted items
	_update_drag_snap()
	
	# Redo relocator: after a Ctrl+Y press we run the relocator on
	# EVERY frame for a short window, not only at the end of the
	# countdown. DD recreates nodes asynchronously and its redo of
	# successive Ctrl+Y can spread across multiple frames; running
	# every frame guarantees we catch the node as soon as it's back
	# in the tree. The map is keyed by node_id and only touches nodes
	# that exist now, so re-running is harmless.
	if _redo_relocate_counter > 0:
		_apply_paste_position_redo()
		_redo_relocate_counter -= 1

	# Post-Ctrl+C check : si DD a rendu un clipboard vide alors qu'on avait
	# une selection (typiquement un mix roof+autres qui declenche un bug
	# de serialisation DD), on reconstruit le clipboard en copiant chaque
	# sous-ensemble separement puis en mergeant.
	if _post_copy_check_counter > 0:
		_post_copy_check_counter -= 1
	elif _post_copy_check_counter == 0:
		_post_copy_check_counter = -1
		_check_and_rebuild_clipboard()


func _apply_paste_position_redo() -> void:
	if _paste_positions.empty():
		return
	if _g.World == null or not _g.World.has_method("HasNodeID"):
		return
	for nid in _paste_positions.keys():
		if not _g.World.HasNodeID(nid):
			continue
		var node = _g.World.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			continue
		# Only relocate nodes that DD just brought back: skip if
		# already at the saved position (i.e. node didn't move during
		# the undo/redo cycle, e.g. a wall handled by our own record).
		if node is Node2D:
			node.position = _paste_positions[nid]


func _update_mouse_world_pos() -> void:
	var camera = _g.Camera
	if camera and camera is Camera2D:
		var viewport = camera.get_viewport()
		if viewport:
			var screen_pos = viewport.get_mouse_position()
			var canvas_xform = camera.get_canvas_transform()
			_mouse_world_pos = canvas_xform.affine_inverse().xform(screen_pos)


func _get_visual_center(s) -> Vector2:
	if s.Type == SELECTABLE_WALL or s.Type == SELECTABLE_PATTERN_SHAPE or s.Type == SELECTABLE_PATHWAY:
		var rect = s.Thing.GlobalRect
		return rect.position + rect.size * 0.5
	# Un Roof a position=(0,0) en local : sa vraie position visible est
	# encodee dans les Polygon2D enfants. Identification par le parent "Roofs"
	# (level.Roofs.get_children()). Sans ce cas, dd_center est tire vers (0,0)
	# et le delta de cursor devient enorme -> le roof est paste tres loin.
	if s.Thing is Node and s.Thing.get_parent() != null and s.Thing.get_parent().name == "Roofs":
		var center = _compute_roof_visual_center(s.Thing)
		if center != Vector2.INF:
			return center
	return s.Thing.global_position


func _compute_roof_visual_center(roof: Node) -> Vector2:
	# Bounding box des polygons enfants en espace global, puis centre.
	var min_p = Vector2.INF
	var max_p = -Vector2.INF
	var found = false
	for child in roof.get_children():
		if child is Polygon2D:
			var xform = child.get_global_transform()
			for p in child.polygon:
				var w = xform.xform(p)
				if not found:
					min_p = w
					max_p = w
					found = true
				else:
					min_p.x = min(min_p.x, w.x)
					min_p.y = min(min_p.y, w.y)
					max_p.x = max(max_p.x, w.x)
					max_p.y = max(max_p.y, w.y)
	if not found:
		return Vector2.INF
	return (min_p + max_p) * 0.5


# ══════════════════════════════════════════════════════════════════════════════
# DRAG SNAP LOGIC (integrated from paste_snap_fix)
# ══════════════════════════════════════════════════════════════════════════════

func _update_drag_snap() -> void:
	# Toggle: drag-snap-after-paste is the runtime side of "Paste Snap".
	if not _is_paste_snap_enabled():
		_restore_snap()
		_reset_drag_state()
		return
	if _g.Editor.ActiveToolName != "SelectTool":
		_restore_snap()
		_reset_drag_state()
		return
	
	# Skip if paste is in progress
	if _paste_move_counter >= 0:
		return
	
	var raw = select_tool.RawSelectables
	var selectables := {}
	var current_ids := {}
	
	if raw != null:
		for s in raw:
			if s == null or s.Thing == null or not is_instance_valid(s.Thing):
				continue
			var nid = s.Thing.get_instance_id()
			if current_ids.has(nid):
				continue
			current_ids[nid] = true
			selectables[s.Thing] = s.Type
	
	if selectables.size() == 0:
		_restore_snap()
		_pasted_ids.clear()
		_drag_active = false
		_tracked_positions.clear()
		_prev_transform_mode = TRANSFORM_MODE_NONE
		return
	
	# Track all IDs we see
	for node in selectables.keys():
		if node != null and is_instance_valid(node):
			_all_known_ids[node.get_instance_id()] = true
	
	# Only track drag for items we pasted
	if _pasted_ids.size() == 0:
		# Defensif: si on a aucun pasted_id en cours mais que _snap_disabled
		# est reste true (etat bloque apres switch tool / Esc / undo en plein
		# drag, etc), on restore CellSize. Sans ca, un drag d'asset non
		# selectionne (jamais paste) ne snap pas car CellSize est encore
		# (1,1) d'une session paste precedente.
		_restore_snap()
		_update_tracked_positions(selectables)
		_prev_transform_mode = select_tool.transformMode
		return
	
	# Check if selection still contains pasted items
	var has_pasted := false
	for nid in current_ids.keys():
		if _pasted_ids.has(nid):
			has_pasted = true
			break
	
	if not has_pasted:
		_restore_snap()
		_pasted_ids.clear()
		_update_tracked_positions(selectables)
		_drag_active = false
		_prev_transform_mode = select_tool.transformMode
		return
	
	# Check if snap is enabled
	if not _snap_disabled:
		if not _is_snap_enabled():
			_update_tracked_positions(selectables)
			_drag_active = false
			_prev_transform_mode = select_tool.transformMode
			return
	
	var current_mode = select_tool.transformMode
	
	# Detect start of drag - disable snap for free positioning
	if current_mode == TRANSFORM_MODE_MOVE and not _snap_disabled:
		_saved_cell_size = _g.WorldUI.CellSize
		_g.WorldUI.CellSize = Vector2(1, 1)
		_snap_disabled = true
		_drag_active = true
	
	# Detect end of drag (transformMode goes from Move to None)
	var drag_ended = (_prev_transform_mode == TRANSFORM_MODE_MOVE and current_mode == TRANSFORM_MODE_NONE)
	var just_moved = select_tool.justManualMoved
	
	if (drag_ended or just_moved) and _snap_disabled:
		_g.WorldUI.CellSize = _saved_cell_size
		_apply_snap_to_selection(selectables)
		_snap_disabled = false
		_drag_active = false
		_pasted_ids.clear()
	
	_prev_transform_mode = current_mode
	_update_tracked_positions(selectables)


func _apply_snap_to_selection(selectables: Dictionary) -> void:
	var snap_delta = _compute_snap_delta_from_selectables(selectables)
	if snap_delta.length() < 1.0:
		return
	
	# Snap objects
	for node in selectables.keys():
		if node == null or not is_instance_valid(node):
			continue
		if selectables[node] == SELECTABLE_WALL:
			node.Offset(snap_delta)
		elif node is Node2D:
			node.global_position += snap_delta
	
	# Also snap walls from clipboard paste
	var pasted_walls = _g.ModMapData.get("_clipboard_pasted_walls", [])
	if pasted_walls is Array:
		for wall in pasted_walls:
			if is_instance_valid(wall):
				wall.Offset(snap_delta)
	
	print("[ClipboardFix] Drag snap applied: %s" % str(snap_delta))
	
	# Refresh transform box
	select_tool.EnableTransformBox(false)
	select_tool.EnableTransformBox(true)
	select_tool.SavePreTransforms()


func _compute_snap_delta_from_selectables(selectables: Dictionary) -> Vector2:
	var deltas := {}
	for node in selectables.keys():
		if node == null or not is_instance_valid(node):
			continue
		if selectables[node] == SELECTABLE_WALL:
			continue
		if not (node is Node2D):
			continue
		var pos = node.global_position
		var snapped = _get_snapped_position(pos)
		var d = snapped - pos
		var key = str(int(round(d.x))) + "," + str(int(round(d.y)))
		if not deltas.has(key):
			deltas[key] = {"count": 0, "delta": d}
		deltas[key].count += 1
	
	var best_key = ""
	var best_count = 0
	for key in deltas.keys():
		if deltas[key].count > best_count:
			best_count = deltas[key].count
			best_key = key
	
	if best_key == "":
		return Vector2.ZERO
	return deltas[best_key].delta


func _restore_snap() -> void:
	if _snap_disabled and _saved_cell_size.x > 1:
		_g.WorldUI.CellSize = _saved_cell_size
		_snap_disabled = false


func _update_tracked_positions(selectables: Dictionary) -> void:
	for node in selectables.keys():
		if node != null and is_instance_valid(node):
			_tracked_positions[node.get_instance_id()] = node.global_position


func _reset_drag_state() -> void:
	_tracked_positions.clear()
	_drag_active = false
	_pasted_ids.clear()
	_prev_transform_mode = TRANSFORM_MODE_NONE


# ══════════════════════════════════════════════════════════════════════════════
# CUT (Ctrl+X)
# ══════════════════════════════════════════════════════════════════════════════

func _on_cut() -> void:
	var tt = _tt()
	if tt != null and tt._selected_texts.size() > 0:
		_text_cut(tt)
		return

	var raw = select_tool.RawSelectables
	var has_walls = _has_selected_walls(raw)
	var has_copyable = select_tool.HasCopyable

	if not has_copyable and not has_walls:
		return

	_save_copy_center()

	_restore_previous_tool = _g.Editor.Toolset.PreviousTool
	_g.Editor.Toolset.PreviousTool = "SelectTool"

	if has_copyable:
		select_tool.Copy()

	select_tool.Delete()
	_hide_previews()

	_restore_frames = 3


func _has_selected_walls(raw) -> bool:
	if raw == null:
		return false
	for s in raw:
		if s != null and s.Type == SELECTABLE_WALL:
			return true
	return false


# ══════════════════════════════════════════════════════════════════════════════
# COPY CENTER + WALL CLIPBOARD
# ══════════════════════════════════════════════════════════════════════════════

func _save_copy_center() -> void:
	var tt = _tt()
	if tt != null and tt._selected_texts.size() > 0:
		_save_text_copy_center(tt)
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		_has_copy_center = false
		_has_wall_clipboard = false
		_wall_clipboard = []
		return

	var center = Vector2.ZERO
	var count = 0
	_wall_clipboard = []
	# Toggle "Move, Transform and Copy Walls" : si OFF, on n'enregistre
	# pas les walls dans le clipboard. Le paste cote walls n'aura donc
	# rien a restaurer.
	var wall_copy_allowed = _is_wall_move_enabled()

	for s in raw:
		if s == null or s.Thing == null:
			continue
		if s.Type == SELECTABLE_WALL:
			if wall_copy_allowed:
				_wall_clipboard.append(_snapshot_wall(s.Thing))
		elif s.Thing is Node2D:
			center += _get_visual_center(s)
			count += 1

	_has_wall_clipboard = _wall_clipboard.size() > 0

	if count == 0 and _has_wall_clipboard:
		for snap in _wall_clipboard:
			var pts = snap["points"]
			if pts.size() > 0:
				var wc = Vector2.ZERO
				for p in pts:
					wc += p
				center += wc / pts.size()
				count += 1

	if count > 0:
		_copy_center = center / count
		_has_copy_center = true

	if _has_wall_clipboard:
		print("[ClipboardFix] Saved %d wall(s) to clipboard" % _wall_clipboard.size())


# ══════════════════════════════════════════════════════════════════════════════
# CLIPBOARD REBUILD (workaround DD bug : mix roof+autres -> clipboard vide)
# ══════════════════════════════════════════════════════════════════════════════

func _snapshot_selection_for_rebuild() -> void:
	# Snapshot des Things selectionnees au moment du Ctrl+C, pour pouvoir
	# reconstruire le clipboard 2 frames plus tard si DD a rate la serialisation.
	if _rebuilding_clipboard:
		return
	_post_copy_selection.clear()
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	for s in raw:
		if s != null and s.Thing != null and is_instance_valid(s.Thing):
			_post_copy_selection.append(s.Thing)
	if _post_copy_selection.size() > 0:
		_post_copy_check_counter = 2


func _check_and_rebuild_clipboard() -> void:
	if _post_copy_selection.empty():
		return
	var clipboard = OS.get_clipboard()
	if clipboard.empty():
		_post_copy_selection.clear()
		return
	var parsed = JSON.parse(clipboard)
	if parsed.error != OK:
		_post_copy_selection.clear()
		return
	var data = parsed.result
	if not (data is Dictionary) or not data.has("dungeondraft_clipboard"):
		_post_copy_selection.clear()
		return
	# Si DD a deja rempli au moins une section : le contenu est OK, mais
	# l'ordre des items dans le clipboard = ordre de SELECTION (bug vanilla).
	# On reordonne par z-order (index dans le parent) pour que le paste
	# preserve l'empilement visuel d'origine.
	if data.size() > 1:
		_reorder_clipboard_by_zorder()
		_post_copy_selection.clear()
		return
	# Clipboard vide avec une selection non-vide : on tente la reconstruction
	# en separant la selection par groupe parent et en faisant copier DD chaque
	# sous-ensemble individuellement.
	print("[ClipboardFix] Empty clipboard with %d selectables -- rebuilding" % _post_copy_selection.size())
	var by_group := {"Roofs": [], "Other": []}
	for thing in _post_copy_selection:
		if not is_instance_valid(thing):
			continue
		var group = "Other"
		if thing is Node and thing.get_parent() != null and thing.get_parent().name == "Roofs":
			group = "Roofs"
		by_group[group].append(thing)
	_rebuilding_clipboard = true
	var merged_data := {"dungeondraft_clipboard": 1}
	for group_name in ["Other", "Roofs"]:
		var subset = by_group[group_name]
		if subset.empty():
			continue
		_copy_subset_into_merged(merged_data, subset, group_name)
	# Restaurer la selection d'origine
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	for thing in _post_copy_selection:
		if is_instance_valid(thing):
			select_tool.SelectThing(thing, true)
	# Ecrire le clipboard merge
	OS.set_clipboard(JSON.print(merged_data, "\t"))
	var sections = merged_data.size() - 1
	print("[ClipboardFix] Clipboard rebuilt with %d section(s)" % sections)
	_rebuilding_clipboard = false
	_post_copy_selection.clear()


# ══════════════════════════════════════════════════════════════════════════════
# REORDER PAR Z-ORDER (workaround bug vanilla : items pastes ordonnes par
# ordre de selection au lieu de leur empilement reel)
# ══════════════════════════════════════════════════════════════════════════════

# DD serialise le clipboard dans l'ordre de SELECTION. Quand plusieurs items
# du meme layer sont selectionnes en SHIFT+clic, le paste les recree dans cet
# ordre -> le dernier selectionne remonte au-dessus, ce qui inverse/casse
# l'empilement d'origine. On corrige en re-selectionnant les items tries par
# z-order (index dans leur parent) puis en relancant Copy() de DD, qui reecrit
# le clipboard dans le bon ordre. On restaure ensuite la selection d'origine.
# Tourne en differe (2 frames apres Ctrl+C) donc apres la Copy native de DD :
# pas de dependance a l'ordre d'execution des input handlers.
func _reorder_clipboard_by_zorder() -> void:
	if select_tool == null:
		return
	if not select_tool.has_method("DeselectAll") or not select_tool.has_method("SelectThing"):
		return
	if not select_tool.has_method("Copy"):
		return

	var things := []
	for t in _post_copy_selection:
		if is_instance_valid(t):
			things.append(t)
	if things.size() < 2:
		return

	# Tri par z-order : meme parent -> index ascendant (bas -> haut). Ainsi la
	# Copy ecrit l'item du dessous en premier et celui du dessus en dernier ;
	# le paste, qui recree dans l'ordre du clipboard, reproduit l'empilement.
	var sorted_things = things.duplicate()
	sorted_things.sort_custom(self, "_cmp_zorder")

	# Rien a faire si la selection est deja dans l'ordre z (evite une Copy inutile
	# et un flicker de selection).
	var same := true
	for i in range(things.size()):
		if things[i] != sorted_things[i]:
			same = false
			break
	if same:
		return

	# Verifier qu'au moins 2 items partagent un parent (sinon le reorder ne
	# change rien de visible : items sur des layers distincts).
	var parent_counts := {}
	for t in things:
		var p = t.get_parent()
		if p == null:
			continue
		var key = str(p.get_instance_id())
		parent_counts[key] = int(parent_counts.get(key, 0)) + 1
	var has_shared := false
	for key in parent_counts.keys():
		if parent_counts[key] >= 2:
			has_shared = true
			break
	if not has_shared:
		return

	_rebuilding_clipboard = true
	select_tool.DeselectAll()
	for t in sorted_things:
		if is_instance_valid(t):
			select_tool.SelectThing(t, true)
	select_tool.Copy()

	# Restaurer la selection d'origine (meme ensemble, ordre d'origine) pour
	# que l'utilisateur ne voie aucun changement.
	select_tool.DeselectAll()
	for t in things:
		if is_instance_valid(t):
			select_tool.SelectThing(t, true)
	if select_tool.has_method("OnFinishSelection"):
		select_tool.OnFinishSelection()
	_rebuilding_clipboard = false
	print("[ClipboardFix] Clipboard reordonne par z-order (%d items)" % things.size())


# Comparateur de tri : strict weak ordering. Meme parent -> index ascendant.
# Parents differents -> ordre stable par instance id (suffit a grouper, le
# reorder intra-layer etant le seul qui compte visuellement).
func _cmp_zorder(a, b) -> bool:
	if not is_instance_valid(a) or not is_instance_valid(b):
		return false
	var pa = a.get_parent()
	var pb = b.get_parent()
	if pa != pb:
		var ida = pa.get_instance_id() if pa != null else -1
		var idb = pb.get_instance_id() if pb != null else -1
		return ida < idb
	return a.get_index() < b.get_index()


func _copy_subset_into_merged(merged_data: Dictionary, subset: Array, label: String) -> void:
	# Selectionner uniquement `subset`, faire copier DD, parser le clipboard,
	# fusionner les sections dans merged_data (concatenation des Arrays).
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	for thing in subset:
		if is_instance_valid(thing):
			select_tool.SelectThing(thing, true)
	select_tool.Copy()
	var clipboard = OS.get_clipboard()
	if clipboard.empty():
		print("[ClipboardFix] %s subset: clipboard empty after Copy()" % label)
		return
	var parsed = JSON.parse(clipboard)
	if parsed.error != OK:
		print("[ClipboardFix] %s subset: JSON parse error" % label)
		return
	var data = parsed.result
	if not (data is Dictionary):
		return
	# Fusionner les sections (Arrays) dans merged_data
	for key in data.keys():
		if key == "dungeondraft_clipboard":
			continue
		if not (data[key] is Array):
			continue
		if merged_data.has(key) and merged_data[key] is Array:
			for item in data[key]:
				merged_data[key].append(item)
		else:
			merged_data[key] = data[key]


func _snapshot_wall(wall) -> Dictionary:
	var pts = PoolVector2Array()
	var raw_pts = wall.Points
	if raw_pts != null:
		for p in raw_pts:
			pts.append(p)

	# Count portals for info message (but don't copy them - API limitation)
	var portal_count = 0
	var portals = wall.Portals
	if portals != null:
		portal_count = portals.size()

	if portal_count > 0:
		print("[ClipboardFix] Wall has %d portal(s) - these will NOT be copied (DD API limitation)" % portal_count)

	return {
		"points": pts,
		"texture": wall.Texture,
		"color": wall.Color,
		"loop": wall.Loop,
		"shadow": wall.HasShadow,
		"type": int(wall.Type),
		"joint": int(wall.Joint),
		"normalize_uv": wall.NormalizeUV,
	}


# ══════════════════════════════════════════════════════════════════════════════
# PASTE
# ══════════════════════════════════════════════════════════════════════════════

func _on_paste_in_place() -> void:
	if not _has_copy_center and not _has_wall_clipboard:
		return
	if not _has_copy_center:
		_on_paste()
		return

	_paste_in_place = true
	_paste_cursor_target = _copy_center
	_paste_hidden_nodes = []
	_paste_move_counter = 1

	select_tool.EnableTransformBox(false)
	_hide_pasted_items()


func _on_paste() -> void:
	_paste_in_place = false
	# Toggle: when "Paste Under Cursor" is OFF, paste at the center of the
	# screen — that's vanilla DD's behavior. (NOT _copy_center, which would
	# reproduce paste-in-place / Ctrl+Shift+V semantics.)
	if _is_paste_under_cursor_enabled():
		_paste_cursor_target = _mouse_world_pos
	else:
		_paste_cursor_target = _get_screen_center_world()
	_paste_hidden_nodes = []
	_paste_move_counter = 1

	select_tool.EnableTransformBox(false)
	_hide_pasted_items()


func _hide_pasted_items() -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	for s in raw:
		if s and s.Thing and s.Thing is CanvasItem:
			if s.Thing.visible:
				s.Thing.visible = false
				if not _paste_hidden_nodes.has(s.Thing):
					_paste_hidden_nodes.append(s.Thing)


func _compute_snap_delta(raw, pasted_walls := []) -> Vector2:
	if not _is_snap_enabled():
		return Vector2.ZERO
	
	var deltas := {}
	
	# Check non-wall objects
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if s.Type == SELECTABLE_WALL:
			continue
		if not (s.Thing is Node2D):
			continue
		# Pour les roofs : global_position=(0,0), on prend le centre des polygons
		var pos: Vector2
		if s.Thing.get_parent() != null and s.Thing.get_parent().name == "Roofs":
			var rc = _compute_roof_visual_center(s.Thing)
			if rc == Vector2.INF:
				continue
			pos = rc
		else:
			pos = s.Thing.global_position
		var snapped = _get_snapped_position(pos)
		if pos.distance_to(snapped) <= OFFSNAP_THRESHOLD:
			continue
		var d = snapped - pos
		var key = str(int(round(d.x))) + "," + str(int(round(d.y)))
		if not deltas.has(key):
			deltas[key] = {"count": 0, "delta": d}
		deltas[key].count += 1
	
	# Check wall points (use first point of each wall)
	for wall in pasted_walls:
		if not is_instance_valid(wall):
			continue
		var pts = wall.Points
		if pts == null or pts.size() == 0:
			continue
		var pos = pts[0]  # Use first point
		var snapped = _get_snapped_position(pos)
		if pos.distance_to(snapped) <= OFFSNAP_THRESHOLD:
			continue
		var d = snapped - pos
		var key = str(int(round(d.x))) + "," + str(int(round(d.y)))
		if not deltas.has(key):
			deltas[key] = {"count": 0, "delta": d}
		deltas[key].count += 1
	
	var best_key = ""
	var best_count = 0
	for key in deltas.keys():
		if deltas[key].count > best_count:
			best_count = deltas[key].count
			best_key = key
	
	if best_key == "":
		return Vector2.ZERO
	return deltas[best_key].delta


func _move_pasted_items_to_cursor() -> void:
	_move_pasted_texts_to_cursor()

	var pasted_walls = _paste_walls_from_clipboard()

	var raw = select_tool.RawSelectables
	if raw == null:
		raw = []

	var dd_center = Vector2.ZERO
	var dd_count = 0
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if s.Type == SELECTABLE_WALL:
			continue
		if s.Thing is Node2D:
			dd_center += _get_visual_center(s)
			dd_count += 1

	if dd_count == 0 and pasted_walls.size() == 0:
		_show_hidden_nodes()
		return

	if dd_count > 0:
		dd_center /= dd_count
		var delta_dd = _paste_cursor_target - dd_center

		if delta_dd.length() >= 1.0:
			# DO NOT wrap this move in SavePreTransforms / RecordTransforms.
			# DD already pushed a "create" record for the paste itself when
			# Ctrl+V triggered. Adding a second record for the cursor move
			# would split the undo into two steps: the first Ctrl+Z would
			# only revert the move (items snap back to center), and a
			# second Ctrl+Z would actually delete them. Keeping the move
			# unrecorded means a single Ctrl+Z removes the pasted items
			# wherever they ended up.
			for s in raw:
				if s == null or s.Thing == null:
					continue
				if s.Type == SELECTABLE_WALL:
					continue
				if s.Thing is Node2D:
					s.Thing.position += delta_dd

		var delta_walls = _paste_cursor_target - _copy_center
		for wall in pasted_walls:
			if is_instance_valid(wall):
				wall.Offset(delta_walls)
	else:
		var delta_walls = _paste_cursor_target - _copy_center
		if delta_walls.length() >= 1.0:
			for wall in pasted_walls:
				if is_instance_valid(wall):
					wall.Offset(delta_walls)

	# === INSTANT SNAP: Apply grid snap BEFORE showing items ===
	# Skip pour le paste-in-place : Ctrl+Shift+V doit reproduire la position
	# exacte de la source. Un asset resize/rotate a souvent son centre hors
	# grille ; snapper ici le decalerait et casserait le "in place".
	if _is_paste_snap_enabled() and not _paste_in_place:
		var snap_delta = _compute_snap_delta(raw, pasted_walls)
		if snap_delta.length() >= 1.0:
			for s in raw:
				if s == null or s.Thing == null:
					continue
				if s.Type == SELECTABLE_WALL:
					continue
				if s.Thing is Node2D:
					s.Thing.global_position += snap_delta
			
			for wall in pasted_walls:
				if is_instance_valid(wall):
					wall.Offset(snap_delta)
			
			print("[ClipboardFix] Instant snap at paste: %s" % str(snap_delta))

	# Register pasted IDs for drag snap tracking
	_pasted_ids.clear()
	var pasted_non_walls: Array = []
	for s in raw:
		if s != null and s.Thing != null and is_instance_valid(s.Thing):
			_pasted_ids[s.Thing.get_instance_id()] = true
			if s.Type != SELECTABLE_WALL:
				pasted_non_walls.append(s.Thing)

	# Pont CMT : re-appliquer les teintes HSL aux nodes collES exacts
	# (contourne le back-count nextNodeID fragile du mod tiers).
	_cmt_apply_to_pasted(pasted_non_walls)

	# NOW show items (already snapped)
	_show_hidden_nodes()

	_g.ModMapData["_clipboard_pasted_walls"] = pasted_walls

	_last_pasted_walls = pasted_walls
	_rebuild_box_frames = 3
	
	# Register one history record covering walls. DD handles non-walls
	# itself via its own paste record (verified empirically when it
	# detaches nodes on its undo). Including non-walls in OUR record
	# created a duplicate undo step per paste.
	if pasted_walls.size() > 0:
		_register_paste_undo(pasted_walls, [])
	
	# Save final positions of pasted non-walls keyed by node_id, so we
	# can put them back where the user dropped them after a Ctrl+Y.
	# DD's redo recreates the nodes at their spawn location (often the
	# map center), losing the cursor placement we did on the original
	# paste. We can't fix this with a history record (it conflicts with
	# DD's own record, breaking the undo flow), so we keep an external
	# map and reapply positions reactively in _on_process when we see
	# a Ctrl+Y trigger.
	for n in pasted_non_walls:
		if n == null or not is_instance_valid(n):
			continue
		if not n.has_meta("node_id"):
			continue
		var nid = n.get_meta("node_id")
		if typeof(nid) == TYPE_INT:
			_paste_positions[nid] = n.position


func _rebuild_transform_box() -> void:
	select_tool.OnFinishSelection()

	for wall in _last_pasted_walls:
		if is_instance_valid(wall):
			select_tool.SelectThing(wall, true)
	_last_pasted_walls = []
	_g.ModMapData["_clipboard_pasted_walls"] = []


func _paste_walls_from_clipboard() -> Array:
	var new_walls := []
	if not _has_wall_clipboard or _wall_clipboard.size() == 0:
		return new_walls

	var level = _g.World.GetCurrentLevel()
	if level == null:
		return new_walls

	var walls_container = level.Walls
	if walls_container == null:
		return new_walls

	for snap in _wall_clipboard:
		var wall = walls_container.AddWall(
			snap["points"],
			snap["texture"],
			snap["color"],
			snap["loop"],
			snap["shadow"],
			snap["type"],
			snap["joint"],
			snap["normalize_uv"]
		)
		if wall == null:
			continue
		new_walls.append(wall)

	if new_walls.size() > 0:
		print("[ClipboardFix] Pasted %d wall(s)" % new_walls.size())
	# Note: undo registration moved to _move_pasted_items_to_cursor so
	# the same record can also include non-wall pasted nodes (DD doesn't
	# push its own paste record, so without us those non-walls would
	# stay on Ctrl+Z).

	return new_walls


# Gestion undo/redo des walls pastes.
#
# Ancienne approche (detach/re-attach de la MEME instance) : sur redo on
# re-attachait le node detache via add_child. Probleme : DD n'expose pas
# de RemoveWall ; sa suppression native (SUPPR) traite les walls inline et
# s'appuie sur le registre node_id du World. Un wall detache puis re-attache
# reste une instance "perimee" que la suppression native n'arrive plus a
# traiter -> SUPPR ne faisait rien sur le wall reapparu apres redo.
#
# Nouvelle approche : on RECREE le wall via AddWall sur redo (exactement
# comme un paste neuf, qui se delete sans probleme) et on le DETRUIT
# proprement sur undo. Le wall redo est donc un wall DD normal, pleinement
# enregistre, et SUPPR fonctionne. Bonus : un wall detruit n'est plus dans
# l'arbre, donc jamais serialise au save (le souci d'origine des ghost walls
# est aussi resolu).


# Snapshot (points monde + proprietes) de chaque wall vivant, pour pouvoir
# le recreer a l'identique plus tard.
func _snapshot_walls_for_record(walls: Array) -> Array:
	var snaps := []
	for w in walls:
		if w != null and is_instance_valid(w):
			snaps.append(_snapshot_wall(w))
	return snaps


# Recree les walls a partir des snapshots via l'API DD AddWall. Retourne
# les nouvelles instances (selectionnables et deletables comme un paste neuf).
func _recreate_walls(snaps: Array) -> Array:
	var new_walls := []
	if _g == null or _g.World == null:
		return new_walls
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return new_walls
	var walls_container = level.Walls
	if walls_container == null:
		return new_walls
	for snap in snaps:
		var wall = walls_container.AddWall(
			snap["points"],
			snap["texture"],
			snap["color"],
			snap["loop"],
			snap["shadow"],
			snap["type"],
			snap["joint"],
			snap["normalize_uv"]
		)
		if wall == null:
			continue
		# AddWall enregistre normalement le node_id, mais on securise pour
		# garantir que SUPPR puisse retrouver le wall dans le registre World.
		if _g.World.has_method("AssignNodeID"):
			var registered := false
			if wall.has_meta("node_id") and _g.World.has_method("HasNodeID"):
				var nid = wall.get_meta("node_id")
				if _g.World.HasNodeID(nid) and _g.World.GetNodeByID(nid) == wall:
					registered = true
			if not registered:
				_g.World.AssignNodeID(wall)
		new_walls.append(wall)
	return new_walls


# Detruit proprement les walls (detache + queue_free). Detache du parent
# d'abord pour les exclure immediatement de la serialisation, puis libere.
func _destroy_walls(walls: Array) -> void:
	for w in walls:
		if w == null or not is_instance_valid(w):
			continue
		var parent = w.get_parent()
		if parent != null and is_instance_valid(parent):
			parent.remove_child(w)
			# Recalcule les joints des walls voisins maintenant qu'il a disparu.
			if parent.has_method("RemakeLines"):
				parent.RemakeLines()
		w.queue_free()


# Re-selectionne les walls recrees pour que l'utilisateur puisse enchainer
# directement (SUPPR, move, etc.) sans avoir a recliquer.
func _select_walls(walls: Array) -> void:
	if select_tool == null:
		return
	for w in walls:
		if is_instance_valid(w):
			select_tool.SelectThing(w, true)
	if select_tool.has_method("OnFinishSelection"):
		select_tool.OnFinishSelection()



func _deselect_all_safe() -> void:
	if select_tool == null:
		return
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	# DeselectAll empties the selection store but doesn't hide DD's
	# transform box on its own. After Ctrl+Z deletes the pasted items
	# the box would otherwise remain on screen, floating around the
	# now-invisible items. Force it off here.
	if select_tool.has_method("EnableTransformBox"):
		select_tool.EnableTransformBox(false)


func _set_non_walls_present(nodes: Array, present: bool) -> void:
	# Detach from / re-attach to the original parent. Hidden-but-attached
	# nodes get persisted by DD on save, which would resurrect them at
	# reload after the user undoed and saved, so we detach instead.
	for n in nodes:
		if n == null or not is_instance_valid(n):
			continue
		var parent = n.get_parent()
		if present:
			if parent == null and n.has_meta("_clipboardfix_orig_parent"):
				var p = n.get_meta("_clipboardfix_orig_parent")
				if p != null and is_instance_valid(p) and p.is_inside_tree():
					p.add_child(n)
		else:
			if parent != null and is_instance_valid(parent):
				n.set_meta("_clipboardfix_orig_parent", parent)
				parent.remove_child(n)


func _register_paste_undo(walls: Array, non_walls: Array) -> void:
	if walls.size() == 0 and non_walls.size() == 0:
		return
	if _g.Editor == null:
		return
	var history = _g.Editor.get("History")
	if history == null or not history.has_method("Record"):
		return
	var record = PasteHistoryRecord.new()
	record.owner_mod = self
	record.live_walls = walls
	record.wall_snaps = _snapshot_walls_for_record(walls)
	record.non_walls = non_walls
	if history.has_method("CreateCustomRecord"):
		history.CreateCustomRecord(record)
	else:
		history.Record(record)


class PasteHistoryRecord:
	# Records a paste of walls AND/OR non-walls.
	# Les walls sont geres par recreation : undo detruit les instances vivantes
	# (apres avoir re-snapshote leur etat courant), redo les recree via AddWall.
	# Les non-walls restent geres par detach/re-attach (DD gere les siens via
	# son propre record ; non_walls est generalement vide cote clipboard_fix).
	extends Reference
	var owner_mod
	var wall_snaps: Array       # snapshots pour recreer les walls
	var live_walls: Array       # instances vivantes courantes
	var non_walls: Array
	func undo():
		if owner_mod != null:
			owner_mod._deselect_all_safe()
			# Re-snapshot l'etat courant avant destruction (capture une
			# eventuelle edition post-paste), puis detruit proprement.
			var fresh = owner_mod._snapshot_walls_for_record(live_walls)
			if fresh.size() > 0:
				wall_snaps = fresh
			owner_mod._destroy_walls(live_walls)
			live_walls = []
			owner_mod._set_non_walls_present(non_walls, false)
	func redo():
		if owner_mod != null:
			owner_mod._deselect_all_safe()
			owner_mod._set_non_walls_present(non_walls, true)
			live_walls = owner_mod._recreate_walls(wall_snaps)
			owner_mod._select_walls(live_walls)


func _show_hidden_nodes() -> void:
	for node in _paste_hidden_nodes:
		if is_instance_valid(node) and node is CanvasItem:
			node.visible = true
	_paste_hidden_nodes = []


func _hide_previews():
	if _preview_nodes.size() == 0:
		_scan_for_previews(_g.Editor)
	for node in _preview_nodes:
		if node != null and is_instance_valid(node) and node.visible:
			node.visible = false


func _scan_for_previews(node):
	if node == null or not is_instance_valid(node):
		return
	var name_lower = node.name.to_lower()
	if "preview" in name_lower and (node is PopupPanel or node is Popup or node is PanelContainer or node is Panel):
		_preview_nodes.append(node)
	if node.get_class() == "ItemList" or "GridMenu" in str(node.get_class()):
		for child in node.get_children():
			if child is Popup or child is PopupPanel or child is Panel:
				if "preview" in child.name.to_lower() or child is PopupPanel:
					_preview_nodes.append(child)
	for child in node.get_children():
		_scan_for_previews(child)


# ══════════════════════════════════════════════════════════════════════════════
# TEXT EXTENSIONS
# ══════════════════════════════════════════════════════════════════════════════

func _text_cut(tt: Object) -> void:
	tt._copy_selection()
	var vp = _g.World.get_tree().root.get_node_or_null("Master/ViewportContainer2D/Viewport2D")
	if vp: tt._delete_selection()
	_save_text_copy_center(tt)
	_restore_previous_tool = _g.Editor.Toolset.PreviousTool
	_g.Editor.Toolset.PreviousTool = "SelectTool"
	_restore_frames = 3
	print("[ClipboardFix] Text cut done")


func _save_text_copy_center(tt: Object) -> void:
	var center = Vector2.ZERO
	var count = 0
	for t in tt._selected_texts:
		if is_instance_valid(t):
			center += t.rect_position + t.rect_size * t.rect_scale * 0.5
			count += 1
	if count > 0:
		_copy_center = center / count
		_has_copy_center = true


func _move_pasted_texts_to_cursor() -> void:
	var tt = _tt()
	if tt == null or tt._selected_texts.size() == 0: return
	var texts = tt._selected_texts
	var center = Vector2.ZERO
	var count = 0
	for t in texts:
		if is_instance_valid(t):
			center += t.rect_position + t.rect_size * t.rect_scale * 0.5
			count += 1
	if count == 0: return
	center /= count
	var target = _paste_cursor_target if not _paste_in_place else _copy_center
	var delta = target - center
	if delta.length() < 1.0: return
	var ttf = _g.ModMapData.get("_ttf_handler")
	for t in texts:
		if not is_instance_valid(t): continue
		t.rect_position += delta
		if ttf: ttf.update_anchor_after_move(t)
	print("[ClipboardFix] Moved %d texts by %s" % [count, str(delta)])
