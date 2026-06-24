# pack_embed_fix.gd  v12

var _g
var popup_blur = null

var _custom_dir = ""
# Pack unique fixe — independant de la map
const PACK_ID       = "DROPEMBED"
const PACK_SUFFIX   = "dropembed"
const PACK_NAME     = "_DropEmbed.dungeondraft_pack"
const PACK_RES_BASE = "res://packs/DROPEMBED/"
const INDEX_PATH    = "user://UnofficialPatch/DropEmbed/index.json"
const TMP_PATH      = "user://UnofficialPatch/DropEmbed/tmp"

# (variables _pack_id etc. gardees pour compat avec _add_to_manifest/_rebuild_pack)
var _pack_id       = PACK_ID
var _pack_path     = ""
var _pack_res_base = PACK_RES_BASE
var _pack_suffix   = PACK_SUFFIX

# Pack file index: {filename: original_absolute_path}
var _pack_files = {}

# Cache: {filename: PoolByteArray}
var _tex_cache = {}

# Session state
var _session_has_drops = false
var _save_key_held = false
var _post_process_pending = false
var _post_process_delay = 0.0

# Detection adaptative de la fin de sauvegarde (remplace le delai fixe)
const _PP_MIN_DELAY     = 0.3   # grace avant le 1er check (mtime frais)
const _PP_POLL_INTERVAL = 0.25  # frequence de polling
const _PP_TIMEOUT       = 6.0   # secours si rien n'est detecte
const _PP_EXPECTED      = 1.5   # duree typique, pour l'animation de la barre
var _pp_elapsed = 0.0
var _pp_check_accum = 0.0
var _pp_last_size = -1
var _pp_stable_count = 0
var _pp_finishing = false
var _pp_finish_delay = 0.0

# Auto-save after drop
var _auto_save_timer = -1.0
var _save_button = null

# Save hooks
var _hooks_done = false

var _session_has_saved = false
var _no_dir_muted = false
var _map_path = ""
var _map_ready = false
var _startup_frames = 0
var _last_world_id = -1
var _first_drop_time = 0

# Popup state
var _popup_muted = false
var _no_last_dir_muted = false
var _loading_dialog = null
var _loading_bar = null
# Vrai uniquement entre un drop et la fin de sa conversion
var _pending_drop_conversion = false

# Timestamp au moment de la sauvegarde (pour _find_map_path par mtime)
var _save_detected_time = 0


func initialize():
	_ensure_dropfix_dir()
	_read_config()
	
	# Always connect drop signal (to show warning if no custom dir)
	if _g.World and is_instance_valid(_g.World) and _g.World.is_inside_tree():
		var tree = _g.World.get_tree()
		if tree and not tree.is_connected("files_dropped", self, "_on_files_dropped"):
			tree.connect("files_dropped", self, "_on_files_dropped")
	
	if _custom_dir == "":
		print("[DropEmbed] WARNING: No custom_assets_directory set.")
	
	print("[DropEmbed] initialized v12, custom_dir=", _custom_dir)


func _is_drop_embed_enabled() -> bool:
	if _g == null or _g.get("ModMapData") == null or not (_g.ModMapData is Dictionary):
		return true
	var ms = _g.ModMapData.get("_mod_settings")
	if ms == null or not ms.has_method("is_enabled"):
		return true
	return ms.is_enabled("drop_embed")


# ===== Config & Persistence =====

func _ensure_dropfix_dir():
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	if not dir.dir_exists("user://UnofficialPatch/DropEmbed"):
		dir.make_dir("user://UnofficialPatch/DropEmbed")


func _read_config():
	var f = File.new()
	if f.open("user://config.ini", File.READ) != OK:
		return
	var content = f.get_as_text()
	f.close()
	for line in content.split("\n"):
		line = line.strip_edges()
		if line.begins_with("custom_assets_directory="):
			var val = line.substr(len("custom_assets_directory=")).strip_edges()
			if val.begins_with("\"") and val.ends_with("\""):
				val = val.substr(1, val.length() - 2)
			val = val.replace("\\\\", "\\")
			if val != "":
				_custom_dir = val
				print("[DropEmbed] Custom dir: ", _custom_dir)
			break





# ===== Index Persistence =====

