# pattern_scale_bake.gd
#
# Test mod: bakes a PatternShape's `node.scale` into its `polygon`.
# Triggered manually via the right-click context menu on a SelectTool
# selection that contains at least one pattern with a non-(1,1) scale.
#
# Why
# ---
# Vanilla DD's resize of a pattern multiplies `node.scale` while leaving
# `polygon` unchanged. DD's snap (and Snappy mod's snap) reference
# `node.position` for grid alignment, so the corners — at world
# `position + polygon[i] * scale` — drift off-grid by amounts that
# aren't multiples of the grid spacing. Baking transforms the scale
# back into the polygon: after `polygon *= scale; scale = 1`, the
# corners are at `position + polygon[i]` which match what DD's snap
# pipeline assumes.
#
# Risk — TEST FIRST
# -----------------
# DD's stock pattern shader uses local VERTEX coords for UV sampling.
# Baking changes VERTEX values, which MAY make the rendered texture
# look different (more/smaller tiles within the same on-screen
# polygon, or a shift in the texture origin). If the visual is
# preserved, we'll automate this on drag end. If not, the user can
# invoke it only on patterns where the visual change is acceptable
# (e.g. solid-colour patterns).
#
# Undo
# ----
# Pushes a custom history record so Ctrl+Z reverts the bake (restores
# polygon AND scale). DD's own resize record is unaffected.

var script_class = "tool"
var _g
var ui_util

const SELECTABLE_PATTERN_SHAPE := 7

# right_click_util provider hooks --------------------------------------

func get_context_items(raw) -> Array:
	# Show the menu item only if at least one selected pattern has a
	# non-identity scale.
	var any_scaled = false
	for s in raw:
		if s == null:
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if not (thing is Polygon2D):
			continue
		# Must be a PatternShape (type 7), not a generic Polygon2D.
		var t = _get_selectable_type(thing)
		if t != SELECTABLE_PATTERN_SHAPE:
			continue
		if thing.scale != Vector2.ONE:
			any_scaled = true
			break
	if not any_scaled:
		return []
	return [{
		"label": "Bake Pattern Scale",
		"icon": null,
		"action_id": "bake_pattern_scale",
	}]


func on_context_action(action_id: String, raw) -> void:
	if action_id != "bake_pattern_scale":
		return
	_bake_selection(raw)


# ---------------------------------------------------------------------

func initialize() -> void:
	print("[PatternScaleBake] Initialized")


# Register with right_click_util — invoked by Main.gd after
# right_click_util loads.
func register_with(rcu) -> void:
	if rcu == null:
		return
	if rcu.has_method("register"):
		rcu.register(self)


# Bake every PatternShape in `raw` whose scale isn't (1,1). Pushes ONE
# group history record covering all baked patterns so a single Ctrl+Z
# reverts them.
func _bake_selection(raw) -> void:
	var entries := []
	for s in raw:
		if s == null:
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if not (thing is Polygon2D):
			continue
		var t = _get_selectable_type(thing)
		if t != SELECTABLE_PATTERN_SHAPE:
			continue
		if thing.scale == Vector2.ONE:
			continue
		var entry = _bake_pattern(thing)
		if entry != null:
			entries.append(entry)
	if entries.size() == 0:
		return
	_push_record(entries)


# Bake one pattern. Returns the entry dict for the undo record, or null
# if there was nothing to do.
#
# Pre-bake state captured so undo can restore it exactly.
func _bake_pattern(pattern):
	var s = pattern.scale
	if s == Vector2.ONE:
		return null
	var pre_polygon = []
	var poly = pattern.polygon
	for p in poly:
		pre_polygon.append(p)
	# Apply scale to each polygon vertex.
	var new_poly = PoolVector2Array()
	for p in poly:
		new_poly.append(Vector2(p.x * s.x, p.y * s.y))
	pattern.polygon = new_poly
	# Outline (Line2D) child must be rebuilt from the new polygon so
	# the visible selection outline matches.
	var outline = pattern.get("Outline")
	if outline != null and outline is Line2D:
		var lpts = PoolVector2Array()
		for p in new_poly:
			lpts.append(p)
		if lpts.size() > 0:
			lpts.append(lpts[0])
		outline.points = lpts
	# Reset scale.
	pattern.scale = Vector2.ONE
	return {
		"pattern": pattern,
		"pre_scale": s,
		"pre_polygon": pre_polygon,
	}


# Undo / redo record ---------------------------------------------------

class BakeRecord:
	extends Reference
	var owner_mod
	var entries: Array = []
	var label: String = "Bake Pattern Scale"

	func undo():
		_apply(true)

	func redo():
		_apply(false)

	func _apply(use_pre: bool) -> void:
		for e in entries:
			var pattern = e.get("pattern")
			if pattern == null or not is_instance_valid(pattern):
				continue
			if use_pre:
				# Restore original polygon and scale.
				var poly = PoolVector2Array()
				for p in e["pre_polygon"]:
					poly.append(p)
				pattern.polygon = poly
				pattern.scale = e["pre_scale"]
			else:
				# Re-apply bake: scale → polygon, scale = 1.
				var s = e["pre_scale"]
				var new_poly = PoolVector2Array()
				for p in e["pre_polygon"]:
					new_poly.append(Vector2(p.x * s.x, p.y * s.y))
				pattern.polygon = new_poly
				pattern.scale = Vector2.ONE
			# Rebuild Outline either way.
			var outline = pattern.get("Outline")
			if outline != null and outline is Line2D:
				var lpts = PoolVector2Array()
				for p in pattern.polygon:
					lpts.append(p)
				if lpts.size() > 0:
					lpts.append(lpts[0])
				outline.points = lpts


func _push_record(entries: Array) -> void:
	if _g == null or _g.Editor == null:
		return
	var history = _g.Editor.get("History")
	if history == null:
		return
	var rec = BakeRecord.new()
	rec.owner_mod = self
	rec.entries = entries
	if history.has_method("CreateCustomRecord"):
		history.CreateCustomRecord(rec)
	elif history.has_method("Record"):
		history.Record(rec)


# ---------------------------------------------------------------------

func _get_selectable_type(thing) -> int:
	if _g == null or _g.Editor == null:
		return -1
	var st = _g.Editor.Tools.get("SelectTool") if _g.Editor.get("Tools") != null else null
	if st == null or not st.has_method("GetSelectableType"):
		return -1
	return st.GetSelectableType(thing)
