# asset_cycle.gd
# Shift+scroll to cycle assets in any tool
# - Over an ItemList: cycles that list
# - Over the map: cycles the active tool's primary asset list
# - Skips color palettes
# - In ScatterTool: passes through (DD's native cycling handles selection)
# - Handles OptionButton (fonts in TextTool)
# - Handles TerrainWindow (WindowDialog with TextureMenu ItemList)
# - Terrain: slot/settings sync + popup highlights current texture
# Auto-scrolls asset lists on tool switch or external selection change

var _g
var ui_util
var pattern_fix  # optional ref to pattern_fix — set by Main.gd
var input_listener: Node
var _list_selections = {}  # instance_id -> last known selected index
var _last_tool_name = ""
var _tool_lists = {}       # tool_name -> ItemList cache
var _visible_lists = {}    # instance_id -> true, tracks which lists were visible last frame
var _lists_needs_scroll = {} # instance_id -> true, lists that reappeared and need autoscroll
var _select_tool_map_click = 0  # countdown frames after user clicked on map in SelectTool

# Terrain references
var _terrain_window = null
var _terrain_texture_list = null
var _terrain_brush = null
var _terrain_was_visible = false
# True when _terrain_window points at ASO's custom TerrainWindow rather than
# DD's native one. Toggles the cycle/highlight/button-injection code paths.
var _terrain_is_aso = false
# True once we've disconnected ASO's item_selected handler on TextureMenu and
# installed our own preview-only handler (keeps popup open after a click).
# Reset to false whenever _terrain_window changes identity.
var _aso_click_hooked = false

# Position du popup capturée juste avant le clic sur une texture, pour la
# restaurer après que le handler natif de DD ait recentré la fenêtre.
# Null = aucun clic en cours / pas besoin de restaurer.
var _terrain_pos_before_click = null

# Tools that support on-map cycling
const MAP_CYCLE_TOOLS = [
	"PortalTool", "RoofTool", "WallTool", "FloorShapeTool",
	"PatternShapeTool", "ObjectTool", "LightTool", "PathTool",
	"TextTool", "TerrainBrush", "PrefabTool"
]

func initialize():
	_install_input_listener()

func _install_input_listener():
	input_listener = Node.new()
	input_listener.name = "AssetCycleListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _ready():
	set_process_input(true)
	process_priority = -90
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", input_listener)


var _dbg_last_tool = ""

func update(_delta):
	if not _g or not _g.Editor:
		return
	# Si Escape vient de fermer le popup, DD peut désélectionner le
	# TerrainBrush de façon différée — on surveille pendant plusieurs frames
	# et on restaure dès que ça arrive.
	if _terrain_escape_restore > 0:
		_terrain_escape_restore -= 1
		if _g.Editor.ActiveToolName != "TerrainBrush":
			if _g.Editor.Toolset and _g.Editor.Toolset.has_method("Quickswitch"):
				_g.Editor.Toolset.Quickswitch("TerrainBrush")
				_terrain_escape_restore = 0
	_do_autoscroll()
	_do_terrain_sync()
	_apply_prefab_transform()


# ==================== AUTOSCROLL ====================
# Scroll asset lists to show selected item when:
# 1) Tool switches (returning to a tool)
# 2) Selection changes externally (e.g. clicking object on map)
# Does NOT scroll when user clicks directly on the list

func _do_autoscroll():
	if not is_instance_valid(input_listener):
		return
	if not _g.Editor:
		return
	
	var tool_name = _g.Editor.ActiveToolName
	if not tool_name or tool_name == "" or tool_name == "Null" or tool_name == "ScatterTool":
		_last_tool_name = tool_name
		# All lists are gone — mark them so they get autoscrolled when they reappear
		for lid in _visible_lists.keys():
			_lists_needs_scroll[lid] = true
		_visible_lists.clear()
		return
	
	var tool_changed = (tool_name != _last_tool_name)
	_last_tool_name = tool_name
	
	var mouse_pos = input_listener.get_viewport().get_mouse_position()
	
	# Collect all lists to monitor for autoscroll
	var lists_to_check = _get_autoscroll_lists(tool_name)
	
	# Build set of currently visible list IDs
	var now_visible = {}
	for il in lists_to_check:
		now_visible[il.get_instance_id()] = true
	
	# Any list that was visible last frame but is gone now:
	# mark it for autoscroll when it reappears
	for lid in _visible_lists.keys():
		if not now_visible.has(lid):
			_lists_needs_scroll[lid] = true
	_visible_lists = now_visible
	
	# Consume the SelectTool map click counter
	var map_click = _select_tool_map_click > 0
	if _select_tool_map_click > 0:
		_select_tool_map_click -= 1
	
	for il in lists_to_check:
		_autoscroll_list(il, tool_changed, mouse_pos, map_click)


var _sel_lists_cache := []
var _sel_lists_frame := -100


func _get_autoscroll_lists(tool_name: String) -> Array:
	var result = []
	
	# For SelectTool: monitor ALL visible non-color ItemLists
	# (objects, paths, walls, lights, etc. panels can be visible)
	if tool_name == "SelectTool":
		# In SelectTool we monitor ALL visible ItemLists, which requires a
		# full scene-tree DFS. Doing that every frame is the single biggest
		# per-frame cost in this mod, so we throttle the scan and reuse a
		# validated cache in between (autoscroll responsiveness within
		# ~150ms is imperceptible).
		var frame = Engine.get_frames_drawn()
		if frame - _sel_lists_frame < 10:
			for il in _sel_lists_cache:
				if is_instance_valid(il) and il.is_visible_in_tree() \
						and not _is_color_list(il) and il.get_item_count() > 0:
					result.append(il)
			return result
		_sel_lists_frame = frame
		var root = input_listener.get_tree().root
		if root:
			var all = []
			_find_all_visible_item_lists(root, all)
			for il in all:
				if not _is_color_list(il) and il.get_item_count() > 0:
					result.append(il)
		_sel_lists_cache = result
		return result
	
	# For other tools: primary tool list
	var il = _get_tool_item_list(tool_name)
	if il != null and is_instance_valid(il) and il.is_visible_in_tree():
		result.append(il)
	
	return result


func _autoscroll_list(il: ItemList, tool_changed: bool, mouse_pos: Vector2, map_click: bool = false):
	if not is_instance_valid(il) or not il.is_visible_in_tree():
		return
	
	var selected = il.get_selected_items()
	var lid = il.get_instance_id()
	
	if selected.size() == 0:
		# No selection: clear tracking so next selection triggers scroll
		_list_selections.erase(lid)
		_lists_needs_scroll.erase(lid)
		return
	
	var current_sel = selected[0]
	
	var first_time = not _list_selections.has(lid)
	var reappeared = _lists_needs_scroll.has(lid)
	_lists_needs_scroll.erase(lid)
	
	var selection_changed = false
	if not first_time:
		if _list_selections[lid] != current_sel:
			selection_changed = true
	
	_list_selections[lid] = current_sel
	
	# Scroll if: tool changed, selection changed, first time, list reappeared,
	# or user clicked on map in SelectTool (may re-select same asset)
	if not tool_changed and not selection_changed and not first_time and not reappeared and not map_click:
		return
	
	# Don't scroll if mouse is over the list (user clicked directly on it)
	# But DO scroll on tool change, first appearance, reappearance, or map click
	if not tool_changed and not first_time and not reappeared and not map_click:
		var rect = il.get_global_rect()
		if rect.has_point(mouse_pos):
			return
	
	_scroll_to_item(il, current_sel)


# ==================== TERRAIN SYNC ====================
# 1) When terrain slot is selected, also select corresponding settings button
# 2) When terrain popup opens, highlight the texture of the active slot

func _init_terrain_brush():
	if _terrain_brush != null:
		return
	if not _g.Editor or not _g.Editor.Tools:
		return
	if not _g.Editor.Tools.has("TerrainBrush"):
		return
	_terrain_brush = _g.Editor.Tools["TerrainBrush"]


var _terrain_last_id = -1
var _terrain_buttons_connected = false
var _terrain_button_count = 0
var _terrain_deep_diag_done = false