func _load_file_index():
	var f = File.new()
	var path = INDEX_PATH
	if f.open(path, File.READ) == OK:
		var text = f.get_as_text()
		f.close()
		var parsed = JSON.parse(text)
		if parsed.error == OK and parsed.result is Dictionary:
			var index_data = parsed.result
			if index_data.has("_files"):
				_pack_files = index_data["_files"]
			else:
				_pack_files = index_data
		print("[DropEmbed] Index loaded: ", _pack_files.size(), " files")


func _save_file_index():
	var f = File.new()
	var path = INDEX_PATH
	if f.open(path, File.WRITE) == OK:
		f.store_string(JSON.print({"_files": _pack_files}))
		f.close()


# ===== Drop Handler =====

func _on_files_dropped(files: PoolStringArray, _screen: int):
	if not _is_drop_embed_enabled():
		return
	# Re-read config if no custom dir (user may have just set it in DD)
	if _custom_dir == "":
		_read_config()
		if _custom_dir != "" and _map_ready:
			_setup_map_pack()
	if _custom_dir == "":
		_show_no_dir_warning(files)
		return
	if _pack_id == "":
		return
	if files.size() == 0:
		return
	
	var new_files = []
	for i in range(files.size()):
		var ext = files[i].get_extension().to_lower()
		if ext == "webp" or ext == "png" or ext == "jpg" or ext == "jpeg":
			new_files.append(files[i])
	
	if new_files.size() == 0:
		return

	# Bloquer si last_map_directory inconnu : le post-process ne pourra pas
	# modifier le fichier .dungeondraft_map sans savoir ou il se trouve.
	if _get_map_directories().size() == 0:
		_show_no_last_dir_warning()
		return

	for path in new_files:
		var fname = path.get_file()
		_pack_files[fname] = path
		var f = File.new()
		if f.open(path, File.READ) == OK:
			_tex_cache[fname] = f.get_buffer(f.get_len())
			f.close()
	_save_file_index()
	_rebuild_pack()
	
	_session_has_drops = true
	_pending_drop_conversion = true
	if _first_drop_time == 0:
		_first_drop_time = OS.get_unix_time()
	
	if not _session_has_saved:
		_auto_save_timer = 2.0
	else:
		_auto_save_timer = 10.0
	print("[DropEmbed] DROP tracked: ", new_files.size(), " file(s)")


# ===== Update Loop =====

var _config_recheck_timer = 0.0

func update(delta):
	if _custom_dir == "":
		_config_recheck_timer -= delta
		if _config_recheck_timer <= 0:
			_config_recheck_timer = 2.0
			_read_config()
		if _custom_dir == "":
			return
	
	if not _g.World or not is_instance_valid(_g.World):
		_map_ready = false
		_last_world_id = -1
		return
	if not _g.World.is_inside_tree():
		_map_ready = false
		return
	
	var world_id = _g.World.get_instance_id()
	if world_id != _last_world_id:
		_last_world_id = world_id
		_map_ready = false
		_startup_frames = 0
		_map_path = ""
		_hooks_done = false
		_save_button = null
		_session_has_drops = false
		_session_has_saved = false
		_first_drop_time = 0
		_pack_files.clear()
		_tex_cache.clear()
		_pack_id       = PACK_ID
		_pack_suffix   = PACK_SUFFIX
		_pack_path     = ""
		_pack_res_base = PACK_RES_BASE
		_no_last_dir_muted = false
		print("[DropEmbed] Map changed - reset")
		return
	
	if not _map_ready:
		_startup_frames += 1
		if _startup_frames == 61:
			_map_ready = true
			_find_map_path()
			_hook_save_buttons()
			_setup_map_pack()
			print("[DropEmbed] Map ready: ", _map_path, " pack=", _pack_id)
		return
	
	# Attente de la fin de sauvegarde, puis post-process
	if _post_process_pending:
		_pp_elapsed += delta
		_pp_check_accum += delta
		if _loading_bar != null and is_instance_valid(_loading_bar):
			var p = clamp(_pp_elapsed / _PP_EXPECTED, 0.0, 0.95)
			_loading_bar.value = p * 100.0
		if _pp_elapsed < _PP_MIN_DELAY:
			return
		if _pp_check_accum >= _PP_POLL_INTERVAL:
			_pp_check_accum = 0.0
			if _check_save_complete() or _pp_elapsed >= _PP_TIMEOUT:
				_post_process_pending = false
				if _loading_bar != null and is_instance_valid(_loading_bar):
					_loading_bar.value = 100.0
				_pp_finishing = true
				_pp_finish_delay = 0.4
		return

	# Barre a 100% visible un court instant avant le traitement/fermeture
	if _pp_finishing:
		_pp_finish_delay -= delta
		if _pp_finish_delay <= 0:
			_pp_finishing = false
			_setup_map_pack()
			_do_post_process()
			_pending_drop_conversion = false
			_hide_loading_popup()
		return
	
	# Auto-save timer
	if _auto_save_timer > 0:
		_auto_save_timer -= delta
		if _auto_save_timer <= 0:
			_auto_save_timer = -1.0
			if not _session_has_saved:
				_show_save_prompt()
			else:
				_trigger_save()
	
	# Detect Ctrl+S
	if _pack_files.size() > 0:
		var ctrl = Input.is_key_pressed(KEY_CONTROL)
		var s = Input.is_key_pressed(KEY_S)
		if ctrl and s:
			if not _save_key_held:
				_save_key_held = true
				_on_save_detected("Ctrl+S")
		else:
			_save_key_held = false


