# prefabs_fix.gd
# Sub-mod for BugFixes -- Prefab selection, copy-paste, and save fixes
#
# Fix 1: Box-select dedup
# Fix 2: Copy-paste prefab_id
# Fix 3: Unplaced prefab preview saved to map (v9)
#
#   Covers: Ctrl+S, SAVE button, MENU Save/Save As, UnsavedChanges dialog,
#   AND autosave backups (user://backups/).
#
#   node_ids in .dungeondraft_map files are HEX STRINGS ("1e", "b")
#   while get_meta("node_id") returns DECIMAL INTEGERS (30, 11).

var _g
var select_tool
var prefab_tool
var input_listener: Node

var _was_drawing := false
var _fix_frame_counter := -1

var _next_paste_prefab_id := -1
var _copy_frame_counter := -1
var _copy_generation := 1  # starts at 1; generation=0 is always stale
var _instance_id := 0
var _last_assigned_pid := 0
var _copy_z_order := []  # [{texture, layer}, ...] sorted by z-index at copy time
var _last_active_tool := ""  # pour detecter le retour au PrefabTool

# Fix 3 -- manual save state
var _preview_node_ids_hex := {}
var _patch_pending := false
var _patch_poll_frames := 0
const PATCH_POLL_INTERVAL := 10
const PATCH_POLL_TIMEOUT := 600
var _last_patched_path := ""
var _last_patched_mtime := 0

# Fix 3 -- autosave backup monitoring
var _backup_scan_counter := 0
const BACKUP_SCAN_INTERVAL := 30   # scan every ~0.5s at 60fps
var _known_backups := {}           # {filename: true} -- already seen/patched
var _backups_initialized := false

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	prefab_tool = _g.Editor.Tools["PrefabTool"]
	_install_input_listener()
	call_deferred("_hook_save_ui")
	call_deferred("_hook_select_tool_buttons")
	call_deferred("_discover_prefab_tool_panel")
	call_deferred("_init_known_backups")
	# Enregistrer cette instance comme instance active (la derniere chargee gagne)
	_instance_id = OS.get_ticks_usec()
	Engine.set_meta("pfx_active_instance", _instance_id)
	if not Engine.has_meta("pfx_last_pid"):
		Engine.set_meta("pfx_last_pid", 10000)
	print("[PrefabsFix] Initialized -- instance_id=%d select_tool=%s" % [_instance_id, str(select_tool)])


func _install_input_listener() -> void:
	var tree = _g.World.get_tree() if _g.World else null
	if tree == null or tree.root == null:
		print("[PrefabsFix] ERROR: no tree/root, listener NOT installed")
		return

	# Supprimer tous les anciens listeners orphelins (instances precedentes apres reload de map)
	var purged := 0
	for child in tree.root.get_children():
		if child.name == "PrefabsFixListener":
			child.queue_free()
			purged += 1
	if purged > 0:
		print("[PrefabsFix] Purged %d orphan input listener(s)" % purged)

	input_listener = Node.new()
	input_listener.name = "PrefabsFixListener"
	var listener_script = GDScript.new()
	listener_script.source_code = """extends Node
var handler = null
func _input(event) -> void:
	if handler != null:
		handler._on_input(event)
func _process(delta) -> void:
	if handler != null:
		handler._on_process(delta)
func _on_save_triggered() -> void:
	if handler != null:
		handler._on_save_triggered()
"""
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	tree.root.call_deferred("add_child", input_listener)
	print("[PrefabsFix] Input listener scheduled")


