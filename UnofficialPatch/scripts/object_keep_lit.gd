# object_keep_lit.gd
# Adds a "Keep Object Lit" toggle (below "Block Light") to the ObjectTool and
# SelectTool panels, for objects that have "Block Light" enabled.
#
# Problem: Prop.GenerateOccluder() builds the LightOccluder2D polygons with
# CullMode = Disabled, so every edge of the silhouette casts a shadow and the
# object itself ends up fully dark.
#
# Fix: switch the OccluderPolygon2D cull mode to one-sided (matching the
# polygon winding). Only the edges facing away from the light cast shadows,
# so the object stays lit while everything behind it is still shadowed.
#
# The per-object state is stored in Global.ModMapData (saved with the map),
# keyed by the object's node_id. A polling timer re-applies the cull mode
# because DD regenerates the occluders (with Disabled) whenever Block Light
# is toggled, on undo/redo, or on map load.

var _g

var _select_tool = null
var _select_panel = null
var _select_button = null

var _object_tool = null
var _object_panel = null
var _object_button = null
var _object_bl_button = null    # DD's own "Block Light" button in the ObjectTool panel
var _next_objects_lit := false   # Mode: newly placed objects will be kept lit
var _known_prop_ids := {}        # instance_id -> true, to detect new props

var _timer = null
var _user_toggling := false

const CHECK_INTERVAL := 0.15
const FAST_CHECK_INTERVAL := 0.03
const STORE_KEY := "object_keep_lit"   # ModMapData key -> { "node-id-X": true }

# OccluderPolygon2D.CullMode
const CULL_DISABLED := 0
const CULL_CLOCKWISE := 1
const CULL_COUNTER_CLOCKWISE := 2

# Geometry.is_polygon_clockwise() uses the y-up math convention, so a polygon
# that looks clockwise on screen (y-down) reports false. Flip this if the
# result is inverted in practice (object still dark).
const INVERT_CULL := true

# Morphological "closing" radius (px, texture space) applied to the outline
# while the object is kept lit. Jagged outlines contain tiny edges that face
# away from the light on the object's lit side; with one-sided culling each
# of them casts a hairline shadow across the object. Dilating then eroding
# the outline fills those notches. 0 disables it.
const SMOOTH_RADIUS := 6.0


func initialize() -> void:
	# Object Tool: mode toggle for newly placed objects
	_object_tool = _g.Editor.Tools["ObjectTool"]
	_object_panel = _g.Editor.Toolset.GetToolPanel("ObjectTool")
	var obj_bl = _find_block_light_button(_object_tool, _object_panel)
	if obj_bl != null:
		_object_bl_button = obj_bl
		_object_button = _create_button("_on_object_toggled",
			"When enabled, newly placed objects with Block Light will cast shadows without being shadowed themselves.")
		_place_after(_object_button, obj_bl)
	else:
		print("[OKL] WARNING: ObjectTool Block Light button not found")

	# Select Tool: per-object toggle
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if _select_panel != null:
		_select_button = _create_button("_on_select_toggled",
			"When enabled, selected object(s) with Block Light cast shadows without being shadowed themselves.")
		var sel_bl = _find_block_light_button(_select_tool, _select_panel)
		if sel_bl != null:
			_place_after(_select_button, sel_bl)
		else:
			# Fallback: park it in the panel; _tick() re-anchors it next to the
			# visible Block Light button once the object options are shown.
			var parent = _select_panel.get("Align")
			if parent == null:
				parent = _select_panel.find_node("Align", true, false)
			if parent != null:
				parent.add_child(_select_button)
	else:
		print("[OKL] WARNING: SelectTool panel not found")

	# Cross-session guard: _g.Editor persists across map reloads, so an autostart
	# Timer added by a previous mod instance keeps ticking forever. Free the
	# previous one before adding ours -- otherwise they accumulate per reload.
	if Engine.has_meta("okl_timer"):
		var old_t = Engine.get_meta("okl_timer")
		if is_instance_valid(old_t):
			old_t.queue_free()
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	Engine.set_meta("okl_timer", _timer)
	_g.Editor.add_child(_timer)

	print("[OKL] initialized, object_btn=" + str(_object_button != null) + " select_btn=" + str(_select_button != null))


# ── UI ──────────────────────────────────────────────────────────────────────

func _create_button(callback: String, tooltip: String) -> CheckButton:
	var btn = CheckButton.new()
	btn.text = "Keep Object Lit"
	btn.hint_tooltip = tooltip
	btn.pressed = false
	btn.connect("toggled", self, callback)
	return btn


