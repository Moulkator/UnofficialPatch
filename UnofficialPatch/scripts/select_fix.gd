# select_fix.gd
# Reset SelectTool UI when selection becomes empty (e.g. after delete)
# Also resets UI when entering SelectTool with no active selection.
# Also prunes from the selection anything that is hidden (invisible in the
# scene tree, e.g. layers hidden by third-party mods like Hide Layers) or
# rejected by SelectTool.IsObjectLayerFiltered(). DD's click pick can still
# grab such things (vanilla gap for walls/paths/patterns/portals, and hidden
# nodes are never excluded from hit tests), showing a transform box around
# an invisible asset that can then be moved blindly.
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
	if _active_tool_name() == "SelectTool" and not _select_panel.visible:
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
	# Garde : retirer de la selection les elements caches ou filtres par
	# calque AVANT d'evaluer l'etat de la selection, pour que _reset_ui
	# parte la meme frame si la selection se vide.
	raw = _prune_hidden_or_filtered(raw)
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


# Retire de la selection tout element invisible dans l'arbre (couvre les
# containers Walls/Portals/Roofs caches et les nodes caches un a un) ou
# rejete par IsObjectLayerFiltered (methode C# publique : c'est le filtre
# de calques que le pick au clic de DD n'applique pas de facon fiable).
# Renvoie le RawSelectables a jour si on a purge, sinon le raw d'entree.
func _prune_hidden_or_filtered(raw):
	if raw == null or raw.size() == 0:
		return raw
	# Suspension cross-mod : clipboard_fix (paste) cache VOLONTAIREMENT des
	# things selectionnes le temps de les deplacer vers la cible, et
	# rafraichit ce meta chaque frame tant que la fenetre est ouverte. On ne
	# purge pas pendant cette fenetre (grace de 2 frames apres le dernier
	# rafraichissement, puis auto-expiration en cas d'abandon).
	if Engine.has_meta("up_selection_prune_hold_frame"):
		var _hold = int(Engine.get_meta("up_selection_prune_hold_frame"))
		if Engine.get_idle_frames() - _hold <= 2:
			return raw
	# Ne jamais intervenir pendant une drag box, un drag ou une transform :
	# on ne purge qu'a l'etat repos, juste apres le pick fautif. Certains
	# mods peuvent aussi masquer temporairement des nodes en cours
	# d'operation ; ces gardes evitent de casser leur selection.
	if bool(select_tool.get("isDrawing")):
		return raw
	var tm = select_tool.get("transformMode")
	if tm != null and int(tm) != 0:
		return raw
	var ma = select_tool.get("manualAction")
	if ma != null and int(ma) != 0:
		return raw
	var to_remove = []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing) or not thing.is_inside_tree():
			continue
		var hidden = (thing is CanvasItem) and not thing.is_visible_in_tree()
		var filtered = false
		if not hidden and select_tool.has_method("IsObjectLayerFiltered"):
			filtered = select_tool.IsObjectLayerFiltered(thing)
		if hidden or filtered:
			to_remove.append(thing)
	if to_remove.empty():
		return raw
	if to_remove.size() >= raw.size():
		# Tout est a purger : DeselectAll retire aussi les widgets, puis on
		# ferme la transform box. _reset_ui suivra via has_selection=false.
		if select_tool.has_method("DeselectAll"):
			select_tool.call("DeselectAll")
		if select_tool.has_method("EnableTransformBox"):
			select_tool.call("EnableTransformBox", false)
	else:
		for thing in to_remove:
			if select_tool.has_method("SelectThing"):
				select_tool.SelectThing(thing, false)
		# Recalculer la box autour de ce qui reste.
		if select_tool.has_method("EnableTransformBox"):
			select_tool.call("EnableTransformBox", true)
	return select_tool.RawSelectables


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


# ── Per-frame cached editor state (published by Main.gd, Engine metadata) ──
# Reading native/C# editor properties marshals a fresh GDScript object across
# the interop boundary on EVERY access; with dozens of submods polling every
# frame this is a steady allocation stream (background commit-charge growth).
# Main.gd reads ActiveToolName once per frame and publishes it; we read the
# shared copy here. THREE rules, each learned from a measured failure:
#   1. PRECONDITION: never serve a cached name when this mod's _g.Editor is
#      unreachable — callers would reach into editor objects that are unsafe
#      to touch (native access violation c0000005 on tool switch / map churn).
#   2. MEMOIZATION: the _g.Editor null-check itself marshals a wrapper per
#      access; doing it per call cost as much as the problem this cache
#      solves (+0.037 MB/s, +12% main CPU over 600 s). One read per mod per
#      process tick keeps the safety signal at ~1/10th the volume.
#   3. FORCED COPY: never hand out a COW reference to the String stored in
#      the shared Dictionary — hence "%s" % v.
var _uu_ed_frame := -1
var _uu_ed_ok := false


func _active_tool_name() -> String:
	if not _uu_editor_reachable():
		return ""
	if Engine.has_meta("_uu_editor_state"):
		var s = Engine.get_meta("_uu_editor_state")
		if s is Dictionary:
			var v = s.get("active_tool_name")
			if v is String:
				return "%s" % v
	return str(_g.Editor.ActiveToolName)


func _uu_editor_reachable() -> bool:
	var f = Engine.get_idle_frames()
	if f == _uu_ed_frame:
		return _uu_ed_ok
	_uu_ed_frame = f
	_uu_ed_ok = _g != null and _g.Editor != null
	return _uu_ed_ok
