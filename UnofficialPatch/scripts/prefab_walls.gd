# prefab_walls.gd
# Sub-mod -- Walls & portals in prefabs.
#
# Vanilla DD drops walls when a prefab is made: SelectTool.Serialize() has no
# case for SelectableType.Wall and Level.Deserialize() has no "walls" section.
# Portals anchored to a wall are children of that wall, so they are lost too
# (freestanding portals already work, they go through SelectableType.PortalFree).
#
# What this mod does:
#   1. SAVE  -- right after DD wrote the .dungeondraft_prefab file, appends a
#      "walls" section to it. Unknown keys are ignored by Deserialize(), so an
#      enriched prefab stays fully readable by vanilla DD (and by DD without
#      this mod), and prefabs made without the mod keep working here.
#   2. PREVIEW -- a ghost (Line2D per wall + Sprite per portal) parented to
#      WorldUI follows the cursor next to DD's own preview. No real Wall node
#      exists before the click, so an unplaced preview can never end up in a
#      saved map.
#   3. PLACE -- on the confirming click, real walls are created through
#      Walls.AddWall() / Wall.AddPortal() (the same path clipboard_fix uses for
#      wall paste, which is known to survive save/reload/delete), plus our own
#      history record.
#
# Anchoring
# ---------
# DD re-centres its preview on every mouse motion:
#     translation = World.UI.SnappedPosition - GetSelectionRect(preview).GetCenter()
# so the preview centre IS SnappedPosition. The ghost therefore only needs to
# sit at SnappedPosition + (points - anchor), where `anchor` is that very same
# rect centre, computed once at save time from the live selection.
#
# One subtlety: GetSelectionRect() measures the *preview* nodes. A preview Prop
# is never selected, so its SpriteWidget.Rect is still Rect2(0,0,0,0) (that Rect
# is only assigned in SpriteWidget.OnChange(), i.e. on Highlight/Select) and the
# object contributes nothing but its Position. _anchor_of_selection() reproduces
# that on purpose -- using the live (selected, padded) widget rect instead would
# shift the ghost.
#
# Undo
# ----
# DD records its own MultiRecord for the non-wall part, we record ours for the
# walls, so a mixed prefab takes two Ctrl+Z (walls first). Both records go
# through Editor.History, so the UI's UNDO button behaves identically.

var _g
var ui_util

const GHOST_NODE_NAME := "PrefabWallsGhost"
# Cle ecrite dans Global.ModMapData, que Save.Serialize() sort sous "mod".
const MAP_DATA_KEY := "prefab_walls_groups"
const MAX_LEVELS := 64
const MIN_REPLACE_SQR_DISTANCE := 256.0   # mirrors PrefabTool.minSqrDistance

# SelectableType (see SelectableType.cs)
const SEL_WALL := 1
const SEL_PORTAL_FREE := 2
const SEL_PORTAL_WALL := 3
const SEL_OBJECT := 4
const SEL_PATHWAY := 5
const SEL_LIGHT := 6
const SEL_PATTERN_SHAPE := 7
const SEL_ROOF := 8

var select_tool = null
var prefab_tool = null

# --- Panel discovery ---
var _panel = null
var _item_list = null
var _set_option = null
var _panel_attempts := 0

# --- SelectTool side (Make Prefab button) ---
var _select_panel = null
var _prefab_button = null

# --- MakePrefab window watch ---
# The window is polled instead of hooked: nothing of ours stays connected to a
# node that outlives this mod instance (the suite is re-instantiated on every
# map load), and no stale node reference is kept between frames.
var _window = null
var _window_visible := false
var _window_open_time := 0
var _pending_walls := []
var _pending_anchor := Vector2.ZERO
var _pending_has_anchor := false
var _pending_save = null      # {set, name, since, frames}

# --- Ghost state ---
var _restore_ticks := 0
var _restored_total := 0
var _ghost: Node2D = null
var _ghost_data = null        # {walls: Array, anchor: Vector2}
var _current_key := ""
var _tex_cache := {}
var _wall_material = null
var _wall_material_looked_up := false

# --- Placement state ---
var _has_placed := false
var _last_place_pos := Vector2.ZERO
var _lmb_down := false

# --- Prefab group tracking ---
# DD tags the preview nodes it builds in PrefabTool.Instance() with the
# prefab_id it just allocated. Watching the containers grow is the only
# reliable way to tell those nodes apart from everything already on the map.
# Rotation / scale published by asset_cycle (scroll = rotate, alt+scroll =
# scale, right-click = +90 deg). Walls follow the rotation like everything else,
# but the scale only spreads their points apart: the texture width stays put and
# the portals keep their own size, which is how a wall resize behaves in DD.
var _tf_rotation := 0.0
var _tf_scale := 1.0
var _tf_active := false
var _tf_capture_mouse := Vector2.ZERO
var _tf_capture_snapped := Vector2.ZERO
var _tf_capture_centroid := Vector2.ZERO
var _tf_capture_count := 0
var _ghost_lines := []      # [{node, base_local}]
var _ghost_portals := []    # [{node, base_local}]
var _ghost_applied_scale := 1.0

var _preview_group_id := ""
var _container_counts := {}
const PREVIEW_CONTAINERS := ["Objects", "Pathways", "Roofs", "Lights", "Portals"]

var _tick := 0

# The whole suite is re-instantiated on every map load, and an older instance
# can still be ticked afterwards (two "first update()" lines in the same
# session). Without this guard both instances place their own copy of the
# walls on a single click -- two stacked walls, two stacked shadows, which
# reads as "the prefab walls are darker".
var _instance_id := 0


func initialize() -> void:
	_instance_id = OS.get_ticks_usec()
	Engine.set_meta("pw_active_instance", _instance_id)
	var tools = _g.Editor.get("Tools")
	if tools != null and tools is Dictionary:
		if tools.has("SelectTool"):
			select_tool = tools["SelectTool"]
		if tools.has("PrefabTool"):
			prefab_tool = tools["PrefabTool"]
	_find_window()
	_discover_panel()
	_discover_select_panel()
	if _g.Editor != null and is_instance_valid(_g.Editor) and _g.Editor.has_signal("OnSaveBegin") \
			and not _g.Editor.is_connected("OnSaveBegin", self, "_on_save_begin"):
		_g.Editor.connect("OnSaveBegin", self, "_on_save_begin")
	print("[PrefabWalls] Initialized")


# ══════════════════════════════════════════════════════════════════════════════
# SETTINGS / HELPERS
# ══════════════════════════════════════════════════════════════════════════════

func _is_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("prefab_walls")


func _snapped_position() -> Vector2:
	if _g.get("WorldUI") == null:
		return Vector2.ZERO
	return _g.WorldUI.SnappedPosition


func _mouse_position() -> Vector2:
	if _g.get("WorldUI") == null:
		return Vector2.ZERO
	return _g.WorldUI.MousePosition


