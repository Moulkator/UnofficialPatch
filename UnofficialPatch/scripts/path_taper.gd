# path_taper.gd
# Adds a "Custom Grow/Shrink" toggle plus two sliders (Grow %, Shrink %) to
# the SelectTool panel for selected paths.
#
# Vanilla Dungeondraft (Pathway.GrowShrinkEnds) tapers a Grow/Shrink path
# over a fixed number of smoothed points (count/3, max 50) with an ease
# curve. This mod, when the toggle is ON, overrides that with a LINEAR ramp
# whose length is a percentage of the path's arc length:
#   - Grow   X% : width goes 0 -> full over the first X% of the path
#   - Shrink X% : width goes full -> 0 over the last X% of the path
#   - 100% = the ramp spans the whole path, 0% = no taper at all.
# When the toggle is OFF the path keeps the vanilla behavior.
#
# The controls are shown only when at least one path is selected and every
# selected path has Grow (Grow row) and/or Shrink (Shrink row) enabled.
#
# Persistence: ModMapData["_path_taper"] = { "node-id-N": {on, grow, shrink} }.
# DD saves ModMapData inside the map file, so the settings follow the map.
#
# Re-application: DD's Smooth() rebuilds the smoothed points and re-runs the
# vanilla taper on every edit/load. There is no hook, so a Timer polls the
# stored paths and re-applies the per-point widths whenever the geometry
# signature (point count, width, points hash) changes.
#
# Free Transform interop (independent, FT is NOT required): if a path also
# carries an FT width profile, widths are applied through FT (which queries
# compute_taper() below) so both effects combine instead of fighting.

var _g

var _select_tool  = null
var _select_panel = null
var _undo_lib     = null

# UI
var _group       : Control = null   # header row (label + CheckButton)
var _toggle      : CheckButton = null
var _grow_row    : Control = null
var _grow_slider : HSlider = null
var _grow_spin   : SpinBox = null
var _shrink_row  : Control = null
var _shrink_slider : HSlider = null
var _shrink_spin   : SpinBox = null
var _syncing := false

var _timer = null
const CHECK_INTERVAL := 0.1
const STORE_KEY := "_path_taper"
const TYPE_PATHWAY := 5           # SelectableType.Pathway
const GROW_DEFAULT := 33
const SHRINK_DEFAULT := 33
const UNDO_IDLE_MS := 400         # slider burst -> single undo record

# Selection tracking (avoid treating a selection-sync as a user change)
var _last_sel_ids := []
var _last_toggle_pressed := false

# Undo burst handling for sliders
var _burst_before := []           # captured states at start of a burst
var _burst_paths := []
var _burst_last_ms := 0

# Geometry signatures of paths we last applied widths to
var _applied_sig := {}


# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func initialize() -> void:
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if _select_panel != null:
		_create_ui()
	else:
		print("[PathTaper] WARNING: SelectTool panel not found")

	# Cross-session guard (same pattern as wall_bevel): free a Timer left by a
	# previous instance before adding ours.
	if Engine.has_meta("pt_timer"):
		var old_t = Engine.get_meta("pt_timer")
		if is_instance_valid(old_t):
			old_t.queue_free()
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	Engine.set_meta("pt_timer", _timer)
	_g.Editor.add_child(_timer)

	# Expose ourselves to free_transform (compute_taper).
	Engine.set_meta("up_path_taper", self)
	print("[PathTaper] initialized (ui=%s)" % str(_group != null))


func cleanup() -> void:
	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
	_timer = null
	for c in [_group, _grow_row, _shrink_row]:
		if c != null and is_instance_valid(c):
			c.queue_free()
	_group = null
	_grow_row = null
	_shrink_row = null
	if Engine.has_meta("up_path_taper") and Engine.get_meta("up_path_taper") == self:
		Engine.remove_meta("up_path_taper")


# ─────────────────────────────────────────────────────────────────────────────
# UI
# ─────────────────────────────────────────────────────────────────────────────

