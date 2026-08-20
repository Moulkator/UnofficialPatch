# library_right_panel.gd
# Moves the asset libraries that live inside the left tool panels into a
# dedicated right-side panel, next to DD's native ObjectLibraryPanel /
# PathLibraryPanel.
#
# Vanilla scene structure:
#   Master/Editor/VPartition/Panels
#     Tools/Anchor/<ToolPanel>/Divider/.../Align   <- left tool panels
#     HSplit
#       Content              <- map viewport
#       ObjectLibraryPanel   <- native right library (Object / Scatter tools)
#       PathLibraryPanel     <- native right library (Path tool)
#
# Our panel is inserted in HSplit, after PathLibraryPanel, so it behaves
# exactly like the native ones: HSplit is a horizontal box, so the panel
# steals width from Content instead of overlapping it. That matters because
# an overlapping panel would let clicks reach DD's _ContentInput.
#
# Which libraries are moved (see ENTRIES): every GridMenu / ItemList that
# Toolset.Init() builds through CreateTextureGridMenu / CreateWideTextureGridMenu
# / CreateTilesetMenu, registered in Tool.Controls under a known key.
#
# How a library is moved:
#   Toolset builds each library as   Label("WALL"), GridMenu   in the same
#   parent VBox. We move the GridMenu plus every sibling sitting between the
#   label and the grid (that is where AdditionalSearchOptions injects its
#   search bars, so they travel with their library), and we hide the original
#   label -- the right panel carries its own English heading instead.
#
# Visibility:
#   A moved library must be shown exactly when it would have been shown in
#   the left panel. Since we only removed the grid, its original parent is
#   still in the tree and DD keeps calling Show()/Hide() on it (tool panels
#   for the plain tools, per-type option sections for the SelectTool). So
#   "original parent .is_visible_in_tree()" is the authoritative probe, and
#   it works uniformly for both cases.
#
# ORDERING NOTE (AdditionalSearchOptions):
#   ASO computes its insertion index from grid_menu.get_index() inside
#   tool_panel.Align. If we moved the grid before ASO built its UI, ASO would
#   insert its search bars at the wrong place. We therefore delay the initial
#   move by BOOT_DELAY seconds so ASO gets to build first. A hot toggle from
#   Mod Settings applies immediately (boot_delay is reset to 0 by Main.gd).

var _g
var ui_util = null

const PANEL_NAME     := "UP_LibraryRightPanel"
const STATE_FILE     := "user://UnofficialPatch/library_right_panel.json"
const STATE_DIR      := "user://UnofficialPatch"

const MIN_WIDTH      := 260.0
const DEFAULT_WIDTH  := 340.0

# Heading size, as a multiple of a normal DD panel label. See _heading_font().
const HEADING_SCALE  := 1.6

# Seconds to wait at startup before moving anything (see ORDERING NOTE).
const BOOT_DELAY     := 4.0

# How often (seconds) we look for controls other mods injected next to a
# library after we relocated it.
const ADOPT_INTERVAL := 0.5

# Opt-out contract for other mods. A control that happens to sit between a
# section label and its library, but is NOT part of the library, stays on the
# left if it carries this metadata:
#
#     my_container.set_meta("lrp_keep_left", true)
#
# KEEP_LEFT_NAMES is a fallback for containers we know about but that do not
# set the flag yet.
# DD's own right-side library panels whose search row we rebuild -- see
# _try_split_search_row(). ObjectLibraryPanel is deliberately left out: it is
# wide enough that the field stays usable even with ASO's buttons on the row.
const NATIVE_PANELS := ["PathLibraryPanel"]

const KEEP_LEFT_META  := "lrp_keep_left"
const KEEP_LEFT_NAMES := [
	"LightShadowsToolContainer",
	"LightShadowsSelectContainer",
]