# Locate DD's own "Block Light" CheckButton. First via the tool's Controls
# dictionary, then by scanning the panel for a CheckButton with that text.
func _find_block_light_button(dd_tool, panel):
	if dd_tool != null:
		var controls = dd_tool.get("Controls")
		if controls != null and controls.has("BlockLight"):
			var c = controls["BlockLight"]
			if c != null and is_instance_valid(c) and c is Control:
				return c
	if panel == null:
		return null
	var found: Array = []
	_scan_block_light_buttons(panel, found)
	if found.size() > 0:
		return found[0]
	return null


func _scan_block_light_buttons(node, result: Array) -> void:
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is CheckButton or child is CheckBox:
			var t: String = (child.text if child.text != null else "").to_lower()
			if "block" in t and "light" in t:
				result.append(child)
		if child.get_child_count() > 0:
			_scan_block_light_buttons(child, result)


# Put our button right after `anchor` (same parent, next index).
func _place_after(btn, anchor) -> void:
	if btn == null or anchor == null or not is_instance_valid(anchor):
		return
	var parent = anchor.get_parent()
	if parent == null:
		return
	if btn.get_parent() != parent:
		if btn.get_parent() != null:
			btn.get_parent().remove_child(btn)
		parent.add_child(btn)
	var want = anchor.get_index() + 1
	if btn.get_index() != want:
		parent.move_child(btn, want)


# In the SelectTool panel several "Block Light" buttons may exist (objects,
# walls, ...). Keep ours anchored to whichever one is currently visible.
func _reanchor_select_button() -> void:
	if _select_button == null or _select_panel == null:
		return
	var found: Array = []
	_scan_block_light_buttons(_select_panel, found)
	var visible_bl = null
	for c in found:
		if c == _select_button:
			continue
		if c.is_visible_in_tree():
			visible_bl = c
			break
	if visible_bl == null:
		return
	var parent = visible_bl.get_parent()
	if _select_button.get_parent() != parent or _select_button.get_index() != visible_bl.get_index() + 1:
		_place_after(_select_button, visible_bl)


func _tick() -> void:
	var active_tool = _g.Editor.ActiveToolName

	# ObjectTool: only show our toggle while Block Light is enabled
	if _object_button != null:
		var bl_on := false
		if active_tool == "ObjectTool" and _object_bl_button != null and is_instance_valid(_object_bl_button):
			bl_on = _object_bl_button.pressed
		_object_button.visible = bl_on

	if active_tool == "ObjectTool":
		_apply_to_preview()
		if _next_objects_lit:
			_check_for_new_props()

	if active_tool == "SelectTool":
		_reanchor_select_button()
		_update_select_button()
	elif _select_button != null:
		_select_button.visible = false

	_reapply_all()


func _update_select_button() -> void:
	if _select_button == null or _user_toggling:
		return
	var props := _get_selected_props()
	# Show only when at least one selected object has Block Light on
	var first = null
	for p in props:
		if p.get("BlockLight") == true:
			first = p
			break
	_select_button.visible = (first != null)
	if first == null:
		return
	var is_lit := _is_lit(first)
	if _select_button.pressed != is_lit:
		_select_button.disconnect("toggled", self, "_on_select_toggled")
		_select_button.pressed = is_lit
		_select_button.connect("toggled", self, "_on_select_toggled")


func _on_select_toggled(pressed: bool) -> void:
	_user_toggling = true
	var props := _get_selected_props()
	var ids: Array = []
	for p in props:
		if p.get("BlockLight") == true:
			var nid = _node_id(p)
			if nid != "":
				ids.append(nid)

	var before := _capture_states(ids)
	for nid in ids:
		_set_lit(nid, pressed)
	_reapply_all()
	var after := _capture_states(ids)
	_record_change(before, after)

	print("[OKL] Keep lit=" + str(pressed) + " on " + str(ids.size()) + " object(s)")
	_user_toggling = false


func _on_object_toggled(pressed: bool) -> void:
	_next_objects_lit = pressed
	if pressed:
		_init_known_props()
		_timer.wait_time = FAST_CHECK_INTERVAL
	else:
		_timer.wait_time = CHECK_INTERVAL
	print("[OKL] Next objects keep lit mode: " + str(pressed))


# ── ObjectTool preview ──────────────────────────────────────────────────────

# The ObjectTool preview is a Prop too (ObjectTool.Preview); DD regenerates
# its occluders whenever the asset/Block Light changes, so we re-apply the
# cull mode every tick to mirror the current mode.
func _apply_to_preview() -> void:
	if _object_tool == null:
		return
	var preview = _object_tool.get("Preview")
	if preview == null or not is_instance_valid(preview):
		return
	if not preview.has_method("GenerateOccluder"):
		return
	_apply_cull(preview, _next_objects_lit)


# ── New object detection (ObjectTool mode) ──────────────────────────────────