# ui_util n'est utile qu'au clic, mais il DOIT etre la : sans lui, le clic sur
# la floatbar (ou n'importe quel panneau) posait quand meme les walls, alors que
# DD ne pose rien -- son _ContentInput ne recoit pas les evenements consommes
# par l'UI. Voir _try_place pour le choix is_mouse_over_hud vs is_mouse_over_ui. Si Main.gd ne nous l'a pas injecte, on emprunte l'instance d'un
# autre sous-mod plutot que d'ignorer silencieusement la garde.
func _ui_util():
	if ui_util != null and is_instance_valid(ui_util):
		return ui_util
	if _g != null and _g.get("ModMapData") != null and _g.ModMapData is Dictionary:
		var dsw = _g.ModMapData.get("_drag_select_walls")
		if dsw != null and is_instance_valid(dsw):
			var borrowed = dsw.get("ui_util")
			if borrowed != null and is_instance_valid(borrowed):
				ui_util = borrowed
				return ui_util
	if not Engine.has_meta("pw_ui_util_warned"):
		Engine.set_meta("pw_ui_util_warned", true)
		printerr("[PrefabWalls] ui_util unavailable; clicks on UI panels cannot be filtered.")
	return null


# Fenetre au premier plan ? Hors focus, DD gele son apercu : ses objets restent
# la ou ils etaient au moment de l'alt-tab. Nous suivions le curseur malgre
# tout, donc walls et portals derivaient loin du reste du prefab et un clic les
# posait a cet endroit-la. On calque le comportement de DD.
func _window_focused() -> bool:
	if OS.has_method("is_window_focused"):
		return OS.is_window_focused()
	return true


func _is_exporting() -> bool:
	var tree = _g.World.get_tree() if _g.World != null else null
	if tree == null or tree.root == null:
		return false
	var master_node = tree.root.get_node_or_null("Master")
	if master_node == null:
		return false
	return master_node.get("IsExporting") == true


func _current_level():
	if _g == null or _g.World == null:
		return null
	return _g.World.GetCurrentLevel()


# ══════════════════════════════════════════════════════════════════════════════
# PER-FRAME
# ══════════════════════════════════════════════════════════════════════════════

func update(_delta) -> void:
	_tick += 1
	if Engine.has_meta("pw_active_instance") and Engine.get_meta("pw_active_instance") != _instance_id:
		# Superseded by a newer instance: stand down and drop our ghost.
		if _ghost != null:
			_clear_ghost()
		return

	# Per-frame path deliberately touches no C# property. The two gates below
	# are plain Godot Control reads on nodes discovered once at init: the
	# PrefabTool side panel's visibility stands in for "the PrefabTool is
	# active", and the MakePrefab dialog's own visibility drives the save side.
	_poll_group_restore()
	_poll_make_prefab_window()
	if _pending_save != null:
		_flush_pending_save()
	if (_tick % 10) == 0:
		_update_prefab_button()

	if _panel == null or not is_instance_valid(_panel):
		if (_tick % 120) == 0:
			_discover_panel()
		return
	if not _panel.visible:
		if _ghost != null:
			_clear_ghost()
		_current_key = ""
		_has_placed = false
		_lmb_down = false
		_preview_group_id = ""
		_container_counts.clear()
		return
	if not _is_enabled():
		if _ghost != null:
			_clear_ghost()
		return

	if _item_list == null or not is_instance_valid(_item_list):
		return
	var key = _current_prefab_key()
	if key != _current_key:
		_current_key = key
		_clear_ghost()
		_ghost_data = (_load_prefab_walls(key) if key != "" else null)
		_has_placed = false
		_preview_group_id = ""
		_container_counts.clear()
		if _ghost_data != null:
			_build_ghost()
	elif _ghost_data != null and (_ghost == null or not is_instance_valid(_ghost) or not _ghost.is_inside_tree()):
		# A map reload frees WorldUI, and the ghost along with it.
		_ghost = null
		_build_ghost()

	if _ghost_data != null:
		_watch_preview_group()

	_read_transform_state()

	if _ghost != null and is_instance_valid(_ghost):
		# Position figee hors focus (cf. _window_focused) : le reste --
		# rotation, echelle, visibilite -- reste synchronise, seul le suivi du
		# curseur s'arrete, exactement comme l'apercu de DD.
		if _window_focused():
			_ghost.position = _ghost_origin()
		_ghost.rotation = _tf_rotation
		if _tf_scale != _ghost_applied_scale:
			_apply_ghost_scale(_tf_scale)
		if (_tick % 30) == 0:
			_ghost.visible = not _is_exporting()

	# Placement click, polled instead of intercepted: DD's PrefabTool.Confirm()
	# runs during the input phase, so by the time this runs its own preview has
	# already been committed at the same SnappedPosition.
	var pressed = Input.is_mouse_button_pressed(BUTTON_LEFT)
	if pressed and not _lmb_down:
		_try_place()
	_lmb_down = pressed


func _try_place() -> void:
	if _ghost_data == null or _ghost_data["walls"].size() == 0:
		return
	if not _window_focused():
		return
	var uu = _ui_util()
	var ui_node = _ui_node()
	if uu != null and ui_node != null:
		# is_mouse_over_hud, PAS is_mouse_over_ui : la seconde ne connait que
		# les bords d'ecran (toolbar, panneaux lateraux, barre du bas) et la
		# floatbar flotte AU-DESSUS du canvas, loin de tout bord. La premiere
		# ajoute un hit-test direct des Controls interactifs du HUD, ce qui
		# est exactement ce cas -- elle cite d'ailleurs la floatbar.
		if uu.has_method("is_mouse_over_hud"):
			if uu.is_mouse_over_hud(ui_node):
				return
		elif uu.is_mouse_over_ui(ui_node):
			return
	# Mirror PrefabTool: after a confirm, DD only rebuilds its preview once the
	# mouse travelled far enough. A second click on the same spot places nothing
	# on its side, so it must place nothing on ours either.
	var mouse = _mouse_position()
	if _has_placed and mouse.distance_squared_to(_last_place_pos) <= MIN_REPLACE_SQR_DISTANCE:
		return
	_place_walls()
	_has_placed = true
	_last_place_pos = mouse


func _ui_node() -> Node:
	if _g == null:
		return null
	var editor = _g.get("Editor")
	if editor != null and editor is Node and is_instance_valid(editor):
		return editor
	return null


# ══════════════════════════════════════════════════════════════════════════════
# PANEL DISCOVERY
# ══════════════════════════════════════════════════════════════════════════════

func _discover_panel() -> void:
	_panel_attempts += 1
	if _panel_attempts > 20:
		return
	if _g.Editor == null or _g.Editor.get("Toolset") == null:
		return
	_panel = _g.Editor.Toolset.GetToolPanel("PrefabTool")
	if _panel == null or not is_instance_valid(_panel):
		return
	_item_list = _panel.get("itemList")
	_set_option = _panel.get("setOption")


func _current_prefab_key() -> String:
	if _item_list == null or not is_instance_valid(_item_list):
		return ""
	if _set_option == null or not is_instance_valid(_set_option):
		return ""
	var selected = _item_list.get_selected_items()
	if selected == null or selected.size() == 0:
		return ""
	var set_index = _set_option.selected
	if set_index < 0:
		return ""
	return "%s/%s" % [_set_option.get_item_text(set_index), _item_list.get_item_text(selected[0])]


