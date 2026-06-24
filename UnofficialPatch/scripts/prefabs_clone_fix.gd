# prefabs_clone_fix.gd
# Sub-mod for BugFixes -- Level clone prefab_id fix
#
# Fix 4A: When cloning a level that has prefabs, show a popup asking
#         the user to save & reload so prefab_ids are separated.
# Fix 4B: On every save, remap prefab_ids that are shared across levels.

var _g

const PREFAB_SECTIONS_FILE = ["objects", "paths", "portals", "walls", "lights", "roofs", "patterns"]

# Fix 4A state
var _known_level_instance_ids := {}
var _pre_clone_source_level = null
var _pre_clone_new_label = ""
var _clone_hook_connected := false


func initialize() -> void:
	call_deferred("_snapshot_existing_levels")
	call_deferred("_hook_new_level_ui")
	call_deferred("_hook_save_for_fix4b")
	print("[PrefabsCloneFix] Initialized")


# ------------------------------------------------------
# Fix 4A -- Level clone detection & popup
# ------------------------------------------------------

func _snapshot_existing_levels() -> void:
	for level in _get_all_levels():
		if is_instance_valid(level):
			_known_level_instance_ids[level.get_instance_id()] = true
	print("[PrefabsCloneFix] Snapshotted %d levels" % _known_level_instance_ids.size())


func _get_all_levels() -> Array:
	var levels = _g.World.get("Levels")
	if levels is Array:
		return levels
	var result = []
	for child in _g.World.get_children():
		if child.get("Cloning") != null:
			result.append(child)
	return result


func _get_prefab_nodes_of_level(level) -> Array:
	var result = []
	if not is_instance_valid(level):
		return result
	for cname in ["Objects", "Pathways", "Portals", "Lights", "Walls", "Roofs"]:
		var container = level.get_node_or_null(cname)
		if container == null:
			continue
		for child in container.get_children():
			if child.has_meta("prefab_id"):
				result.append(child)
			for sub in child.get_children():
				if sub.has_meta("prefab_id"):
					result.append(sub)
	return result


func _level_has_prefabs(level) -> bool:
	if not is_instance_valid(level):
		return false
	for node in _get_prefab_nodes_of_level(level):
		if node.has_meta("prefab_id"):
			return true
	return false


func _hook_new_level_ui() -> void:
	if _clone_hook_connected:
		return
	var root = _g.World.get_tree().root
	var okay_btn = root.get_node_or_null(
		"Master/Editor/Windows/NewLevel/Margins/VAlign/Buttons/OkayButton")
	if okay_btn != null and okay_btn is BaseButton:
		okay_btn.connect("pressed", self, "_on_new_level_okay_pressed")
		_clone_hook_connected = true
		print("[PrefabsCloneFix] Hooked NewLevel OkayButton")
	else:
		var t = _g.World.get_tree().create_timer(2.0)
		t.connect("timeout", self, "_hook_new_level_ui")


func _on_new_level_okay_pressed() -> void:
	var root = _g.World.get_tree().root
	var clone_opt = root.get_node_or_null(
		"Master/Editor/Windows/NewLevel/Margins/VAlign/CloneLevel/CloneLevelOptionButton")
	if clone_opt == null:
		return
	var selected_idx = clone_opt.get_selected()
	if selected_idx < 0:
		return
	var selected_text = clone_opt.get_item_text(selected_idx)
	if selected_text == "---" or selected_text == "":
		return
	# Capture label typed by user
	var name_field = root.get_node_or_null(
		"Master/Editor/Windows/NewLevel/Margins/VAlign/LevelName/LevelNameField")
	var new_label = ""
	if name_field != null and name_field.has_method("get_text"):
		new_label = name_field.get_text()
	# Find source level
	var source_level = null
	for lv in _get_all_levels():
		if is_instance_valid(lv) and lv.get("Label") == selected_text:
			source_level = lv
			break
	if source_level == null:
		source_level = _g.World.GetCurrentLevel()
	if not is_instance_valid(source_level):
		return
	if not _level_has_prefabs(source_level):
		return
	print("[PrefabsCloneFix] Clone of prefab level detected, new_label='%s'" % new_label)
	_pre_clone_new_label = new_label
	_pre_clone_source_level = source_level
	var t = _g.World.get_tree().create_timer(0.3)
	t.connect("timeout", self, "_after_clone_detected")