# Libraries to relocate.
#   tool    : key in Editor.Tools / Toolset.ToolPanels
#   control : key in Tool.Controls (set by ToolPanel.CreateXxx)
#   title   : heading shown in the right panel (English, per mod convention)
const ENTRIES := [
	{"id": "floor_tiles",  "tool": "FloorShapeTool",   "control": "SmartTileId",    "title": "Floors"},
	{"id": "floor_walls",  "tool": "FloorShapeTool",   "control": "WallTexture",    "title": "Walls"},
	{"id": "wall",         "tool": "WallTool",         "control": "Texture",        "title": "Walls"},
	{"id": "portal",       "tool": "PortalTool",       "control": "Texture",        "title": "Portals"},
	{"id": "cave",         "tool": "CaveBrush",        "control": "Texture",        "title": "Caves"},
	{"id": "pattern",      "tool": "PatternShapeTool", "control": "Texture",        "title": "Patterns"},
	{"id": "roof",         "tool": "RoofTool",         "control": "Texture",        "title": "Roofs"},
	{"id": "material",     "tool": "MaterialBrush",    "control": "Texture",        "title": "Materials"},
	{"id": "light",        "tool": "LightTool",        "control": "Texture",        "title": "Lights"},
	{"id": "sel_wall",     "tool": "SelectTool",       "control": "WallTexture",    "title": "Walls"},
	{"id": "sel_portal",   "tool": "SelectTool",       "control": "PortalTexture",  "title": "Portals"},
	{"id": "sel_pattern",  "tool": "SelectTool",       "control": "PatternTexture", "title": "Patterns"},
	{"id": "sel_light",    "tool": "SelectTool",       "control": "LightTexture",   "title": "Lights"},
]

var _panel   = null
var _content = null
var _grabber = null

# One record per relocated library:
#   {id, tool, parent, start, nodes, label, label_visible, box}
var _moved := []

# Libraries hosted on behalf of another mod (see attach_dynamic).
#   id -> {box, node}
var _dynamic := {}

var _applied    := false
var _adopt_timer := 0.0
var _heading_font_cache = null

# panel key -> {hbox, row, nodes, indices, line_edit, le_flags}
var _search_split := {}
var _width      := DEFAULT_WIDTH
var _dpi        := 1.0
var _retry      := 0.0
var _last_state := {}

# Set to 0.0 by Main.gd when the mod is hot-loaded from Mod Settings.
var boot_delay := BOOT_DELAY


# ── lifecycle ────────────────────────────────────────────────────────────────

func initialize() -> void:
	_dpi = max(OS.get_screen_dpi() / 96.0, 1.0)
	_load_width()
	# Publish for cross-mod use (roof_select hosts its Roofs style list here).
	if _g != null and _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		_g.ModMapData["_library_right_panel"] = self
	print("[LibraryRightPanel] Initialized")


func cleanup() -> void:
	for id in _dynamic.keys():
		var d = _dynamic[id]
		if is_instance_valid(d["box"]):
			d["box"].queue_free()
	_dynamic.clear()

	for m in _moved:
		_restore_entry(m)
	_moved.clear()

	_restore_search_rows()

	_save_width()

	if _panel != null and is_instance_valid(_panel):
		if _panel.get_parent() != null:
			_panel.get_parent().remove_child(_panel)
		_panel.queue_free()
	_panel = null
	_content = null
	_grabber = null
	_applied = false

	if _g != null and _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		if _g.ModMapData.get("_library_right_panel") == self:
			_g.ModMapData.erase("_library_right_panel")
	print("[LibraryRightPanel] Cleaned up")


func update(delta) -> void:
	if _g == null or _g.Editor == null:
		return

	if not _applied:
		if boot_delay > 0.0:
			boot_delay -= delta
			return
		if _retry > 0.0:
			_retry -= delta
			return
		if not _apply():
			_retry = 1.0
		return

	if _panel == null or not is_instance_valid(_panel):
		return

	_adopt_timer -= delta
	if _adopt_timer <= 0.0:
		_adopt_timer = ADOPT_INTERVAL
		_adopt_orphans()
		for key in NATIVE_PANELS:
			_try_split_search_row(key)

	_refresh_visibility()


# ── public API (used by other sub-mods) ──────────────────────────────────────

# True once the panel exists and the libraries have been relocated.
func is_active() -> bool:
	return _applied and _panel != null and is_instance_valid(_panel)


# Host a control created by another mod. The control is reparented into the
# panel under its own heading; detach_dynamic() frees it.
func attach_dynamic(id: String, node: Control, title: String) -> bool:
	if not is_active() or node == null or not is_instance_valid(node):
		return false
	detach_dynamic(id)
	var box = _make_entry_box(title)
	_content.add_child(box)
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	box.add_child(node)
	_dynamic[id] = {"box": box, "node": node}
	return true