# ══════════════════════════════════════════════════════════════════════════════
# MAKE PREFAB BUTTON
# ══════════════════════════════════════════════════════════════════════════════

# DD gates its Make Prefab button on HasCopyable (= the transform box being
# visible), which a walls-only selection never satisfies: walls are ours, not
# DD's. Re-enable it whenever the selection holds at least one wall.
func _discover_select_panel() -> void:
	if _g.Editor == null or _g.Editor.get("Toolset") == null:
		return
	_select_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")


func _update_prefab_button() -> void:
	if not _is_enabled():
		return
	if _select_panel == null or not is_instance_valid(_select_panel):
		return
	if not _select_panel.visible:
		return
	if _prefab_button == null or not is_instance_valid(_prefab_button):
		_prefab_button = _find_prefab_button()
		if _prefab_button == null:
			return
	if not _prefab_button.disabled:
		return
	if _selection_has_walls():
		_prefab_button.disabled = false


func _find_prefab_button():
	var direct = _select_panel.get("prefabButton")
	if direct != null and direct is BaseButton:
		return direct
	return _find_button_matching(_select_panel, "prefab", 0)


func _find_button_matching(node: Node, needle: String, depth: int):
	if node == null or depth > 8:
		return null
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is BaseButton:
			var haystack = ("%s %s %s" % [child.name, child.get("text"), child.hint_tooltip]).to_lower()
			if needle in haystack and not ("separate" in haystack):
				return child
		var found = _find_button_matching(child, needle, depth + 1)
		if found != null:
			return found
	return null


func _selection_has_walls() -> bool:
	if select_tool == null:
		return false
	var raw = select_tool.RawSelectables
	if raw == null:
		return false
	for s in raw:
		if s != null and s.Thing != null and s.Type == SEL_WALL:
			return true
	return false


# ══════════════════════════════════════════════════════════════════════════════
# SAVE SIDE -- MakePrefab hook
# ══════════════════════════════════════════════════════════════════════════════

# Resolved once at init; afterwards only its `visible` flag is read, which is a
# plain Control property (no signal is connected to it, so nothing of ours is
# left behind on a node that outlives this mod instance).
func _find_window() -> void:
	if _g == null or _g.Editor == null:
		return
	var windows = _g.Editor.get("Windows")
	if windows == null or not (windows is Dictionary) or not windows.has("MakePrefab"):
		return
	var w = windows["MakePrefab"]
	if w == null or not is_instance_valid(w) or not (w is Popup):
		return
	_window = w


func _poll_make_prefab_window() -> void:
	var w = _window
	if w == null or not is_instance_valid(w):
		# Editor.Windows is not always populated when the mod initializes
		# (ExportTraceImage hits the same thing with the Export dialog), so
		# keep retrying until the dialog shows up.
		if (_tick % 60) == 0:
			_find_window()
		return
	var visible_now = w.visible
	if visible_now and not _window_visible:
		_on_window_opened()
	elif not visible_now and _window_visible:
		_on_window_closed(w)
	_window_visible = visible_now


# The modal is up, so the selection cannot change any more: snapshot it now.
func _on_window_opened() -> void:
	_pending_walls = []
	_pending_anchor = Vector2.ZERO
	_pending_has_anchor = false
	_window_open_time = OS.get_unix_time()
	if not _is_enabled() or select_tool == null:
		return
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	# DD serializes a selection in HashSet order, which is roughly selection
	# order: recreating from it would stack the last-picked wall on top. Sort by
	# sibling index instead (ascending = bottom to top, DD's own stacking model,
	# the same fix clipboard_fix applies to copy/paste).
	var wall_nodes := []
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if s.Type == SEL_WALL and is_instance_valid(s.Thing):
			wall_nodes.append(s.Thing)
	if wall_nodes.size() == 0:
		return
	wall_nodes.sort_custom(self, "_sort_by_child_index")
	for w in wall_nodes:
		_pending_walls.append(_snapshot_wall(w))
	if _pending_walls.size() == 0:
		return
	var anchor = _anchor_of_selection(raw)
	_pending_anchor = anchor["center"]
	_pending_has_anchor = anchor["has_content"]


# DD writes the file from its OnAccepted handler, which runs before Hide(), so
# by now the file exists -- unless the user cancelled, in which case nothing was
# written and the mtime test below finds no candidate.
func _on_window_closed(w) -> void:
	if _pending_walls.size() == 0:
		return
	_pending_save = {
		"set": _window_set_name(w),
		"name": _window_prefab_name(w),
		"since": _window_open_time,
		"frames": 0,
	}


func _node_from_exported_path(node, property: String):
	if node == null:
		return null
	var path = node.get(property)
	if path == null or not (path is NodePath) or str(path) == "":
		return null
	return node.get_node_or_null(path)


func _find_child_named(node: Node, target: String, depth: int):
	if node == null or depth > 8:
		return null
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child.name == target:
			return child
		var found = _find_child_named(child, target, depth + 1)
		if found != null:
			return found
	return null


# sort_custom is unstable in Godot 3, hence the explicit instance-id tiebreak.
func _sort_by_child_index(a, b) -> bool:
	var ia = a.get_index()
	var ib = b.get_index()
	if ia == ib:
		return a.get_instance_id() < b.get_instance_id()
	return ia < ib


func _window_set_name(w) -> String:
	var node = _node_from_exported_path(w, "setPath")
	if node == null:
		return ""
	var value = node.get("Selected")
	return str(value) if value != null else ""


func _window_prefab_name(w) -> String:
	var node = _node_from_exported_path(w, "fieldPath")
	if node == null:
		node = _find_child_named(w, "NameEdit", 0)
	if node == null or not (node is LineEdit):
		return ""
	return node.text


func _flush_pending_save() -> void:
	_pending_save["frames"] += 1
	var since = _pending_save["since"]
	var path = ""
	var set_name = _pending_save["set"]
	var prefab_name = _pending_save["name"]
	if set_name != "" and prefab_name != "":
		var candidate = "user://prefabs/%s/%s.dungeondraft_prefab" % [set_name, prefab_name]
		var f = File.new()
		# The mtime test also rules out Cancel: the name field may point at an
		# existing prefab that must not be rewritten with this selection.
		if f.file_exists(candidate) and f.get_modified_time(candidate) >= since:
			path = candidate
	if path == "":
		path = _newest_prefab_file(since)
	if path == "":
		if _pending_save["frames"] > 120:
			print("[PrefabWalls] No prefab file written (cancelled?), walls dropped -- set='%s' name='%s'" % [str(set_name), str(prefab_name)])
			_pending_save = null
			_pending_walls = []
		return
	_patch_prefab_file(path, _pending_walls, _pending_anchor, _pending_has_anchor)
	_pending_save = null
	_pending_walls = []