func _on_save_detected(source: String):
	if _post_process_pending:
		return
	_session_has_saved = true
	print("[DropEmbed] Save detected (", source, ")! Waiting for write to finish...")
	_auto_save_timer      = -1.0
	_save_detected_time   = OS.get_unix_time()
	_post_process_pending = true
	_map_path             = ""
	_pp_elapsed           = 0.0
	_pp_check_accum        = 0.0
	_pp_last_size         = -1
	_pp_stable_count      = 0
	_pp_finishing         = false
	_pp_finish_delay      = 0.0
	# Loading popup uniquement pour les conversions declenchees par un drop
	if _pending_drop_conversion:
		_show_loading_popup()


func _setup_map_pack():
	# Pack fixe : le nom ne depend pas de la map
	_pack_id       = PACK_ID
	_pack_suffix   = PACK_SUFFIX
	_pack_path     = _custom_dir.plus_file(PACK_NAME)
	_pack_res_base = PACK_RES_BASE
	_pack_files.clear()
	_tex_cache.clear()
	_load_file_index()
	print("[DropEmbed] Pack setup: ", _pack_id, " (", _pack_files.size(), " existing files)")


# ===== Save Button Hooks =====

func _hook_save_buttons():
	if _hooks_done:
		return
	_hooks_done = true
	if not _g.Editor or not is_instance_valid(_g.Editor):
		return
	
	var sb = _g.Editor.get("saveButton")
	if sb and is_instance_valid(sb) and sb is BaseButton:
		_save_button = sb
		if not sb.is_connected("pressed", self, "_on_save_button"):
			sb.connect("pressed", self, "_on_save_button")
			print("[DropEmbed] Hooked saveButton")
	
	var menu_bar = _g.Editor.get("menuBar")
	if menu_bar == null:
		menu_bar = _find_node_by_class(_g.Editor, "MenuBar")
	if menu_bar == null:
		menu_bar = _find_node_by_class(_g.Editor, "MenuButton")
	if menu_bar and is_instance_valid(menu_bar):
		var popups = _find_popups(menu_bar)
		for popup in popups:
			if not popup.is_connected("id_pressed", self, "_on_menu_id"):
				popup.connect("id_pressed", self, "_on_menu_id")
				print("[DropEmbed] Hooked menu popup")


func _on_save_button():
	_on_save_detected("saveButton")


func _on_menu_id(id: int):
	if id == 1:
		_on_save_detected("menu")


func _trigger_save():
	if _save_button and is_instance_valid(_save_button):
		print("[DropEmbed] Auto-save: pressing save button...")
		_save_button.emit_signal("pressed")
		_on_save_detected("auto-save")


func _show_save_prompt():
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return

	var dirs = _get_map_directories()
	var dir_hint = ""
	if dirs.size() > 0:
		dir_hint = "\n\nPlease save your map in your last known directory:\n" + dirs[0]

	var dialog = AcceptDialog.new()
	dialog.window_title = "DropEmbed"
	dialog.dialog_text = "Dropped assets will now be converted into a custom asset pack.\nPlease save your map." + dir_hint
	dialog.get_ok().text = "Save"

	dialog.connect("confirmed", self, "_on_save_prompt_confirmed", [dialog])
	dialog.connect("popup_hide", self, "_on_save_prompt_dismissed", [dialog])

	_add_dialog(dialog)
	dialog.popup_exclusive = true
	var dialog_size = Vector2(480, 190) if dirs.size() > 0 else Vector2(420, 130)
	_deferred_popup_centered(dialog, dialog_size)