func _on_input(event) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if not event.control:
		return
	# Ignorer si cette instance n'est pas l'instance active (listener orphelin)
	if not Engine.has_meta("pfx_active_instance") or Engine.get_meta("pfx_active_instance") != _instance_id:
		return
	print("[PrefabsFix] _on_input: Ctrl+scancode=%d" % event.scancode)
	if event.scancode == KEY_C:
		var raw = select_tool.RawSelectables
		if raw != null and raw.size() > 0:
			# Ctrl+C valide -- capturer l'ID et incrementer le token de generation
			_copy_generation += 1
			_log_selection_on_copy()
			var world_next = _g.World.get("NextPrefabID")
			if world_next is int and world_next > 0:
				_next_paste_prefab_id = world_next
			elif world_next is String and world_next.is_valid_integer() and int(world_next) > 0:
				_next_paste_prefab_id = int(world_next)
			else:
				_next_paste_prefab_id = _find_max_prefab_id_on_map() + 1
			print("[PrefabsFix] Fix2: Ctrl+C valid gen=%d, World.NextPrefabID=%s next_paste=%d" % [_copy_generation, str(world_next), _next_paste_prefab_id])
			_copy_frame_counter = 1
		else:
			print("[PrefabsFix] Fix2: Ctrl+C ignored (RawSelectables null/empty)")
	elif event.scancode == KEY_V:
		Engine.set_meta("pfx_paste_cooldown", 12)  # 12 frames de grace apres paste
		var map_max = _find_max_prefab_id_on_map()
		var engine_last = int(Engine.get_meta("pfx_last_pid")) if Engine.has_meta("pfx_last_pid") else 10000
		var first_pid = max(max(map_max, engine_last) + 1, 10001)
		print("[PrefabsFix] Fix2: Ctrl+V, first_pid=%d (map_max=%d, engine_last=%d)" % [first_pid, map_max, engine_last])
		var last_used = _rewrite_clipboard_prefab_id_to(first_pid)
		Engine.set_meta("pfx_last_pid", last_used)
	elif event.scancode == KEY_S:
		_on_save_triggered()


func _on_process(_delta) -> void:
	# Fix 1
	var is_drawing_now = select_tool.isDrawing
	if _was_drawing and not is_drawing_now:
		_fix_frame_counter = 2
	if _fix_frame_counter > 0:
		_fix_frame_counter -= 1
	elif _fix_frame_counter == 0:
		_fix_frame_counter = -1
		_apply_dedup_fix()
	_was_drawing = is_drawing_now

	# Fix 2
	if _copy_frame_counter > 0:
		_copy_frame_counter -= 1
	elif _copy_frame_counter == 0:
		_copy_frame_counter = -1
		_rewrite_clipboard_after_copy(0, _copy_generation, _next_paste_prefab_id)

	# Fix 3 -- manual save poll
	if _patch_pending:
		_patch_poll_frames += 1
		if _patch_poll_frames > PATCH_POLL_TIMEOUT:
			_patch_pending = false
			_preview_node_ids_hex.clear()
		elif _patch_poll_frames % PATCH_POLL_INTERVAL == 0:
			_try_patch()

	# Fix 3 -- autosave backup monitoring
	if _backups_initialized:
		_backup_scan_counter += 1
		if _backup_scan_counter >= BACKUP_SCAN_INTERVAL:
			_backup_scan_counter = 0
			_scan_for_new_backups()


# -- Fix 1 -------------------------------------------

func _apply_dedup_fix() -> void:
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return
	var seen_things = {}
	var has_duplicates = false
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if seen_things.has(s.Thing):
			has_duplicates = true
			break
		seen_things[s.Thing] = true
	if not has_duplicates:
		return
	var prefab_representatives = {}
	var non_prefab_things = []
	var seen_nodes = {}
	for s in raw:
		if s == null or s.Thing == null:
			continue
		var thing = s.Thing
		if seen_nodes.has(thing):
			continue
		seen_nodes[thing] = true
		if thing is Node and thing.has_meta("prefab_id"):
			var pid = thing.get_meta("prefab_id")
			if not prefab_representatives.has(pid):
				prefab_representatives[pid] = thing
		else:
			non_prefab_things.append(thing)
	select_tool.DeselectAll()
	for pid in prefab_representatives.keys():
		select_tool.SelectThing(prefab_representatives[pid], true)
	for thing in non_prefab_things:
		select_tool.SelectThing(thing, true)
	select_tool.EnableTransformBox(true)


# -- Fix 2 -------------------------------------------

