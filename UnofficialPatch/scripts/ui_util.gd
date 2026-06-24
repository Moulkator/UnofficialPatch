# ui_util.gd
# Shared utility for detecting if mouse is over UI panels/popups
# Detects panels dynamically by finding controls anchored to screen edges

var _g
var _left_edge := 0.0
var _right_edge := 99999.0
var _edge_cache_frame := -1

# Per-frame cache for _has_visible_popup. Without this, every caller of
# is_mouse_over_ui (text_transform, text_tool_fix, etc) triggers a recursive
# tree walk each frame — measurable in SelectTool when multiple mods poll.
var _popup_cache_frame := -1
var _popup_cache_value := false

# Cache for find_aso_terrain_window. The full scene-tree scan it performs is
# O(scene nodes) and was being run multiple times per frame by asset_cycle's
# terrain sync (update() → _do_terrain_sync → _is_terrain_window_visible).
# On a loaded map that scan is the dominant cause of the Terrain-tool framerate
# drop. We keep the found window instance and validate it with cheap checks (no
# tree walk); when no ASO window exists we only re-run the full scan every
# _ASO_RESCAN_FRAMES frames instead of every frame.
var _aso_win_cache = null
var _aso_scan_frame := -100000
const _ASO_RESCAN_FRAMES := 60

func _cached_has_visible_popup(tree: SceneTree) -> bool:
	var frame = Engine.get_frames_drawn()
	if frame - _popup_cache_frame < 3:
		return _popup_cache_value
	_popup_cache_frame = frame
	_popup_cache_value = _has_visible_popup(tree.root)
	return _popup_cache_value

func is_mouse_over_ui(listener_node: Node) -> bool:
	# Profiler hook: when Main's F10 profiler is active, accumulate this
	# (per-frame-cached) UI walk so we can see its true cost separately —
	# it's shared across ~20 callers and otherwise charged to whichever mod
	# calls it first in the frame.
	if _g == null or not (_g.ModMapData is Dictionary) or not _g.ModMapData.get("_prof_dsw_on", false):
		return _is_mouse_over_ui_impl(listener_node)
	var _t0 := OS.get_ticks_usec()
	var _r := _is_mouse_over_ui_impl(listener_node)
	_g.ModMapData["_prof_umou_usec"] = _g.ModMapData.get("_prof_umou_usec", 0) + (OS.get_ticks_usec() - _t0)
	return _r


func _is_mouse_over_ui_impl(listener_node: Node) -> bool:
	var tree = listener_node.get_tree()
	if tree and _cached_has_visible_popup(tree):
		return true

	var vp = listener_node.get_viewport()
	if vp == null:
		return true
	var mouse = vp.get_mouse_position()
	var vp_size = vp.size

	# Toolbar
	if mouse.y < 50:
		return true

	# Dynamic left/right panel edges
	_update_panel_edges(tree, vp_size)
	if mouse.x < _left_edge or mouse.x > _right_edge:
		return true

	# Extra UI rects registered by floating mod panels (e.g. SelectFilterBar),
	# which the edge/toolbar checks above don't cover.
	if _g != null:
		var mmd = _g.get("ModMapData")
		if mmd is Dictionary and mmd.has("_extra_ui_rects"):
			var rects = mmd["_extra_ui_rects"]
			if rects is Dictionary:
				for r in rects.values():
					if r is Rect2 and r.has_point(mouse):
						return true

	return false


# Check if mouse is directly over a popup/window dialog
func is_mouse_over_popup(listener_node: Node) -> bool:
	return get_popup_under_mouse(listener_node) != null


# Get the popup/window dialog under the mouse (if any)
func get_popup_under_mouse(listener_node: Node):
	var vp = listener_node.get_viewport()
	if vp == null:
		return null
	var mouse = vp.get_mouse_position()
	var tree = listener_node.get_tree()
	if tree == null:
		return null
	return _find_popup_at(tree.root, mouse)


# Scroll the popup under the mouse (returns true if scrolled)
func scroll_popup_under_mouse(listener_node: Node, up: bool) -> bool:
	var vp = listener_node.get_viewport()
	if vp == null:
		return false
	var mouse = vp.get_mouse_position()
	
	# First find the popup under the mouse
	var tree = listener_node.get_tree()
	if tree == null:
		return false
	
	var popup = _find_popup_at(tree.root, mouse)
	if popup == null:
		return false
	
	# Now find ScrollContainer within this popup
	var scroll = _find_scroll_in_node(popup, mouse)
	if scroll == null:
		return false
	
	# Use the scrollbar for more reliable scrolling
	var vbar = scroll.get_v_scrollbar()
	if vbar != null:
		var step = 50.0
		if up:
			vbar.value -= step
		else:
			vbar.value += step
	else:
		# Fallback to direct property
		var amount = 50 if up else -50
		scroll.scroll_vertical -= amount
	
	return true


