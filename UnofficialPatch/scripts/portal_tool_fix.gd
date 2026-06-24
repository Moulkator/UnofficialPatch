# portal_tool_fix.gd
# Loaded dynamically by Core.gd
#
# Fixes two bugs in the Portal Tool caused by the X portal (index 0, null.png)
# triggering a C# crash in Infobar.SetAssetInfo('') → KeyNotFoundException.
#
# Also adds "Above Walls" feature for freestanding portals:
# - Toggle in PortalTool panel (visible only in freestanding mode)
# - When ON, newly placed freestanding portals render above walls
# - Per-portal z_index (150) puts them above Walls (z=600) since Portals parent is z=500

var _g  # Global, passed by Core.gd

var _portal_tool = null
var _texture_menu = null
var _null_texture = null
var _safe_texture = null
var _tool_panel = null

var _original_target = null
var _original_method = ""

var _x_was_selected = false
var _timer = null
var _last_tool_panel_visible = false

# Above Walls feature
var _anchored_btn = null
var _above_walls_btn = null
var _above_walls_new = false  # Apply to NEW portals being placed
var _last_portal_count = -1    # -1 = not initialized yet
const ABOVE_WALLS_Z = 150     # 500 + 150 = 650 > Walls 600

# Save/load above walls data per map
var _save_path = "user://UnofficialPatch/bugfixes_portal_z.json"
var _last_map_path = ""
var _old_map_key = ""
var _applied_load = false
var _last_level_count = 0

# Clipboard z_index tracking for copy/paste
var _clipboard_z_indices = []
var _pending_save = false
var _save_delay = 0
var _select_hide_countdown := 0

const CHECK_INTERVAL = 0.15

# SelectTool Above Walls button
var _select_tool = null
var _select_panel = null
var _select_portal_vbox = null
var _select_above_btn = null
var _select_rotate_btn = null
var _selected_portals = []