func _create_ui() -> void:
	var parent = _select_panel.get("Align")
	if parent == null:
		parent = _select_panel.find_node("Align", true, false)
	if parent == null:
		return

	# Header: label + ON/OFF
	_group = HBoxContainer.new()
	_group.name = "PathTaperGroup"
	_group.focus_mode = Control.FOCUS_NONE
	var lbl = Label.new()
	lbl.text = "Custom Grow/Shrink"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.focus_mode = Control.FOCUS_NONE
	_toggle = CheckButton.new()
	_toggle.hint_tooltip = "Override the vanilla Grow/Shrink taper of the selected path(s)\nwith a linear ramp over a chosen fraction of the path."
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed = false
	# No signal on the toggle: state is polled in _tick (safe outside UI callbacks).
	_group.add_child(lbl)
	_group.add_child(_toggle)

	_grow_row = _make_slider_row("Grow", GROW_DEFAULT,
		"Length of the grow ramp, as a percentage of the path (100% = whole path, 0% = no taper).",
		"_on_grow_slider", "_on_grow_spin")
	_grow_slider = _grow_row.get_meta("slider")
	_grow_spin = _grow_row.get_meta("spin")
	_shrink_row = _make_slider_row("Shrink", SHRINK_DEFAULT,
		"Length of the shrink ramp, as a percentage of the path (100% = whole path, 0% = no taper).",
		"_on_shrink_slider", "_on_shrink_spin")
	_shrink_slider = _shrink_row.get_meta("slider")
	_shrink_spin = _shrink_row.get_meta("spin")

	parent.add_child(_group)
	parent.add_child(_grow_row)
	parent.add_child(_shrink_row)
	# Place just before the hidden option sections (same as wall_bevel).
	var final_idx = parent.get_child_count()
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		if child is VBoxContainer and not child.visible and child != _grow_row and child != _shrink_row:
			final_idx = i
			break
	parent.move_child(_group, final_idx)
	parent.move_child(_grow_row, final_idx + 1)
	parent.move_child(_shrink_row, final_idx + 2)
	_group.visible = false
	_grow_row.visible = false
	_shrink_row.visible = false


func _make_slider_row(title: String, default_value: int, tooltip: String,
		slider_cb: String, spin_cb: String) -> VBoxContainer:
	var box = VBoxContainer.new()
	box.name = "PathTaper" + title
	box.focus_mode = Control.FOCUS_NONE
	var lbl = Label.new()
	lbl.text = title
	lbl.focus_mode = Control.FOCUS_NONE
	var row = HBoxContainer.new()
	row.focus_mode = Control.FOCUS_NONE
	var sld = HSlider.new()
	sld.min_value = 0
	sld.max_value = 100
	sld.step = 1
	sld.value = default_value
	sld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sld.focus_mode = Control.FOCUS_NONE
	sld.rect_min_size = Vector2(110, 0)
	sld.hint_tooltip = tooltip
	var spin = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 100
	spin.step = 1
	spin.value = default_value
	spin.suffix = "%"
	spin.focus_mode = Control.FOCUS_CLICK
	var rst = Button.new()
	rst.hint_tooltip = "Reset to " + str(default_value) + "%"
	rst.focus_mode = Control.FOCUS_NONE
	rst.icon = _load_icon("icons/reset.png", 0.5)
	rst.connect("pressed", self, "_on_reset_pressed", [title.to_lower()])
	row.add_child(sld)
	row.add_child(spin)
	row.add_child(rst)
	box.add_child(lbl)
	box.add_child(row)
	sld.connect("value_changed", self, slider_cb)
	spin.connect("value_changed", self, spin_cb)
	box.set_meta("slider", sld)
	box.set_meta("spin", spin)
	return box


func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	image.load(_g.Root + icon_path)
	if scale != 1.0:
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


# Reset button: back to the default percentage, recorded as its own undo step.
func _on_reset_pressed(field: String) -> void:
	var paths = _get_selected_paths()
	if paths.empty():
		return
	if not _burst_before.empty():
		_commit_burst()
	var default_value = GROW_DEFAULT if field == "grow" else SHRINK_DEFAULT
	var before = _capture_states(paths)
	for p in paths:
		_entry(p, true)[field] = default_value
		_apply_to_path(p)
	_syncing = true
	var sld = _grow_slider if field == "grow" else _shrink_slider
	var spin = _grow_spin if field == "grow" else _shrink_spin
	if sld != null: sld.value = default_value
	if spin != null: spin.value = default_value
	_syncing = false
	_record_change(before, _capture_states(paths))