func _log_selection_on_copy() -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		print("[PrefabsFix] Fix2: Ctrl+C -- RawSelectables=null")
		return
	print("[PrefabsFix] Fix2: Ctrl+C -- %d selectables" % raw.size())
	var seen_pids = {}
	var z_entries = []
	for sel in raw:
		if sel == null or sel.Thing == null:
			continue
		var thing = sel.Thing
		var pid = thing.get_meta("prefab_id") if (thing is Node and thing.has_meta("prefab_id")) else null
		var nid = thing.get_meta("node_id") if (thing is Node and thing.has_meta("node_id")) else null
		var z = thing.get_index() if thing is Node else 0
		var tex = ""
		var spr = thing.get("Sprite")
		if spr and spr.texture:
			tex = spr.texture.resource_path
		var layer = thing.get("layer") if thing.get("layer") != null else -1
		print("[PrefabsFix] Fix2:   node=%s nid=%s prefab_id=%s z=%s tex=%s" % [
			thing.name if thing is Node else str(thing),
			str(nid), str(pid), str(z), tex
		])
		if pid != null:
			seen_pids[str(pid)] = seen_pids.get(str(pid), 0) + 1
		if tex != "":
			z_entries.append({"z": z, "texture": tex})
	print("[PrefabsFix] Fix2: distinct prefab_ids: %s" % str(seen_pids))
	# Trier par z-index et sauvegarder l'ordre
	z_entries.sort_custom(self, "_sort_by_z")
	_copy_z_order = z_entries
	print("[PrefabsFix] Fix2: saved z_order with %d entries" % _copy_z_order.size())


func _sort_by_z(a, b) -> bool:
	return a["z"] < b["z"]


func _rewrite_clipboard_after_copy(attempt: int = 0, generation: int = 0, pid: int = -1) -> void:
	# La reecriture est desormais entierement geree au Ctrl+V -- cette fonction ne fait plus rien.
	pass

func _rewrite_clipboard_prefab_id_only() -> void:
	print("[PrefabsFix] Fix2: prefab_id_only with pid=%d" % _next_paste_prefab_id)
	var clipboard = OS.get_clipboard()
	if clipboard.empty():
		print("[PrefabsFix] Fix2: clipboard empty on paste")
		return
	var parsed = JSON.parse(clipboard)
	if parsed.error != OK:
		return
	var data = parsed.result
	if not data is Dictionary or not data.has("dungeondraft_clipboard"):
		return
	var modified = false
	for section in ["objects", "pathways", "walls", "lights", "portals", "pattern_shapes", "roofs"]:
		if data.has(section) and data[section] is Array:
			for item in data[section]:
				if item is Dictionary and item.has("prefab_id"):
					print("[PrefabsFix] Fix2: paste rewriting %s -> %d" % [str(item.prefab_id), _next_paste_prefab_id])
					item.prefab_id = str(_next_paste_prefab_id)
					modified = true
	if modified:
		OS.set_clipboard(JSON.print(data, "\t"))
		print("[PrefabsFix] Fix2: paste clipboard rewritten OK")
	else:
		print("[PrefabsFix] Fix2: no prefab_id in clipboard on paste")

# ======================================================
# Fix 3: Post-save file patching
# ======================================================


func _rewrite_clipboard_prefab_id_to(first_pid: int) -> int:
	var clipboard = OS.get_clipboard()
	if clipboard.empty():
		print("[PrefabsFix] Fix2: clipboard empty on paste")
		return first_pid - 1
	var parsed = JSON.parse(clipboard)
	if parsed.error != OK:
		return first_pid - 1
	var data = parsed.result
	if not data is Dictionary or not data.has("dungeondraft_clipboard"):
		return first_pid - 1

	# 1. Collecter les pids distincts dans le clipboard
	var old_pids_seen = {}
	for section in ["objects", "pathways", "walls", "lights", "portals", "pattern_shapes", "roofs"]:
		if data.has(section) and data[section] is Array:
			for item in data[section]:
				if item is Dictionary and item.has("prefab_id"):
					old_pids_seen[str(item.prefab_id)] = true

	if old_pids_seen.size() == 0:
		print("[PrefabsFix] Fix2: no prefab_id in clipboard on paste")
		return first_pid - 1

	# 2. Construire le mapping old_pid -> new_pid
	var pid_map = {}
	var next_pid = first_pid
	for old_pid_str in old_pids_seen.keys():
		pid_map[old_pid_str] = next_pid
		next_pid += 1
	print("[PrefabsFix] Fix2: paste pid mapping: %s" % str(pid_map))

	# 3. Reecrire les prefab_ids
	for section in ["objects", "pathways", "walls", "lights", "portals", "pattern_shapes", "roofs"]:
		if data.has(section) and data[section] is Array:
			for item in data[section]:
				if item is Dictionary and item.has("prefab_id"):
					var old_str = str(item.prefab_id)
					if pid_map.has(old_str):
						item.prefab_id = str(pid_map[old_str])

	# 4. Reordonner les objects selon l'ordre z sauvegarde au Ctrl+C
	if _copy_z_order.size() > 0 and data.has("objects") and data["objects"] is Array:
		data["objects"] = _sort_clipboard_objects_by_z(data["objects"])

	OS.set_clipboard(JSON.print(data, "\t"))
	print("[PrefabsFix] Fix2: clipboard rewritten OK, pids %d..%d" % [first_pid, next_pid - 1])
	return next_pid - 1