func _init_known_props() -> void:
	_known_prop_ids.clear()
	var objects = _get_objects_node()
	if objects == null:
		return
	for i in range(objects.get_child_count()):
		var prop = objects.get_child(i)
		if is_instance_valid(prop) and prop.has_method("GenerateOccluder"):
			_known_prop_ids[prop.get_instance_id()] = true


func _check_for_new_props() -> void:
	var objects = _get_objects_node()
	if objects == null:
		return
	var current := {}
	for i in range(objects.get_child_count()):
		var prop = objects.get_child(i)
		if not is_instance_valid(prop) or not prop.has_method("GenerateOccluder"):
			continue
		if prop.has_meta("preview") and prop.get_meta("preview") == true:
			continue
		current[prop.get_instance_id()] = prop
	for iid in current:
		if _known_prop_ids.has(iid):
			continue
		var prop = current[iid]
		var nid = _node_id(prop)
		if nid == "":
			continue   # node_id not assigned yet, retry next tick
		if prop.get("BlockLight") == true:
			_set_lit(nid, true)
			_apply_cull(prop, true)
			print("[OKL] Auto-applied Keep Lit to new object " + nid)
		_known_prop_ids[iid] = true
	var to_remove: Array = []
	for iid in _known_prop_ids:
		if not current.has(iid):
			to_remove.append(iid)
	for iid in to_remove:
		_known_prop_ids.erase(iid)


# ── Selection helpers ───────────────────────────────────────────────────────

# Walk RawSelectables ourselves (see wall_allow_light.gd for why the C#
# Selectables property can throw). A Prop is recognised by its
# GenerateOccluder method rather than by SelectableType.
func _get_selected_props() -> Array:
	var out: Array = []
	if _select_tool == null:
		return out
	var raw = _select_tool.get("RawSelectables")
	if raw == null:
		return out
	var seen := {}
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if seen.has(thing):
			continue
		if not thing.has_method("GenerateOccluder"):
			continue
		seen[thing] = true
		out.append(thing)
	return out


func _get_objects_node():
	var level = _g.World.GetCurrentLevel()
	if level == null:
		return null
	return level.get("Objects")


func _node_id(prop) -> String:
	if not prop.has_meta("node_id"):
		return ""
	return "node-id-" + str(prop.get_meta("node_id"))


# ── Persistent state (ModMapData) ───────────────────────────────────────────

func _store() -> Dictionary:
	if not (_g.ModMapData is Dictionary):
		return {}
	if not _g.ModMapData.has(STORE_KEY) or not (_g.ModMapData[STORE_KEY] is Dictionary):
		_g.ModMapData[STORE_KEY] = {}
	return _g.ModMapData[STORE_KEY]


func _is_lit(prop) -> bool:
	var nid = _node_id(prop)
	return nid != "" and _store().has(nid)


func _set_lit(nid: String, lit: bool) -> void:
	var store = _store()
	if lit:
		store[nid] = true
	else:
		store.erase(nid)


# ── Occluder cull mode ──────────────────────────────────────────────────────

func _reapply_all() -> void:
	var store = _store()
	var objects = _get_objects_node()
	if objects == null:
		return
	for i in range(objects.get_child_count()):
		var prop = objects.get_child(i)
		if not is_instance_valid(prop) or not prop.has_method("GenerateOccluder"):
			continue
		var nid = _node_id(prop)
		if nid == "":
			continue
		_apply_cull(prop, store.has(nid))