# Fallback when the window fields could not be read: the freshly written
# prefab is simply the most recently modified one.
func _newest_prefab_file(since: int) -> String:
	var best := ""
	var best_time := 0
	var root_dir = Directory.new()
	if root_dir.open("user://prefabs") != OK:
		return ""
	root_dir.list_dir_begin(true, true)
	var entry = root_dir.get_next()
	while entry != "":
		if root_dir.current_is_dir():
			var sub = Directory.new()
			if sub.open("user://prefabs/" + entry) == OK:
				sub.list_dir_begin(true, true)
				var f = sub.get_next()
				while f != "":
					if f.ends_with(".dungeondraft_prefab"):
						var full = "user://prefabs/%s/%s" % [entry, f]
						var file = File.new()
						var mtime = file.get_modified_time(full)
						if mtime >= since and mtime > best_time:
							best_time = mtime
							best = full
					f = sub.get_next()
				sub.list_dir_end()
		entry = root_dir.get_next()
	root_dir.list_dir_end()
	return best


func _patch_prefab_file(path: String, walls: Array, anchor: Vector2, has_anchor: bool) -> void:
	var file = File.new()
	if file.open(path, File.READ) != OK:
		print("[PrefabWalls] Cannot read %s" % path)
		return
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not (parsed.result is Dictionary):
		print("[PrefabWalls] Malformed prefab file %s" % path)
		return
	var data = parsed.result
	var entries := []
	for snap in walls:
		entries.append(_wall_snapshot_to_json(snap))
	# Appended last: the section order of the sections DD knows is preserved,
	# which matters because Deserialize() iterates keys in order and
	# GetSelectionRect() treats the first deserialized node specially.
	data["walls"] = entries
	if has_anchor:
		data["up_anchor"] = [anchor.x, anchor.y]
	if file.open(path, File.WRITE) != OK:
		print("[PrefabWalls] Cannot write %s" % path)
		return
	file.store_line(JSON.print(data, "\t"))
	file.close()
	print("[PrefabWalls] Saved %d wall(s) into %s" % [entries.size(), path])


# ══════════════════════════════════════════════════════════════════════════════
# ANCHOR
# ══════════════════════════════════════════════════════════════════════════════

# Reproduces Level.GetSelectionRect() as it will run on the *preview* built by
# Level.Deserialize(), and returns its centre. Iteration order matters (the
# first entry seeds the box), so the selection is bucketed exactly the way
# SelectTool.Serialize() fills its arrays, then read back in the order those
# arrays are inserted into the JSON dictionary.
func _anchor_of_selection(raw) -> Dictionary:
	var objects := []
	var patterns := []
	var portals := []
	var pathways := []
	var lights := []
	var roofs := []
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if s.Type == SEL_OBJECT:
			objects.append(s.Thing)
		elif s.Type == SEL_PATTERN_SHAPE:
			patterns.append(s.Thing)
		elif s.Type == SEL_PORTAL_FREE:
			portals.append(s.Thing)
		elif s.Type == SEL_PATHWAY:
			pathways.append(s.Thing)
		elif s.Type == SEL_LIGHT:
			lights.append(s.Thing)
		elif s.Type == SEL_ROOF:
			roofs.append(s.Thing)
	var ordered := []
	for n in objects:
		ordered.append([n, SEL_OBJECT])
	for n in patterns:
		ordered.append([n, SEL_PATTERN_SHAPE])
	for n in portals:
		ordered.append([n, SEL_PORTAL_FREE])
	for n in pathways:
		ordered.append([n, SEL_PATHWAY])
	for n in lights:
		ordered.append([n, SEL_LIGHT])
	for n in roofs:
		ordered.append([n, SEL_ROOF])
	if ordered.size() == 0:
		# Walls-only prefab: DD's preview is empty and its translation applies
		# to nothing, so the ghost anchors on the walls' own bounding box.
		return {"has_content": false, "center": Vector2.ZERO}

	var first_node = ordered[0][0]
	var first_type = ordered[0][1]
	var seed_point = first_node.position
	if first_type == SEL_ROOF:
		var rrect = first_node.get("Rect")
		if rrect != null:
			seed_point = first_node.to_global(rrect.position)
	elif first_type == SEL_PATTERN_SHAPE:
		var poly = first_node.polygon
		if poly != null and poly.size() > 0:
			seed_point = first_node.to_global(poly[0])
	var box = Rect2(seed_point, Vector2.ZERO)

	for entry in ordered:
		var node = entry[0]
		var kind = entry[1]
		var t = node.transform
		if kind == SEL_OBJECT:
			# Preview props are never selected, so SpriteWidget.Rect is still
			# Rect2(0,0,0,0): only the position contributes.
			box = box.expand(t.xform(Vector2.ZERO))
		elif kind == SEL_PORTAL_FREE:
			box = _expand_rect(box, t, node.get("Rect"))
		elif kind == SEL_PATHWAY:
			var grect = node.get("GlobalRect")
			if grect != null:
				box = box.merge(grect)
		elif kind == SEL_LIGHT:
			box = _expand_rect(box, t, _light_widget_rect(node))
		elif kind == SEL_ROOF:
			box = _expand_rect(box, t, node.get("Rect"))
		elif kind == SEL_PATTERN_SHAPE:
			var poly2 = node.polygon
			if poly2 != null:
				for p in poly2:
					box = box.expand(t.xform(p))
	return {"has_content": true, "center": box.position + box.size * 0.5}


func _expand_rect(box: Rect2, t: Transform2D, rect) -> Rect2:
	if rect == null or not (rect is Rect2):
		return box
	var p = rect.position
	var s = rect.size
	box = box.expand(t.xform(p))
	box = box.expand(t.xform(p + Vector2(s.x, 0.0)))
	box = box.expand(t.xform(p + s))
	box = box.expand(t.xform(p + Vector2(0.0, s.y)))
	return box


# LightWidget.Rect is a computed 256x256 box centred on the widget. The widget
# is the light's first child (see LightWidgetEx.GetWidget).
func _light_widget_rect(light):
	if light.get_child_count() > 0:
		var widget = light.get_child(0)
		var rect = widget.get("Rect")
		if rect != null and rect is Rect2:
			return rect
	return Rect2(Vector2(-128.0, -128.0), Vector2(256.0, 256.0))


# ══════════════════════════════════════════════════════════════════════════════
# WALL SNAPSHOT <-> JSON
# ══════════════════════════════════════════════════════════════════════════════

# A wall's Points are world coordinates (the Wall node itself sits at the
# origin), and a portal's local position therefore equals its world position.
func _snapshot_wall(wall) -> Dictionary:
	var pts = PoolVector2Array()
	var raw_pts = wall.Points
	if raw_pts != null:
		for p in raw_pts:
			pts.append(p)
	var portal_snaps := []
	var portals = wall.Portals
	if portals != null:
		for p in portals:
			if p == null or not is_instance_valid(p) or p.is_queued_for_deletion():
				continue
			portal_snaps.append({
				"texture": p.Texture,
				"closed": p.Closed,
				"position": p.position,
				"rotation": p.rotation,
				"direction": p.Direction,
				"point_index": int(p.WallPointIndex),
				"radius": p.Radius,
				"flip": p.Flip,
			})
	return {
		"points": pts,
		"texture": wall.Texture,
		"color": wall.Color,
		"loop": wall.Loop,
		"shadow": wall.HasShadow,
		"type": int(wall.Type),
		"joint": int(wall.Joint),
		"normalize_uv": wall.NormalizeUV,
		"portals": portal_snaps,
	}