func _on_save_prompt_confirmed(dialog: Node):
	if is_instance_valid(dialog):
		dialog.queue_free()
	if _save_button and is_instance_valid(_save_button):
		_save_button.emit_signal("pressed")


func _on_save_prompt_dismissed(dialog: Node):
	if is_instance_valid(dialog):
		dialog.queue_free()


func _find_node_by_class(root: Node, cls: String):
	if not is_instance_valid(root):
		return null
	if root.get_class() == cls:
		return root
	for i in range(root.get_child_count()):
		var child = root.get_child(i)
		if not is_instance_valid(child):
			continue
		var found = _find_node_by_class(child, cls)
		if found:
			return found
	return null


func _find_popups(node: Node) -> Array:
	var result = []
	if not is_instance_valid(node):
		return result
	if node is MenuButton:
		var popup = node.get_popup()
		if popup:
			result.append(popup)
	if node is PopupMenu:
		result.append(node)
	for i in range(node.get_child_count()):
		result += _find_popups(node.get_child(i))
	return result


# ===== Map Path Detection =====

func _check_save_complete() -> bool:
	# Detecte la fin d'ecriture : on retrouve la map recemment modifiee,
	# puis on attend que sa taille soit stable et que le JSON soit valide.
	if _map_path == "":
		_find_map_path()
	if _map_path == "":
		return false
	var f = File.new()
	if f.open(_map_path, File.READ) != OK:
		return false
	var size = f.get_len()
	f.close()
	if size <= 0:
		_pp_last_size = size
		_pp_stable_count = 0
		return false
	if size == _pp_last_size:
		_pp_stable_count += 1
	else:
		_pp_stable_count = 0
		_pp_last_size = size
	# Taille stable sur 2 polls -> on confirme avec un parse JSON complet
	if _pp_stable_count >= 2:
		if f.open(_map_path, File.READ) == OK:
			var text = f.get_as_text()
			f.close()
			var parsed = JSON.parse(text)
			if parsed.error == OK and parsed.result is Dictionary and parsed.result.has("world"):
				print("[DropEmbed] Save complete detected (", _pp_elapsed, "s)")
				return true
	return false


func _find_map_path():
	# Cherche le .dungeondraft_map modifie depuis _save_detected_time.
	# Fonctionne pour un Save classique dans last_map_directory.
	if _map_path != "":
		return
	var cutoff = _save_detected_time - 1
	if cutoff <= 0:
		print("[DropEmbed] _find_map_path: no save timestamp")
		return
	var search_dirs = _get_map_directories()
	var recent = _get_recent_maps()
	for path in recent:
		var d = path.get_base_dir()
		if d != "" and not d in search_dirs:
			search_dirs.append(d)
	var f = File.new()
	var best_path  = ""
	var best_mtime = 0
	for dir_path in search_dirs:
		var dir = Directory.new()
		if dir.open(dir_path) != OK:
			continue
		dir.list_dir_begin(true, true)
		var fname = dir.get_next()
		while fname != "":
			if fname.ends_with(".dungeondraft_map"):
				var full = dir_path.plus_file(fname)
				if f.file_exists(full):
					var mtime = f.get_modified_time(full)
					if mtime >= cutoff and mtime > best_mtime:
						best_mtime = mtime
						best_path  = full
			fname = dir.get_next()
	if best_path != "":
		_map_path = best_path
		print("[DropEmbed] Map path (mtime): ", _map_path)
	else:
		print("[DropEmbed] Map path: not found (cutoff=", cutoff, ")")


func _get_map_directories() -> Array:
	var dirs = []
	var f = File.new()
	if f.open("user://config.ini", File.READ) != OK:
		return dirs
	var content = f.get_as_text()
	f.close()
	for line in content.split("\n"):
		line = line.strip_edges()
		if line.begins_with("last_map_directory="):
			var val = line.substr(len("last_map_directory=")).strip_edges()
			if val.begins_with("\"") and val.ends_with("\""):
				val = val.substr(1, val.length() - 2)
			val = val.replace("\\\\", "\\")
			if val != "":
				dirs.append(val)
	return dirs