func _find_popup_at(node: Node, mouse: Vector2):
	if not is_instance_valid(node):
		return null
	
	# Check if this node is a visible popup under the mouse
	if (node is WindowDialog or node is Popup):
		if node.visible and node.is_visible_in_tree():
			var rect = node.get_global_rect()
			if rect.has_point(mouse):
				return node
	
	# Check children
	for child in node.get_children():
		var found = _find_popup_at(child, mouse)
		if found != null:
			return found
	
	return null


func _find_scroll_in_node(node: Node, mouse: Vector2) -> ScrollContainer:
	# Find ScrollContainer under mouse within this node's subtree
	if not is_instance_valid(node):
		return null
	if node is CanvasItem and not node.is_visible_in_tree():
		return null
	
	var result: ScrollContainer = null
	
	# If this node is a ScrollContainer under the mouse, it's a candidate
	if node is ScrollContainer:
		var rect = node.get_global_rect()
		if rect.has_point(mouse):
			result = node
	
	# Check children for a more specific (deeper) ScrollContainer
	for child in node.get_children():
		var found = _find_scroll_in_node(child, mouse)
		if found != null:
			result = found  # Deeper one wins
	
	return result


func _update_panel_edges(tree: SceneTree, vp_size: Vector2) -> void:
	var frame = Engine.get_frames_drawn()
	if frame - _edge_cache_frame < 12:
		return
	_edge_cache_frame = frame

	_left_edge = 0.0
	_right_edge = vp_size.x

	_scan_edge_panels(tree.root, vp_size, 0)


func _scan_edge_panels(node: Node, vp_size: Vector2, depth: int) -> void:
	if depth > 5:
		return
	for child in node.get_children():
		if child is Control and child.visible:
			var rect = child.get_global_rect()
			# Real side panels: narrow (<25% viewport), tall (>50% viewport)
			# Must be Panel or PanelContainer (not generic containers)
			if (child is Panel or child is PanelContainer) and rect.size.y > vp_size.y * 0.8 and rect.size.x > 50 and rect.size.x < vp_size.x * 0.25:
				# Left panel: starts near x=0
				if rect.position.x < 5:
					var right = rect.position.x + rect.size.x
					if right > _left_edge:
						_left_edge = right
				# Right panel: ends near viewport right edge
				if rect.position.x + rect.size.x > vp_size.x - 5:
					if rect.position.x < _right_edge:
						_right_edge = rect.position.x
		_scan_edge_panels(child, vp_size, depth + 1)


func _has_visible_popup(node: Node, depth: int = 0) -> bool:
	if depth > 4:
		return false
	if node is Popup and node.visible:
		return true
	if node is WindowDialog and node.visible:
		return true
	for child in node.get_children():
		if _has_visible_popup(child, depth + 1):
			return true
	return false


# =============================================================================
# TerrainWindow detection (compatibility with Additional Search Options mod)
# =============================================================================
# The native DD TerrainWindow lives at editor.Windows["TerrainWindow"]. ASO
# instantiates a SECOND TerrainWindow from the same .tscn and attaches it as a
# sibling under the Editor/Windows container node, then hides the native one
# every time a terrain slot button is pressed. Both share the node name
# "TerrainWindow" and the same internal structure (PackList, TextureMenu), but
# ASO additionally wraps TextureMenu in a VBoxContainer alongside its own
# search HBox, and its window lacks DD C# methods like OnPackSelected and the
# `sets` dictionary.

# =============================================================================
# TerrainWindow detection (compatibility with Additional Search Options mod)
# =============================================================================
# The native DD TerrainWindow lives at editor.Windows["TerrainWindow"]. ASO
# instantiates a SECOND TerrainWindow from the same .tscn and attaches it as a
# SIBLING of the native one (same parent: the Editor/Windows container node),
# then hides the native one every time a terrain slot button is pressed. Both
# share the node name "TerrainWindow" and the same internal structure
# (PackList, TextureMenu), but ASO additionally wraps TextureMenu in a
# VBoxContainer alongside its own search HBox, and its window lacks DD C#
# methods like OnPackSelected and the `sets` dictionary.
#
# Detection strategy: only look at SIBLINGS of the native window. Avoids false
# positives from unrelated "TerrainWindow"-named nodes elsewhere in the tree
# (template scenes loaded into pack caches, hidden preview nodes, etc.).


# Returns the native DD TerrainWindow (read straight from the Windows dict).
# Matches the pre-patch behavior of callers that did this lookup inline.
func get_native_terrain_window(editor):
	if editor == null:
		return null
	var windows_dict = editor.get("Windows")
	if not (windows_dict is Dictionary):
		return null
	if not windows_dict.has("TerrainWindow"):
		return null
	var tw = windows_dict["TerrainWindow"]
	if tw == null or not is_instance_valid(tw):
		return null
	return tw