func _wall_snapshot_to_json(snap: Dictionary) -> Dictionary:
	var portals := []
	for p in snap["portals"]:
		portals.append({
			"texture": _texture_path(p["texture"]),
			"closed": p["closed"],
			"position": [p["position"].x, p["position"].y],
			"rotation": p["rotation"],
			"direction": [p["direction"].x, p["direction"].y],
			"point_index": p["point_index"],
			"radius": p["radius"],
			"flip": p["flip"],
		})
	var color = snap["color"]
	return {
		# "texture" is kept as a plain resource path so that the existing
		# missing-asset scan in prefabs_thumbnails picks walls up as well.
		"texture": _texture_path(snap["texture"]),
		"color": [color.r, color.g, color.b, color.a],
		"loop": snap["loop"],
		"shadow": snap["shadow"],
		"type": snap["type"],
		"joint": snap["joint"],
		"normalize_uv": snap["normalize_uv"],
		"points": var2str(snap["points"]),
		"portals": portals,
	}


func _texture_path(texture) -> String:
	if texture == null:
		return ""
	var path = texture.resource_path
	return str(path) if path != null else ""


# ══════════════════════════════════════════════════════════════════════════════
# LOAD SIDE
# ══════════════════════════════════════════════════════════════════════════════

func _prefab_file_path(key: String) -> String:
	var parts = key.split("/", true, 1)
	if parts.size() != 2:
		return ""
	var file = File.new()
	for root in ["user://prefabs", "res://prefabs"]:
		var path = "%s/%s/%s.dungeondraft_prefab" % [root, parts[0], parts[1]]
		if file.file_exists(path):
			return path
	return ""


func _load_prefab_walls(key: String):
	var path = _prefab_file_path(key)
	if path == "":
		return null
	var file = File.new()
	if file.open(path, File.READ) != OK:
		print("[PrefabWalls] %s: cannot read %s" % [key, path])
		return null
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	if parsed.error != OK or not (parsed.result is Dictionary):
		print("[PrefabWalls] %s: malformed prefab file" % key)
		return null
	var data = parsed.result
	var has_dd_content := false
	# Centroid of every entry DD turns into a preview node, in prefab space.
	# A rigid transform maps a centroid onto the centroid of the transformed
	# points, which is what lets the ghost be re-anchored on DD's live preview
	# every frame instead of on a capture that can go stale.
	var centroid := Vector2.ZERO
	var centroid_count := 0
	for section in ["objects", "pattern_shapes", "portals", "pathways", "lights", "roofs"]:
		if data.has(section) and data[section] is Array and data[section].size() > 0:
			has_dd_content = true
			for item in data[section]:
				if item is Dictionary:
					centroid += _parse_dd_vector2(str(item.get("position", "")))
					centroid_count += 1
	if centroid_count > 0:
		centroid = centroid / float(centroid_count)
	if not data.has("walls") or not (data["walls"] is Array):
		return null

	var walls := []
	var missing := 0
	for entry in data["walls"]:
		if not (entry is Dictionary):
			continue
		var tex_path = str(entry.get("texture", ""))
		var texture = _resolve_texture(tex_path)
		if texture == null:
			print("[PrefabWalls] texture not resolved: %s" % tex_path)
			# Without the real Texture resource the wall would be saved with an
			# empty texture path and break on reload, so skip it.
			missing += 1
			continue
		var points = str2var(str(entry.get("points", "")))
		if not (points is PoolVector2Array) or points.size() < 2:
			continue
		var color_arr = entry.get("color", [1.0, 1.0, 1.0, 1.0])
		var portals := []
		for p in entry.get("portals", []):
			if not (p is Dictionary):
				continue
			var ptex = _resolve_texture(str(p.get("texture", "")))
			if ptex == null:
				continue
			portals.append({
				"texture": ptex,
				"closed": p.get("closed", false) == true,
				"position": _to_vec(p.get("position", [0.0, 0.0])),
				"rotation": float(p.get("rotation", 0.0)),
				"direction": _to_vec(p.get("direction", [1.0, 0.0])),
				"point_index": int(p.get("point_index", 0)),
				"radius": float(p.get("radius", 128.0)),
				"flip": p.get("flip", false) == true,
			})
		walls.append({
			"points": points,
			"texture": texture,
			"color": Color(float(color_arr[0]), float(color_arr[1]), float(color_arr[2]), float(color_arr[3])),
			"loop": entry.get("loop", false) == true,
			"shadow": entry.get("shadow", true) == true,
			"type": int(entry.get("type", 1)),
			"joint": int(entry.get("joint", 1)),
			"normalize_uv": entry.get("normalize_uv", true) == true,
			"portals": portals,
		})
	if missing > 0:
		print("[PrefabWalls] %d wall(s) skipped: texture not available" % missing)
	if walls.size() == 0:
		return null

	var anchor: Vector2
	if data.has("up_anchor") and data["up_anchor"] is Array:
		anchor = _to_vec(data["up_anchor"])
	else:
		anchor = _walls_bounds_center(walls)
	return {
		"walls": walls,
		"anchor": anchor,
		"has_dd_content": has_dd_content,
		"preview_centroid": centroid,
		"preview_count": centroid_count,
	}


func _parse_dd_vector2(raw: String) -> Vector2:
	var clean = raw.replace("Vector2(", "").replace(")", "").replace(" ", "")
	var parts = clean.split(",")
	if parts.size() >= 2:
		return Vector2(float(parts[0]), float(parts[1]))
	return Vector2.ZERO


func _to_vec(value) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


func _walls_bounds_center(walls: Array) -> Vector2:
	var box = Rect2()
	var started := false
	for w in walls:
		for p in w["points"]:
			if not started:
				box = Rect2(p, Vector2.ZERO)
				started = true
			else:
				box = box.expand(p)
	if not started:
		return Vector2.ZERO
	return box.position + box.size * 0.5


# Textures must be the very resources DD already holds: an ImageTexture rebuilt
# from the file has no resource_path, and Wall.Save() writes that path, so such
# a wall would come back textureless after a reload. The tool libraries hold the
# canonical instances for every installed pack.
func _resolve_texture(path: String):
	if path == "":
		return null
	if _tex_cache.has(path):
		return _tex_cache[path]
	var texture = _find_texture_in_tool("WallTool", path)
	if texture == null:
		texture = _find_texture_in_tool("PortalTool", path)
	if texture == null and ResourceLoader.exists(path):
		texture = ResourceLoader.load(path, "Texture")
	_tex_cache[path] = texture
	return texture