func _get_recent_maps() -> Array:
	var maps = []
	var f = File.new()
	if f.open("user://config.ini", File.READ) != OK:
		return maps
	var content = f.get_as_text()
	f.close()
	for line in content.split("\n"):
		line = line.strip_edges()
		if line.begins_with("recently_opened_maps="):
			var arr_str = line.substr(len("recently_opened_maps=")).strip_edges()
			var idx = 0
			while true:
				var start = arr_str.find("\"", idx)
				if start < 0:
					break
				var end = arr_str.find("\"", start + 1)
				if end < 0:
					break
				var path = arr_str.substr(start + 1, end - start - 1)
				path = path.replace("\\\\", "\\")
				maps.append(path)
				idx = end + 1
			break
	return maps


# ===== No Dir Warning =====

func _show_no_dir_warning(files: PoolStringArray):
	var has_images = false
	for i in range(files.size()):
		var ext = files[i].get_extension().to_lower()
		if ext == "webp" or ext == "png" or ext == "jpg" or ext == "jpeg":
			has_images = true
			break
	if not has_images:
		return
	if _no_dir_muted:
		return
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	
	var dialog = AcceptDialog.new()
	dialog.window_title = "DropEmbed"
	dialog.dialog_text = "DropEmbed mod can't work properly because you didn't set a Custom Asset Folder.\nMake sure to set one next time you restart Dungeondraft, before you start a map."
	dialog.get_ok().text = "Continue without DropEmbed"
	
	var restart_btn = dialog.add_button("Save and restart Dungeondraft", false, "save_restart")
	dialog.connect("custom_action", self, "_on_no_dir_action", [dialog])
	dialog.connect("confirmed", self, "_on_no_dir_continue", [dialog])
	dialog.connect("popup_hide", self, "_on_no_dir_closed", [dialog])
	
	_add_dialog(dialog)
	dialog.popup_exclusive = true
	_deferred_popup_centered(dialog, Vector2(520, 160))



func _show_no_last_dir_warning():
	if _no_last_dir_muted:
		return
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var dialog = AcceptDialog.new()
	dialog.window_title = "DropEmbed"
	dialog.dialog_text = ("DropEmbed could not find your Last Known Directory.\n\n"
		+ "Without it, dropped assets cannot be properly embedded into your map.\n\n"
		+ "Please save your map first, then restart Dungeondraft before dropping assets.")
	dialog.get_ok().text = "OK"
	dialog.add_button("Don't show again (this session)", true, "mute")
	dialog.connect("custom_action", self, "_on_no_last_dir_action", [dialog])
	dialog.connect("confirmed", self, "_on_no_last_dir_closed", [dialog])
	dialog.connect("popup_hide", self, "_on_no_last_dir_closed", [dialog])
	_add_dialog(dialog)
	dialog.popup_exclusive = true
	_deferred_popup_centered(dialog, Vector2(480, 200))


func _on_no_last_dir_action(action: String, dialog: Node):
	if action == "mute":
		_no_last_dir_muted = true
	if is_instance_valid(dialog):
		dialog.queue_free()


func _on_no_last_dir_closed(dialog: Node):
	if is_instance_valid(dialog):
		dialog.queue_free()

func _on_no_dir_continue(dialog: Node):
	_no_dir_muted = true
	if is_instance_valid(dialog):
		dialog.queue_free()


func _on_no_dir_action(action: String, dialog: Node):
	if action == "save_restart":
		if is_instance_valid(dialog):
			dialog.hide()
			dialog.queue_free()
		_save_and_restart()


func _save_and_restart():
	# Delete the asset that was just placed (undo last action)
	var undone = false
	# Try 1: Editor's undo_redo
	if _g.Editor and is_instance_valid(_g.Editor):
		var ur = _g.Editor.get("undo_redo")
		if ur == null:
			ur = _g.Editor.get("UndoRedo")
		if ur and is_instance_valid(ur) and ur.has_method("undo"):
			ur.undo()
			undone = true
			print("[DropEmbed] Undo via UndoRedo")
	# Try 2: Delete last child of current level's Objects node
	if not undone and _g.World and is_instance_valid(_g.World):
		var level = _g.World.get("Level")
		if level == null:
			level = _g.World.get("currentLevel")
		if level and is_instance_valid(level):
			var objects = level.get_node("Objects") if level.has_node("Objects") else null
			if objects and is_instance_valid(objects) and objects.get_child_count() > 0:
				var last = objects.get_child(objects.get_child_count() - 1)
				if is_instance_valid(last):
					last.queue_free()
					undone = true
					print("[DropEmbed] Deleted last object from level")
	if not undone:
		print("[DropEmbed] Could not undo last drop")
	
	# Find save button if not already hooked
	var sb = _save_button
	if (sb == null or not is_instance_valid(sb)) and _g.Editor and is_instance_valid(_g.Editor):
		sb = _g.Editor.get("saveButton")
	
	if sb and is_instance_valid(sb) and sb is BaseButton:
		sb.emit_signal("pressed")
		if sb.has_method("_pressed"):
			sb._pressed()
		print("[DropEmbed] Save triggered before restart")
	else:
		print("[DropEmbed] No save button, trying Ctrl+S")
		var ev = InputEventKey.new()
		ev.scancode = KEY_S
		ev.control = true
		ev.pressed = true
		Input.parse_input_event(ev)
	
	# Wait for save to complete, then restart
	if _g.World and is_instance_valid(_g.World) and _g.World.is_inside_tree():
		var timer = Timer.new()
		timer.wait_time = 2.0
		timer.one_shot = true
		timer.connect("timeout", self, "_do_restart", [timer])
		_g.World.get_tree().root.add_child(timer)
		timer.start()
	else:
		_do_restart(null)