func _do_terrain_sync():
	if not _g.Editor:
		return
	var atn = _g.Editor.ActiveToolName
	if not atn or atn != "TerrainBrush":
		# Close terrain popup when leaving terrain tool
		_terrain_keep_open = false
		if _terrain_was_visible and _terrain_window and is_instance_valid(_terrain_window) and _terrain_window.visible:
			_terrain_window.visible = false
		_terrain_was_visible = false
		_terrain_last_id = -1
		return
	
	_init_terrain_brush()
	if _terrain_brush == null:
		return
	
	# Connect/reconnect settings buttons (handles expanded slots)
	_ensure_terrain_buttons_connected()
	
	# Connect terrainList to detect slot selection changes
	if _terrain_brush.terrainList and is_instance_valid(_terrain_brush.terrainList):
		if not _terrain_brush.terrainList.is_connected("item_selected", self, "_on_terrain_slot_selected"):
			_terrain_brush.terrainList.connect("item_selected", self, "_on_terrain_slot_selected")
	
	# Connect PackList to detect pack tab changes (re-highlight on return)
	# Native DD only — ASO has its own _on_pack_list_item_selected handler that
	# fully manages TextureMenu repopulate; our additional connection there
	# just creates duplicate fires and potential clear/repopulate churn.
	if _terrain_window and is_instance_valid(_terrain_window) and not _terrain_is_aso:
		var pack_list = _find_node_by_name(_terrain_window, "PackList")
		if pack_list and is_instance_valid(pack_list) and pack_list is ItemList:
			if not pack_list.is_connected("item_selected", self, "_on_terrain_pack_selected"):
				pack_list.connect("item_selected", self, "_on_terrain_pack_selected")
	
	# Empêche le popup de se recentrer quand l'utilisateur clique sur une
	# texture après avoir déplacé la fenêtre.
	_ensure_terrain_pos_guard()
	
	var vis = _is_terrain_window_visible()
	var current_id = _terrain_brush.TerrainID
	
	# Keep popup open when clicking textures so preview flow works on both
	# native DD and both ASO versions. Exceptions where we let the popup
	# close naturally on click-commit:
	#  - Native DD with user's toggle OFF (legacy mode)
	#  - ASO new with its accept_required toggle OFF (ASO will clear
	#    TextureMenu + hide on click; we must not reopen it, else user
	#    sees an empty popup)
	var aso_has_native_buttons = _terrain_is_aso and _aso_has_accept_cancel()
	var keep_open_wanted = _compute_keep_open_wanted()
	if vis and keep_open_wanted:
		_terrain_keep_open = true
		if _terrain_window and not _terrain_window.is_connected("visibility_changed", self, "_on_terrain_vis_changed"):
			_terrain_window.connect("visibility_changed", self, "_on_terrain_vis_changed")
	elif vis:
		# Legacy mode (native toggle off, or ASO toggle off): let the click
		# handler close the window.
		_terrain_keep_open = false
	
	# When popup transitions false → true, de-modalize so clicks outside the
	# popup reach the slot / settings buttons. Also picks up initial show,
	# before _on_terrain_vis_changed has had a chance to fire.
	if vis and not _terrain_was_visible and _terrain_is_aso:
		if not _demodalizing:
			call_deferred("_demodalize_terrain_window", _terrain_window)
	
	# ASO (old version only): replace ASO's _on_terrain_item_selected handler
	# on TextureMenu with our preview handler. When ASO already ships Accept/
	# Cancel with its own accept_required toggle, it handles preview itself.
	if vis and _terrain_is_aso and not _aso_click_hooked and not aso_has_native_buttons:
		_hook_aso_texture_click()
	
	# ASO (new version): force its accept_required_button to on so preview is
	# the default flow, and style its buttons to match our look. Idempotent.
	if vis and _terrain_is_aso and aso_has_native_buttons:
		_aso_prep_native_buttons()
	
	# Trigger terrain popup update when:
	# 1) Popup genuinely opened (not re-opened by keep-open after texture click)
	# 2) TerrainID changed while popup is open
	var need_update = false
	if vis and not _terrain_was_visible and not _terrain_reopened_by_keepopen:
		need_update = true
	elif vis and current_id != _terrain_last_id:
		need_update = true
	_terrain_reopened_by_keepopen = false
	
	if need_update:
		# Save original texture for cancel functionality
		if not _terrain_was_visible and vis:
			# Popup just opened - save original state
			var terrain = null
			if _g.World and _g.World.Level:
				terrain = _g.World.Level.Terrain
			if terrain:
				_terrain_original_slot_id = current_id
				_terrain_original_texture = terrain.GetTexture(current_id)
		elif vis and current_id != _terrain_last_id:
			# Slot changed while popup open - save new slot's original state
			var terrain = null
			if _g.World and _g.World.Level:
				terrain = _g.World.Level.Terrain
			if terrain:
				_terrain_original_slot_id = current_id
				_terrain_original_texture = terrain.GetTexture(current_id)
		
		_on_terrain_popup_opened()
		var tw = _get_terrain_texture_list()
		if tw != null:
			_list_selections.erase(tw.get_instance_id())
	
	# Add Accept/Cancel buttons to popup
	if vis and not _terrain_buttons_added:
		_add_terrain_popup_buttons()
	
	_terrain_was_visible = vis
	_terrain_last_id = current_id


func _ensure_terrain_buttons_connected():
	if _terrain_brush == null:
		return
	var bbox = _terrain_brush.terrainButtonBox
	if bbox == null or not is_instance_valid(bbox):
		return
	
	var buttons = []
	_find_all_buttons(bbox, buttons)
	
	# Reconnect if button count changed (e.g. expanded slots)
	if buttons.size() != _terrain_button_count:
		_terrain_button_count = buttons.size()
		for i in range(buttons.size()):
			var btn = buttons[i]
			if btn.is_connected("pressed", self, "_on_terrain_settings_pressed"):
				continue
			btn.connect("pressed", self, "_on_terrain_settings_pressed", [i])


func _find_all_buttons(node, result):
	if node is Button:
		result.append(node)
	for child in node.get_children():
		if is_instance_valid(child):
			_find_all_buttons(child, result)


var _terrain_slot_switching = false


func _on_terrain_settings_pressed(slot_idx: int):
	if _terrain_brush == null or _terrain_slot_switching:
		return
	_terrain_brush.TerrainID = slot_idx
	var slot_list = _terrain_brush.terrainList
	if slot_list and is_instance_valid(slot_list) and slot_idx < slot_list.get_item_count():
		_terrain_slot_switching = true
		slot_list.select(slot_idx)
		slot_list.emit_signal("item_selected", slot_idx)
		_terrain_slot_switching = false


func _on_terrain_slot_selected(idx: int):
	if _terrain_brush == null or _terrain_slot_switching:
		return
	_terrain_brush.TerrainID = idx
	# On ASO, don't re-emit the slot button press. ASO has its own
	# `_on_terrain_selection_button_pressed` connected to every slot button;
	# it updates `target` directly and, if the native window was open, re-
	# opens ASO's window. Re-emitting from here triggers that same cascade a
	# second time, which silently re-pops the ASO window to the modal stack
	# — and more importantly, collides with ASO's own click-to-commit flow
	# (commit → SetTextureFromWindow → fires terrainList.item_selected →
	# re-enters this function → re-pops popup just before ASO's hide()).
	# Net effect: toggle-OFF-then-click-texture fails to close the popup.
	if _terrain_is_aso:
		return
	# If popup is open, simulate clicking the settings button for this slot
	# This makes DD re-bind the popup to the new slot
	if _is_terrain_window_visible():
		_terrain_slot_switching = true
		var bbox = _terrain_brush.terrainButtonBox
		if bbox:
			var buttons = []
			_find_all_buttons(bbox, buttons)
			if idx < buttons.size():
				buttons[idx].emit_signal("pressed")
		_terrain_slot_switching = false
		# Defer the popup update so DD finishes re-binding the slot first
		_terrain_last_id = -1
		call_deferred("_on_terrain_popup_opened")


func _on_terrain_pack_selected(_pack_idx: int):
	# When user switches pack tab, re-highlight if this pack contains current slot's texture
	if not _is_terrain_window_visible() or _terrain_brush == null:
		return
	# Defer to let DD finish loading the pack's textures into textureMenu
	# Don't force pack switch - only highlight if user navigated to the correct pack
	call_deferred("_on_terrain_popup_opened_no_switch")


func _on_terrain_popup_opened_no_switch():
	_on_terrain_popup_opened(false)


func _on_terrain_popup_opened(switch_pack: bool = true):
	if _terrain_brush == null:
		return
	
	var slot_id = _terrain_brush.TerrainID
	if slot_id < 0:
		return
	
	var terrain = null
	if _g.World and _g.World.Level:
		terrain = _g.World.Level.Terrain
	if terrain == null:
		return
	
	var slot_texture = terrain.GetTexture(slot_id)
	if slot_texture == null:
		return
	
	var tex_list = _get_terrain_texture_list()
	if tex_list == null:
		return
	
	var slot_path = slot_texture.resource_path
	var pack_list = _find_node_by_name(_terrain_window, "PackList")
	if pack_list == null or not (pack_list is ItemList):
		return
	
	# ==== ASO path ====
	# ASO's window has no `sets` dict and no OnPackSelected() method — those
	# are DD C# APIs on the native TerrainWindow class. But ASO populates
	# PackList metadata with pack IDs and TextureMenu metadata with full
	# resource paths, which makes the highlight logic one-shot cheap.
	if _terrain_is_aso:
		_highlight_on_aso_window(slot_path, slot_id, pack_list, tex_list, switch_pack)
		return
	
	# ==== Native DD path (unchanged logic) ====
	var sets = _terrain_window.get("sets")
	if sets == null or typeof(sets) != TYPE_DICTIONARY:
		return
	
	# Strategy: 
	# 1) Extract pack ID from slot texture path (res://packs/PACKID/textures/terrain/...)
	# 2) Find pack index in sets.keys()
	# 3) Switch to that pack tab
	# 4) Match the slot's icon (from terrainList) against textureMenu icons
	
	# Step 1: Determine which pack this texture belongs to
	var target_pack_key = ""
	if slot_path.begins_with("res://packs/"):
		# Extract pack ID: res://packs/PACKID/textures/...
		var after_packs = slot_path.substr(len("res://packs/"))
		var slash_pos = after_packs.find("/")
		if slash_pos > 0:
			target_pack_key = after_packs.substr(0, slash_pos)
	elif slot_path.begins_with("res://textures/"):
		target_pack_key = "Default"
	
	if target_pack_key == "" or not sets.has(target_pack_key):
		return
	
	# Step 2: Find pack index in sets.keys() (order matches PackList)
	var pack_keys = sets.keys()
	var target_pack_idx = -1
	for i in range(pack_keys.size()):
		if pack_keys[i] == target_pack_key:
			target_pack_idx = i
			break
	
	if target_pack_idx < 0 or target_pack_idx >= pack_list.get_item_count():
		return
	
	# Step 3: Switch to correct pack or check if current pack matches
	var current_pack = pack_list.get_selected_items()
	var current_pack_idx = current_pack[0] if current_pack.size() > 0 else -1
	
	if current_pack_idx != target_pack_idx:
		if switch_pack:
			pack_list.select(target_pack_idx)
			_terrain_window.OnPackSelected(target_pack_idx)
		else:
			# User is browsing a different pack - don't highlight anything
			return
	
	# Step 4: Find the texture index in the pack
	# Extract filename from slot_path to match against textureMenu item names
	# e.g. "res://packs/rXMyPdvK/textures/terrain/Tileset_BrickPaversGray_FNV.webp" -> "Tileset_BrickPaversGray_FNV"
	var slot_filename = slot_path.get_file().get_basename()
	
	var target_tex_index = -1
	
	# Method 1: Match filename against textureMenu tooltip/text
	# DD typically uses the texture name as tooltip
	for i in range(tex_list.get_item_count()):
		var item_text = tex_list.get_item_text(i)
		var item_tooltip = tex_list.get_item_tooltip(i)
		# Check if the filename matches (with or without underscores/spaces)
		var clean_filename = slot_filename.replace("_", " ")
		if item_text == slot_filename or item_text == clean_filename:
			target_tex_index = i
			break
		if item_tooltip == slot_filename or item_tooltip == clean_filename:
			target_tex_index = i
			break
	
	# Method 2: Match slot icon from terrainList against textureMenu icons by reference
	if target_tex_index < 0:
		var slot_list = _terrain_brush.terrainList
		var slot_icon = null
		if slot_list and is_instance_valid(slot_list) and slot_id < slot_list.get_item_count():
			slot_icon = slot_list.get_item_icon(slot_id)
		if slot_icon != null:
			for i in range(tex_list.get_item_count()):
				if tex_list.get_item_icon(i) == slot_icon:
					target_tex_index = i
					break
	
	# Method 3: Match slot icon against sets[pack_key] thumbnails
	if target_tex_index < 0:
		var slot_list = _terrain_brush.terrainList
		var slot_icon = null
		if slot_list and is_instance_valid(slot_list) and slot_id < slot_list.get_item_count():
			slot_icon = slot_list.get_item_icon(slot_id)
		if slot_icon != null:
			var pack_textures = sets[target_pack_key]
			if typeof(pack_textures) == TYPE_ARRAY:
				for i in range(pack_textures.size()):
					if pack_textures[i] == slot_icon:
						target_tex_index = i
						break
	
	# Method 4: Image data comparison as last resort
	if target_tex_index < 0:
		var slot_list = _terrain_brush.terrainList
		var slot_icon = null
		if slot_list and is_instance_valid(slot_list) and slot_id < slot_list.get_item_count():
			slot_icon = slot_list.get_item_icon(slot_id)
		if slot_icon != null:
			var slot_img = slot_icon.get_data()
			if slot_img:
				var slot_bytes = slot_img.get_data()
				var slot_size = slot_img.get_size()
				for i in range(tex_list.get_item_count()):
					var item_icon = tex_list.get_item_icon(i)
					if item_icon == null:
						continue
					var item_img = item_icon.get_data()
					if item_img == null:
						continue
					if item_img.get_size() == slot_size and item_img.get_data() == slot_bytes:
						target_tex_index = i
						break
	
	if target_tex_index >= 0 and target_tex_index < tex_list.get_item_count():
		tex_list.select(target_tex_index)
		_scroll_to_item(tex_list, target_tex_index)
		_list_selections[tex_list.get_instance_id()] = target_tex_index