func _sort_clipboard_objects_by_z(objects: Array) -> Array:
	if _copy_z_order.size() == 0:
		return objects
	# Construire un index de position dans _copy_z_order pour chaque (texture, layer)
	# Pour les doublons (meme texture+layer), on les matche dans l'ordre d'apparition
	var order_counters = {}  # texture -> next index in _copy_z_order
	var tex_to_z = {}  # "texture|occurrence" -> z rank
	for i in range(_copy_z_order.size()):
		var entry = _copy_z_order[i]
		var key = entry["texture"]
		var count = order_counters.get(key, 0)
		tex_to_z["%s|%d" % [key, count]] = i
		order_counters[key] = count + 1

	# Associer chaque item du clipboard a un rang z
	var item_counters = {}
	var ranked = []
	for item in objects:
		if not (item is Dictionary):
			ranked.append({"item": item, "rank": 9999})
			continue
		var tex = str(item.get("texture", ""))
		var count = item_counters.get(tex, 0)
		var lookup = "%s|%d" % [tex, count]
		var rank = tex_to_z.get(lookup, 9999)
		item_counters[tex] = count + 1
		ranked.append({"item": item, "rank": rank})

	ranked.sort_custom(self, "_sort_by_rank")
	var result = []
	for r in ranked:
		result.append(r["item"])
	print("[PrefabsFix] Fix2: z-order reapplied to %d objects" % result.size())
	return result


func _sort_by_rank(a, b) -> bool:
	return a["rank"] < b["rank"]

# ======================================================
# Fix 3: Post-save file patching
# ======================================================

func _has_active_preview() -> bool:
	if prefab_tool == null:
		return false
	var preview = prefab_tool.preview
	return preview != null and preview is Dictionary and preview.size() > 0


func _get_current_map_path() -> String:
	var val = _g.Editor.get("CurrentMapFile")
	if val != null and val is String and val != "":
		return val
	return ""


func _int_to_hex(n: int) -> String:
	if n == 0:
		return "0"
	var hex = ""
	var digits = "0123456789abcdef"
	var v = n
	while v > 0:
		hex = digits[v & 0xF] + hex
		v = v >> 4
	return hex


func _collect_preview_hex_ids() -> Dictionary:
	var ids = {}
	if not _has_active_preview():
		return ids
	for node in prefab_tool.preview.keys():
		if node is Node and is_instance_valid(node) and node.has_meta("node_id"):
			var nid = node.get_meta("node_id")
			if nid is int:
				ids[_int_to_hex(nid)] = true
	return ids


# -- Manual save handling ----------------------------

func _on_save_triggered() -> void:
	if not _has_active_preview():
		return
	if _patch_pending:
		return

	_preview_node_ids_hex = _collect_preview_hex_ids()
	if _preview_node_ids_hex.size() == 0:
		return

	var path = _get_current_map_path()
	if path != "":
		var f = File.new()
		if f.file_exists(path):
			_last_patched_mtime = f.get_modified_time(path)
		else:
			_last_patched_mtime = 0
	else:
		_last_patched_mtime = 0

	_patch_pending = true
	_patch_poll_frames = 0
	_last_patched_path = ""