# Returns ASO's TerrainWindow clone if ASO is installed, else null.
#
# Detection by structural signature, scanning the entire scene tree — ASO does
# NOT place its window as a sibling of the native one. In practice ASO attaches
# its clone under Editor/VPartition (somewhere, unspecified), while DD's native
# lives under Editor/Windows. So any strategy that limits itself to a known
# parent will miss it.
#
# The discriminating signature we rely on:
#   - is a WindowDialog (filters out regular controls)
#   - has a PackList descendant (filters out other WindowDialogs like Export)
#   - has a TextureMenu descendant (same — drops Welcome, Help, etc.)
#   - has a LineEdit descendant (ASO's search bar — DD's native TerrainWindow
#     has zero LineEdit anywhere in its hierarchy)
#   - is NOT the instance referenced by editor.Windows["TerrainWindow"]
#
# Note: DD's NewTemplateWindow also has PackList+TextureMenu+LineEdit, so the
# "not native" check is what nails it down — ASO's clone is the *extra* window
# that has all three markers.
func find_aso_terrain_window(editor):
	if editor == null:
		return null

	# Fast path: a previously found ASO window, validated with cheap checks
	# only (instance validity + not the native window). No tree walk here, so
	# this is what keeps the Terrain tool from scanning the scene every frame.
	if _aso_win_cache != null and is_instance_valid(_aso_win_cache):
		var native_now = get_native_terrain_window(editor)
		if _aso_win_cache != native_now:
			return _aso_win_cache
		# Cached node has become the native window (rare) — drop and rescan.
		_aso_win_cache = null

	# Throttle the expensive full-tree scan. When no ASO window currently
	# exists we only rescan periodically instead of on every call/frame. ASO
	# injects its window once at load, so a coarse interval is more than enough
	# to pick it up.
	var frame = Engine.get_frames_drawn()
	if _aso_win_cache == null and frame - _aso_scan_frame < _ASO_RESCAN_FRAMES:
		return null
	_aso_scan_frame = frame

	var native = get_native_terrain_window(editor)
	# We still need a tree to scan. Use the native's tree if we have one,
	# otherwise try the editor's.
	var tree_root = null
	if native != null and native.is_inside_tree():
		tree_root = native.get_tree().root
	elif editor.has_method("is_inside_tree") and editor.is_inside_tree():
		tree_root = editor.get_tree().root
	if tree_root == null:
		return null

	var candidates = []
	_collect_aso_candidates(tree_root, native, candidates, 0)
	# Prefer an exact name match if multiple structurally-valid candidates
	# exist (minimises odds of picking a misidentified similar-shaped window).
	var found = null
	for c in candidates:
		if c.name == "TerrainWindow":
			found = c
			break
	if found == null and candidates.size() > 0:
		found = candidates[0]

	_aso_win_cache = found
	return found


func _collect_aso_candidates(node: Node, native, out: Array, depth: int) -> void:
	if depth > 20 or not is_instance_valid(node):
		return
	if node is WindowDialog and node != native:
		# Skip DD's own scripted windows — if it has a C# script, it's a
		# first-party DD window (Export, Preferences, ...), not ASO's clone.
		# ASO's window has no attached script on the root — it's a vanilla
		# scene instance with behavior wired in from TerrainWindowUI.gd.
		var s = node.get_script()
		var is_dd_scripted = false
		if s != null:
			var rp = s.resource_path
			if rp is String and rp.begins_with("res://"):
				is_dd_scripted = true
		if not is_dd_scripted \
				and _has_descendant_class(node, "LineEdit") \
				and _has_descendant_named(node, "PackList") \
				and _has_descendant_named(node, "TextureMenu"):
			out.append(node)
	for child in node.get_children():
		_collect_aso_candidates(child, native, out, depth + 1)


func _has_descendant_class(node: Node, cls: String) -> bool:
	if not is_instance_valid(node):
		return false
	if node.get_class() == cls:
		return true
	for c in node.get_children():
		if _has_descendant_class(c, cls):
			return true
	return false


func _has_descendant_named(node: Node, target: String) -> bool:
	if not is_instance_valid(node):
		return false
	if node.name == target:
		return true
	for c in node.get_children():
		if _has_descendant_named(c, target):
			return true
	return false


# Old helper, unused now but kept for API compat if anyone imports it.
func _has_lineedit_descendant(node: Node) -> bool:
	return _has_descendant_class(node, "LineEdit")


# The terrain window the user actually sees when clicking a terrain slot —
# ASO's custom window if ASO is installed, else the native one.
func get_active_terrain_window(editor):
	var aso = find_aso_terrain_window(editor)
	if aso != null:
		return aso
	return get_native_terrain_window(editor)


# True if `window` is ASO's clone (as opposed to DD's native instance).
func is_aso_terrain_window(editor, window) -> bool:
	if window == null:
		return false
	var aso = find_aso_terrain_window(editor)
	return aso != null and aso == window


# Shortcut: is ASO installed and has it injected its custom window?
func aso_terrain_window_present(editor) -> bool:
	return find_aso_terrain_window(editor) != null


# Back-compat shim for callers that used the earlier array-returning helper.
func find_terrain_windows(editor) -> Array:
	return [get_native_terrain_window(editor), find_aso_terrain_window(editor)]