func initialize():
	_portal_tool = _g.Editor.Tools["PortalTool"]
	if _portal_tool == null:
		print("[PortalToolFix] ERROR: PortalTool not found")
		return
	
	_texture_menu = _portal_tool.textureMenu
	if _texture_menu == null:
		print("[PortalToolFix] ERROR: textureMenu not found")
		return
	
	# Get the ToolPanel for visibility tracking
	var toolset = _g.Editor.get("Toolset")
	if toolset != null and toolset.has_method("GetToolPanel"):
		_tool_panel = toolset.GetToolPanel("PortalTool")
	
	# Store textures
	if _texture_menu.get_item_count() > 0:
		_null_texture = _texture_menu.get_item_icon(0)
	if _texture_menu.get_item_count() > 1:
		var meta1 = _texture_menu.get_item_metadata(1)
		if meta1 != null and meta1 is String and meta1 != "":
			_safe_texture = ResourceLoader.load(meta1)
		if _safe_texture == null:
			_safe_texture = _texture_menu.get_item_icon(1)
	
	# Disconnect the original C# handler that crashes on index 0
	var conns = _texture_menu.get_signal_connection_list("item_selected")
	for c in conns:
		if c["method"] == "OnItemSelected":
			_original_target = c["target"]
			_original_method = c["method"]
			_texture_menu.disconnect("item_selected", _original_target, _original_method)
			break
	
	# Connect our interceptor
	_texture_menu.connect("item_selected", self, "_on_portal_item_selected")
	
	# Timer to detect tool switching and new portal placement
	_timer = Timer.new()
	_timer.wait_time = CHECK_INTERVAL
	_timer.autostart = true
	_timer.connect("timeout", self, "_tick")
	_g.Editor.add_child(_timer)
	
	_last_tool_panel_visible = _is_portal_tool_active()
	
	print("[PortalToolFix] initialized (safe_texture=" + str(_safe_texture) + ")")

	# --- Above Walls button ---
	if _tool_panel != null:
		var align = _tool_panel.get_node("Align")
		if align != null:
			for child in align.get_children():
				if child is Button and child.text == "ANCHORED":
					_anchored_btn = child
					break
	if _anchored_btn != null:
		_above_walls_btn = CheckButton.new()
		_above_walls_btn.text = "Above Walls"
		_above_walls_btn.visible = false
		_above_walls_btn.connect("toggled", self, "_on_above_walls_toggled")
		var align2 = _anchored_btn.get_parent()
		var idx = _anchored_btn.get_index()
		align2.add_child(_above_walls_btn)
		align2.move_child(_above_walls_btn, idx + 1)
		# Load saved setting
		var cfg_path = "user://UnofficialPatch/bugfixes_above_walls.cfg"
		var f = File.new()
		if f.file_exists(cfg_path):
			f.open(cfg_path, File.READ)
			var data = parse_json(f.get_as_text())
			f.close()
			if data != null and data is Dictionary and data.has("above_walls"):
				_above_walls_new = data["above_walls"]
				_above_walls_btn.pressed = _above_walls_new
		if _anchored_btn.toggle_mode:
			_anchored_btn.connect("toggled", self, "_on_anchored_toggled")
			_above_walls_btn.visible = _anchored_btn.pressed
		print("[PortalToolFix] Above Walls button added")

	# --- SelectTool Above Walls button ---
	_select_tool = _g.Editor.Tools["SelectTool"]
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if _select_panel != null:
		var sel_align = null
		for child in _select_panel.get_children():
			if child is VBoxContainer and child.name == "Align":
				sel_align = child
				break
		if sel_align != null:
			# Find the portal context VBox (first child is a Button with text BLOCK_LIGHT)
			var found_sep = false
			for child in sel_align.get_children():
				if child is HSeparator:
					found_sep = true
				elif child is VBoxContainer and found_sep:
					for gc in child.get_children():
						if gc is Button and gc.text == "BLOCK_LIGHT":
							_select_portal_vbox = child
							break
					if _select_portal_vbox != null:
						break
		if _select_portal_vbox != null:
			_select_rotate_btn = CheckButton.new()
			_select_rotate_btn.text = "Rotate 180"
			_select_rotate_btn.visible = false
			_select_rotate_btn.connect("toggled", self, "_on_select_rotate_180_toggled")
			_select_portal_vbox.add_child(_select_rotate_btn)
			_select_portal_vbox.move_child(_select_rotate_btn, 0)

			_select_above_btn = CheckButton.new()
			_select_above_btn.text = "Above Walls"
			_select_above_btn.visible = false
			_select_above_btn.connect("toggled", self, "_on_select_above_walls_toggled")
			_select_portal_vbox.add_child(_select_above_btn)
			_select_portal_vbox.move_child(_select_above_btn, 1)

			print("[PortalToolFix] Above Walls + Rotate 180 buttons added to SelectTool")
		else:
			print("[PortalToolFix] WARNING: _select_portal_vbox not found — dumping sel_align children:")
			if sel_align != null:
				for child in sel_align.get_children():
					print("  child: ", child.get_class(), " name=", child.name, " type=", child.get_class())


func _is_portal_tool_active():
	if _tool_panel != null and _tool_panel is Node:
		return _tool_panel.visible
	return false


func _is_null_texture_active():
	var tex = _portal_tool.get("Texture")
	if tex == null:
		return false
	if tex == _null_texture:
		return true
	if tex is Texture and tex.resource_path == "res://textures/ui/null.png":
		return true
	return false