func _find_texture_in_tool(tool_name: String, path: String):
	var tools = _g.Editor.get("Tools")
	if tools == null or not (tools is Dictionary) or not tools.has(tool_name):
		return null
	var t = tools[tool_name]
	if t == null or not is_instance_valid(t):
		return null
	var controls = t.get("Controls")
	if controls != null and controls is Dictionary:
		for key in controls.keys():
			var c = controls[key]
			if c == null or not is_instance_valid(c) or not (c is ItemList):
				continue
			var found = _icon_with_path(c, path)
			if found != null:
				return found
	# library_right_panel can move the library out of Controls' reach, so fall
	# back to walking the tool panel for any ItemList.
	if _g.Editor.get("Toolset") == null:
		return null
	var panel = _g.Editor.Toolset.GetToolPanel(tool_name)
	if panel == null or not is_instance_valid(panel):
		return null
	return _icon_in_subtree(panel, path, 0)


func _icon_with_path(list: ItemList, path: String):
	for i in range(list.get_item_count()):
		var icon = list.get_item_icon(i)
		if icon != null and str(icon.resource_path) == path:
			return icon
	return null


func _icon_in_subtree(node: Node, path: String, depth: int):
	if node == null or depth > 6:
		return null
	if node is ItemList:
		var found = _icon_with_path(node, path)
		if found != null:
			return found
	for i in range(node.get_child_count()):
		var r = _icon_in_subtree(node.get_child(i), path, depth + 1)
		if r != null:
			return r
	return null


# ══════════════════════════════════════════════════════════════════════════════
# GHOST PREVIEW
# ══════════════════════════════════════════════════════════════════════════════

func _read_transform_state() -> void:
	if not Engine.has_meta("_ac_prefab_transform"):
		_tf_rotation = 0.0
		_tf_scale = 1.0
		_tf_active = false
		return
	var state = Engine.get_meta("_ac_prefab_transform")
	if not (state is Dictionary):
		_tf_rotation = 0.0
		_tf_scale = 1.0
		_tf_active = false
		return
	_tf_rotation = float(state.get("rotation", 0.0))
	_tf_scale = float(state.get("scale", 1.0))
	_tf_capture_mouse = state.get("capture_mouse", Vector2.ZERO)
	_tf_capture_snapped = state.get("capture_snapped", Vector2.ZERO)
	_tf_capture_centroid = state.get("capture_centroid", Vector2.ZERO)
	_tf_capture_count = int(state.get("capture_count", 0))
	_tf_active = (_tf_rotation != 0.0 or _tf_scale != 1.0)


func _ghost_origin() -> Vector2:
	# Untransformed: DD re-centres its preview on SnappedPosition at every mouse
	# motion, and so do we.
	if not _tf_active:
		return _snapped_position()
	# Transformed: asset_cycle pins every preview node to the raw mouse using
	# offsets frozen at capture time, so the anchor follows the same rule.
	#
	# The reference point is rebuilt from the centroid of the preview nodes AS
	# THEY STOOD AT CAPTURE. Reading their live positions instead makes the ghost
	# flicker: on a frame carrying a mouse motion, DD has already re-centred them
	# on SnappedPosition but asset_cycle (process priority 9999, i.e. after this
	# code) has not yet rotated them back, so every other frame measures a
	# completely different centroid.
	#
	# Deriving the reference from SnappedPosition alone is not enough either:
	# DD's _ContentInput used the value computed during the *previous* frame's
	# _Process, so a capture landing on a frame where the cursor changed grid
	# cell is off by a full cell -- which is exactly the drift seen after the
	# first placement, since the preview (and therefore the capture) is rebuilt
	# right after each one.
	var reference = _tf_capture_snapped
	if _ghost_data != null and _tf_capture_count > 0 \
			and _tf_capture_count == int(_ghost_data["preview_count"]):
		reference = _tf_capture_centroid - (_ghost_data["preview_centroid"] - _ghost_data["anchor"])
	return _world_mouse_position() + (reference - _tf_capture_mouse).rotated(_tf_rotation) * _tf_scale


# Must match asset_cycle's _get_mouse_world_position(): the raw, unsnapped mouse
# in world space, read live so the ghost does not trail the assets by a frame.
func _world_mouse_position() -> Vector2:
	var ui = _g.get("WorldUI")
	if ui != null and is_instance_valid(ui) and ui is Node2D:
		return ui.get_global_mouse_position()
	return _mouse_position()


func _apply_ghost_scale(scale: float) -> void:
	_ghost_applied_scale = scale
	for entry in _ghost_lines:
		var line = entry["node"]
		if line == null or not is_instance_valid(line):
			continue
		var pts = PoolVector2Array()
		for p in entry["base_local"]:
			pts.append(p * scale)
		line.points = pts
	for entry in _ghost_portals:
		var sprite = entry["node"]
		if sprite == null or not is_instance_valid(sprite):
			continue
		sprite.position = entry["base_local"] * scale


func _clear_ghost() -> void:
	_ghost_lines = []
	_ghost_portals = []
	_ghost_applied_scale = 1.0
	if _ghost != null and is_instance_valid(_ghost):
		if _ghost.get_parent() != null:
			_ghost.get_parent().remove_child(_ghost)
		_ghost.queue_free()
	_ghost = null


func _build_ghost() -> void:
	if _ghost_data == null:
		return
	var parent = _g.get("WorldUI")
	if parent == null or not is_instance_valid(parent):
		return
	for child in parent.get_children():
		if child.name == GHOST_NODE_NAME:
			child.queue_free()
	_ghost = Node2D.new()
	_ghost.name = GHOST_NODE_NAME
	_ghost.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_ghost_lines = []
	_ghost_portals = []
	_ghost_applied_scale = 1.0
	var anchor: Vector2 = _ghost_data["anchor"]
	for w in _ghost_data["walls"]:
		var line = _make_ghost_line(w, anchor)
		_ghost.add_child(line)
		_ghost_lines.append({"node": line, "base_local": line.points})
		for p in w["portals"]:
			var sprite = _make_ghost_portal(p, anchor)
			_ghost.add_child(sprite)
			_ghost_portals.append({"node": sprite, "base_local": sprite.position})
	parent.add_child(_ghost)
	_read_transform_state()
	_ghost.position = _ghost_origin()
	_ghost.rotation = _tf_rotation
	if _tf_scale != 1.0:
		_apply_ghost_scale(_tf_scale)


func _make_ghost_line(w: Dictionary, anchor: Vector2) -> Line2D:
	var line = Line2D.new()
	var local = PoolVector2Array()
	for p in w["points"]:
		local.append(p - anchor)
	if w["loop"] and local.size() > 2:
		local.append(local[0])
	var texture = w["texture"]
	line.texture = texture
	line.width = float(texture.get_height()) if texture != null else 32.0
	line.texture_mode = Line2D.LINE_TEXTURE_TILE
	line.joint_mode = w["joint"]
	line.default_color = w["color"]
	line.antialiased = false
	line.points = local
	# DD builds Godot with extra Line2D properties; set them only if present.
	if _has_property(line, "normalize_uv"):
		line.set("normalize_uv", w["normalize_uv"])
	var mat = _get_wall_material()
	if mat != null:
		line.material = mat
	return line


func _has_property(node: Object, property: String) -> bool:
	for entry in node.get_property_list():
		if entry.get("name", "") == property:
			return true
	return false