func _on_grow_slider(value) -> void:
	_apply_from_ui("grow", int(value))

func _on_grow_spin(value) -> void:
	_apply_from_ui("grow", int(value))

func _on_shrink_slider(value) -> void:
	_apply_from_ui("shrink", int(value))

func _on_shrink_spin(value) -> void:
	_apply_from_ui("shrink", int(value))


# Slider/spin changed by the user: update the store and the paths, keep the
# twin control in sync, and open/extend an undo burst.
func _apply_from_ui(field: String, value: int) -> void:
	if _syncing:
		return
	var paths = _get_selected_paths()
	if paths.empty():
		return
	if _burst_before.empty():
		_burst_before = _capture_states(paths)
		_burst_paths = paths.duplicate()
	_burst_last_ms = OS.get_ticks_msec()
	for p in paths:
		var e = _entry(p, true)
		e[field] = value
	_syncing = true
	var sld = _grow_slider if field == "grow" else _shrink_slider
	var spin = _grow_spin if field == "grow" else _shrink_spin
	if sld != null and int(sld.value) != value:
		sld.value = value
	if spin != null and int(spin.value) != value:
		spin.value = value
	_syncing = false
	for p in paths:
		_apply_to_path(p)


func _sync_ui_from(path) -> void:
	var e = _entry(path, false)
	var on = e != null and bool(e.get("on", false))
	var gv = int(e.get("grow", GROW_DEFAULT)) if e != null else GROW_DEFAULT
	var sv = int(e.get("shrink", SHRINK_DEFAULT)) if e != null else SHRINK_DEFAULT
	_syncing = true
	_toggle.pressed = on
	_last_toggle_pressed = on
	if _grow_slider != null: _grow_slider.value = gv
	if _grow_spin != null: _grow_spin.value = gv
	if _shrink_slider != null: _shrink_slider.value = sv
	if _shrink_spin != null: _shrink_spin.value = sv
	_syncing = false


# ─────────────────────────────────────────────────────────────────────────────
# Tick: UI visibility / toggle polling / undo bursts / re-application
# ─────────────────────────────────────────────────────────────────────────────

func _tick() -> void:
	if _g == null or _g.Editor == null or _g.World == null:
		return
	# Keep stored paths tapered whatever the active tool (Smooth() can be
	# triggered by any tool, plus map load).
	_reapply_all()
	# Commit a finished slider burst as a single undo record.
	if not _burst_before.empty() and OS.get_ticks_msec() - _burst_last_ms > UNDO_IDLE_MS:
		_commit_burst()

	if _group == null or not is_instance_valid(_group):
		return
	if str(_g.Editor.ActiveToolName) != "SelectTool":
		_set_visible(false, false, false)
		return
	var paths = _get_selected_paths()
	if paths.empty():
		_set_visible(false, false, false)
		_last_sel_ids = []
		return
	var all_grow = true
	var all_shrink = true
	for p in paths:
		if not bool(p.get("Grow")):
			all_grow = false
		if not bool(p.get("Shrink")):
			all_shrink = false
	if not all_grow and not all_shrink:
		_set_visible(false, false, false)
		_last_sel_ids = []
		return

	# Selection changed -> sync controls from the first path, no apply.
	var ids := []
	for p in paths:
		ids.append(p.get_instance_id())
	if ids != _last_sel_ids:
		_last_sel_ids = ids
		_sync_ui_from(paths[0])
	# Stable selection: a toggle state change = user click.
	elif _toggle.pressed != _last_toggle_pressed:
		_last_toggle_pressed = _toggle.pressed
		_set_custom_on(paths, _toggle.pressed)

	var on = _toggle.pressed
	_set_visible(true, on and all_grow, on and all_shrink)