func _try_patch() -> void:
	var path = _get_current_map_path()
	if path == "":
		return

	if path == _last_patched_path:
		_patch_pending = false
		_preview_node_ids_hex.clear()
		return

	var file = File.new()
	if not file.file_exists(path):
		return

	var current_mtime = file.get_modified_time(path)
	if _last_patched_mtime > 0 and current_mtime <= _last_patched_mtime:
		return

	var count = _patch_map_file(path, _preview_node_ids_hex)
	if count >= 0:
		_last_patched_path = path
		_patch_pending = false
		_preview_node_ids_hex.clear()


# -- Autosave backup monitoring ----------------------

func _init_known_backups() -> void:
	# Snapshot existing backup files so we don't patch old ones.
	var dir = Directory.new()
	if dir.open("user://backups") != OK:
		# Folder might not exist yet -- that's fine, we'll check later.
		_backups_initialized = true
		return
	dir.list_dir_begin(true, true)
	var fname = dir.get_next()
	while fname != "":
		if fname.ends_with(".dungeondraft_map"):
			_known_backups[fname] = true
		fname = dir.get_next()
	dir.list_dir_end()
	_backups_initialized = true
	print("[PrefabsFix] Tracking %d existing backups" % _known_backups.size())


func _scan_for_new_backups() -> void:
	if not _has_active_preview():
		return

	var dir = Directory.new()
	if dir.open("user://backups") != OK:
		return

	dir.list_dir_begin(true, true)
	var fname = dir.get_next()
	var new_files = []
	while fname != "":
		if fname.ends_with(".dungeondraft_map") and not _known_backups.has(fname):
			new_files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	if new_files.size() == 0:
		return

	# Collect current preview hex ids
	var hex_ids = _collect_preview_hex_ids()
	if hex_ids.size() == 0:
		# No preview ids -- just mark files as known
		for f in new_files:
			_known_backups[f] = true
		return

	for f in new_files:
		var full_path = "user://backups/" + f
		_patch_map_file(full_path, hex_ids)
		_known_backups[f] = true


# -- Shared patching logic ---------------------------

func _patch_map_file(path: String, hex_ids: Dictionary) -> int:
	# Returns: number of entries stripped, or -1 if file not ready/error
	var file = File.new()
	var err = file.open(path, File.READ)
	if err != OK:
		return -1
	var content = file.get_as_text()
	file.close()

	if content.empty():
		return -1

	var parsed = JSON.parse(content)
	if parsed.error != OK:
		return -1

	var data = parsed.result
	if not (data is Dictionary):
		return -1

	var total_removed = _strip_preview_entries(data, hex_ids)

	if total_removed > 0:
		err = file.open(path, File.WRITE)
		if err != OK:
			return -1
		file.store_string(JSON.print(data, "\t"))
		file.close()
		print("[PrefabsFix] Patched '%s': stripped %d preview entries" \
			% [path.get_file(), total_removed])

	return total_removed


func _strip_preview_entries(data, hex_ids: Dictionary) -> int:
	var removed = 0
	if data is Dictionary:
		for key in data.keys():
			var val = data[key]
			if val is Array:
				removed += _strip_from_array(data, key, hex_ids)
			elif val is Dictionary:
				removed += _strip_preview_entries(val, hex_ids)
	return removed


func _strip_from_array(parent_dict: Dictionary, key: String, hex_ids: Dictionary) -> int:
	var arr = parent_dict[key]
	if not (arr is Array) or arr.size() == 0:
		return 0

	var has_node_ids = false
	for item in arr:
		if item is Dictionary and item.has("node_id"):
			has_node_ids = true
			break

	if not has_node_ids:
		var removed = 0
		for item in arr:
			if item is Dictionary:
				removed += _strip_preview_entries(item, hex_ids)
		return removed

	var filtered = []
	var removed = 0
	for item in arr:
		if item is Dictionary and item.has("node_id"):
			var nid_str = str(item["node_id"])
			if hex_ids.has(nid_str):
				removed += 1
				continue
		filtered.append(item)
		if item is Dictionary:
			removed += _strip_preview_entries(item, hex_ids)

	if removed > 0:
		parent_dict[key] = filtered
	return removed