func _tick():
	var visible_now = _is_portal_tool_active()
	
	if _last_tool_panel_visible and not visible_now:
		if _is_null_texture_active():
			_x_was_selected = true
			_portal_tool.set("texture", _safe_texture)
	
	elif not _last_tool_panel_visible and visible_now:
		if _x_was_selected:
			_x_was_selected = false
			call_deferred("_restore_x_selection")
	
	_last_tool_panel_visible = visible_now
	
	# Monitor for newly placed or pasted portals
	_check_new_portals()
	
	# Monitor SelectTool for portal selection
	_update_select_above_walls()
	
	# Detect map change and load saved z_index data
	_check_map_change()
	
	# Detect level clone
	_check_level_clone()
	
	# Process delayed save
	if _pending_save:
		_save_delay -= 1
		if _save_delay <= 0:
			_pending_save = false
			_save_portal_z_data()


func _check_new_portals():
	var world = _g.World
	if world == null:
		return
	var level = world.Level
	if level == null:
		return
	var portals_node = level.get("Portals")
	if portals_node == null:
		return
	var count = portals_node.get_child_count()
	if _last_portal_count == -1:
		# First call — just init, don't treat existing portals as new
		_last_portal_count = count
		return
	if count > _last_portal_count:
		var new_count = count - _last_portal_count
		var changed = false
		# Collect new freestanding portals
		var new_portals = []
		var i = _last_portal_count
		while i < count:
			var portal = portals_node.get_child(i)
			if is_instance_valid(portal):
				var wall_id = portal.get("WallID")
				if wall_id != null and wall_id == -1:
					new_portals.append(portal)
			i += 1
		if new_portals.size() > 0:
			if _above_walls_new and _is_portal_tool_active():
				# Placing new portals with Above Walls on
				for portal in new_portals:
					portal.z_index = ABOVE_WALLS_Z
					changed = true
			elif _clipboard_z_indices.size() > 0:
				# Paste — apply clipboard z_indices to new portals in order
				var ci = 0
				for portal in new_portals:
					if ci < _clipboard_z_indices.size():
						portal.z_index = _clipboard_z_indices[ci]
						ci += 1
						changed = true
			else:
				# Check saved data for position matches
				var saved = _get_saved_portal_data()
				if saved.size() > 0:
					for portal in new_portals:
						var pkey = _portal_pos_key(portal)
						if saved.has(pkey):
							var entry = saved[pkey]
							if entry is Dictionary:
								portal.z_index = int(entry.get("z", 0))
								if entry.has("rot"):
									portal.rotation = float(entry["rot"])
							else:
								portal.z_index = int(entry)
							changed = true
		if changed:
			# Delay save to let portal positions settle after paste
			_pending_save = true
			_save_delay = 10  # ~10 ticks (1.5s)
	_last_portal_count = count


func _get_saved_portal_data():
	var key = _get_map_key()
	if key == "":
		return {}
	var all_data = _load_all_data()
	if all_data.has(key):
		return all_data[key]
	return {}


func _restore_x_selection():
	_portal_tool.set("texture", _null_texture)
	_portal_tool.ChangeTexture(_null_texture, "Texture")
	_texture_menu.select(0)
	call_deferred("_fix_null_portal_preview")


func _on_portal_item_selected(index):
	if index == 0:
		_x_was_selected = false
		_portal_tool.set("texture", _null_texture)
		_portal_tool.ChangeTexture(_null_texture, "Texture")
		call_deferred("_fix_null_portal_preview")
	else:
		_x_was_selected = false
		if _original_target != null:
			_original_target.call(_original_method, index)


func _fix_null_portal_preview():
	var wui_tex = _g.WorldUI.get("Texture")
	if wui_tex == null:
		return
	wui_tex.Texture = _null_texture


# --- Above Walls feature ---

func _on_anchored_toggled(pressed):
	# pressed=true = freestanding mode active
	_above_walls_btn.visible = pressed
	_update_portal_count()


func _on_above_walls_toggled(pressed):
	_above_walls_new = pressed
	var f = File.new()
	f.open("user://UnofficialPatch/bugfixes_above_walls.cfg", File.WRITE)
	f.store_string(to_json({"above_walls": _above_walls_new}))
	f.close()
	_update_portal_count()