func _make_ghost_portal(p: Dictionary, anchor: Vector2) -> Sprite:
	var sprite = Sprite.new()
	sprite.texture = p["texture"]
	sprite.position = p["position"] - anchor
	sprite.rotation = p["rotation"]
	sprite.z_index = 1
	return sprite


# The wall shader lives in Cache.Materials.Wall, which GDScript cannot reach,
# so borrow it from any wall already on the map.
func _get_wall_material():
	if _wall_material_looked_up and _wall_material != null and is_instance_valid(_wall_material):
		return _wall_material
	_wall_material_looked_up = true
	var level = _current_level()
	if level == null or level.Walls == null:
		return null
	for wall in level.Walls.get_children():
		for i in range(wall.get_child_count()):
			var child = wall.get_child(i)
			if child is Line2D and child.material != null:
				_wall_material = child.material
				return _wall_material
	return null


# ══════════════════════════════════════════════════════════════════════════════
# PLACEMENT
# ══════════════════════════════════════════════════════════════════════════════

func _place_walls() -> void:
	# Use the ghost's own position rather than a freshly read SnappedPosition so
	# the walls land exactly where the user saw them.
	var origin = _ghost_origin()
	if _ghost != null and is_instance_valid(_ghost):
		origin = _ghost.position
	var anchor: Vector2 = _ghost_data["anchor"]
	var snaps := []
	for w in _ghost_data["walls"]:
		snaps.append(_transformed_snapshot(w, anchor, origin, _tf_rotation, _tf_scale))
	var group_id = _current_prefab_group_id()
	var created = _recreate_walls(snaps, group_id)
	if created.size() == 0:
		return
	_register_undo(created, group_id)
	_preview_group_id = ""


# Scale only spreads the points apart -- the line width comes from the texture
# height and is left alone, and portals keep their own radius and texture. That
# matches how a wall is resized in DD.
func _transformed_snapshot(w: Dictionary, anchor: Vector2, origin: Vector2, rotation: float, scale: float) -> Dictionary:
	var pts = PoolVector2Array()
	for p in w["points"]:
		pts.append(((p - anchor) * scale).rotated(rotation) + origin)
	var portals := []
	for p in w["portals"]:
		var copy = p.duplicate()
		copy["position"] = ((p["position"] - anchor) * scale).rotated(rotation) + origin
		copy["direction"] = p["direction"].rotated(rotation)
		copy["rotation"] = p["rotation"] + rotation
		portals.append(copy)
	return {
		"points": pts,
		"texture": w["texture"],
		"color": w["color"],
		"loop": w["loop"],
		"shadow": w["shadow"],
		"type": w["type"],
		"joint": w["joint"],
		"normalize_uv": w["normalize_uv"],
		"portals": portals,
	}


# Instance() appends its preview nodes to the regular containers all at once,
# so a container growing while the PrefabTool is active means preview nodes just
# appeared -- and the newest of them carries the prefab_id to join. Reading the
# last child unconditionally would instead pick up whatever was already on the
# map (a node from an older prefab), which is how every placement ended up in
# the same stale group.
func _watch_preview_group() -> void:
	var level = _current_level()
	if level == null:
		return
	for key in PREVIEW_CONTAINERS:
		var c = level.get(key)
		if c == null or not is_instance_valid(c) or not (c is Node):
			continue
		var count = c.get_child_count()
		var previous = _container_counts.get(key, -1)
		_container_counts[key] = count
		if previous < 0 or count <= previous:
			continue
		for i in range(count - 1, previous - 1, -1):
			var node = c.get_child(i)
			if node != null and node.has_meta("prefab_id"):
				var pid = str(node.get_meta("prefab_id"))
				if pid != "":
					_preview_group_id = pid
				return


func _current_prefab_group_id() -> String:
	# A walls-only prefab produces no preview node at all, so there is no DD
	# group to join: take a fresh id instead, otherwise every placement would
	# fall back on some unrelated node's prefab_id and link them all together.
	if _ghost_data != null and not _ghost_data["has_dd_content"]:
		if _g != null and _g.World != null and _g.World.has_method("GetNextPrefabID"):
			return str(_g.World.GetNextPrefabID())
		return ""
	if _preview_group_id != "":
		return _preview_group_id
	# Seed for the very first placement after picking the prefab: Instance()
	# ran during the input phase of a frame we had not sampled yet, so the
	# preview nodes are simply the last children.
	var level = _current_level()
	if level != null:
		for key in PREVIEW_CONTAINERS:
			var c = level.get(key)
			if c == null or not is_instance_valid(c) or not (c is Node):
				continue
			var count = c.get_child_count()
			if count == 0:
				continue
			var last = c.get_child(count - 1)
			if last != null and last.has_meta("prefab_id"):
				var pid = str(last.get_meta("prefab_id"))
				if pid != "":
					return pid
	return ""


func _recreate_walls(snaps: Array, group_id: String = "") -> Array:
	var new_walls := []
	var level = _current_level()
	if level == null or level.Walls == null:
		return new_walls
	var container = level.Walls
	for snap in snaps:
		var wall = container.AddWall(
			snap["points"],
			snap["texture"],
			snap["color"],
			snap["loop"],
			snap["shadow"],
			snap["type"],
			snap["joint"],
			snap["normalize_uv"]
		)
		if wall == null:
			continue
		# AddWall registers the node id, but make sure of it: DD's own delete
		# path resolves walls through the World registry.
		if _g.World.has_method("AssignNodeID"):
			var registered := false
			if wall.has_meta("node_id") and _g.World.has_method("HasNodeID"):
				var nid = wall.get_meta("node_id")
				if _g.World.HasNodeID(nid) and _g.World.GetNodeByID(nid) == wall:
					registered = true
			if not registered:
				_g.World.AssignNodeID(wall)
		_recreate_portals(wall, snap["portals"])
		if group_id != "":
			_join_prefab_group(wall, group_id)
		new_walls.append(wall)
	return new_walls


# Rattache un wall -- et les portals qu'il porte -- au groupe d'un prefab.
# Les portals sont des enfants du wall et le suivent deja geometriquement,
# mais DD selectionne par groupe : sans ca ils resteraient en dehors.
func _join_prefab_group(wall, group_id: String) -> void:
	if wall == null or not is_instance_valid(wall) or group_id == "":
		return
	if not wall.is_in_group(group_id):
		wall.add_to_group(group_id)
	wall.set_meta("prefab_id", group_id)
	var portals_list = wall.get("Portals")
	if portals_list == null:
		return
	for p in portals_list:
		if p == null or not is_instance_valid(p):
			continue
		if not p.is_in_group(group_id):
			p.add_to_group(group_id)
		p.set_meta("prefab_id", group_id)