func _after_clone_detected() -> void:
	var clone_level = null
	for lv in _get_all_levels():
		if not is_instance_valid(lv):
			continue
		var iid = lv.get_instance_id()
		if _known_level_instance_ids.has(iid):
			continue
		if _pre_clone_source_level != null and iid == _pre_clone_source_level.get_instance_id():
			continue
		if clone_level == null or iid > clone_level.get_instance_id():
			clone_level = lv
	if clone_level == null:
		print("[PrefabsCloneFix] Clone not found")
		_pre_clone_source_level = null
		_pre_clone_new_label = ""
		return
	_known_level_instance_ids[clone_level.get_instance_id()] = true
	if _pre_clone_new_label != "":
		clone_level.set("Label", _pre_clone_new_label)
	var map_path = _get_current_map_path()
	_show_clone_prefab_popup(clone_level, map_path)
	_pre_clone_source_level = null
	_pre_clone_new_label = ""


# ------------------------------------------------------
# Fix 4B -- Hook save to remap cross-level prefab_ids
# ------------------------------------------------------

var _fix4b_listener: Node = null

func _hook_save_for_fix4b() -> void:
	var root = _g.World.get_tree().root if _g.World else null
	if root == null:
		return
	# Create a listener node for save events
	_fix4b_listener = Node.new()
	_fix4b_listener.name = "PrefabsCloneFixListener"
	var ls = GDScript.new()
	ls.source_code = """extends Node
var handler = null
func _on_save_triggered() -> void:
	if handler != null:
		handler._on_save_triggered_fix4b()
"""
	ls.reload()
	_fix4b_listener.set_script(ls)
	_fix4b_listener.handler = self
	root.call_deferred("add_child", _fix4b_listener)
	# Hook save button
	var save_btn = _g.Editor.get("saveButton")
	if save_btn != null and save_btn is BaseButton:
		if not save_btn.is_connected("pressed", _fix4b_listener, "_on_save_triggered"):
			save_btn.connect("pressed", _fix4b_listener, "_on_save_triggered")
			print("[PrefabsCloneFix] Hooked saveButton for Fix4B")


var _fix4b_pending := false
var _fix4b_poll_frames := 0
var _fix4b_last_mtime := 0
var _clone_save_mtime := 0   # mtime snapshot before clone save — used to detect write completion
const FIX4B_POLL_INTERVAL := 10
const FIX4B_POLL_TIMEOUT := 600


func _on_save_triggered_fix4b() -> void:
	if _fix4b_pending:
		return
	var path = _get_current_map_path()
	var f = File.new()
	_fix4b_last_mtime = f.get_modified_time(path) if path != "" and f.file_exists(path) else 0
	_fix4b_pending = true
	_fix4b_poll_frames = 0
	# Poll via timer
	_fix4b_schedule_poll()


func _fix4b_schedule_poll() -> void:
	var t = _g.World.get_tree().create_timer(0.17)  # ~10 frames at 60fps
	t.connect("timeout", self, "_fix4b_poll")


func _fix4b_poll() -> void:
	if not _fix4b_pending:
		return
	_fix4b_poll_frames += FIX4B_POLL_INTERVAL
	if _fix4b_poll_frames > FIX4B_POLL_TIMEOUT:
		_fix4b_pending = false
		return
	var path = _get_current_map_path()
	if path == "":
		_fix4b_schedule_poll()
		return
	var f = File.new()
	if not f.file_exists(path):
		_fix4b_schedule_poll()
		return
	var mtime = f.get_modified_time(path)
	if _fix4b_last_mtime > 0 and mtime <= _fix4b_last_mtime:
		_fix4b_schedule_poll()
		return
	# File was saved -- patch it
	_fix4b_pending = false
	_patch_file_fix4b(path)


func _patch_file_fix4b(path: String) -> void:
	var file = File.new()
	if file.open(path, File.READ) != OK:
		return
	var content = file.get_as_text()
	file.close()
	if content.empty():
		return
	var parsed = JSON.parse(content)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var data = parsed.result
	var remapped = _remap_cross_level_prefab_ids_in_file(data)
	if remapped > 0:
		if file.open(path, File.WRITE) != OK:
			return
		file.store_string(JSON.print(data, "\t"))
		file.close()
		print("[PrefabsCloneFix] Fix4B: remapped %d nodes in '%s'" % [remapped, path.get_file()])


# ------------------------------------------------------
# Popup UI helpers
# ------------------------------------------------------

func _get_current_map_path() -> String:
	var val = _g.Editor.get("CurrentMapFile")
	if val != null and val is String and val != "":
		return val
	return ""