func detach_dynamic(id: String) -> void:
	if not _dynamic.has(id):
		return
	var d = _dynamic[id]
	_dynamic.erase(id)
	# Freeing the box frees the hosted control with it.
	if is_instance_valid(d["box"]):
		d["box"].queue_free()


# Hit test for "is the mouse over UI" logic in other sub-mods.
func contains_mouse() -> bool:
	if _panel == null or not is_instance_valid(_panel) or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(_panel.get_global_mouse_position())


# Returns the relocated control for a given tool/Controls key, or null when
# it has not been moved (mod disabled, or entry not found).
func get_moved_control(tool_key: String, control_key: String):
	for m in _moved:
		if m["tool"] == tool_key and m["control"] == control_key:
			if is_instance_valid(m["node"]):
				return m["node"]
			return null
	return null


# ── build / apply ────────────────────────────────────────────────────────────

func _apply() -> bool:
	if _panel == null or not is_instance_valid(_panel):
		if not _build_panel():
			return false

	var count = 0
	for e in ENTRIES:
		if _move_entry(e):
			count += 1

	if count == 0:
		return false

	# Flag entries whose original parent hosts more than one library, so the
	# adoption pass can skip them (it cannot attribute a stray control).
	for a in _moved:
		var shared = false
		for b in _moved:
			if a != b and b["parent"] == a["parent"]:
				shared = true
				break
		a["shared_parent"] = shared

	for key in NATIVE_PANELS:
		_try_split_search_row(key)

	_applied = true
	_refresh_visibility()
	print("[LibraryRightPanel] ", count, " libraries moved to the right panel")
	return true


func _find_host():
	if _g == null or _g.Editor == null:
		return null

	# Start next to the native library panels...
	var node = null
	var olp = _g.Editor.get("ObjectLibraryPanel")
	if olp != null and is_instance_valid(olp):
		node = olp.get_parent()
	if node == null:
		node = _g.Editor.get_node_or_null("VPartition/Panels/HSplit")

	# ...but HSplit is a SplitContainer: it only lays out its first two
	# *visible* children. A third panel added there keeps a zero rect and
	# never shows. Walk up until we reach a regular box container (Panels),
	# which is also where AdditionalSearchOptions puts its terrain panel.
	var guard = 3
	while node != null and is_instance_valid(node) and node is SplitContainer and guard > 0:
		node = node.get_parent()
		guard -= 1

	if node == null or not is_instance_valid(node):
		node = _g.Editor.get_node_or_null("VPartition/Panels")
	return node


func _build_panel() -> bool:
	var host = _find_host()
	if host == null or not is_instance_valid(host):
		return false

	_panel = PanelContainer.new()
	_panel.name = PANEL_NAME
	# The theme's default panel stylebox is a light grey that clashes with the
	# editor chrome; use a translucent black like the native library panels.
	var sb = StyleBoxFlat.new()
	sb.set_bg_color(Color(0, 0, 0, 0.4))
	_panel.add_stylebox_override("panel", sb)
	_panel.visible = false
	host.add_child(_panel)
	host.move_child(_panel, host.get_child_count() - 1)

	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(row)

	# Thin drag strip on the left edge, same trick as the native panels.
	_grabber = VBoxContainer.new()
	_grabber.rect_min_size = Vector2(5, 0)
	_grabber.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_grabber.connect("gui_input", self, "_on_grabber_input")
	row.add_child(_grabber)

	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_constant_override("separation", 4)
	row.add_child(_content)

	_panel.rect_min_size = Vector2(max(_width, MIN_WIDTH * _dpi), 0)
	return true


# DD's PanelHeadingFont.tres is a shared resource: load() hands out the cached
# instance, so a mod doing `load(...).size = 48` mutates it for everyone, us
# included -- duplicating it afterwards only copies the corrupted size. We
# therefore always set the size ourselves, derived from the theme's normal
# label font so it still tracks DD's Enlarge UI setting.
func _heading_font():
	if _heading_font_cache != null and is_instance_valid(_heading_font_cache):
		return _heading_font_cache

	var ref = 0
	var theme = _g.get("Theme")
	if theme != null and is_instance_valid(theme) and theme is Theme:
		if theme.has_font("font", "Label"):
			var lf = theme.get_font("font", "Label")
			if lf != null and lf.get("size") != null:
				ref = int(lf.size)
	if ref <= 0:
		ref = 16

	var f = load("res://ui/fonts/PanelHeadingFont.tres")
	if f == null:
		return null
	f = f.duplicate()
	if f.get("size") != null:
		f.size = int(round(ref * HEADING_SCALE))
	_heading_font_cache = f
	return f


