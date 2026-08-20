# prefab_context.gd
# Right-click context menu provider: "Make Prefab" and "Separate Prefab" for
# SelectTool selections.
#
# Both actions exist in DD, but only as buttons in the SelectTool panel, and the
# Make Prefab one is gated on HasCopyable (= the transform box being visible),
# which a walls-only selection never satisfies. Going through the context menu
# calls SelectTool.MakePrefab() / Separate() directly, so the entry is available
# whenever the selection actually supports it.
#
# Icons are borrowed from DD's own buttons when they can be found, so the menu
# matches the panel.

var _g

# Groupes custom de group_assets.gd : prefab_id ENTIER >= 10000 + groupe Godot
# nomme str(gid). Ils reutilisent le mecanisme prefab de DD mais n'en sont pas.
const CUSTOM_GROUP_MIN_ID = 10000

var _icon_make = null
var _icon_separate = null
var _icons_resolved := false


func initialize() -> void:
	print("[PrefabContext] Initialized")


# ===== Provider interface (right_click_util) =====

func get_context_items(raw) -> Array:
	var items = []
	if raw == null or raw.size() == 0:
		return items
	var select_tool = _get_select_tool()
	if select_tool == null:
		return items
	_resolve_icons()
	# Make and Separate are mutually exclusive: once the selection holds a
	# prefab, re-prefabbing it would nest a group inside another and DD has no
	# UI to untangle that, so only Separate is offered.
	if _selection_has_prefab(raw):
		items.append({label = "Separate Prefab", icon = _icon_separate, action_id = "separate_prefab"})
	elif _count_selectables(raw) > 1:
		# A prefab of a single asset is just that asset: nothing to group.
		items.append({label = "Make Prefab", icon = _icon_make, action_id = "make_prefab"})
	return items


func on_context_action(action_id: String, raw) -> void:
	var select_tool = _get_select_tool()
	if select_tool == null:
		return
	if action_id == "make_prefab":
		if select_tool.has_method("MakePrefab"):
			select_tool.MakePrefab()
	elif action_id == "separate_prefab":
		if not select_tool.has_method("Separate"):
			return
		select_tool.Separate()
		# Separate() only mutates the nodes; the panel buttons refresh on the
		# next selection change, so nudge the selection to update them now.
		if select_tool.has_method("OnFinishSelection"):
			select_tool.OnFinishSelection()


# ===== Helpers =====

# Mirrors DD's SelectTool.HasPrefab (any group membership), with the prefab_id
# meta as the primary test so unrelated groups added by other mods don't offer
# a Separate that would do nothing useful. Les groupes custom de
# group_assets.gd (prefab_id int >= 10000, groupe Godot numerique) ne sont PAS
# des prefabs : ils sont exclus des deux tests.
func _selection_has_prefab(raw) -> bool:
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if thing.has_meta("prefab_id"):
			var v = thing.get_meta("prefab_id")
			if not _is_custom_group_id(v):
				return true
		var groups = thing.get_groups()
		if groups != null:
			for gname in groups:
				if not _is_custom_group_name(str(gname)):
					return true
	return false


func _is_custom_group_id(v) -> bool:
	return (v is int) and int(v) >= CUSTOM_GROUP_MIN_ID


func _is_custom_group_name(gname: String) -> bool:
	return gname.is_valid_integer() and int(gname) >= CUSTOM_GROUP_MIN_ID


func _count_selectables(raw) -> int:
	var seen := []
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing):
			continue
		if not (thing in seen):
			seen.append(thing)
	return seen.size()


func _resolve_icons() -> void:
	if _icons_resolved:
		return
	_icons_resolved = true
	if _g == null or _g.Editor == null or _g.Editor.get("Toolset") == null:
		return
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel):
		return
	var make_button = _find_button_matching(panel, "prefab", true, 0)
	if make_button != null:
		_icon_make = make_button.icon
	var separate_button = _find_button_matching(panel, "separate", false, 0)
	if separate_button != null:
		_icon_separate = separate_button.icon


# `exclude_separate` keeps the "prefab" search from landing on the Separate
# button, whose tooltip mentions prefabs too.
func _find_button_matching(node: Node, needle: String, exclude_separate: bool, depth: int):
	if node == null or depth > 8:
		return null
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is BaseButton:
			var haystack = ("%s %s %s" % [child.name, child.get("text"), child.hint_tooltip]).to_lower()
			if needle in haystack and not (exclude_separate and "separate" in haystack):
				return child
		var found = _find_button_matching(child, needle, exclude_separate, depth + 1)
		if found != null:
			return found
	return null


func _get_select_tool():
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return null
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary):
		return null
	return tools.get("SelectTool")