func _add_dialog(dialog: Node) -> void:
	var windows = _g.Editor.get_node_or_null("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)


func _deferred_style(dialog: Node) -> void:
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_dialog_buttons", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _style_dialog_buttons(dialog: Node, timer: Timer) -> void:
	timer.queue_free()
	if not is_instance_valid(dialog):
		return
	for child in dialog.get_children():
		if child is Label:
			child.align = Label.ALIGN_CENTER
			child.valign = Label.VALIGN_CENTER
			child.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for child in dialog.get_children():
		if child is HBoxContainer:
			for btn in child.get_children():
				if btn is Button:
					var existing = btn.get_stylebox("normal")
					if existing != null and existing is StyleBoxFlat:
						var style = existing.duplicate()
						style.border_color = Color(0.6, 0.6, 0.6, 0.7)
						style.set_border_width_all(1)
						style.content_margin_left = 20
						style.content_margin_right = 20
						btn.add_stylebox_override("normal", style)


func _show_reloading_popup() -> AcceptDialog:
	var d = AcceptDialog.new()
	d.window_title = "Prefab Fix"
	d.dialog_text = "Reloading map... please wait."
	d.get_ok().visible = false
	_add_dialog(d)
	d.popup_exclusive = true
	d.popup_centered(Vector2(340, 100))
	_deferred_style(d)
	return d


func _show_clone_prefab_popup(clone_level, map_path: String) -> void:
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var dialog = AcceptDialog.new()
	dialog.window_title = "Prefab Fix"
	dialog.dialog_text = "Your map needs to be saved and reloaded\nfor prefabs to be separated on the cloned level."
	dialog.get_ok().text = "Save & Reload"
	if map_path == "":
		dialog.add_button("Cancel", true, "cancel")
	dialog.connect("confirmed", self, "_on_clone_popup_confirmed", [dialog, clone_level, map_path != ""])
	dialog.connect("custom_action", self, "_on_clone_popup_closed", [dialog])
	dialog.connect("popup_hide", self, "_on_clone_popup_closed", [dialog])
	_add_dialog(dialog)
	dialog.popup_exclusive = true
	dialog.popup_centered(Vector2(440, 130))
	_deferred_style(dialog)


func _on_clone_popup_confirmed(dialog: Node, clone_level, has_path: bool) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()
	var save_btn = _g.Editor.get("saveButton") if _g.Editor != null else null
	if not has_path:
		if save_btn != null and is_instance_valid(save_btn):
			_clone_save_mtime = 0  # path unknown yet, mtime check happens after path is found
			save_btn.emit_signal("pressed")
			var t = _g.World.get_tree().create_timer(0.5)
			t.connect("timeout", self, "_poll_for_path_then_reload", [clone_level, 0])
		return
	var reload_dlg = _show_reloading_popup()
	if save_btn != null and is_instance_valid(save_btn):
		# Snapshot mtime before save so we can detect when the file is fully written
		var _path_now = _get_current_map_path()
		var _f = File.new()
		_clone_save_mtime = _f.get_modified_time(_path_now) if _path_now != "" and _f.file_exists(_path_now) else 0
		save_btn.emit_signal("pressed")
		var t = _g.World.get_tree().create_timer(0.5)
		t.connect("timeout", self, "_poll_for_write_then_reload", [clone_level, reload_dlg, 0])


func _on_clone_popup_closed(action, dialog: Node) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()


func _poll_for_path_then_reload(clone_level, attempts: int) -> void:
	var path = _get_current_map_path()
	if path != "" or attempts >= 20:
		if path != "":
			var reload_dlg = _show_reloading_popup()
			# Save was triggered before we had the path, so we can't snapshot mtime before
			# the write. Set to 0 so _poll_for_write_then_reload proceeds immediately.
			_clone_save_mtime = 0
			var t = _g.World.get_tree().create_timer(0.5)
			t.connect("timeout", self, "_poll_for_write_then_reload", [clone_level, reload_dlg, 0])
		return
	var t = _g.World.get_tree().create_timer(0.5)
	t.connect("timeout", self, "_poll_for_path_then_reload", [clone_level, attempts + 1])


func _poll_for_write_then_reload(clone_level, reload_dlg, attempts: int) -> void:
	# Poll until the file's mtime changes (write complete) or timeout after ~30s (60 attempts * 0.5s)
	var path = _get_current_map_path()
	if path == "":
		# Path lost — give up
		_do_post_clone_reload(clone_level, reload_dlg)
		return
	var f = File.new()
	var current_mtime = f.get_modified_time(path) if f.file_exists(path) else 0
	var file_written = (_clone_save_mtime == 0 or current_mtime > _clone_save_mtime)
	if file_written or attempts >= 60:
		if not file_written:
			print("[PrefabsCloneFix] Write poll timed out after 30s — reloading anyway")
		_do_post_clone_reload(clone_level, reload_dlg)
		return
	var t = _g.World.get_tree().create_timer(0.5)
	t.connect("timeout", self, "_poll_for_write_then_reload", [clone_level, reload_dlg, attempts + 1])


func _do_post_clone_reload(clone_level, reload_dlg) -> void:
	var map_path = _get_current_map_path()
	if map_path == "":
		if is_instance_valid(reload_dlg):
			reload_dlg.queue_free()
		return
	_patch_file_fix4b(map_path)
	print("[PrefabsCloneFix] Calling ForceOpenMap")
	# Keep popup visible until ForceOpenMap — it disappears naturally on reload
	_g.Editor.ForceOpenMap(map_path)
	if is_instance_valid(reload_dlg):
		reload_dlg.queue_free()


# ------------------------------------------------------
# Fix 4B -- Remap cross-level prefab_id conflicts in file data
# ------------------------------------------------------

func _remap_cross_level_prefab_ids_in_file(data: Dictionary) -> int:
	var world = data.get("world")
	if not (world is Dictionary):
		return 0
	var levels = world.get("levels")
	if not (levels is Dictionary) or levels.size() < 2:
		return 0
	# Build map: prefab_id -> list of level keys that use it
	var pid_to_levels := {}
	for lvl_key in levels.keys():
		var lvl = levels[lvl_key]
		if not (lvl is Dictionary):
			continue
		for section in PREFAB_SECTIONS_FILE:
			var items = lvl.get(section, [])
			if not (items is Array):
				continue
			for item in items:
				if item is Dictionary and item.has("prefab_id"):
					var pid = str(item["prefab_id"])
					if pid == "0":
						continue
					if not pid_to_levels.has(pid):
						pid_to_levels[pid] = []
					if not (lvl_key in pid_to_levels[pid]):
						pid_to_levels[pid].append(lvl_key)
	# Find conflicts
	var conflicts := {}
	for pid in pid_to_levels.keys():
		if pid_to_levels[pid].size() > 1:
			conflicts[pid] = pid_to_levels[pid]
	if conflicts.size() == 0:
		return 0
	# Determine next free prefab_id
	var next_pid_raw = world.get("next_prefab_id", "0")
	var next_pid: int
	if next_pid_raw is String and next_pid_raw.is_valid_integer():
		next_pid = int(next_pid_raw)
	elif next_pid_raw is int:
		next_pid = next_pid_raw
	else:
		next_pid = _find_max_pid_in_file_levels(levels) + 1
	# Build per-level remaps (keep first level's ids, remap all others)
	var level_remaps := {}
	for pid in conflicts.keys():
		var lvl_keys = conflicts[pid]
		for i in range(1, lvl_keys.size()):
			var lk = lvl_keys[i]
			if not level_remaps.has(lk):
				level_remaps[lk] = {}
			if not level_remaps[lk].has(pid):
				level_remaps[lk][pid] = str(next_pid)
				next_pid += 1
	if level_remaps.size() == 0:
		return 0
	# Apply remaps
	var total = 0
	for lvl_key in level_remaps.keys():
		var remap = level_remaps[lvl_key]
		var lvl = levels[lvl_key]
		for section in PREFAB_SECTIONS_FILE:
			var items = lvl.get(section, [])
			if not (items is Array):
				continue
			for item in items:
				if item is Dictionary and item.has("prefab_id"):
					var old_pid = str(item["prefab_id"])
					if remap.has(old_pid):
						item["prefab_id"] = remap[old_pid]
						total += 1
	world["next_prefab_id"] = str(next_pid)
	return total


func _find_max_pid_in_file_levels(levels: Dictionary) -> int:
	var max_pid = 0
	for lvl_key in levels.keys():
		var lvl = levels[lvl_key]
		if not (lvl is Dictionary):
			continue
		for section in PREFAB_SECTIONS_FILE:
			var items = lvl.get(section, [])
			if not (items is Array):
				continue
			for item in items:
				if item is Dictionary and item.has("prefab_id"):
					var pid_str = str(item["prefab_id"])
					if pid_str.is_valid_integer():
						var pid = int(pid_str)
						if pid > max_pid:
							max_pid = pid
	return max_pid