# -- UI hooks -----------------------------------------

func _discover_prefab_tool_panel() -> void:
	var panel = _g.Editor.Toolset.GetToolPanel("PrefabTool")
	if panel == null:
		print("[PrefabsFix] PrefabTool panel=null")
		return
	var set_option = panel.get("setOption")
	if set_option is OptionButton:
		if not set_option.is_connected("item_selected", self, "_on_prefab_set_selected"):
			set_option.connect("item_selected", self, "_on_prefab_set_selected")
		print("[PrefabsFix] Hooked PrefabTool setOption")
	else:
		print("[PrefabsFix] PrefabTool setOption NOT found")
	# Detecter le retour au PrefabTool via la visibilite du panel
	if panel.is_connected("visibility_changed", self, "_on_prefab_panel_visibility_changed"):
		pass
	else:
		panel.connect("visibility_changed", self, "_on_prefab_panel_visibility_changed")
		print("[PrefabsFix] Hooked PrefabTool panel visibility_changed")


func _on_prefab_set_selected(index: int) -> void:
	Engine.set_meta("pfx_last_prefab_set", index)
	print("[PrefabsFix] PrefabTool set saved: index=%d" % index)


func _on_prefab_panel_visibility_changed() -> void:
	var panel = _g.Editor.Toolset.GetToolPanel("PrefabTool")
	if panel == null or not panel.visible:
		return
	if not Engine.has_meta("pfx_last_prefab_set"):
		return
	var saved_index = int(Engine.get_meta("pfx_last_prefab_set"))
	var set_option = panel.get("setOption")
	if not (set_option is OptionButton):
		return
	if saved_index < set_option.get_item_count() and set_option.selected != saved_index:
		set_option.select(saved_index)
		var t = _g.World.get_tree().create_timer(0.05)
		t.connect("timeout", self, "_emit_prefab_set_selected", [set_option, saved_index])
		print("[PrefabsFix] PrefabTool set restoring: index=%d" % saved_index)


func _emit_prefab_set_selected(set_option: OptionButton, index: int) -> void:
	set_option.emit_signal("item_selected", index)
	print("[PrefabsFix] PrefabTool set restored: index=%d" % index)


func _hook_select_tool_buttons() -> void:
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		print("[PrefabsFix] _hook_select_tool_buttons: panel=null")
		return

	var copy_btn = panel.get("copyButton")
	var paste_btn = panel.get("pasteButton")

	if copy_btn is BaseButton:
		if not copy_btn.is_connected("pressed", self, "_on_copy_button_pressed"):
			copy_btn.connect("pressed", self, "_on_copy_button_pressed")
			print("[PrefabsFix] Hooked SelectTool copyButton")
	else:
		print("[PrefabsFix] SelectTool copyButton NOT found")

	if paste_btn is BaseButton:
		if not paste_btn.is_connected("button_down", self, "_on_paste_button_pressed"):
			paste_btn.connect("button_down", self, "_on_paste_button_pressed")
			print("[PrefabsFix] Hooked SelectTool pasteButton (button_down)")
	else:
		print("[PrefabsFix] SelectTool pasteButton NOT found")


func _on_copy_button_pressed() -> void:
	# Ignorer si cette instance n'est pas active
	if not Engine.has_meta("pfx_active_instance") or Engine.get_meta("pfx_active_instance") != _instance_id:
		return
	print("[PrefabsFix] Fix2: copy button pressed")
	# Meme logique que Ctrl+C
	var raw = select_tool.RawSelectables
	if raw != null and raw.size() > 0:
		_copy_generation += 1
		_log_selection_on_copy()
		print("[PrefabsFix] Fix2: copy button valid gen=%d" % _copy_generation)
	else:
		print("[PrefabsFix] Fix2: copy button ignored (RawSelectables null/empty)")


