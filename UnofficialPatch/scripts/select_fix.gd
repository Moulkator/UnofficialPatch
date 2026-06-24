# select_fix.gd
# Reset SelectTool UI when selection becomes empty (e.g. after delete)
# Also resets UI when entering SelectTool with no active selection.
# Also detects and recovers from a vanilla DD bug where the SelectTool
# panel gets stuck with visible=false after an undo destroys a selected
# asset (an ObjectDisposedException in SelectToolPanel.UpdateButtons
# interrupts SelectTool.Enable() before it sets the panel visible).

var _g

var select_tool = null
var _select_panel = null
var _had_selection = false
var _context_containers = []
var _align = null
var _was_in_select_tool = false


func initialize():
	select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	print("[SelectFix] initialized")


func update(delta):
	if _select_panel == null:
		return
	
	# Detect DD's panel-stuck-hidden bug. While SelectTool is the
	# active tool, the panel must be visible. If DD's Enable() crashed
	# before setting it, force it on and run a UI reset so any stale
	# context containers from the destroyed selection get cleared too.
	var editor = _g.Editor
	if editor.ActiveToolName == "SelectTool" and not _select_panel.visible:
		_select_panel.visible = true
		_reset_ui()
		_had_selection = false
		_was_in_select_tool = true
		return
	
	var in_select_tool = _select_panel.visible
	if not in_select_tool:
		_had_selection = false
		_was_in_select_tool = false
		return
	
	if _align == null:
		_find_containers()
	
	# NOTE: select_tool.Selectables (C# property) calls ToDictionary() internally,
	# which throws when a drag box causes duplicate keys (e.g. prefabs).
	# RawSelectables is the safe equivalent for a simple empty-check.
	var raw = select_tool.RawSelectables
	var has_selection = false
	if raw != null and raw.size() > 0:
		# After a destructive undo (asset deleted), RawSelectables can
		# still contain the entry for the now-disposed Prop. Without
		# this scan we'd consider the selection still alive and skip
		# _reset_ui, leaving the contextual menu painted around an
		# invisible asset until the user clicks elsewhere.
		for s in raw:
			if s == null:
				continue
			if not is_instance_valid(s):
				continue
			var thing = s.get("Thing")
			if thing == null or not is_instance_valid(thing):
				continue
			if not thing.is_inside_tree() or thing.get_parent() == null:
				continue
			has_selection = true
			break
	
	# Reset UI when: selection was cleared (delete), OR just entered SelectTool with no selection
	var just_entered = not _was_in_select_tool
	if (_had_selection and not has_selection) or (just_entered and not has_selection):
		_reset_ui()
	
	_had_selection = has_selection
	_was_in_select_tool = true


func _reset_ui():
	# Call DeselectAllEx
	if select_tool.has_method("DeselectAllEx"):
		select_tool.DeselectAllEx()
	# Hide left panel contextual containers
	for c in _context_containers:
		if c.visible:
			c.visible = false
	# Hide right panels
	var editor = _g.Editor
	var path_panel = editor.get("PathLibraryPanel")
	if path_panel != null and path_panel.visible:
		path_panel.visible = false
	var obj_panel = editor.get("ObjectLibraryPanel")
	if obj_panel != null and obj_panel.visible:
		obj_panel.visible = false


func _find_containers():
	for child in _select_panel.get_children():
		if child is VBoxContainer and child.name == "Align":
			_align = child
			break
	if _align == null:
		return
	var found_first_sep = false
	for child in _align.get_children():
		if child is HSeparator:
			found_first_sep = true
		elif child is VBoxContainer and found_first_sep:
			_context_containers.append(child)