# ══════════════════════════════════════════════════════════════════════════════
# PREFAB GROUP PERSISTENCE
# ══════════════════════════════════════════════════════════════════════════════
#
# Prop.Save() writes "prefab_id" and Prop.Load() restores both the meta and the
# group membership. Wall.Save() (C#) does neither, so after a save + reload the
# walls of a prefab -- and the portals they carry -- silently left the group:
# dragging one of the prefab's objects no longer took them along.
#
# We cannot touch Wall.Save(), but Save.Serialize() writes
# ModManager.ModMapData verbatim under the "mod" key, so we keep our own
# node_id -> prefab_id table there. Two constraints drive the format:
#   - the file goes through JSON.Print, which turns every key into text and
#     every int into a float, so both sides are stored as String;
#   - node ids survive a reload (Wall.Load calls AssignSpecificNodeID), which
#     is exactly what makes them usable as a persistent handle.
#
# The table is rebuilt from the live scene on OnSaveBegin rather than
# maintained incrementally: DD's own Ungroup (SelectTool) removes the meta
# behind our back, and a stale entry would resurrect a dead group on reload.

func _mod_map_data():
	if _g == null:
		return null
	var d = _g.get("ModMapData")
	if d is Dictionary:
		return d
	return null


# Every wall of every level. Only walked on save and on restore, never per
# frame. World.levels is a private C# List so it cannot be read directly;
# TryGetLevel() returns null past the end, which gives us the bound.
func _all_walls() -> Array:
	var out := []
	if _g == null or _g.World == null or not _g.World.has_method("TryGetLevel"):
		return out
	for i in range(MAX_LEVELS):
		var level = _g.World.TryGetLevel(i)
		if level == null or not is_instance_valid(level):
			continue
		var container = level.get("Walls")
		if container == null or not is_instance_valid(container) or not (container is Node):
			continue
		for j in range(container.get_child_count()):
			var w = container.get_child(j)
			if w != null and is_instance_valid(w) and w.has_method("RemakeLines"):
				out.append(w)
	return out


# Editor.OnSaveBegin fires synchronously, before Save.Serialize() is handed to
# its Task, so writing into ModMapData here lands in the file being written.
func _on_save_begin(_path = null, _is_backup = null) -> void:
	if Engine.has_meta("pw_active_instance") and Engine.get_meta("pw_active_instance") != _instance_id:
		return
	var mmd = _mod_map_data()
	if mmd == null:
		return
	var table := {}
	for wall in _all_walls():
		if not wall.has_meta("prefab_id") or not wall.has_meta("node_id"):
			continue
		var pid = str(wall.get_meta("prefab_id"))
		if pid == "":
			continue
		table[str(int(wall.get_meta("node_id")))] = pid
	if table.empty():
		mmd.erase(MAP_DATA_KEY)
	else:
		mmd[MAP_DATA_KEY] = table


# Polled: the map's ModMapData replaces ours on load, so the key simply shows
# up. Entries are consumed as their wall becomes resolvable -- Walls.Load runs
# level by level, so the first passes may find nothing -- and the key is
# dropped once the table empties or the retry budget runs out, which also
# stops this from firing again until the next save.
func _poll_group_restore() -> void:
	if (_tick % 10) != 0:
		return
	var mmd = _mod_map_data()
	if mmd == null or not mmd.has(MAP_DATA_KEY):
		_restore_ticks = 0
		return
	var table = mmd[MAP_DATA_KEY]
	if not (table is Dictionary) or table.empty():
		mmd.erase(MAP_DATA_KEY)
		_restore_ticks = 0
		return
	if _g.World == null or not _g.World.has_method("HasNodeID"):
		return
	_restore_ticks += 1
	var pending := {}
	var restored := 0
	for key in table:
		var pid = str(table[key])
		if pid == "":
			continue
		var nid := int(key)
		if not _g.World.HasNodeID(nid):
			pending[key] = table[key]
			continue
		var wall = _g.World.GetNodeByID(nid)
		if wall == null or not is_instance_valid(wall):
			continue
		_join_prefab_group(wall, pid)
		restored += 1
	if restored > 0:
		_restored_total += restored
	if pending.empty() or _restore_ticks > 30:
		mmd.erase(MAP_DATA_KEY)
		_restore_ticks = 0
		if _restored_total > 0:
			print("[PrefabWalls] Restored prefab group on %d wall(s)." % _restored_total)
		_restored_total = 0
	else:
		mmd[MAP_DATA_KEY] = pending


func _recreate_portals(wall, portal_snaps: Array) -> void:
	if wall == null or not is_instance_valid(wall) or portal_snaps.size() == 0:
		return
	for snap in portal_snaps:
		var portal = wall.AddPortal(
			snap["texture"],
			snap["closed"],
			snap["position"],
			snap["direction"],
			snap["point_index"],
			snap["radius"],
			snap["flip"]
		)
		if portal == null:
			# DD refuses two portals sharing the same WallDistance.
			continue
		_g.World.AssignNodeID(portal)
		portal.rotation = snap["rotation"]


# Detach portals before removing the wall, otherwise the C# side raises
# "Parent node is busy".
func _destroy_walls(walls: Array) -> void:
	for w in walls:
		if w == null or not is_instance_valid(w):
			continue
		var portals_list = w.get("Portals")
		if portals_list != null:
			var to_remove := []
			for p in portals_list:
				if p != null and is_instance_valid(p):
					to_remove.append(p)
			for p in to_remove:
				if p.get_parent() != null:
					p.get_parent().remove_child(p)
				p.free()
		var parent = w.get_parent()
		if parent != null and is_instance_valid(parent):
			parent.remove_child(w)
		w.queue_free()


# Undoing a wall that is still selected would leave the SelectTool holding a
# freed instance (and its transform box floating on screen).
func _deselect_if_contains(walls: Array) -> void:
	if select_tool == null or walls.size() == 0:
		return
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var hit := false
	for s in raw:
		if s != null and s.Thing != null and walls.has(s.Thing):
			hit = true
			break
	if not hit:
		return
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	if select_tool.has_method("EnableTransformBox"):
		select_tool.EnableTransformBox(false)


func _snapshot_walls_for_record(walls: Array) -> Array:
	var snaps := []
	for w in walls:
		if w != null and is_instance_valid(w):
			snaps.append(_snapshot_wall(w))
	return snaps


func _register_undo(walls: Array, group_id: String = "") -> void:
	if walls.size() == 0 or _g.Editor == null:
		return
	var history = _g.Editor.get("History")
	if history == null:
		return
	var record = PrefabWallsRecord.new()
	record.owner_mod = self
	record.live_walls = walls
	record.wall_snaps = _snapshot_walls_for_record(walls)
	record.group_id = group_id
	if history.has_method("CreateCustomRecord"):
		history.CreateCustomRecord(record)
	elif history.has_method("Record"):
		history.Record(record)


# Walls are undone by destruction and redone by recreation through AddWall:
# a re-attached detached instance stays unknown to DD's native delete path,
# whereas a freshly created wall behaves exactly like a hand-drawn one.
class PrefabWallsRecord:
	extends Reference
	var owner_mod
	var wall_snaps: Array
	var live_walls: Array
	var group_id := ""

	func undo():
		if owner_mod == null:
			return
		owner_mod._deselect_if_contains(live_walls)
		var fresh = owner_mod._snapshot_walls_for_record(live_walls)
		if fresh.size() > 0:
			wall_snaps = fresh
		owner_mod._destroy_walls(live_walls)
		live_walls = []

	func redo():
		if owner_mod == null:
			return
		live_walls = owner_mod._recreate_walls(wall_snaps, group_id)