func _update_portal_count():
	var world = _g.World
	if world == null:
		return
	var level = world.Level
	if level == null:
		return
	var portals_node = level.get("Portals")
	if portals_node == null:
		return
	_last_portal_count = portals_node.get_child_count()


# --- SelectTool Above Walls ---

func _update_select_above_walls():
	if _select_above_btn == null or _select_panel == null:
		return
	if not _select_panel.visible:
		_selected_portals = []
		return
	# Check if portal context is visible — grace period to avoid flicker during transforms
	if _select_portal_vbox == null or not _select_portal_vbox.visible:
		_select_hide_countdown -= 1
		if _select_hide_countdown <= 0 and _selected_portals.size() == 0:
			_select_above_btn.visible = false
			if _select_rotate_btn != null: _select_rotate_btn.visible = false
		return
	# Find ALL selected portals
	var selectables = _select_tool.get("Selectables")
	if selectables == null or not (selectables is Dictionary) or selectables.size() == 0:
		_select_hide_countdown -= 1
		if _select_hide_countdown <= 0 and _selected_portals.size() == 0:
			_select_above_btn.visible = false
			if _select_rotate_btn != null: _select_rotate_btn.visible = false
		return
	var fs_portals = []
	var all_portals = []
	var keys = selectables.keys()
	for key in keys:
		if key is Node and is_instance_valid(key):
			var wall_id = key.get("WallID")
			if wall_id != null:  # has WallID = is a portal
				all_portals.append(key)
				if wall_id == -1:
					fs_portals.append(key)
	if all_portals.size() > 0:
		_selected_portals = all_portals
		_select_hide_countdown = 4  # reset grace period
		# Determine button state: ON if all are above, OFF otherwise
		var all_above = true
		for portal in fs_portals:
			if portal.z_index != ABOVE_WALLS_Z:
				all_above = false
				break
		# "Above Walls" n'a de sens que pour les portals freestanding.
		# Si la sélection ne contient que des portals anchored, cacher le bouton.
		var has_freestanding = fs_portals.size() > 0
		# Update button without triggering signal
		if _select_above_btn.is_connected("toggled", self, "_on_select_above_walls_toggled"):
			_select_above_btn.disconnect("toggled", self, "_on_select_above_walls_toggled")
		_select_above_btn.pressed = all_above
		_select_above_btn.connect("toggled", self, "_on_select_above_walls_toggled")
		_select_above_btn.visible = has_freestanding
		if _select_rotate_btn != null:
			# ON si le portal a un décalage de ~180° par rapport à sa rotation naturelle sur le mur
			var portal = _selected_portals[0]
			var is_rotated = _portal_is_rotated_180(portal)
			if _select_rotate_btn.is_connected("toggled", self, "_on_select_rotate_180_toggled"):
				_select_rotate_btn.disconnect("toggled", self, "_on_select_rotate_180_toggled")
			_select_rotate_btn.pressed = is_rotated
			_select_rotate_btn.connect("toggled", self, "_on_select_rotate_180_toggled")
			_select_rotate_btn.visible = true
		# Update clipboard only when selection has portal(s) with above-walls
		# Don't overwrite if we already have values (preserve for paste)
		var has_above = false
		for portal in fs_portals:
			if portal.z_index == ABOVE_WALLS_Z:
				has_above = true
				break
		if has_above:
			_clipboard_z_indices = []
			for key in keys:
				if key is Node and is_instance_valid(key):
					var pp = key.get_parent()
					if pp != null and str(pp.name) == "Portals":
						_clipboard_z_indices.append(key.z_index)
	else:
		_select_hide_countdown -= 1
		if _select_hide_countdown <= 0:
			_select_above_btn.visible = false
			if _select_rotate_btn != null: _select_rotate_btn.visible = false
			_selected_portals = []