func _do_restart(timer):
	if timer and is_instance_valid(timer):
		timer.queue_free()
	# Restart DD
	var exe = OS.get_executable_path()
	print("[DropEmbed] Restarting DD: ", exe)
	OS.execute(exe, [], false)
	# Quit current instance
	if _g.World and is_instance_valid(_g.World) and _g.World.is_inside_tree():
		_g.World.get_tree().quit()


func _on_no_dir_closed(dialog: Node):
	if is_instance_valid(dialog):
		dialog.queue_free()


# ===== Dialogs =====

func _add_dialog(dialog: Node):
	var windows = _g.Editor.get_node("Windows") if _g.Editor else null
	if windows != null:
		windows.add_child(dialog)
	else:
		_g.World.get_tree().root.add_child(dialog)


func _show_loading_popup():
	if _loading_dialog != null and is_instance_valid(_loading_dialog):
		return
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var dialog = AcceptDialog.new()
	dialog.window_title = "DropEmbed"
	dialog.dialog_text = "Converting dropped assets into an asset pack...\nPlease wait."
	dialog.get_ok().hide()
	dialog.popup_exclusive = true
	var bar = ProgressBar.new()
	bar.rect_min_size = Vector2(360, 16)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 0
	bar.percent_visible = true
	dialog.add_child(bar)
	_loading_bar = bar
	_loading_dialog = dialog
	_add_dialog(dialog)
	_deferred_popup_centered(dialog, Vector2(440, 110))


func _hide_loading_popup():
	if _loading_dialog != null and is_instance_valid(_loading_dialog):
		_loading_dialog.hide()
		_loading_dialog.queue_free()
	_loading_dialog = null
	_loading_bar = null


func _show_restart_warning():
	_hide_loading_popup()
	if _popup_muted:
		return
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	
	var dialog = AcceptDialog.new()
	dialog.window_title = "DropEmbed"
	dialog.dialog_text = "SUCCESS!\n\nDropped assets have successfully been turned into a\ncustom asset pack that will now be loaded with this map.\n\nPlease restart Dungeondraft when you're ready for it to work as intended."
	
	dialog.add_button("Don't show again (until next session)", true, "mute")
	dialog.connect("custom_action", self, "_on_dialog_action", [dialog])
	dialog.connect("confirmed", self, "_on_dialog_closed", [dialog])
	dialog.connect("popup_hide", self, "_on_dialog_closed", [dialog])
	
	_add_dialog(dialog)
	dialog.popup_exclusive = true
	_deferred_popup_centered(dialog, Vector2(460, 170))


