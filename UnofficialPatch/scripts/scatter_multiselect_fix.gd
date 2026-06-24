# scatter_multiselect_fix.gd
#
# Fixes the O(N^2) freeze when Shift-selecting a large range of assets in the
# Object library (shared by the Object Tool and Scatter Tool), while keeping the
# selected texture pool 100% correct.
#
# The original freeze:
#   Godot's ItemList emits "multi_selected" once PER ITEM of a Shift-range.
#   GridMenu.OnMultiSelected rebuilt the whole selected list on EVERY emission,
#   so a range of N items cost O(N^2). We disconnect the vanilla self-connection
#   and collapse the burst into ONE end-of-frame call -> O(N).
#
# Why no deferred / progressive trick here:
#   ScatterTool's pool must be resolved through the vanilla path
#   (GridMenu.OnMultiSelected -> OnTexturesSelected -> ScatterTool.Textures),
#   which uses Master.Library.Seek and is the only correct resolver for all asset
#   sources (default + custom packs) and all views (All/Used/Tags/Search).
#   Spreading that resolution over several frames is what caused the "only the
#   first asset shows up on large selections" bug: the pool stayed on its previous
#   value until the spread finished, so anything placed meanwhile used the stale
#   (single) texture. So we assign immediately and correctly.
#
#   The residual cost is the genuine, unavoidable decode of N full-resolution
#   textures: it is O(N), happens once (Godot caches them -> repeat selections are
#   fast), and is the real price of handing ScatterTool a large pool. The previous
#   "smoothness" was an illusion created by deferring (or, in one version, not
#   actually doing) that work.
#
# Notes:
#   - Single-select (Object Tool) uses "item_selected" -> untouched.
#   - The call is deferred by one frame only (call_deferred) to collapse the burst;
#     that is imperceptible and the pool is correct from that same frame.

var _g

var _menu = null
var _wired := false
var _pending := false


func initialize():
	print("[ScatterMultiselectFix] Initialized.")


func update(_delta):
	if _wired and _menu != null and is_instance_valid(_menu):
		if not _menu.is_connected("multi_selected", self, "_on_multi_selected"):
			_wired = false
	if not _wired:
		_try_wire()


# --- wiring ------------------------------------------------------------------

func _try_wire():
	if _g == null or _g.Editor == null or not is_instance_valid(_g.Editor):
		return
	var panel = _g.Editor.get("ObjectLibraryPanel")
	if panel == null or not is_instance_valid(panel):
		return
	var menu = _find_object_menu(panel)
	if menu == null:
		return

	# Drop the vanilla self-connection so OnMultiSelected no longer runs on every
	# single emission of a Shift-range burst.
	if menu.is_connected("multi_selected", menu, "OnMultiSelected"):
		menu.disconnect("multi_selected", menu, "OnMultiSelected")

	if not menu.is_connected("multi_selected", self, "_on_multi_selected"):
		menu.connect("multi_selected", self, "_on_multi_selected")

	_menu = menu
	_wired = true
	print("[ScatterMultiselectFix] Hooked ObjectsMenu multi-select (debounced).")


# --- debounce ----------------------------------------------------------------

func _on_multi_selected(_index, _selected):
	# Collapse every emission fired in this frame into a single deferred flush.
	if _pending:
		return
	_pending = true
	call_deferred("_flush_multiselect")


func _flush_multiselect():
	_pending = false
	if _menu == null or not is_instance_valid(_menu):
		return
	if _menu.has_method("OnMultiSelected"):
		# Args are ignored (the method rebuilds from GetSelectedItems()).
		# ONE authoritative call -> OnTexturesSelected -> ScatterTool.Textures,
		# with the full, correctly Seek-resolved pool. O(N) instead of O(N^2).
		_menu.OnMultiSelected(0, true)


# --- node lookup helpers -----------------------------------------------------

func _find_object_menu(panel):
	var by_name = _find_node_by_name(panel, "ObjectsMenu")
	if by_name != null:
		return by_name
	return _find_item_list(panel)


func _find_node_by_name(node, target):
	if node == null or not is_instance_valid(node):
		return null
	if node.name == target:
		return node
	for c in node.get_children():
		var r = _find_node_by_name(c, target)
		if r != null:
			return r
	return null


func _find_item_list(node):
	if node == null or not is_instance_valid(node):
		return null
	if node is ItemList:
		return node
	for c in node.get_children():
		var r = _find_item_list(c)
		if r != null:
			return r
	return null