# ASO-specific highlight: uses ASO's own metadata (pack_id on PackList items,
# resource path on TextureMenu items) rather than DD's C# `sets` / OnPackSelected.
func _highlight_on_aso_window(slot_path: String, slot_id: int, pack_list: ItemList, tex_list: ItemList, switch_pack: bool):
	# 1) Extract pack_id from the slot's resource path.
	var target_pack_id = ""
	if slot_path.begins_with("res://packs/"):
		var after_packs = slot_path.substr(len("res://packs/"))
		var slash_pos = after_packs.find("/")
		if slash_pos > 0:
			target_pack_id = after_packs.substr(0, slash_pos)
	elif slot_path.begins_with("res://textures/"):
		# TerrainWindowUI.find_texture_name_and_pack() tags native DD assets
		# with pack_id "nativeDD".
		target_pack_id = "nativeDD"
	
	if target_pack_id == "":
		return
	
	# 2) Find a matching pack in PackList by metadata.
	var target_pack_idx = -1
	for i in range(pack_list.get_item_count()):
		var meta = pack_list.get_item_metadata(i)
		if meta == target_pack_id:
			target_pack_idx = i
			break
	
	# Pack not listed (e.g. "Default" disabled). Try matching against "all"
	# which ASO always prepends at index 0.
	if target_pack_idx < 0:
		for i in range(pack_list.get_item_count()):
			if pack_list.get_item_metadata(i) == "all":
				target_pack_idx = i
				break
	
	if target_pack_idx < 0 or target_pack_idx >= pack_list.get_item_count():
		return
	
	# 3) Switch pack if needed. ASO repopulates TextureMenu via its
	# _on_pack_list_item_selected handler wired to item_selected, so emitting
	# the signal is enough — no equivalent of OnPackSelected needed.
	var current_pack = pack_list.get_selected_items()
	var current_pack_idx = current_pack[0] if current_pack.size() > 0 else -1
	if current_pack_idx != target_pack_idx:
		if switch_pack:
			pack_list.select(target_pack_idx)
			pack_list.emit_signal("item_selected", target_pack_idx)
		else:
			return
	
	# 4) Find the texture index by metadata — ASO stores the full resource
	# path on each TextureMenu item, so this is a cheap direct match.
	var target_tex_index = -1
	for i in range(tex_list.get_item_count()):
		if tex_list.get_item_metadata(i) == slot_path:
			target_tex_index = i
			break
	
	# Fallback: match on basename if metadata matching fails (e.g. path was
	# rewritten for the fav pack).
	if target_tex_index < 0:
		var slot_basename = slot_path.get_file().get_basename()
		for i in range(tex_list.get_item_count()):
			var m = tex_list.get_item_metadata(i)
			if m is String and m.get_file().get_basename() == slot_basename:
				target_tex_index = i
				break
	
	if target_tex_index >= 0 and target_tex_index < tex_list.get_item_count():
		tex_list.select(target_tex_index)
		_scroll_to_item(tex_list, target_tex_index)
		_list_selections[tex_list.get_instance_id()] = target_tex_index


# ==================== ASO CLICK-HANDLER HIJACK ====================
# ASO wires its TextureMenu.item_selected signal to its own
# _on_terrain_item_selected, which emits a commit, clears the TextureMenu and
# hides the popup. That kills any preview-then-Accept/Cancel flow. We take
# over that signal: emit SetTextureFromWindow for the preview (identical to
# what ASO's emitted signal does upstream in its parent script) but leave the
# list populated and the window open. This reuses the native-DD UX — click to
# preview, shift+scroll to cycle previews, Accept/Cancel/X to finish — inside
# ASO's popup (so the user still gets ASO's search bar).

func _hook_aso_texture_click() -> void:
	if _aso_click_hooked:
		return
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return
	if not _terrain_is_aso:
		return
	var texturemenu = _get_terrain_texture_list()
	if texturemenu == null or not is_instance_valid(texturemenu):
		return
	# Disconnect ASO's click handler. We match by method name rather than by
	# target identity (we don't have a reference to ASO's TerrainWindowUI
	# instance, and looking it up reliably is more trouble than matching
	# "_on_terrain_item_selected" which is ASO-specific).
	var connections = texturemenu.get_signal_connection_list("item_selected")
	var disconnected = 0
	for conn in connections:
		if conn.method == "_on_terrain_item_selected":
			texturemenu.disconnect("item_selected", conn.target, conn.method)
			disconnected += 1
	if not texturemenu.is_connected("item_selected", self, "_on_aso_texture_clicked"):
		texturemenu.connect("item_selected", self, "_on_aso_texture_clicked")
	_aso_click_hooked = true


func _on_aso_texture_clicked(index: int) -> void:
	# Called when user clicks a texture in ASO's popup. Apply as preview;
	# leave the list and window alone so Accept/Cancel can still decide.
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return
	var texturemenu = _get_terrain_texture_list()
	if texturemenu == null:
		return
	_aso_preview_texture_at(texturemenu, index)


# Shared by click (_on_aso_texture_clicked) and shift+scroll (_cycle_terrain's
# ASO branch). Reads the resource path out of the item metadata (ASO populates
# it via set_item_metadata when it builds the list) and commits the texture to
# the current slot WITHOUT touching the popup.
func _aso_preview_texture_at(texturemenu: ItemList, index: int) -> void:
	if _terrain_brush == null:
		return
	if index < 0 or index >= texturemenu.get_item_count():
		return
	var tex_path = texturemenu.get_item_metadata(index)
	if not (tex_path is String) or tex_path == "":
		return
	var texture = _safe_load_texture(tex_path)
	if texture == null:
		return
	_terrain_brush.SetTextureFromWindow(texture, _terrain_brush.TerrainID)


func _safe_load_texture(path: String):
	if path == null or path == "":
		return null
	# Default pack textures (res://textures/...) are registered resources:
	# ResourceLoader.load works. Custom pack textures (res://packs/...webp)
	# are typically not in the resource database — ResourceLoader returns
	# null and we must load them as runtime images. Matches the fallback
	# chain ASO uses in its own safe_load_texture.
	if ResourceLoader.exists(path):
		var tex = ResourceLoader.load(path)
		if tex != null:
			return tex
	var file = File.new()
	if file.file_exists(path):
		var img = Image.new()
		if img.load(path) == OK:
			var runtime_tex = ImageTexture.new()
			runtime_tex.create_from_image(img)
			runtime_tex.resource_path = path
			return runtime_tex
	return null


# ==================== INPUT HANDLING ====================

func _is_shift_scroll(event) -> bool:
	if not (event is InputEventMouseButton) or not event.pressed:
		return false
	if event.button_index != BUTTON_WHEEL_UP and event.button_index != BUTTON_WHEEL_DOWN:
		return false
	if not Input.is_key_pressed(KEY_SHIFT):
		return false
	if Input.is_key_pressed(KEY_CONTROL):
		return false
	# Shift+Z+scroll = precision rotation (handled by rotation_fix / light_tool_fix)
	if Input.is_key_pressed(KEY_Z):
		return false
	return true