func _on_paste_button_pressed() -> void:
	# Ignorer si cette instance n'est pas active
	if not Engine.has_meta("pfx_active_instance") or Engine.get_meta("pfx_active_instance") != _instance_id:
		return
	Engine.set_meta("pfx_paste_cooldown", 12)
	print("[PrefabsFix] Fix2: paste button pressed")
	# Meme logique que Ctrl+V
	var map_max = _find_max_prefab_id_on_map()
	var engine_last = int(Engine.get_meta("pfx_last_pid")) if Engine.has_meta("pfx_last_pid") else 10000
	var first_pid = max(max(map_max, engine_last) + 1, 10001)
	print("[PrefabsFix] Fix2: paste button first_pid=%d" % first_pid)
	var last_used = _rewrite_clipboard_prefab_id_to(first_pid)
	Engine.set_meta("pfx_last_pid", last_used)


func _hook_save_ui() -> void:
	var root = null
	if _g.World and _g.World.get_tree():
		root = _g.World.get_tree().root
	if root == null:
		return

	var save_btn = _g.Editor.get("saveButton")
	if save_btn != null and save_btn is BaseButton:
		if not save_btn.is_connected("pressed", input_listener, "_on_save_triggered"):
			save_btn.connect("pressed", input_listener, "_on_save_triggered")
			print("[PrefabsFix] Hooked Editor.saveButton")

	var unsaved_save = root.get_node_or_null(
		"Master/Editor/Windows/UnsavedChanges/Margins/VAlign/Buttons/SaveButton")
	if unsaved_save and unsaved_save is BaseButton:
		if not unsaved_save.is_connected("pressed", input_listener, "_on_save_triggered"):
			unsaved_save.connect("pressed", input_listener, "_on_save_triggered")
			print("[PrefabsFix] Hooked UnsavedChanges SaveButton")

	var menu_btn = root.get_node_or_null(
		"Master/Editor/VPartition/MenuBar/MenuAlign/MenuButton")
	if menu_btn != null and menu_btn is MenuButton:
		var popup = menu_btn.get_popup()
		if popup:
			var save_ids = []
			for i in range(popup.get_item_count()):
				var label = popup.get_item_text(i)
				if label in ["Save", "Save As...", "Save As", "SAVE", "SAVE_AS"]:
					save_ids.append(popup.get_item_id(i))
			if save_ids.size() > 0:
				# Supprimer les anciens menu listeners orphelins
				var purged := 0
				for child in _g.World.get_children():
					if child.name == "PFMenuListener":
						child.queue_free()
						purged += 1
				if purged > 0:
					print("[PrefabsFix] Purged %d orphan menu listener(s)" % purged)

				var ml = Node.new()
				ml.name = "PFMenuListener"
				var mls = GDScript.new()
				mls.source_code = """extends Node
var handler = null
var save_ids = []
func _on_id(id) -> void:
	if handler != null and id in save_ids:
		handler._on_save_triggered()
"""
				mls.reload()
				ml.set_script(mls)
				ml.handler = self
				ml.save_ids = save_ids
				_g.World.add_child(ml)
				popup.connect("id_pressed", ml, "_on_id")
				print("[PrefabsFix] Hooked MENU popup (ids: %s)" % str(save_ids))


# -- Helpers ------------------------------------------

func _find_max_prefab_id_on_map() -> int:
	var max_pid = 0
	var nodes = _get_all_prefab_nodes()
	for node in nodes:
		if node.has_meta("prefab_id"):
			var pid = node.get_meta("prefab_id")
			var pid_int = pid if pid is int else (int(pid) if pid is String and pid.is_valid_integer() else 0)
			if pid_int > max_pid:
				max_pid = pid_int
	print("[PrefabsFix] Fix2: max_prefab_id scanned %d nodes, max=%d" % [nodes.size(), max_pid])
	return max_pid

func _get_all_prefab_nodes() -> Array:
	var result = []
	var level = _g.World.Level
	if level == null:
		return result
	for cname in ["Objects", "Pathways", "Portals", "Lights", "PatternShapes", "Roofs"]:
		var container = level.get_node_or_null(cname)
		if container:
			for child in container.get_children():
				if child.has_meta("prefab_id"):
					result.append(child)
	var walls = level.get_node_or_null("Walls")
	if walls:
		for child in walls.get_children():
			if child.has_meta("prefab_id"):
				result.append(child)
			for sub in child.get_children():
				if sub.has_meta("prefab_id"):
					result.append(sub)
	return result