func _set_visible(group: bool, grow: bool, shrink: bool) -> void:
	if _group != null and is_instance_valid(_group):
		_group.visible = group
	if _grow_row != null and is_instance_valid(_grow_row):
		_grow_row.visible = grow
	if _shrink_row != null and is_instance_valid(_shrink_row):
		_shrink_row.visible = shrink


func _set_custom_on(paths: Array, on: bool) -> void:
	var before = _capture_states(paths)
	for p in paths:
		var e = _entry(p, true)
		e["on"] = on
		_apply_to_path(p)
	_record_change(before, _capture_states(paths))


# ─────────────────────────────────────────────────────────────────────────────
# Store
# ─────────────────────────────────────────────────────────────────────────────

func _store() -> Dictionary:
	if _g.ModMapData == null:
		return {}
	if not _g.ModMapData.has(STORE_KEY) or not (_g.ModMapData[STORE_KEY] is Dictionary):
		_g.ModMapData[STORE_KEY] = {}
	return _g.ModMapData[STORE_KEY]


func _key(node) -> String:
	if node != null and is_instance_valid(node) and node.has_meta("node_id"):
		return "node-id-" + str(node.get_meta("node_id"))
	return ""


func _node_from_key(key: String):
	if not key.begins_with("node-id-"):
		return null
	var node_id = int(key.substr(8))
	if not _g.World.HasNodeID(node_id):
		return null
	return _g.World.GetNodeByID(node_id)


# Returns the store entry of a path (created with defaults if `create`).
func _entry(path, create: bool):
	var key = _key(path)
	if key == "":
		return null
	var store = _store()
	if store.has(key):
		return store[key]
	if not create:
		return null
	store[key] = {"on": false, "grow": GROW_DEFAULT, "shrink": SHRINK_DEFAULT}
	return store[key]


# Public: true if the custom taper is active for this path.
func is_custom_on(path) -> bool:
	var e = _entry(path, false)
	return e != null and bool(e.get("on", false))


# ─────────────────────────────────────────────────────────────────────────────
# Taper math / application
# ─────────────────────────────────────────────────────────────────────────────

# Public (also used by free_transform): per-point width factors [0..1] for the
# smoothed points of `path`, or null if the custom taper is not active.
func compute_taper(path, count: int):
	var e = _entry(path, false)
	if e == null or not bool(e.get("on", false)):
		return null
	if count < 2:
		return null
	var grow = bool(path.get("Grow"))
	var shrink = bool(path.get("Shrink"))
	var gr = clamp(float(e.get("grow", GROW_DEFAULT)) / 100.0, 0.0, 1.0)
	var sr = clamp(float(e.get("shrink", SHRINK_DEFAULT)) / 100.0, 0.0, 1.0)
	var pts = path.points
	# Arc-length fraction of each point (open polyline, like the vanilla
	# index-based taper which ignores the loop closing segment).
	var cum = [0.0]
	for i in range(count - 1):
		cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
	var total = cum[count - 1]
	var taper = []
	for i in range(count):
		var f = cum[i] / total if total > 0.001 else float(i) / float(count - 1)
		var w = 1.0
		if grow and gr > 0.0:
			w *= clamp(f / gr, 0.0, 1.0)
		if shrink and sr > 0.0:
			w *= clamp((1.0 - f) / sr, 0.0, 1.0)
		taper.append(w)
	return taper


func _geom_sig(path) -> Array:
	var pts = path.points
	var h = 0.0
	var n = pts.size()
	for i in range(n):
		h += pts[i].x * (i + 1) + pts[i].y * (n - i)
	return [n, path.width, h]


# Applies (or restores vanilla) widths on one path according to its entry.
func _apply_to_path(path) -> void:
	if path == null or not is_instance_valid(path) or not (path is Line2D):
		return
	var key = _key(path)
	if key == "":
		return
	var e = _entry(path, false)
	var on = e != null and bool(e.get("on", false))
	if not on:
		# Back to vanilla: Smooth() re-runs GrowShrinkEnds (or leaves uniform
		# widths). FT, if present, also re-reads compute_taper (null now).
		if path.has_method("Smooth"):
			path.Smooth()
		_applied_sig.erase(key)
		_ft_refresh(path)
		return
	# Path also has a Free Transform width profile: let FT apply the combined
	# result (it calls compute_taper()).
	if _ft_apply_if_profiled(path):
		_applied_sig[key] = _geom_sig(path)
		return
	var count = path.points.size()
	var taper = compute_taper(path, count)
	if taper == null:
		return
	var base_w = float(path.width)
	if path.has_method("set_point_width"):
		for i in range(count):
			path.set_point_width(i, base_w * taper[i])
	_applied_sig[key] = _geom_sig(path)