func _on_input(event):
	# Escape ferme uniquement le popup terrain, sans quitter le TerrainBrush.
	# set_input_as_handled() ne bloque PAS les autres _input() (DD voit
	# quand même Escape et désélectionne le tool), donc on arme aussi un
	# flag pour restaurer TerrainBrush au frame suivant.
	if event is InputEventKey and event.pressed and not event.echo and event.scancode == KEY_ESCAPE:
		# _is_terrain_window_visible() rafraîchit le ref via _find_terrain_window()
		# avant de tester la visibilité : si _terrain_window était obsolète/null
		# (changement natif <-> ASO, fenêtre pas encore mise en cache), on ne rate
		# plus l'armement du restore.
		if _is_terrain_window_visible():
			_terrain_allow_close_once = true  # évite la réouverture par keep_open
			_on_terrain_cancel()
			_terrain_escape_restore = 10     # restauré dans update() pendant ~10 frames
			input_listener.get_tree().set_input_as_handled()
			return
	
	# Detect left-click on map in SelectTool for autoscroll
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_LEFT:
		if _g.Editor and _g.Editor.ActiveToolName == "SelectTool":
			var _st_mpos = input_listener.get_viewport().get_mouse_position()
			var _st_hovered = _get_hovered_item_list(_st_mpos)
			if _st_hovered == null:
				_select_tool_map_click = 3  # give DD a few frames to update selection
	
	# Handle right-click = +90° rotation in PatternShapeTool or PrefabTool
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_RIGHT:
		if _g.Editor:
			var atn = _g.Editor.ActiveToolName
			# PatternShapeTool: rotate the Rotation slider by +90°
			# Skip when mouse is over UI (lets favorites/context menus work on the panel)
			if atn == "PatternShapeTool":
				if not (ui_util and ui_util.is_mouse_over_ui(input_listener)):
					var pst = _g.Editor.Tools.get("PatternShapeTool")
					if pst and not pst.isDragging:
						var rot_range = pst.Rotation
						if rot_range and is_instance_valid(rot_range):
							var new_val = rot_range.value + 90.0
							# Wrap to stay within slider range (e.g. -180 to 180)
							if new_val > rot_range.max_value:
								new_val = rot_range.min_value + (new_val - rot_range.max_value)
							rot_range.value = new_val
							rot_range.emit_signal("value_changed", rot_range.value)
							input_listener.get_tree().set_input_as_handled()
							return
			# PrefabTool: rotate preview by +90°
			elif atn == "PrefabTool":
				# Skip when mouse is over UI (lets context menus work on the panel)
				if not (ui_util and ui_util.is_mouse_over_ui(input_listener)):
					var preview = _get_prefab_preview()
					if preview != null and preview.size() > 0:
						_prefab_rotate(true, 90.0)
						input_listener.get_tree().set_input_as_handled()
						return
	
	# Handle PrefabTool rotation (plain scroll) and scale (alt+scroll) on map
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
			if _g.Editor and _g.Editor.ActiveToolName == "PrefabTool":
				var up = event.button_index == BUTTON_WHEEL_UP
				var mouse_pos = input_listener.get_viewport().get_mouse_position()
				
				# Check if mouse is over a popup - if so, scroll it and don't rotate prefab
				if ui_util and ui_util.scroll_popup_under_mouse(input_listener, up):
					input_listener.get_tree().set_input_as_handled()
					return
				
				var hovered_list = _get_hovered_item_list(mouse_pos)
				var hovered_opt = _get_hovered_option_button(mouse_pos)
				# Don't consume scroll if mouse is over a list or option button
				if hovered_list == null and hovered_opt == null:
					if Input.is_key_pressed(KEY_ALT) and not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CONTROL):
						_prefab_scale(up)
						input_listener.get_tree().set_input_as_handled()
						return
					elif Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_Z) and not Input.is_key_pressed(KEY_CONTROL):
						# Shift+Z+scroll = 1° precision rotation
						_prefab_rotate(up, 1.0)
						input_listener.get_tree().set_input_as_handled()
						return
					elif Input.is_key_pressed(KEY_Z) and not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CONTROL):
						# Z+scroll = 5° fine rotation
						_prefab_rotate(up, 5.0)
						input_listener.get_tree().set_input_as_handled()
						return
					elif not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CONTROL) and not Input.is_key_pressed(KEY_ALT):
						_prefab_rotate(up)
						input_listener.get_tree().set_input_as_handled()
						return
	
	if not _is_shift_scroll(event):
		return
	# Extended-terrain picker open: it owns shift+scroll (texture cycling),
	# so skip all slot/list cycling while it is up.
	if Engine.has_meta("terrain_slots_extended_singleton"):
		var _tse = Engine.get_meta("terrain_slots_extended_singleton")
		if _tse != null and is_instance_valid(_tse) and _tse.has_method("is_picker_open") and _tse.is_picker_open():
			return
	
	# Let ScatterTool handle shift+scroll natively (cycles selected objects)
	if _g.Editor.ActiveToolName == "ScatterTool":
		return
	
	var up = event.button_index == BUTTON_WHEEL_UP
	var mouse_pos = input_listener.get_viewport().get_mouse_position()
	
	# 1) Check if TerrainWindow is open and mouse is over it
	if _is_terrain_window_visible():
		var tw_list = _get_active_terrain_list()
		if tw_list != null:
			var rect = _terrain_window.get_global_rect()
			if rect.has_point(mouse_pos):
				_cycle_terrain(tw_list, up)
				input_listener.get_tree().set_input_as_handled()
				return
	
	# 2) Check if mouse is over an ItemList
	var item_list = _get_hovered_item_list(mouse_pos)
	if item_list != null:
		if _is_color_list(item_list):
			return
		_cycle_item_list(item_list, up)
		input_listener.get_tree().set_input_as_handled()
		return
	
	# 3) Check if mouse is over an OptionButton
	var option_btn = _get_hovered_option_button(mouse_pos)
	if option_btn != null:
		_cycle_option_button(option_btn, up)
		input_listener.get_tree().set_input_as_handled()
		return
	
	# 4) On the map: cycle the active tool's primary list
	var tool_name = _g.Editor.ActiveToolName
	if tool_name in MAP_CYCLE_TOOLS:
		var tool_list = _get_tool_item_list(tool_name)
		if tool_list != null:
			if _is_color_list(tool_list):
				return
			_cycle_item_list(tool_list, up)
			# For ObjectTool/PrefabTool: simulate mouse motion to show preview
			if tool_name == "ObjectTool" or tool_name == "PrefabTool":
				call_deferred("_simulate_mouse_motion")
				if tool_name == "PrefabTool":
					_prefab_reset_transform()
			# Debug: find prefab preview node
			pass
			input_listener.get_tree().set_input_as_handled()
			return


# ==================== TERRAIN WINDOW ====================

func _is_terrain_window_visible() -> bool:
	# Always re-pick the preferred window each call: ASO may have been loaded
	# after we first cached _terrain_window (which would've been the native,
	# and native is never visible in the ASO setup). Cheap to call — just
	# walks Editor/Windows and does one tree scan when ASO is present.
	_find_terrain_window()
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return false
	return _terrain_window.visible


func _get_preferred_terrain_window():
	# Layered lookup. Each layer is independent so a failure in one doesn't
	# block the next.
	# 1) ASO's clone if ASO is installed (and only when it's confirmed distinct
	#    from the native — ui_util.find_aso_terrain_window handles that).
	if ui_util != null:
		var aso = ui_util.find_aso_terrain_window(_g.Editor)
		if aso != null and is_instance_valid(aso):
			return aso
	# 2) Native window straight from Editor.Windows — proven reliable path
	#    used by PopupBlur and other mods.
	if ui_util != null:
		var native = ui_util.get_native_terrain_window(_g.Editor)
		if native != null and is_instance_valid(native):
			return native
	# 3) Pre-patch fallback: DFS from scene root. Ensures we return SOMETHING
	# if either ui_util is absent or the dictionary hasn't been populated yet.
	if input_listener == null:
		return null
	var root = input_listener.get_tree().root
	if root == null:
		return null
	return _find_node_by_name(root, "TerrainWindow")


func _find_terrain_window():
	# Prefer ASO's window when ASO is installed — it's the one the user
	# actually sees when clicking a terrain slot button. The native window
	# stays resident but hidden.
	var picked = _get_preferred_terrain_window()
	if picked == null:
		_terrain_window = null
		_terrain_is_aso = false
		_aso_click_hooked = false
		return
	if picked != _terrain_window:
		# Window changed — invalidate dependent caches/UI that are tied to a
		# specific instance.
		_terrain_texture_list = null
		_terrain_buttons_added = false
		_aso_click_hooked = false
	_terrain_window = picked
	_terrain_is_aso = (ui_util != null) and ui_util.is_aso_terrain_window(_g.Editor, picked)


func _get_terrain_texture_list():
	if _terrain_texture_list != null and is_instance_valid(_terrain_texture_list):
		return _terrain_texture_list
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return null
	_terrain_texture_list = _find_node_by_name(_terrain_window, "TextureMenu")
	return _terrain_texture_list


# === Préservation position popup terrain au clic texture ===
# DD natif recentre la fenêtre quand on clique une texture (via le handler
# C# de DD attaché à TextureMenu.item_selected). On capture la position
# AVANT le clic via gui_input (qui fire avant item_selected) et on la
# restaure en call_deferred après que DD ait recentré.
func _ensure_terrain_pos_guard() -> void:
	var tm = _get_terrain_texture_list()
	if tm == null or not is_instance_valid(tm):
		return
	if not tm.is_connected("gui_input", self, "_on_terrain_texture_gui_input"):
		tm.connect("gui_input", self, "_on_terrain_texture_gui_input")


func _on_terrain_texture_gui_input(event) -> void:
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != BUTTON_LEFT:
		return
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return
	if not _terrain_window.visible:
		return
	_terrain_pos_before_click = _terrain_window.rect_position
	call_deferred("_restore_terrain_pos_after_click")


func _restore_terrain_pos_after_click() -> void:
	if _terrain_pos_before_click == null:
		return
	if _terrain_window and is_instance_valid(_terrain_window) and _terrain_window.visible:
		if _terrain_window.rect_position != _terrain_pos_before_click:
			_terrain_window.rect_position = _terrain_pos_before_click
	_terrain_pos_before_click = null


# When user is in favorites mode, the "FavsOverlay" ItemList (created by
# favorites.gd) sits visible in front of the hidden TextureMenu. Shift+scroll
# cycling should traverse the favorites the user actually sees, not the
# hidden full list below. Return the overlay if it's visible, else fall back
# to TextureMenu.
func _get_active_terrain_list():
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return null
	var overlay = _find_node_by_name(_terrain_window, "FavsOverlay")
	if overlay != null and is_instance_valid(overlay) and overlay.visible:
		return overlay
	return _get_terrain_texture_list()


func _find_node_by_name(node, target_name: String):
	if not is_instance_valid(node):
		return null
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found = _find_node_by_name(child, target_name)
		if found:
			return found
	return null