func _portal_is_rotated_180(portal) -> bool:
	# Pour un portal ancré à un mur, la rotation naturelle est celle du segment de mur.
	# On compare la rotation actuelle à cette référence.
	var wall_id = portal.get("WallID")
	if wall_id == null or wall_id == -1:
		# Freestanding : rotation naturelle = 0
		var rot_mod = fmod(portal.rotation + PI * 4, PI * 2)
		return rot_mod > PI * 0.5 and rot_mod < PI * 1.5
	# Ancré : lit WallPointIndex et cherche la direction du segment
	var wall = _find_wall_by_id(wall_id)
	if wall == null:
		# Fallback si wall non trouvé
		var rot_mod = fmod(portal.rotation + PI * 4, PI * 2)
		return rot_mod > PI * 0.5 and rot_mod < PI * 1.5
	var points = wall.get("Points")
	var idx = portal.get("WallPointIndex")
	if points == null or idx == null or idx >= points.size() - 1:
		return false
	var seg_dir = (points[idx + 1] - points[idx]).normalized()
	var arc_rot = atan2(seg_dir.y, seg_dir.x)
	var diff = fmod(portal.rotation - arc_rot + PI * 4, PI * 2)
	return diff > PI * 0.5 and diff < PI * 1.5


func _find_wall_by_id(wall_id) -> Node:
	var level = _g.World.GetCurrentLevel()
	if level == null: return null
	var walls = level.get("Walls")
	if walls == null: return null
	for wall in walls.get_children():
		if wall.get_instance_id() == wall_id:
			return wall
	return null


func _on_select_above_walls_toggled(pressed):
	if _selected_portals.size() == 0:
		return
	
	# Capture each portal's current z_index before we mutate. Stored as
	# WeakRefs so a deleted portal just gets skipped at undo time rather
	# than crashing. z_index is a plain int property on Node2D, no quirks.
	var before_states: Array = []
	for portal in _selected_portals:
		if is_instance_valid(portal):
			before_states.append({
				"ref": weakref(portal),
				"z_index": portal.z_index,
			})
	
	for portal in _selected_portals:
		if is_instance_valid(portal):
			portal.z_index = ABOVE_WALLS_Z if pressed else 0
	
	# Capture after state for the redo side of the record.
	var after_states: Array = []
	for entry in before_states:
		var portal = entry["ref"].get_ref()
		if portal == null or not is_instance_valid(portal):
			continue
		after_states.append({
			"ref": entry["ref"],
			"z_index": portal.z_index,
		})
	
	_record_above_walls_change(before_states, after_states)
	
	_pending_save = true
	_save_delay = 2


func _record_above_walls_change(before: Array, after: Array) -> void:
	if before.empty() or after.empty() or before.size() != after.size():
		return
	var changed := false
	for i in range(before.size()):
		if before[i]["z_index"] != after[i]["z_index"]:
			changed = true
			break
	if not changed:
		return
	var undo = null
	if _g != null and _g.get("ModMapData") != null:
		undo = _g.ModMapData.get("_undo_lib")
	if undo == null:
		return
	undo.record_callback(
		self, "_restore_above_walls_states", [before],
		self, "_restore_above_walls_states", [after])


func _restore_above_walls_states(states: Array) -> void:
	for entry in states:
		var portal = entry["ref"].get_ref()
		if portal == null or not is_instance_valid(portal):
			continue
		portal.z_index = entry["z_index"]
	# Schedule a save so the JSON picks up the restored state.
	_pending_save = true
	_save_delay = 2


func _on_select_rotate_180_toggled(pressed):
	if _selected_portals.size() == 0:
		return
	var saved = _selected_portals.duplicate()
	
	# Les portals sont déjà sélectionnés dans SelectTool (sinon ce bouton
	# n'aurait pas été affiché). undo_lib.begin_transform() appelle
	# SavePreTransforms() qui capture leur rotation actuelle, puis
	# commit_transform() appelle RecordTransforms() qui crée le record
	# DD pour Ctrl+Z.
	var undo = null
	if _g != null and _g.get("ModMapData") != null:
		undo = _g.ModMapData.get("_undo_lib")
	var have_undo = undo != null and undo.begin_transform()
	
	for portal in saved:
		if is_instance_valid(portal):
			portal.rotation = portal.rotation + PI if pressed else portal.rotation - PI
	
	if have_undo:
		undo.commit_transform()
	
	_select_hide_countdown = 4
	call_deferred("_restore_selection", saved)
	_pending_save = true
	_save_delay = 2