func _make_entry_box(title: String) -> VBoxContainer:
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_constant_override("separation", 2)
	box.visible = false

	var lbl = Label.new()
	lbl.text = title
	var f = _heading_font()
	if f != null:
		lbl.add_font_override("font", f)
	box.add_child(lbl)
	return box


# True when a control explicitly asked to stay in the left tool panel.
func _keeps_left(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.has_meta(KEEP_LEFT_META) and node.get_meta(KEEP_LEFT_META):
		return true
	return str(node.name) in KEEP_LEFT_NAMES


func _resolve_control(tool_key: String, control_key: String):
	var tools = _g.Editor.get("Tools")
	if not tools is Dictionary:
		return null
	var t = tools.get(tool_key)
	if t == null or not is_instance_valid(t):
		return null
	var controls = t.get("Controls")
	if not controls is Dictionary:
		return null
	var ctrl = controls.get(control_key)
	if ctrl == null or not is_instance_valid(ctrl) or not ctrl is Control:
		return null
	return ctrl


func _move_entry(e: Dictionary) -> bool:
	var node = _resolve_control(e["tool"], e["control"])
	if node == null:
		return false
	var parent = node.get_parent()
	if parent == null or not is_instance_valid(parent):
		return false

	var idx = node.get_index()

	# Locate the section label right above the library, and treat everything
	# between the label and the library as part of the library block (that is
	# where AdditionalSearchOptions injects its search bars).
	var start = idx
	var label = null
	var scan = idx
	while scan - 1 >= 0:
		var prev = parent.get_child(scan - 1)
		if prev is Label:
			label = prev
			start = scan
			break
		scan -= 1
	if label == null:
		# No section label found: move the library alone rather than guessing.
		start = idx

	var nodes := []
	var indices := []
	for i in range(start, idx + 1):
		var c = parent.get_child(i)
		# Anything that opted out stays where it is; only the library itself
		# is never skipped.
		if c != node and _keeps_left(c):
			continue
		nodes.append(c)
		indices.append(i)

	var box = _make_entry_box(e["title"])
	_content.add_child(box)

	for n in nodes:
		parent.remove_child(n)
		box.add_child(n)

	var label_visible = true
	if label != null:
		label_visible = label.visible
		label.visible = false

	_moved.append({
		"id":            e["id"],
		"tool":          e["tool"],
		"control":       e["control"],
		"node":          node,
		"parent":        parent,
		"start":         start,
		"nodes":         nodes,
		"indices":       indices,
		"label":         label,
		"label_visible": label_visible,
		"box":           box,
		"shared_parent": false,
	})
	return true


func _restore_entry(m: Dictionary) -> void:
	var parent = m["parent"]
	if parent != null and is_instance_valid(parent):
		# Ascending original index: nodes that stayed behind shift back into
		# place as each earlier sibling is reinserted.
		for i in range(m["nodes"].size()):
			var n = m["nodes"][i]
			if not is_instance_valid(n):
				continue
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			parent.add_child(n)
			var target = min(m["indices"][i], parent.get_child_count() - 1)
			parent.move_child(n, target)
	var lbl = m["label"]
	if lbl != null and is_instance_valid(lbl):
		lbl.visible = m["label_visible"]
	# Adopted companions (FavsOverlay, *FavsButton, AssetFilterBox_*, ASO
	# rows) live in the box but are NOT in m["nodes"]: freeing the box would
	# free them too, leaving the library blank until the next reload
	# (favorites keeps references to the freed overlay/button). Hand them
	# back to the original parent, right after the library.
	if is_instance_valid(m["box"]) and parent != null and is_instance_valid(parent):
		var grid = m["node"]
		var after = parent.get_child_count() - 1
		if grid != null and is_instance_valid(grid) and grid.get_parent() == parent:
			after = grid.get_index()
		var strays := []
		for c in m["box"].get_children():
			if not (c is Control):
				continue
			if c in m["nodes"]:
				continue
			if c is Label:
				continue  # the box's own heading
			strays.append(c)
		for c in strays:
			m["box"].remove_child(c)
			parent.add_child(c)
			after = min(after + 1, parent.get_child_count() - 1)
			parent.move_child(c, after)
	if is_instance_valid(m["box"]):
		m["box"].queue_free()


# ── visibility ───────────────────────────────────────────────────────────────

func _refresh_visibility() -> void:
	var any = false

	for m in _moved:
		var vis = false
		var p = m["parent"]
		if p != null and is_instance_valid(p):
			vis = p.is_visible_in_tree()
		var box = m["box"]
		if is_instance_valid(box):
			if box.visible != vis:
				box.visible = vis
			if vis:
				any = true

	for id in _dynamic.keys():
		var d = _dynamic[id]
		if is_instance_valid(d["box"]):
			d["box"].visible = true
			any = true

	if _panel.visible != any:
		_panel.visible = any


# ── late arrivals ───────────────────────────────────────────────────────────
# Other mods inject controls next to a library (favorites.gd adds its
# "Favorites only" toggle, AdditionalSearchOptions adds two search rows). When
# they do it after we relocated the library, or when they compute their
# insertion index from a node that no longer lives in the tool panel, the
# control is left behind on the left. We pull those strays over.
func _adopt_orphans() -> void:
	for m in _moved:
		if m["shared_parent"]:
			# Two libraries share this parent (FloorShapeTool): we cannot tell
			# which one a stray control belongs to, so leave it alone.
			continue
		var parent = m["parent"]
		var box = m["box"]
		var grid = m["node"]
		if parent == null or not is_instance_valid(parent):
			continue
		if not is_instance_valid(box) or not is_instance_valid(grid):
			continue
		for child in parent.get_children():
			if child == m["label"] or not (child is Control):
				continue
			if _keeps_left(child):
				continue
			if not _is_library_companion(child):
				continue
			parent.remove_child(child)
			box.add_child(child)
			if str(child.name) == "FavsOverlay":
				# The overlay replaces the grid visually: keep it right after it.
				box.move_child(child, min(grid.get_index() + 1, box.get_child_count() - 1))
			else:
				box.move_child(child, max(grid.get_index(), 0))
			print("[LibraryRightPanel] adopted '", child.name, "' into ", m["id"])


# ── native library panels (Object / Path) ───────────────────────────────────
# DD builds their search area as a single row: Label("Search"), the LineEdit,
# and a clear button. AdditionalSearchOptions inserts its own buttons into that
# same row, and the field collapses to a few pixels. We split the row in two,
# matching the layout ASO uses in the tool panels: label and buttons on top,
# the field and its clear button on their own line underneath.
func _try_split_search_row(key: String) -> void:
	if _search_split.has(key):
		return
	var panel = _g.Editor.get(key)
	if panel == null or not is_instance_valid(panel):
		return

	var le = _find_line_edit(panel, 0)
	if le == null:
		return
	var hbox = le.get_parent()
	if hbox == null or not (hbox is HBoxContainer):
		return
	var host = hbox.get_parent()
	if host == null or not is_instance_valid(host):
		return

	# Vanilla is Label + LineEdit + clear button; leave that alone, it already
	# looks right. Only a row someone else crowded needs splitting.
	if hbox.get_child_count() <= 3:
		return

	# DD wires the clear button to _on_ClearButton_pressed, so Godot's editor
	# named the node ClearButton. Check both, in that order.
	var clear_btn = null
	for c in hbox.get_children():
		if c == le or not (c is Button):
			continue
		if str(c.name) == "ClearButton" or c.is_connected("pressed", panel, "_on_ClearButton_pressed"):
			clear_btn = c
			break

	var moved := []
	var indices := []
	moved.append(le)
	indices.append(le.get_index())
	if clear_btn != null:
		moved.append(clear_btn)
		indices.append(clear_btn.get_index())

	var row = HBoxContainer.new()
	row.name = "UP_SearchFieldRow"
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(row)
	host.move_child(row, hbox.get_index() + 1)

	var le_flags = le.size_flags_horizontal
	for n in moved:
		hbox.remove_child(n)
		row.add_child(n)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_search_split[key] = {
		"hbox":      hbox,
		"row":       row,
		"nodes":     moved,
		"indices":   indices,
		"line_edit": le,
		"le_flags":  le_flags,
	}
	print("[LibraryRightPanel] search row split in ", key)


func _restore_search_rows() -> void:
	for key in _search_split.keys():
		var r = _search_split[key]
		var hbox = r["hbox"]
		if hbox != null and is_instance_valid(hbox):
			# Ascending original index, as in _restore_entry().
			for i in range(r["nodes"].size()):
				var n = r["nodes"][i]
				if not is_instance_valid(n):
					continue
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				hbox.add_child(n)
				hbox.move_child(n, min(r["indices"][i], hbox.get_child_count() - 1))
		var le = r["line_edit"]
		if le != null and is_instance_valid(le):
			le.size_flags_horizontal = r["le_flags"]
		if is_instance_valid(r["row"]):
			r["row"].queue_free()
	_search_split.clear()


# First LineEdit under this node. SpinBox owns an internal LineEdit, so those
# branches are skipped.
func _find_line_edit(node, depth: int):
	if depth > 6:
		return null
	for c in node.get_children():
		if not (c is Control) or c is SpinBox:
			continue
		if c is LineEdit:
			return c
		var found = _find_line_edit(c, depth + 1)
		if found != null:
			return found
	return null


func _is_library_companion(node) -> bool:
	# favorites.gd toggle.
	if node is CheckButton and str(node.name).ends_with("FavsButton"):
		return true
	# favorites.gd Favorites/Hidden overlay list — created before the library
	# moved (boot with >=1 hidden asset) it would otherwise stay on the left.
	if node is ItemList and str(node.name) == "FavsOverlay":
		return true
	# favorites.gd mode-cycle control (button + count label).
	if node is VBoxContainer and str(node.name).begins_with("AssetFilterBox_"):
		return true
	if node is HBoxContainer:
		# AdditionalSearchOptions search row: the LineEdit is a direct child.
		# Direct children only -- a SpinBox owns an internal LineEdit, and a
		# recursive test would swallow DD's slider rows.
		for c in node.get_children():
			if c is LineEdit:
				return true
		# AdditionalSearchOptions button row, sitting just above the search row.
		if node.get_child_count() > 0:
			var first = node.get_child(0)
			if first is Label and str(first.text) == "Search":
				return true
	return false


# ── resize handle ────────────────────────────────────────────────────────────

func _on_grabber_input(event: InputEvent) -> void:
	if _panel == null or not is_instance_valid(_panel):
		return

	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT and not event.pressed:
			_save_width()
		return

	if not (event is InputEventMouseMotion):
		return
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return

	var min_x = MIN_WIDTH * _dpi
	var local = _panel.get_local_mouse_position()
	# Only allow growing while the map viewport still has room left.
	var content = _g.Editor.get("content")
	var room = true
	if content != null and is_instance_valid(content):
		room = content.rect_size.x > 60 or local.x > 0.0
	if not room:
		return
	_width = max(_panel.rect_min_size.x - local.x, min_x)
	_panel.rect_min_size = Vector2(_width, 0)


# ── persistence ──────────────────────────────────────────────────────────────

func _load_width() -> void:
	var f = File.new()
	if not f.file_exists(STATE_FILE):
		return
	if f.open(STATE_FILE, File.READ) != OK:
		return
	var txt = f.get_as_text()
	f.close()
	var res = JSON.parse(txt)
	if res.error != OK or not (res.result is Dictionary):
		return
	var w = res.result.get("width", DEFAULT_WIDTH)
	if typeof(w) == TYPE_REAL or typeof(w) == TYPE_INT:
		_width = max(float(w), MIN_WIDTH)


func _save_width() -> void:
	if _panel != null and is_instance_valid(_panel):
		_width = _panel.rect_min_size.x
	if _last_state.get("width", -1.0) == _width:
		return
	_last_state["width"] = _width
	var d = Directory.new()
	if not d.dir_exists(STATE_DIR):
		d.make_dir_recursive(STATE_DIR)
	var f = File.new()
	if f.open(STATE_FILE, File.WRITE) != OK:
		return
	f.store_string(JSON.print({"width": _width}))
	f.close()