# ==================== CYCLE HELPERS ====================

func _cycle_terrain(item_list: ItemList, up: bool):
	var count = item_list.get_item_count()
	if count == 0:
		return
	
	var current_idx = 0
	var selected = item_list.get_selected_items()
	if selected.size() > 0:
		current_idx = selected[0]
	
	var direction = -1 if up else 1
	var new_idx = (current_idx + direction) % count
	if new_idx < 0:
		new_idx += count
	
	item_list.select(new_idx)
	_scroll_to_item(item_list, new_idx)
	
	# ASO: select visually and preview via SetTextureFromWindow. Don't emit
	# item_selected because on ASO that routes through _on_terrain_item_selected
	# which, if accept_required is OFF, commits + clears + hides. On the
	# new ASO (with native Accept/Cancel), we've already forced accept_required
	# to ON in _aso_prep_native_buttons, so emitting would stay preview-only —
	# but using SetTextureFromWindow directly is cleaner and works on both
	# ASO versions.
	if _terrain_is_aso:
		_aso_preview_texture_at(item_list, new_idx)
		_list_selections[item_list.get_instance_id()] = new_idx
		return
	
	# Block window from hiding during signal emission
	if not _terrain_window.is_connected("visibility_changed", self, "_on_terrain_vis_changed"):
		_terrain_window.connect("visibility_changed", self, "_on_terrain_vis_changed")
	_block_terrain_hide = true
	item_list.emit_signal("item_selected", new_idx)
	_block_terrain_hide = false
	
	_list_selections[item_list.get_instance_id()] = new_idx


var _block_terrain_hide = false
var _terrain_keep_open = false
var _terrain_reopened_by_keepopen = false  # True when popup was force-reopened
var _terrain_original_texture = null  # For cancel: restore original texture
var _terrain_original_slot_id = -1
var _terrain_buttons_added = false

func _on_terrain_vis_changed():
	var tw_visible = false
	if _terrain_window and is_instance_valid(_terrain_window):
		tw_visible = _terrain_window.visible
	
	# One-shot: Accept/Cancel buttons (ours or ASO's) set this so a
	# deliberate hide gets through instead of being force-reopened by
	# keep_open. Consume the flag and return early.
	if _terrain_allow_close_once and _terrain_window and is_instance_valid(_terrain_window):
		if not tw_visible:
			_terrain_allow_close_once = false
			_terrain_keep_open = false
			return
	
	# Block hide when cycling via shift+scroll
	if _block_terrain_hide and _terrain_window and is_instance_valid(_terrain_window):
		if not tw_visible:
			_terrain_window.visible = true
			_terrain_reopened_by_keepopen = true
			return
	
	# Re-evaluate keep_open at this exact moment rather than trusting the
	# cached flag. The sync pass may not have updated it yet if the user's
	# action (toggle off → click) happened within the same frame. This makes
	# ASO's toggle-off-then-click-commits-and-closes flow reliable.
	var keep_open_now = _compute_keep_open_wanted()
	if keep_open_now and _terrain_keep_open and _terrain_window and is_instance_valid(_terrain_window):
		if not tw_visible:
			_terrain_window.visible = true
			_terrain_reopened_by_keepopen = true
			return
	
	# Popup just became visible: re-run de-modalize (ASO re-pushes to modal
	# stack every time it calls popup_centered_ratio on a slot click).
	if _terrain_window and is_instance_valid(_terrain_window) and tw_visible:
		if not _demodalizing and _terrain_is_aso:
			call_deferred("_demodalize_terrain_window", _terrain_window)


# Centralized keep_open decision. Callers: sync loop and visibility handler.
func _compute_keep_open_wanted() -> bool:
	if _terrain_window == null:
		return false
	var aso_has = _terrain_is_aso and _aso_has_accept_cancel()
	var aso_preview_on = aso_has and _aso_toggle_is_pressed()
	var native_preview_on = (not _terrain_is_aso) and _get_native_accept_required()
	# Old ASO (no native buttons) needs keep_open to preserve our hijacked flow.
	var old_aso = _terrain_is_aso and not aso_has
	return old_aso or aso_preview_on or native_preview_on
	
	# If popup actually closed (not blocked), reset state
	if _terrain_window and is_instance_valid(_terrain_window) and not _terrain_window.visible:
		_terrain_original_texture = null
		_terrain_original_slot_id = -1


func _add_terrain_popup_buttons():
	if _terrain_buttons_added:
		return
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return
	
	# On ASO, take the overlay approach (same trick we used for the favorites
	# tab): attach Accept/Cancel as a sibling of Margins directly on the
	# WindowDialog, and push Margins.margin_bottom down by the bar height.
	# This never touches Splitter/PackList/TextureMenu, so it doesn't
	# interfere with ASO's find_node(owned=true) lookups.
	#
	# Exception: recent ASO versions ship their own Accept/Cancel/toggle
	# buttons. Don't pile ours on top — we'd have duplicate controls and
	# conflicting commit semantics. We style ASO's buttons and pre-enable
	# its accept_required_button instead (see _aso_prep_native_buttons).
	if _terrain_is_aso:
		if not _aso_has_accept_cancel():
			_add_aso_popup_buttons_overlay()
		_terrain_buttons_added = true
		return
	
	_terrain_buttons_added = true
	
	# The TerrainWindow structure is:
	# TerrainWindow [WindowDialog]
	#   TextureButton (close X)
	#   Background [Panel]
	#   Margins [MarginContainer]
	#     Splitter [HSplitContainer]
	#       PackList [ItemList]
	#       TextureMenu [ItemList]
	
	# We need to reorganize: wrap existing content in a VBoxContainer
	# and add buttons at the bottom
	var margins = _find_node_by_name(_terrain_window, "Margins")
	if margins == null:
		return
	
	var margins_parent = margins.get_parent()
	if margins_parent == null:
		return
	
	# Create a VBox to hold margins + buttons
	var vbox = VBoxContainer.new()
	vbox.name = "TerrainPopupVBox"
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = margins.margin_left
	vbox.margin_right = margins.margin_right
	vbox.margin_top = margins.margin_top
	vbox.margin_bottom = margins.margin_bottom
	
	# Reparent margins into the vbox
	var margins_idx = margins.get_index()
	margins_parent.remove_child(margins)
	margins.anchor_right = 0
	margins.anchor_bottom = 0
	margins.margin_left = 0
	margins.margin_right = 0
	margins.margin_top = 0
	margins.margin_bottom = 0
	margins.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(margins)
	
	# Button container
	var btn_container = HBoxContainer.new()
	btn_container.name = "TerrainPopupButtons"
	btn_container.set("custom_constants/separation", 16)
	btn_container.alignment = BoxContainer.ALIGN_CENTER
	btn_container.rect_min_size = Vector2(0, 44)
	
	# Larger font
	var font = DynamicFont.new()
	font.font_data = load("res://ui/fonts/NotoSans-Regular.ttf") if ResourceLoader.exists("res://ui/fonts/NotoSans-Regular.ttf") else null
	font.size = 15
	
	# Accept button
	var accept_btn = Button.new()
	accept_btn.text = "Accept"
	accept_btn.rect_min_size = Vector2(120, 34)
	accept_btn.name = "NativeAcceptBtn"
	if font.font_data:
		accept_btn.add_font_override("font", font)
	_add_button_border(accept_btn)
	accept_btn.connect("pressed", self, "_on_terrain_accept")
	btn_container.add_child(accept_btn)
	
	# Toggle button — mirror ASO's accept_required_button exactly:
	# bare Button with only a ring icon. DD's theme provides the dark
	# rounded rect background; the blue pressed-state tint comes from DD's
	# theme too. Don't set flat or override any stylebox — let the theme
	# handle all states like ASO does.
	var toggle_btn = Button.new()
	toggle_btn.toggle_mode = true
	toggle_btn.pressed = _get_native_accept_required()
	toggle_btn.name = "NativeAcceptRequiredBtn"
	toggle_btn.hint_tooltip = "Toggle Acceptance Required. When off, clicking a texture commits immediately."
	toggle_btn.icon = _make_circle_icon(18, Color.white)
	toggle_btn.connect("toggled", self, "_on_native_accept_required_toggled")
	btn_container.add_child(toggle_btn)
	
	# Cancel button
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.rect_min_size = Vector2(120, 34)
	cancel_btn.name = "NativeCancelBtn"
	if font.font_data:
		cancel_btn.add_font_override("font", font)
	_add_button_border(cancel_btn)
	cancel_btn.connect("pressed", self, "_on_terrain_cancel")
	btn_container.add_child(cancel_btn)
	
	# Apply initial enabled state based on toggle
	_apply_native_accept_required_state(toggle_btn.pressed)
	
	vbox.add_child(btn_container)
	
	# Bottom spacer
	var spacer = Control.new()
	spacer.rect_min_size = Vector2(0, 8)
	vbox.add_child(spacer)
	
	# Add vbox to window
	margins_parent.add_child(vbox)
	margins_parent.move_child(vbox, margins_idx)
	
	# Connect the close button (X) to act as Accept
	var close_btn = null
	for child in _terrain_window.get_children():
		if child is TextureButton:
			close_btn = child
			break
	if close_btn:
		# Disconnect default behavior and connect to accept
		var connections = close_btn.get_signal_connection_list("pressed")
		for conn in connections:
			close_btn.disconnect("pressed", conn.target, conn.method)
		close_btn.connect("pressed", self, "_on_terrain_accept")


func _on_terrain_accept():
	# Accept the current texture and close
	_terrain_keep_open = false
	_terrain_original_texture = null
	_terrain_original_slot_id = -1
	if _terrain_window and is_instance_valid(_terrain_window):
		_terrain_window.visible = false


func _add_button_border(btn: Button):
	# Add white 1px border to enabled button states only. We skip "disabled"
	# on purpose: callers (ASO's `disabled = true` and our own toggle logic)
	# rely on DD's theme to grey out the button — overriding "disabled" with
	# a white border keeps the button visually "on" even when it's inactive.
	for state in ["normal", "hover", "pressed", "focus"]:
		var existing = btn.get_stylebox(state, "Button")
		var sb = StyleBoxFlat.new()
		if existing and existing is StyleBoxFlat:
			sb = existing.duplicate()
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_color = Color.white
		btn.add_stylebox_override(state, sb)