func _restore_selection(portals: Array) -> void:
	if _select_tool == null: return
	# DeselectAll d'abord : SelectThing(thing, true) est additif, pas idempotent.
	# Les portals sont encore sélectionnés après _on_select_rotate_180_toggled
	# (modifier portal.rotation ne déselectionne pas), donc les re-SelectThing
	# sans wipe crée des doublons dans RawSelectables, ce qui fait crasher
	# SelectTool.get_Selectables() en C# (ToDictionary : clé dupliquée).
	if _select_tool.has_method("DeselectAll"):
		_select_tool.call("DeselectAll")
	for portal in portals:
		if is_instance_valid(portal):
			_select_tool.call("SelectThing", portal, true)
	if portals.size() > 0:
		_selected_portals = portals.duplicate()
		_select_hide_countdown = 4


# --- Save/Load portal above-walls data ---

func _get_map_key():
	# Try Header methods to get save path
	var header = _g.Header
	if header != null:
		if header.has_method("get_SavePath"):
			var sp = header.get_SavePath()
			if sp != null and str(sp) != "Null" and str(sp) != "":
				return str(sp)
		if header.has_method("GetSavePath"):
			var sp = header.GetSavePath()
			if sp != null and str(sp) != "Null" and str(sp) != "":
				return str(sp)
	# Try the map title from Header
	if header != null:
		if header.has_method("get_Title"):
			var t = header.get_Title()
			if t != null and str(t) != "Null" and str(t) != "":
				return str(t)
	# Fallback: use first level label
	var world = _g.World
	if world == null:
		return ""
	var all_levels = world.get_AllLevels()
	if all_levels == null or all_levels.size() == 0:
		return ""
	var first = all_levels[0]
	if is_instance_valid(first):
		return str(first.Label)
	return ""


func _check_map_change():
	var key = _get_map_key()
	if key == "":
		return
	if key == _last_map_path:
		return
	var old_key = _last_map_path
	_last_map_path = key
	# Init level count
	var world = _g.World
	if world != null:
		var all_levels = world.get_AllLevels()
		if all_levels != null:
			_last_level_count = all_levels.size()
	if old_key == "":
		# First load
		_applied_load = false
		call_deferred("_load_portal_z_data")
	else:
		# Key changed — could be level clone changing the first label
		# Try to load with new key; if not found, try old key
		_applied_load = false
		_old_map_key = old_key
		call_deferred("_load_portal_z_data")


func _check_level_clone():
	var world = _g.World
	if world == null:
		return
	var all_levels = world.get_AllLevels()
	if all_levels == null:
		return
	var lc = all_levels.size()
	if lc > _last_level_count and _last_level_count > 0:
		# New level(s) appeared — find positions of above-walls portals on existing levels
		var above_positions = {}
		for lvl in all_levels:
			if not is_instance_valid(lvl):
				continue
			var portals_node = lvl.get("Portals")
			if portals_node == null:
				continue
			for portal in portals_node.get_children():
				if not is_instance_valid(portal):
					continue
				if portal.z_index == ABOVE_WALLS_Z:
					var poskey = _portal_pos_only(portal)
					above_positions[poskey] = true
		# Now apply to portals that match position but don't have the z_index yet
		if above_positions.size() > 0:
			var count = 0
			for lvl in all_levels:
				if not is_instance_valid(lvl):
					continue
				var portals_node = lvl.get("Portals")
				if portals_node == null:
					continue
				for portal in portals_node.get_children():
					if not is_instance_valid(portal):
						continue
					if portal.z_index != ABOVE_WALLS_Z:
						var poskey = _portal_pos_only(portal)
						if above_positions.has(poskey):
							portal.z_index = ABOVE_WALLS_Z
							count += 1
			if count > 0:
				print("[PortalToolFix] Applied above-walls to " + str(count) + " portal(s) on cloned level")
				_pending_save = true
				_save_delay = 5
	_last_level_count = lc