# Re-applies the custom taper on every stored path whose geometry changed
# since our last application (Smooth() resets widths to vanilla).
func _reapply_all() -> void:
	if _g.ModMapData == null or not _g.ModMapData.has(STORE_KEY):
		return
	var store = _g.ModMapData[STORE_KEY]
	if not (store is Dictionary) or store.empty():
		return
	for key in store.keys():
		var e = store[key]
		if not (e is Dictionary) or not bool(e.get("on", false)):
			continue
		var nd = _node_from_key(key)
		if nd == null or not is_instance_valid(nd) or not (nd is Line2D):
			continue
		if nd.points.size() < 2:
			continue
		var sig = _geom_sig(nd)
		if _applied_sig.get(key) != sig:
			_apply_to_path(nd)


# ── Free Transform interop ───────────────────────────────────────────────────

func _ft_mod():
	if _g.ModMapData == null:
		return null
	var ft = _g.ModMapData.get("_free_transform", null)
	if ft == null or not is_instance_valid(ft):
		return null
	return ft


# If the path carries an FT width profile, apply widths through FT and return
# true. FT's _apply_path_point_widths queries compute_taper() for the taper.
func _ft_apply_if_profiled(path) -> bool:
	var ft = _ft_mod()
	if ft == null or not ft.has_method("_apply_path_point_widths"):
		return false
	var wstore = _g.ModMapData.get("_ft_width_warp", null)
	if not (wstore is Dictionary):
		return false
	var key = _key(path)
	if not wstore.has(key):
		return false
	ft._apply_path_point_widths(path, wstore[key])
	return true


# After switching back to vanilla, make FT re-apply its own profile (if any)
# so the vanilla taper is combined again.
func _ft_refresh(path) -> void:
	_ft_apply_if_profiled(path)


# ─────────────────────────────────────────────────────────────────────────────
# Selection helpers
# ─────────────────────────────────────────────────────────────────────────────

func _get_selected_paths() -> Array:
	var out := []
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
		seen[thing] = true
		var type = -1
		if _select_tool.has_method("GetSelectableType"):
			type = _select_tool.call("GetSelectableType", thing)
		if int(type) == TYPE_PATHWAY and thing is Line2D:
			out.append(thing)
	return out


# ─────────────────────────────────────────────────────────────────────────────
# Undo
# ─────────────────────────────────────────────────────────────────────────────

func _capture_states(paths: Array) -> Array:
	var out := []
	for p in paths:
		var key = _key(p)
		if key == "":
			continue
		var e = _entry(p, false)
		out.append({
			"key": key,
			"entry": e.duplicate(true) if e != null else null,
		})
	return out


func _commit_burst() -> void:
	var before = _burst_before
	var paths = _burst_paths
	_burst_before = []
	_burst_paths = []
	var alive := []
	for p in paths:
		if p != null and is_instance_valid(p):
			alive.append(p)
	_record_change(before, _capture_states(alive))


func _record_change(before: Array, after: Array) -> void:
	if before.empty() or after.empty() or before.size() != after.size():
		return
	var changed := false
	for i in range(before.size()):
		if before[i]["entry"] != after[i]["entry"]:
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
	var store = _store()
	for st in states:
		var key = st["key"]
		if st["entry"] == null:
			store.erase(key)
		else:
			store[key] = st["entry"].duplicate(true)
		var nd = _node_from_key(key)
		if nd != null and is_instance_valid(nd):
			_apply_to_path(nd)
	# Resync the UI so the next tick doesn't read the change as a user click.
	var paths = _get_selected_paths()
	if not paths.empty():
		_sync_ui_from(paths[0])


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")