# Load the white-circle icon from the mod's /icons folder. Cached so we
# only read the file once per session. Falls back to null if not found.
var _cached_circle_icon = null
func _make_circle_icon(_size: int = 18, _color: Color = Color.white) -> Texture:
	if _cached_circle_icon != null:
		return _cached_circle_icon
	var root = ""
	if _g and _g.get("Root") and _g.Root is String:
		root = _g.Root
	if root == "":
		return null
	var img = Image.new()
	if img.load(root + "icons/white-circle-icon.png") != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	_cached_circle_icon = tex
	return tex


# ASO-compatible Accept/Cancel injection: sibling of Margins on the
# WindowDialog, anchored to the bottom. Same approach as the favorites tab
# (overlay pattern) — leaves Splitter/PackList/TextureMenu hierarchy intact.
func _add_aso_popup_buttons_overlay() -> void:
	var tw = _terrain_window
	var margins = _find_node_by_name(tw, "Margins")
	if margins == null:
		return
	
	var bar_h = 52  # enough room for 34px button + padding
	
	# Reserve space at the bottom of Margins so the Splitter doesn't slide
	# under our button bar. Remember the original so re-injection is idempotent.
	if not margins.has_meta("ac_original_bottom"):
		margins.set_meta("ac_original_bottom", margins.margin_bottom)
	var orig_bottom = margins.get_meta("ac_original_bottom")
	margins.margin_bottom = orig_bottom - bar_h
	
	# Container for the buttons — attached directly to the WindowDialog
	# (sibling of Margins), anchored to the bottom.
	var btn_container = HBoxContainer.new()
	btn_container.name = "TerrainPopupButtonsASO"
	btn_container.set("custom_constants/separation", 16)
	btn_container.alignment = BoxContainer.ALIGN_CENTER
	btn_container.anchor_left = 0
	btn_container.anchor_right = 1.0
	btn_container.anchor_top = 1.0
	btn_container.anchor_bottom = 1.0
	btn_container.margin_top = -bar_h + 8
	btn_container.margin_bottom = -8
	btn_container.margin_left = 8
	btn_container.margin_right = -8
	
	var font = DynamicFont.new()
	font.font_data = load("res://ui/fonts/NotoSans-Regular.ttf") if ResourceLoader.exists("res://ui/fonts/NotoSans-Regular.ttf") else null
	font.size = 15
	
	var accept_btn = Button.new()
	accept_btn.text = "Accept"
	accept_btn.rect_min_size = Vector2(120, 34)
	if font.font_data:
		accept_btn.add_font_override("font", font)
	_add_button_border(accept_btn)
	accept_btn.connect("pressed", self, "_on_terrain_accept")
	btn_container.add_child(accept_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.rect_min_size = Vector2(120, 34)
	if font.font_data:
		cancel_btn.add_font_override("font", font)
	_add_button_border(cancel_btn)
	cancel_btn.connect("pressed", self, "_on_terrain_cancel")
	btn_container.add_child(cancel_btn)
	
	tw.add_child(btn_container)
	
	# The X close button (TextureButton child of WindowDialog) still closes
	# the popup via WindowDialog default behavior. Re-route it to Accept so
	# clicking X keeps the previewed texture rather than reverting.
	var close_btn = null
	for child in tw.get_children():
		if child is TextureButton:
			close_btn = child
			break
	if close_btn:
		var connections = close_btn.get_signal_connection_list("pressed")
		for conn in connections:
			close_btn.disconnect("pressed", conn.target, conn.method)
		close_btn.connect("pressed", self, "_on_terrain_accept")
	


# Recent ASO versions ship their own Accept/Cancel/accept_required toggle
# inside the TerrainWindow. Detect by presence of "Accept" and "Cancel"
# Button nodes anywhere under the window. We don't rely on ASO variable
# names (they may change) — we look at the UI structure.
var _aso_native_btn_cache = {"win_id": 0, "has": false}
func _aso_has_accept_cancel() -> bool:
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return false
	# Cache per window instance — the scan is cheap but runs every frame.
	var wid = _terrain_window.get_instance_id()
	if _aso_native_btn_cache["win_id"] == wid:
		return _aso_native_btn_cache["has"]
	var found_accept = false
	var found_cancel = false
	var stack = [_terrain_window]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n is Button:
			var t = n.text
			if t == "Accept": found_accept = true
			elif t == "Cancel": found_cancel = true
			if found_accept and found_cancel:
				break
		for c in n.get_children():
			stack.push_back(c)
	_aso_native_btn_cache["win_id"] = wid
	_aso_native_btn_cache["has"] = found_accept and found_cancel
	return _aso_native_btn_cache["has"]


# Style ASO's native Accept/Cancel buttons to match our look, and pre-enable
# its accept_required toggle so preview flow is on by default. Idempotent:
# uses a meta flag so re-entering the function is a no-op per window.
func _aso_prep_native_buttons() -> void:
	var tw = _terrain_window
	if tw == null or not is_instance_valid(tw):
		return
	if tw.has_meta("aso_buttons_prepped"):
		return
	# First pass: find Accept and Cancel buttons by text. Unambiguous.
	var stack = [tw]
	var accept_btn = null
	var cancel_btn = null
	while stack.size() > 0:
		var n = stack.pop_back()
		if n is Button:
			var t = n.text
			if t == "Accept":
				accept_btn = n
			elif t == "Cancel":
				cancel_btn = n
		for c in n.get_children():
			stack.push_back(c)
	# Find the accept_required toggle: it's the Button sibling between Accept
	# and Cancel in ASO's buttons_hbox. Scanning by "toggle_mode and no text"
	# wasn't reliable — ASO has other toggle buttons in its window (e.g. the
	# "used" filter button) that matched and caused the toggle state to be
	# read from the wrong button.
	var toggle_btn = null
	if accept_btn != null and cancel_btn != null:
		var parent = accept_btn.get_parent()
		if parent != null and parent == cancel_btn.get_parent():
			var a_idx = accept_btn.get_index()
			var c_idx = cancel_btn.get_index()
			# ASO's layout: spacer | Accept | toggle | Cancel | spacer
			# So toggle sits exactly between them, 1 index apart from each.
			if c_idx - a_idx == 2:
				var mid = parent.get_child(a_idx + 1)
				if mid is Button and mid.toggle_mode:
					toggle_btn = mid
			# Fallback: scan the parent's children for a toggle Button with
			# no text between the Accept/Cancel indices.
			if toggle_btn == null:
				var lo = min(a_idx, c_idx)
				var hi = max(a_idx, c_idx)
				for i in range(lo + 1, hi):
					var child = parent.get_child(i)
					if child is Button and child.toggle_mode and child.text == "":
						toggle_btn = child
						break
	
	if accept_btn:
		# Border on enabled states only — when ASO sets disabled=true (toggle
		# off), DD's theme dims the button naturally with no border. When
		# enabled (toggle on), our border makes it stand out.
		_add_button_border(accept_btn)
		# ASO's accept_btn.pressed -> terrainwindow.hide(). Our keep_open
		# handler would force-reopen the window. Flag allow_close first so
		# visibility_changed lets the hide through.
		accept_btn.connect("pressed", self, "_arm_terrain_allow_close")
	if cancel_btn:
		_add_button_border(cancel_btn)
		cancel_btn.connect("pressed", self, "_arm_terrain_allow_close")
	if toggle_btn:
		# Force preview-commit flow on by default. User can toggle back off.
		if not toggle_btn.pressed:
			toggle_btn.pressed = true
			# Fire the signal so ASO's _on_accept_required_button_toggled
			# enables Accept/Cancel and sets up its internal state.
			toggle_btn.emit_signal("toggled", true)
		# Cache the toggle for keep_open logic in _do_terrain_sync: when ASO
		# user turns it off, we must disable keep_open so ASO's click handler
		# can close the popup naturally (otherwise we reopen it empty because
		# ASO clears TextureMenu on commit).
		tw.set_meta("aso_toggle_btn", toggle_btn)
		# Also hook the toggle so when user flips it, we re-apply our
		# "really disabled" treatment (focus_mode + mouse_filter) on ASO's
		# Accept/Cancel. ASO already flips their `disabled` property in its
		# own handler, but Godot's Button still paints the white pressed
		# stylebox on click-before-disabled-check, so we need to also kill
		# focus and mouse input.
		tw.set_meta("aso_accept_btn", accept_btn)
		tw.set_meta("aso_cancel_btn", cancel_btn)
		if not toggle_btn.is_connected("toggled", self, "_on_aso_toggle_toggled"):
			toggle_btn.connect("toggled", self, "_on_aso_toggle_toggled", [tw])
		# Apply the current state now (we forced it ON above → buttons active)
		_set_button_truly_disabled(accept_btn, false)
		_set_button_truly_disabled(cancel_btn, false)
	else:
		print("[AC] WARNING: ASO accept_required toggle NOT FOUND — keep_open logic may misbehave")
	
	# Hook the WindowDialog's built-in close button (X top-right). Without
	# this, clicking X triggers hide() but keep_open force-reopens.
	if tw.has_method("get_close_button"):
		var close_btn = tw.get_close_button()
		if close_btn and close_btn is BaseButton:
			if not close_btn.is_connected("pressed", self, "_arm_terrain_allow_close"):
				close_btn.connect("pressed", self, "_arm_terrain_allow_close")
	
	# Let clicks outside the popup reach UI controls behind (slot buttons,
	# settings buttons). Godot 3's Popup captures all outside clicks via the
	# viewport's modal stack. popup_exclusive=true disables auto-hide but
	# doesn't always release the modal capture. The reliable workaround is
	# to de-modalize: toggle visibility off/on within the same frame. Hiding
	# pops the popup from the viewport modal stack; showing again via
	# direct .visible = true (not .popup*()) does NOT re-push to the stack,
	# so the popup stays on screen as a regular Control — outside clicks
	# now reach other UI.
	if tw is Popup:
		tw.popup_exclusive = true
	# De-modalize is triggered each time the popup becomes visible (see
	# _on_terrain_vis_changed). ASO re-calls popup_centered_ratio every time
	# the user clicks a slot button while the popup is open, which re-adds
	# the window to the modal stack. We need to de-modalize each time, not
	# just once.
	
	tw.set_meta("aso_buttons_prepped", true)


# De-modalize: pop the popup from the viewport's modal stack so clicks
# outside reach UI controls behind. Done deferred so ASO's own post-show
# setup finishes first. Must be called EACH time the popup becomes visible
# — ASO re-calls popup_centered_ratio on slot click, re-pushing to stack.
var _demodalizing = false
func _demodalize_terrain_window(tw) -> void:
	if not is_instance_valid(tw):
		return
	if not tw.visible:
		return
	if _demodalizing:
		return
	_demodalizing = true
	# Arm allow_close so the vis-changed hide doesn't reopen.
	_terrain_allow_close_once = true
	tw.visible = false
	# Re-show as a plain Control (not via popup_*()), preserving position.
	tw.visible = true
	_demodalizing = false


# Called when user presses ASO's Accept/Cancel. Sets a one-shot flag so our
# visibility_changed handler allows this specific hide through instead of
# force-reopening via keep_open.
var _terrain_allow_close_once = false
# Compteur de frames armé par _on_input quand Escape ferme le popup.
# Pendant ces frames, update() restaure TerrainBrush si DD l'a désélectionné
# (DD peut désélectionner de façon différée, d'où le multi-frame).
var _terrain_escape_restore = 0
func _arm_terrain_allow_close() -> void:
	_terrain_allow_close_once = true


# Read ASO's accept_required toggle state. We cache the button reference on
# the window as a meta when preparing the buttons (see _aso_prep_native_
# buttons). Returns true by default if we don't have a reference yet — that
# matches the default we set.
func _aso_toggle_is_pressed() -> bool:
	if _terrain_window == null or not is_instance_valid(_terrain_window):
		return true
	if not _terrain_window.has_meta("aso_toggle_btn"):
		return true
	var btn = _terrain_window.get_meta("aso_toggle_btn")
	if btn == null or not is_instance_valid(btn):
		return true
	return btn.pressed


# Native Accept/Cancel toggle — mirror of ASO's accept_required_button.
# When OFF, clicking a texture commits and closes (legacy DD behavior).
# When ON (default), preview flow with Accept/Cancel. State persists on
# _terrain_brush as a session meta so it survives popup reopens.
func _get_native_accept_required() -> bool:
	if _terrain_brush == null or not is_instance_valid(_terrain_brush):
		return true
	if not _terrain_brush.has_meta("ac_native_accept_required"):
		return true  # default ON
	return _terrain_brush.get_meta("ac_native_accept_required")


func _on_native_accept_required_toggled(pressed: bool) -> void:
	if _terrain_brush != null and is_instance_valid(_terrain_brush):
		_terrain_brush.set_meta("ac_native_accept_required", pressed)
	_apply_native_accept_required_state(pressed)


# Apply the toggle state: enable/disable Accept and Cancel buttons, and
# flip keep_open off so clicks commit+close in legacy mode.
func _apply_native_accept_required_state(required: bool) -> void:
	var accept_btn = null
	var cancel_btn = null
	if _terrain_window and is_instance_valid(_terrain_window):
		accept_btn = _find_node_by_name(_terrain_window, "NativeAcceptBtn")
		cancel_btn = _find_node_by_name(_terrain_window, "NativeCancelBtn")
	_set_button_truly_disabled(accept_btn, not required)
	_set_button_truly_disabled(cancel_btn, not required)
	pass


# Button.disabled alone still lets Godot render click feedback (the white
# "pressed" flash) on mouse press in some cases, because the input reaches
# the button before the disabled check bails out. Combined with
# focus_mode=NONE and mouse_filter=IGNORE, the button becomes fully inert:
# no hover highlight, no click flash, no keyboard focus.
#
# We also strip the hover/pressed/focus stylebox overrides we added in
# _add_button_border when disabling — otherwise Godot still paints the
# white-bordered hover/pressed stylebox on mouse interaction even though
# the button is "disabled" from an input perspective. Restored on re-enable.
func _set_button_truly_disabled(btn, disabled: bool) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	btn.disabled = disabled
	if disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if btn.has_focus():
			btn.release_focus()
		# Strip our border overrides on interactive states — leaving only
		# the "normal" stylebox so the disabled button shows a static look.
		# Save them first (if present) so we can restore on re-enable.
		if not btn.has_meta("ac_saved_styleboxes"):
			var saved = {}
			for state in ["hover", "pressed", "focus"]:
				if btn.has_stylebox_override(state):
					saved[state] = btn.get_stylebox(state, "Button")
					# Remove the override by setting it to null
			btn.set_meta("ac_saved_styleboxes", saved)
		for state in ["hover", "pressed", "focus"]:
			# In Godot 3, remove a stylebox override by adding a null.
			btn.add_stylebox_override(state, null)
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		# Restore any stylebox overrides we stripped on disable.
		if btn.has_meta("ac_saved_styleboxes"):
			var saved = btn.get_meta("ac_saved_styleboxes")
			for state in saved:
				btn.add_stylebox_override(state, saved[state])
			btn.remove_meta("ac_saved_styleboxes")


# Called when the user toggles ASO's accept_required button. ASO's own
# handler sets `disabled = true/false` on Accept/Cancel, but Godot still
# paints click feedback because the button is only semi-disabled. Apply
# our fully-inert treatment on top.
func _on_aso_toggle_toggled(pressed: bool, tw) -> void:
	if tw == null or not is_instance_valid(tw):
		return
	var accept_btn = tw.get_meta("aso_accept_btn") if tw.has_meta("aso_accept_btn") else null
	var cancel_btn = tw.get_meta("aso_cancel_btn") if tw.has_meta("aso_cancel_btn") else null
	# Defer by one frame so ASO's own handler runs first (it resets
	# `disabled` directly on the button). Our helper then layers on top.
	call_deferred("_set_button_truly_disabled", accept_btn, not pressed)
	call_deferred("_set_button_truly_disabled", cancel_btn, not pressed)


func _on_terrain_cancel():
	# Restore original texture and close
	if _terrain_original_texture != null and _terrain_original_slot_id >= 0:
		var terrain = null
		if _g.World and _g.World.Level:
			terrain = _g.World.Level.Terrain
		if terrain:
			terrain.SetTexture(_terrain_original_texture, _terrain_original_slot_id)
			# Also update the slot icon in terrainList
			if _terrain_brush and _terrain_brush.terrainList:
				# Force DD to refresh by calling SetTextureFromWindow with the original
				_terrain_brush.SetTextureFromWindow(_terrain_original_texture, _terrain_original_slot_id)
	
	_terrain_keep_open = false
	_terrain_original_texture = null
	_terrain_original_slot_id = -1
	if _terrain_window and is_instance_valid(_terrain_window):
		_terrain_window.visible = false


func _cycle_item_list(item_list: ItemList, up: bool):
	# If this is the SelectTool pattern list managed by pattern_fix, delegate to it
	# so it uses the safe OnItemSelected path (avoids crash on the X/null pattern).
	if pattern_fix != null and pattern_fix.get("_select_pattern_list") == item_list:
		pattern_fix.cycle_pattern(up)
		_scroll_to_item(item_list, item_list.get_selected_items()[0] if item_list.get_selected_items().size() > 0 else 0)
		_list_selections[item_list.get_instance_id()] = item_list.get_selected_items()[0] if item_list.get_selected_items().size() > 0 else 0
		return
	var count = item_list.get_item_count()
	if count == 0:
		return
	
	var current_idx = 0
	var selected = item_list.get_selected_items()
	if selected.size() > 0:
		current_idx = selected[0]
	
	var direction = -1 if up else 1
	var new_idx = (current_idx + direction) % count
	if new_idx < 0:
		new_idx += count
	
	item_list.select(new_idx)
	item_list.emit_signal("item_selected", new_idx)
	_scroll_to_item(item_list, new_idx)
	_list_selections[item_list.get_instance_id()] = new_idx


func _scroll_to_item(item_list: ItemList, idx: int):
	var vbar = null
	for child in item_list.get_children():
		if child is VScrollBar:
			vbar = child
			break
	if vbar == null:
		return
	var item_count = item_list.get_item_count()
	if item_count <= 0:
		return
	var max_scroll = vbar.max_value - vbar.page
	if max_scroll <= 0:
		return
	# Center the item in the visible area
	var ratio = float(idx) / float(item_count)
	var target = ratio * vbar.max_value - vbar.page * 0.5
	vbar.value = clamp(target, 0.0, max_scroll)


func _cycle_option_button(btn: OptionButton, up: bool):
	var count = btn.get_item_count()
	if count == 0:
		return
	
	var current_idx = btn.selected
	var direction = -1 if up else 1
	var new_idx = (current_idx + direction) % count
	if new_idx < 0:
		new_idx += count
	
	btn.select(new_idx)
	btn.emit_signal("item_selected", new_idx)


func _simulate_mouse_motion():
	var viewport = input_listener.get_viewport()
	if viewport == null:
		return
	var mouse_pos = viewport.get_mouse_position()
	var ev = InputEventMouseMotion.new()
	ev.position = mouse_pos
	ev.global_position = mouse_pos
	ev.relative = Vector2.ZERO
	viewport.input(ev)


func _get_prefab_preview():
	if not _g.Editor or not _g.Editor.Tools:
		return null
	if not _g.Editor.Tools.has("PrefabTool"):
		return null
	var pt = _g.Editor.Tools["PrefabTool"]
	var preview = pt.get("preview")
	if preview == null or typeof(preview) != TYPE_DICTIONARY or preview.size() == 0:
		return null
	return preview


func _get_mouse_world_position() -> Vector2:
	# Use a preview node to get correct world coordinates (handles Camera2D zoom/pan)
	var preview = _get_prefab_preview()
	if preview != null:
		for node in preview.keys():
			if is_instance_valid(node) and node is Node2D:
				return node.get_global_mouse_position()
	# Fallback: use World node if available
	if _g.World and is_instance_valid(_g.World) and _g.World is Node2D:
		return _g.World.get_global_mouse_position()
	# Last resort fallback
	var viewport = input_listener.get_viewport()
	var mouse_screen = viewport.get_mouse_position()
	return viewport.get_canvas_transform().affine_inverse().xform(mouse_screen)



# Prefab transform state
var _prefab_rotation = 0.0
var _prefab_scale_factor = 1.0
var _prefab_last_list_idx = -1
var _prefab_mouse_offsets = {}     # nid -> Vector2 (node.position - mouse_world, captured once)
var _prefab_base_rotations = {}    # nid -> float
var _prefab_base_scales = {}       # nid -> Vector2
var _prefab_late_node = null


func _prefab_get_selected_idx():
	if not _g.Editor or not _g.Editor.Tools:
		return -1
	if not _g.Editor.Tools.has("PrefabTool"):
		return -1
	var pt = _g.Editor.Tools["PrefabTool"]
	var lst = pt.get("list")
	if lst and is_instance_valid(lst) and lst is ItemList:
		var sel = lst.get_selected_items()
		if sel.size() > 0:
			return sel[0]
	return -1


func _ensure_late_process_node():
	if _prefab_late_node and is_instance_valid(_prefab_late_node):
		return
	_prefab_late_node = Node.new()
	_prefab_late_node.name = "PrefabLateProcess"
	var script = GDScript.new()
	script.source_code = """extends Node
var handler = null
func _ready():
	set_process(true)
	process_priority = 9999
func _process(_delta):
	if handler != null:
		handler._late_apply_prefab_transform()
"""
	script.reload()
	_prefab_late_node.set_script(script)
	_prefab_late_node.handler = self
	if _g.World and _g.World is Node:
		var tree = _g.World.get_tree()
		if tree and tree.root:
			tree.root.call_deferred("add_child", _prefab_late_node)


func _prefab_capture_offsets(preview):
	# Capture offset of each node from the mouse world position.
	# DD positions nodes as: node.position = mouse_world + internal_offset[i]
	# We capture internal_offset[i] = node.position - mouse_world
	_prefab_mouse_offsets.clear()
	_prefab_base_rotations.clear()
	_prefab_base_scales.clear()
	
	var mouse = _get_mouse_world_position()
	
	for node in preview.keys():
		if is_instance_valid(node) and node is Node2D:
			var nid = node.get_instance_id()
			_prefab_mouse_offsets[nid] = node.position - mouse
			_prefab_base_rotations[nid] = node.rotation
			_prefab_base_scales[nid] = node.scale


func _prefab_rotate(up: bool, step_deg: float = 15.0):
	var preview = _get_prefab_preview()
	if preview == null:
		return
	
	_ensure_late_process_node()
	
	if _prefab_mouse_offsets.size() == 0:
		_prefab_capture_offsets(preview)
	
	var step = deg2rad(step_deg)
	_prefab_rotation += step if up else -step
	_prefab_last_list_idx = _prefab_get_selected_idx()


func _prefab_scale(up: bool):
	var preview = _get_prefab_preview()
	if preview == null:
		return
	
	_ensure_late_process_node()
	
	if _prefab_mouse_offsets.size() == 0:
		_prefab_capture_offsets(preview)
	
	var factor = 1.1 if up else (1.0 / 1.1)
	_prefab_scale_factor *= factor
	_prefab_last_list_idx = _prefab_get_selected_idx()


func _late_apply_prefab_transform():
	# Runs AFTER DD's _process (priority 9999).
	# DD has set: node.position = mouse_world + dd_offset[i]
	# We override: node.position = mouse_world + dd_offset[i].rotated(rot) * scale
	# Using CURRENT mouse position → no teleport on mouse move.
	if _prefab_rotation == 0.0 and _prefab_scale_factor == 1.0:
		return
	
	if not _g.Editor or _g.Editor.ActiveToolName != "PrefabTool":
		return
	
	var current_idx = _prefab_get_selected_idx()
	if current_idx != _prefab_last_list_idx:
		_prefab_reset_transform()
		return
	
	var preview = _get_prefab_preview()
	if preview == null:
		return
	
	# Check for new nodes (DD recreated preview after placement)
	var has_new = false
	for node in preview.keys():
		if is_instance_valid(node) and not _prefab_mouse_offsets.has(node.get_instance_id()):
			has_new = true
			break
	if has_new:
		_prefab_capture_offsets(preview)
	
	# Get CURRENT mouse position (may have moved since last frame)
	var mouse = _get_mouse_world_position()
	
	# Apply rotated/scaled offsets from current mouse position
	for node in preview.keys():
		if not is_instance_valid(node) or not (node is Node2D):
			continue
		var nid = node.get_instance_id()
		if not _prefab_mouse_offsets.has(nid):
			continue
		var base_offset = _prefab_mouse_offsets[nid]
		node.position = mouse + base_offset.rotated(_prefab_rotation) * _prefab_scale_factor
		node.rotation = _prefab_base_rotations[nid] + _prefab_rotation
		node.scale = _prefab_base_scales[nid] * _prefab_scale_factor


func _apply_prefab_transform():
	# No-op — all work in _late_apply_prefab_transform
	pass


func _prefab_reset_transform():
	_prefab_rotation = 0.0
	_prefab_scale_factor = 1.0
	_prefab_last_list_idx = -1
	_prefab_mouse_offsets.clear()
	_prefab_base_rotations.clear()
	_prefab_base_scales.clear()
	if _tool_lists.has("_prefab_known_ids"):
		_tool_lists["_prefab_known_ids"].clear()


func _prefab_clear_preview():
	_prefab_reset_transform()
	if not _g.Editor or not _g.Editor.Tools:
		return
	if not _g.Editor.Tools.has("PrefabTool"):
		return
	var pt = _g.Editor.Tools["PrefabTool"]
	var preview = pt.get("preview")
	if preview != null and typeof(preview) == TYPE_DICTIONARY and preview.size() > 0:
		pt.Forget()


# ==================== FIND HOVERED CONTROLS ====================

func _get_hovered_item_list(mouse_pos):
	var root = input_listener.get_tree().root
	if root:
		return _find_hovered_control(root, mouse_pos, "ItemList")
	return null


func _get_hovered_option_button(mouse_pos):
	var root = input_listener.get_tree().root
	if root:
		return _find_hovered_control(root, mouse_pos, "OptionButton")
	return null


func _find_hovered_control(node, mouse_pos, target_class: String):
	if node is CanvasItem and not node.is_visible_in_tree():
		return null
	if node.get_class() == target_class and node is CanvasItem and node.is_visible_in_tree():
		var rect = node.get_global_rect()
		if rect.has_point(mouse_pos):
			return node
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		if child is Control or child.get_child_count() > 0:
			var found = _find_hovered_control(child, mouse_pos, target_class)
			if found:
				return found
	return null


# ==================== TOOL PANEL ITEMLIST CACHE ====================

func _get_tool_item_list(tool_name: String):
	if _tool_lists.has(tool_name):
		var cached = _tool_lists[tool_name]
		if cached and is_instance_valid(cached) and cached.is_visible_in_tree() and cached.get_item_count() > 0:
			return cached
		_tool_lists.erase(tool_name)
	
	var result = _find_tool_list(tool_name)
	if result:
		_tool_lists[tool_name] = result
	return result


func _find_tool_list(tool_name: String):
	# ObjectTool / PathTool: asset list is in a separate library panel
	if tool_name == "ObjectTool" or tool_name == "PathTool":
		return _find_library_list(tool_name)
	
	# PrefabTool: use API-provided list
	if tool_name == "PrefabTool":
		if _g.Editor.Tools.has("PrefabTool"):
			var pt = _g.Editor.Tools["PrefabTool"]
			if pt.list and is_instance_valid(pt.list):
				return pt.list
		return null
	
	# Other tools: search the tool panel
	var panel = _g.Editor.Toolset.GetToolPanel(tool_name)
	if panel == null:
		return null
	
	var all_lists = []
	_find_all_item_lists(panel, all_lists)
	
	var asset_lists = []
	for il in all_lists:
		if not _is_color_list(il) and il.is_visible_in_tree():
			asset_lists.append(il)
	
	if asset_lists.size() == 0:
		return null
	
	return asset_lists[asset_lists.size() - 1]


func _find_library_list(tool_name: String):
	var root = input_listener.get_tree().root
	if root == null:
		return null
	
	var tool_panel = _g.Editor.Toolset.GetToolPanel(tool_name)
	
	var all_lists = []
	_find_all_visible_item_lists(root, all_lists)
	
	var candidates = []
	for il in all_lists:
		if _is_color_list(il):
			continue
		if tool_panel and _is_descendant_of(il, tool_panel):
			continue
		if il.get_item_count() > 0:
			candidates.append(il)
	
	if candidates.size() == 0:
		return null
	
	var best = candidates[0]
	for c in candidates:
		if c.get_item_count() > best.get_item_count():
			best = c
	return best


func _is_descendant_of(node, ancestor) -> bool:
	var p = node.get_parent()
	while p:
		if p == ancestor:
			return true
		p = p.get_parent()
	return false


func _find_all_visible_item_lists(node, result):
	if not is_instance_valid(node):
		return
	if node is CanvasItem and not node.is_visible_in_tree():
		return
	if node is ItemList and node.is_visible_in_tree():
		result.append(node)
	for child in node.get_children():
		# ItemLists only ever live in the UI, never under the map. Skipping
		# nested Viewports (the map lives in one) avoids walking every node on
		# the map each scan. NB: we must not skip the root Viewport itself —
		# get_tree().root IS a Viewport, so the guard goes on CHILDREN only.
		if child is Viewport:
			continue
		_find_all_visible_item_lists(child, result)


func _find_all_item_lists(node, result):
	if node is ItemList:
		result.append(node)
	for child in node.get_children():
		if is_instance_valid(child):
			_find_all_item_lists(child, result)


# ==================== FILTERS ====================

func _is_color_list(item_list: ItemList) -> bool:
	if item_list.get_item_count() == 0:
		return false
	var icon = item_list.get_item_icon(0)
	if icon == null:
		return false
	var path = icon.resource_path
	if "color_preview" in path or "color_add" in path:
		return true
	return false