func _portal_pos_key(portal):
	# Use rounded position only - level IDs change between sessions
	var pos = portal.global_position
	return str(int(round(pos.x))) + "," + str(int(round(pos.y)))


func _portal_pos_only(portal):
	# Alias for clone matching (same as _portal_pos_key now)
	return _portal_pos_key(portal)


func _save_portal_z_data():
	var key = _get_map_key()
	if key == "": return
	var world = _g.World
	if world == null: return
	var portal_data = {}
	var all_levels = world.get_AllLevels()
	if all_levels == null: return
	for level in all_levels:
		if not is_instance_valid(level): continue
		var portals_node = level.get("Portals")
		if portals_node == null: continue
		for portal in portals_node.get_children():
			if not is_instance_valid(portal): continue
			var wall_id = portal.get("WallID")
			if wall_id == null or wall_id != -1: continue  # freestanding only
			var has_data = portal.z_index == ABOVE_WALLS_Z
			# Store rotation if it's not a multiple of 2*PI (i.e. was rotated)
			var rot_mod = fmod(abs(portal.rotation), PI * 2)
			var is_rotated = rot_mod > 0.01 and rot_mod < PI * 2 - 0.01
			if has_data or is_rotated:
				var pkey = _portal_pos_key(portal)
				portal_data[pkey] = {
					"z": portal.z_index,
					"rot": portal.rotation
				}
	var all_data = _load_all_data()
	if portal_data.size() > 0:
		all_data[key] = portal_data
	else:
		all_data.erase(key)
	var f = File.new()
	f.open(_save_path, File.WRITE)
	f.store_string(to_json(all_data))
	f.close()


func _load_portal_z_data():
	if _applied_load:
		return
	_applied_load = true
	var key = _get_map_key()
	if key == "":
		return
	var all_data = _load_all_data()
	var portal_data = null
	# If we have an old key (from before level clone changed the key), prefer it
	if _old_map_key != "" and all_data.has(_old_map_key):
		portal_data = all_data[_old_map_key]
		all_data[key] = portal_data
		var ff = File.new()
		ff.open(_save_path, File.WRITE)
		ff.store_string(to_json(all_data))
		ff.close()
	elif all_data.has(key):
		portal_data = all_data[key]
	else:
		return
	_old_map_key = ""
	var world = _g.World
	if world == null:
		return
	var count = 0
	var all_levels = world.get_AllLevels()
	if all_levels == null:
		return
	for level in all_levels:
		if not is_instance_valid(level):
			continue
		var portals_node = level.get("Portals")
		if portals_node == null:
			continue
		for portal in portals_node.get_children():
			if not is_instance_valid(portal):
				continue
			var pkey = _portal_pos_key(portal)
			if portal_data.has(pkey):
				var entry = portal_data[pkey]
				if entry is Dictionary:
					portal.z_index = int(entry.get("z", 0))
					if entry.has("rot"):
						portal.rotation = float(entry["rot"])
				else:
					# Old format: just z_index
					portal.z_index = int(entry)
				count += 1
	if count > 0:
		print("[PortalToolFix] Restored above-walls for " + str(count) + " portal(s)")
	# Re-save under current key to keep positions up to date
	if count > 0:
		_pending_save = true
		_save_delay = 3


func _load_all_data():
	var f = File.new()
	if not f.file_exists(_save_path):
		return {}
	f.open(_save_path, File.READ)
	var text = f.get_as_text()
	f.close()
	var data = parse_json(text)
	if data != null and data is Dictionary:
		return data
	return {}