func _deferred_popup_centered(dialog: Node, size: Vector2):
	# Differer popup_centered pour eviter l'erreur is_inside_tree.
	var timer = Timer.new()
	timer.wait_time = 0.05
	timer.one_shot = true
	timer.connect("timeout", self, "_do_popup_centered", [dialog, size, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _do_popup_centered(dialog: Node, size: Vector2, timer: Timer):
	timer.queue_free()
	if not is_instance_valid(dialog):
		return
	if popup_blur != null:
		popup_blur.register(dialog)
	dialog.popup_centered(size)
	_deferred_style(dialog)


func _deferred_style(dialog: Node):
	if not _g.World or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.one_shot = true
	timer.connect("timeout", self, "_style_dialog_buttons", [dialog, timer])
	_g.World.get_tree().root.add_child(timer)
	timer.start()


func _style_dialog_buttons(dialog: Node, timer: Timer):
	timer.queue_free()
	if not is_instance_valid(dialog):
		return
	for child in dialog.get_children():
		if child is Label:
			child.align = Label.ALIGN_CENTER
	for child in dialog.get_children():
		if child is HBoxContainer:
			for btn in child.get_children():
				if btn is Button:
					var existing = btn.get_stylebox("normal")
					if existing != null and existing is StyleBoxFlat:
						var s = existing.duplicate()
						s.border_color = Color(0.6, 0.6, 0.6, 0.7)
						s.set_border_width_all(1)
						s.content_margin_left = 20
						s.content_margin_right = 20
						s.content_margin_top = 6
						s.content_margin_bottom = 6
						btn.add_stylebox_override("normal", s)
						var h = existing.duplicate()
						h.border_color = Color(0.8, 0.8, 0.8, 0.9)
						h.set_border_width_all(1)
						h.content_margin_left = 20
						h.content_margin_right = 20
						h.content_margin_top = 6
						h.content_margin_bottom = 6
						btn.add_stylebox_override("hover", h)


func _on_dialog_action(action: String, dialog: Node):
	if action == "mute":
		_popup_muted = true
		if is_instance_valid(dialog):
			dialog.hide()
			dialog.queue_free()


func _on_dialog_closed(dialog: Node):
	if is_instance_valid(dialog):
		dialog.queue_free()


# ===== Post-Process =====

func _do_post_process():
	if _map_path == "":
		print("[DropEmbed] PP: no map path")
		return
	
	var f = File.new()
	if f.open(_map_path, File.READ) != OK:
		print("[DropEmbed] PP: cannot open ", _map_path)
		return
	var text = f.get_as_text()
	f.close()
	
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		print("[DropEmbed] PP: JSON error")
		return
	var data = parsed.result
	if not data is Dictionary:
		return
	
	var world = data.get("world")
	if not world is Dictionary:
		return
	var embedded = world.get("embedded")
	if not embedded is Dictionary:
		return
	var levels = world.get("levels")
	if not levels is Dictionary:
		return
	
	print("[DropEmbed] PP: ", embedded.keys().size(), " embedded, ", _pack_files.size(), " tracked")
	
	var changes = 0
	var keys_to_remove = []
	var new_pack_files = false
	
	for embed_key in embedded.keys():
		var filename = embed_key.get_file()
		
		if not _pack_files.has(filename):
			# Extract from embedded data
			var embed_data = embedded[embed_key]
			if embed_data is String and embed_data.length() > 0:
				var decoded = Marshalls.base64_to_raw(embed_data)
				if decoded.size() > 0:
					_pack_files[filename] = embed_key
					_tex_cache[filename] = decoded
					new_pack_files = true
					print("[DropEmbed] PP: extracted ", filename)
				else:
					continue
			else:
				continue
		
		var new_res_path = _pack_res_base + "textures/objects/DropEmbed/" + filename
		var embedded_url = "embedded://" + embed_key
		keys_to_remove.append(embed_key)
		
		for level_id in levels:
			var level = levels[level_id]
			if not level is Dictionary:
				continue
			var objects = level.get("objects")
			if not objects is Array:
				continue
			for obj in objects:
				if not obj is Dictionary:
					continue
				if obj.get("texture", "") == embedded_url:
					obj["texture"] = new_res_path
					changes += 1
	
	for key in keys_to_remove:
		embedded.erase(key)
	
	if changes == 0 and keys_to_remove.size() == 0:
		print("[DropEmbed] PP: nothing to convert")
		return
	
	if new_pack_files:
		_save_file_index()
		_rebuild_pack()
	
	_add_to_manifest(data)
	
	var backup_path = _map_path + ".dropfix_backup"
	var dir = Directory.new()
	if not dir.file_exists(backup_path):
		dir.copy(_map_path, backup_path)
	
	if f.open(_map_path, File.WRITE) != OK:
		print("[DropEmbed] PP: cannot write!")
		return
	f.store_string(JSON.print(data, "\t"))
	f.close()
	
	print("[DropEmbed] PP DONE: ", changes, " converted, ", keys_to_remove.size(), " blobs removed")
	_show_restart_warning()


func _add_to_manifest(data: Dictionary) -> bool:
	var header = data.get("header")
	if not header is Dictionary:
		return false
	var manifest = header.get("asset_manifest")
	if not manifest is Array:
		manifest = []
		header["asset_manifest"] = manifest
	for entry in manifest:
		if entry is Dictionary and entry.get("id") == _pack_id:
			return false
	manifest.append({
		"name": "DropEmbed Assets",
		"id": _pack_id,
		"version": "1",
		"author": "Unofficial Patch",
		"keywords": "",
		"allow_3rd_party_mapping_software_to_read": true,
		"custom_color_overrides": {
			"enabled": false, "min_redness": 0.1,
			"min_saturation": 0, "red_tolerance": 0.04
		}
	})
	return true


# ===== PCK Building =====

func _rebuild_pack() -> bool:
	var tex_data = {}
	var missing = []
	for filename in _pack_files:
		if _tex_cache.has(filename):
			tex_data[filename] = _tex_cache[filename]
		else:
			var src_path = _pack_files[filename]
			var f = File.new()
			if f.open(src_path, File.READ) == OK:
				var data = f.get_buffer(f.get_len())
				f.close()
				tex_data[filename] = data
				_tex_cache[filename] = data
			else:
				missing.append(filename)
	
	for m in missing:
		_pack_files.erase(m)
		_tex_cache.erase(m)
	if missing.size() > 0:
		_save_file_index()
	
	if tex_data.size() == 0:
		return false
	
	var pack_json = JSON.print({
		"name": "DropEmbed Assets",
		"id": _pack_id, "version": "1",
		"author": "Unofficial Patch", "keywords": "",
		"allow_3rd_party_mapping_software_to_read": true,
		"custom_color_overrides": {
			"enabled": false, "min_redness": 0.1,
			"min_saturation": 0, "red_tolerance": 0.04
		}
	})
	var pjb = pack_json.to_utf8()
	
	var pck_files = []
	pck_files.append({"path": "res://packs/" + _pack_id + ".json", "data": pjb})
	pck_files.append({"path": "res://packs/" + _pack_id + "/pack.json", "data": pjb})
	
	var tag_paths = []
	for fname in tex_data:
		tag_paths.append("textures/objects/DropEmbed/" + fname)
	var tags_data = {"tags": {"DropEmbed Assets": tag_paths}, "sets": {}}
	tags_data["sets"]["DropEmbed Assets"] = ["DropEmbed Assets"]
	pck_files.append({"path": "res://packs/" + _pack_id + "/data/default.dungeondraft_tags",
		"data": JSON.print(tags_data, "\t").to_utf8()})
	
	for fname in tex_data:
		pck_files.append({
			"path": "res://packs/" + _pack_id + "/textures/objects/DropEmbed/" + fname,
			"data": tex_data[fname]
		})
	
	var ok = _write_pck(_pack_path, pck_files)
	if ok:
		print("[DropEmbed] PCK rebuilt: ", tex_data.size(), " textures -> ", _pack_path.get_file())
	return ok


func _write_pck(path: String, files: Array) -> bool:
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return false
	f.store_buffer("GDPC".to_ascii())
	f.store_32(1)
	f.store_32(3)
	f.store_32(4)
	f.store_32(2)
	for _i in range(16):
		f.store_32(0)
	f.store_32(files.size())
	
	var entries_size = 0
	for entry in files:
		entries_size += 4 + entry["path"].to_utf8().size() + 8 + 8 + 16
	
	var data_start = 88 + entries_size
	var data_offset = 0
	for entry in files:
		var pb = entry["path"].to_utf8()
		var edata = entry["data"]
		f.store_32(pb.size())
		f.store_buffer(pb)
		f.store_64(data_start + data_offset)
		f.store_64(edata.size())
		f.store_buffer(_compute_md5(edata))
		data_offset += edata.size()
	
	for entry in files:
		f.store_buffer(entry["data"])
	f.close()
	return true


func _compute_md5(data: PoolByteArray) -> PoolByteArray:
	var tmp = "user://UnofficialPatch/DropEmbed/tmp"
	var f = File.new()
	if f.open(tmp, File.WRITE) == OK:
		f.store_buffer(data)
		f.close()
		var md5_str = f.get_md5(tmp)
		var md5_bytes = PoolByteArray()
		for i in range(0, md5_str.length(), 2):
			md5_bytes.append(("0x" + md5_str.substr(i, 2)).hex_to_int())
		Directory.new().remove(tmp)
		return md5_bytes
	var zeros = PoolByteArray()
	zeros.resize(16)
	return zeros