func _apply_cull(prop, lit: bool) -> void:
	# Negative scale (Mirror) flips the winding in world space.
	var flipped: bool = (prop.scale.x * prop.scale.y) < 0.0

	# Collect DD's occluders and our extra ones (created for polygons that
	# split into several pieces after cleanup).
	var dd_occluders: Array = []
	var extras: Array = []
	for i in range(prop.get_child_count()):
		var child = prop.get_child(i)
		if child.get_class() != "LightOccluder2D":
			continue
		if child.has_meta("okl_extra"):
			extras.append(child)
		else:
			dd_occluders.append(child)

	# DD regenerated its occluders (Block Light toggled, UpdateOccluders...)
	# while our extras were still around: drop the stale extras and start over.
	var stale := false
	for occ in dd_occluders:
		if not occ.has_meta("okl_orig"):
			stale = true
			break
	if not lit or stale or dd_occluders.empty():
		for e in extras:
			e.queue_free()
		extras = []

	if not lit:
		for occ in dd_occluders:
			var poly = occ.occluder
			if poly == null:
				continue
			if occ.has_meta("okl_orig"):
				poly.polygon = occ.get_meta("okl_orig")
				occ.remove_meta("okl_orig")
			if occ.has_meta("okl_lit"):
				occ.remove_meta("okl_lit")
			if poly.cull_mode != CULL_DISABLED:
				poly.cull_mode = CULL_DISABLED
		return

	for occ in dd_occluders:
		var poly = occ.occluder
		if poly == null:
			continue
		if not occ.has_meta("okl_orig"):
			occ.set_meta("okl_orig", poly.polygon)
			# BitMap.OpaqueToPolygons (epsilon 8) can produce self-intersecting
			# outlines at thin necks / pinch points. One-sided culling relies on
			# a consistent winding, so such loops leak light. Clean the outline
			# by merging it with itself (Clipper union), which yields simple
			# polygons; holes are discarded (they never reach the floor).
			var pieces := _clean_polygon(poly.polygon)
			if pieces.size() == 0:
				pieces = [poly.polygon]
			poly.polygon = pieces[0]
			for k in range(1, pieces.size()):
				var extra_poly = OccluderPolygon2D.new()
				extra_poly.closed = true
				extra_poly.polygon = pieces[k]
				var extra = LightOccluder2D.new()
				extra.occluder = extra_poly
				extra.light_mask = occ.light_mask
				extra.position = occ.position
				extra.set_meta("okl_extra", true)
				prop.add_child(extra)
				extras.append(extra)
		_set_one_sided(poly, flipped)
		# Flag read by other mods (e.g. Soft Shadows' LightShadows.gd) that
		# rebuild shadows themselves from the occluder polygons.
		if not occ.has_meta("okl_lit"):
			occ.set_meta("okl_lit", true)
			print("[OKL] flagged occluder okl_lit on " + _node_id(prop))
	for e in extras:
		if e.occluder != null:
			_set_one_sided(e.occluder, flipped)
		if not e.has_meta("okl_lit"):
			e.set_meta("okl_lit", true)


func _set_one_sided(poly, flipped: bool) -> void:
	var cw: bool = Geometry.is_polygon_clockwise(poly.polygon)
	if flipped:
		cw = not cw
	if INVERT_CULL:
		cw = not cw
	var target := CULL_CLOCKWISE if cw else CULL_COUNTER_CLOCKWISE
	if poly.cull_mode != target:
		poly.cull_mode = target


# Returns an Array of simple (non self-intersecting) outer polygons.
func _clean_polygon(points: PoolVector2Array) -> Array:
	var out: Array = []
	if points.size() < 3:
		return out
	var merged: Array = Geometry.merge_polygons_2d(points, points)
	var holes: Array = []
	for piece in merged:
		if piece.size() < 3:
			continue
		# merge_polygons_2d marks holes as clockwise polygons.
		if Geometry.is_polygon_clockwise(piece):
			holes.append(piece)
		else:
			out.append(piece)
	# Safety net: if every piece reads as a hole, the winding convention is
	# not what we expect -- keep them all rather than dropping the outline.
	if out.empty():
		out = holes
	if SMOOTH_RADIUS > 0.0:
		out = _close_polygons(out, SMOOTH_RADIUS)
	return out


# Dilate by r then erode by r (round joins). Fills notches smaller than ~r.
func _close_polygons(polys: Array, r: float) -> Array:
	var dilated: Array = []
	for p in polys:
		dilated += Geometry.offset_polygon_2d(p, r, Geometry.JOIN_ROUND)
	if dilated.empty():
		return polys
	var eroded: Array = []
	for p in dilated:
		if Geometry.is_polygon_clockwise(p):
			continue   # hole produced by the dilation, ignore
		eroded += Geometry.offset_polygon_2d(p, -r, Geometry.JOIN_ROUND)
	var out: Array = []
	for p in eroded:
		if p.size() >= 3 and not Geometry.is_polygon_clockwise(p):
			out.append(p)
	if out.empty():
		return polys
	return out


# ── Undo / redo ─────────────────────────────────────────────────────────────

func _capture_states(ids: Array) -> Array:
	var store = _store()
	var out: Array = []
	for nid in ids:
		out.append({"id": nid, "lit": store.has(nid)})
	return out


func _record_change(before: Array, after: Array) -> void:
	if before.empty() or before.size() != after.size():
		return
	var changed := false
	for i in range(before.size()):
		if before[i]["lit"] != after[i]["lit"]:
			changed = true
			break
	if not changed:
		return
	var undo = _get_undo_lib()
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_states", [before],
		self, "_restore_states", [after])


func _restore_states(states: Array) -> void:
	_user_toggling = true
	for entry in states:
		_set_lit(entry["id"], entry["lit"])
	_reapply_all()
	_user_toggling = false


func _get_undo_lib():
	if _g == null or not (_g.ModMapData is Dictionary):
		return null
	return _g.ModMapData.get("_undo_lib")
