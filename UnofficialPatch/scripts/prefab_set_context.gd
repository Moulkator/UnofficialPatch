# prefab_set_context.gd
# Sub-mod -- Right-click on a prefab set (PrefabTool "Set" dropdown) to
# rename or hide it.
#
# Right-click works both on the dropdown button (acts on the current set) and
# on an entry of the open dropdown list (acts on that entry).
#
# - Rename: a small dialog with a text field (Enter confirms). The folder is
#   renamed on disk and DD's Master.Prefabs is refreshed through its own
#   (static) LoadPrefabs(), so the renamed set is usable right away.
# - Hide (any set, nothing is deleted from disk): after a warning popup the
#   set name is stored in user://UnofficialPatch/prefab_sets.json and filtered
#   out of the dropdown. Deleting that file (or using "Restore hidden sets")
#   brings them back. Built-in res://prefabs sets can only be hidden, not
#   renamed.
#
# Notes:
#   * Master.Prefabs is a static C# SortedDictionary: readable from GDScript
#     (marshalled copy) but not writable. Renaming relies on Master.LoadPrefabs
#     ("user://prefabs/") which only ADDS/refreshes keys -- the stale key of a
#     renamed set survives in memory until restart (harmless: it is never
#     shown in the dropdown).
#   * PrefabTool.Enable() rebuilds the dropdown from Master.Prefabs every time
#     the tool is activated, so the filtering is re-applied by polling.
#   * prefabs_fix.gd restores the last selected set by NAME (not index), which
#     keeps it in sync with the entries removed here.

var _g

const PREFS_PATH := "user://UnofficialPatch/prefab_sets.json"
const USER_ROOT := "user://prefabs"
const RES_ROOT := "res://prefabs"
const PREFAB_EXT := ".dungeondraft_prefab"
const INVALID_NAME_CHARS := "/\\:*?\"<>|"

const CTX_RENAME := 1
const CTX_HIDE := 2
const CTX_RESTORE := 3

var _panel = null
var _set_option: OptionButton = null
var _prefab_tool = null

var _ctx: PopupMenu = null
var _ctx_index := -1
var _ctx_from_popup := false

var _rename_edit: LineEdit = null
var _rename_old := ""

var _hidden := []             # persisted (sets hidden by the user)
var _removed_session := []    # old names of renamed sets, filtered until restart

var _right_was_pressed := false
var _poll_accum := 0.0
const POLL_INTERVAL := 0.2


func initialize() -> void:
	_load_prefs()
	call_deferred("_setup")
	print("[PrefabSetContext] Initialized")


func _setup() -> void:
	if _g == null or _g.Editor == null:
		return
	_panel = _g.Editor.Toolset.GetToolPanel("PrefabTool")
	if _panel == null:
		print("[PrefabSetContext] PrefabTool panel not found")
		return
	var so = _panel.get("setOption")
	if not (so is OptionButton):
		print("[PrefabSetContext] setOption not found")
		return
	_set_option = so
	var tools = _g.Editor.get("Tools")
	if tools is Dictionary:
		_prefab_tool = tools.get("PrefabTool")
	if not _panel.is_connected("visibility_changed", self, "_on_panel_visibility_changed"):
		_panel.connect("visibility_changed", self, "_on_panel_visibility_changed")
	call_deferred("_apply_filter")


func update(delta) -> void:
	if _set_option == null or not is_instance_valid(_set_option):
		return
	var right_now = Input.is_mouse_button_pressed(BUTTON_RIGHT)
	if right_now and not _right_was_pressed:
		_on_right_click()
	_right_was_pressed = right_now
	_poll_accum += delta
	if _poll_accum >= POLL_INTERVAL:
		_poll_accum = 0.0
		if _panel != null and is_instance_valid(_panel) and _panel.is_visible_in_tree():
			if _dropdown_needs_filter():
				_apply_filter()


func _on_panel_visibility_changed() -> void:
	if _panel != null and is_instance_valid(_panel) and _panel.visible:
		call_deferred("_apply_filter")


# ===== Right-click detection =====

func _on_right_click() -> void:
	if _panel == null or not is_instance_valid(_panel) or not _panel.is_visible_in_tree():
		return
	if _rename_edit != null and is_instance_valid(_rename_edit):
		return
	var tree = _set_option.get_tree()
	if tree == null:
		return
	var mouse = tree.root.get_mouse_position()
	var popup = _set_option.get_popup()
	if popup != null and popup.visible and popup.get_global_rect().has_point(mouse):
		var idx = popup.get_current_index()
		if idx < 0:
			idx = _popup_item_at(popup, mouse - popup.rect_global_position)
		if idx >= 0 and idx < _set_option.get_item_count():
			_open_ctx(idx, true, mouse)
		return
	if _set_option.is_visible_in_tree() and _set_option.get_global_rect().has_point(mouse):
		if _set_option.selected >= 0:
			_open_ctx(_set_option.selected, false, mouse)


func _open_ctx(index: int, from_popup: bool, mouse: Vector2) -> void:
	_ctx_index = index
	_ctx_from_popup = from_popup
	var set_name = _set_option.get_item_text(index)
	var builtin = _is_builtin_set(set_name)
	if _ctx == null or not is_instance_valid(_ctx):
		_ctx = PopupMenu.new()
		_ctx.name = "PrefabSetCtx"
		_ctx.connect("id_pressed", self, "_on_ctx_pressed")
		_get_popup_layer().add_child(_ctx)
	_ctx.clear()
	_ctx.add_item("Rename set", CTX_RENAME)
	if builtin:
		_ctx.set_item_disabled(_ctx.get_item_index(CTX_RENAME), true)
		_ctx.set_item_tooltip(_ctx.get_item_index(CTX_RENAME), "Built-in sets cannot be renamed.")
	_ctx.add_item("Hide set", CTX_HIDE)
	if _hidden.size() > 0:
		_ctx.add_separator()
		_ctx.add_item("Restore hidden sets (%d)" % _hidden.size(), CTX_RESTORE)
	_ctx.popup(Rect2(mouse, Vector2(1, 1)))


func _on_ctx_pressed(id: int) -> void:
	if _ctx_index < 0 or _ctx_index >= _set_option.get_item_count():
		_ctx_index = -1
		return
	var set_name = _set_option.get_item_text(_ctx_index)
	match id:
		CTX_RENAME:
			_start_rename(_ctx_index, _ctx_from_popup)
		CTX_HIDE:
			_set_option.get_popup().hide()
			_confirm(
				"Hide prefab set",
				"Hide the set \"%s\"?\nNothing is deleted from disk. It can be restored from this\nmenu, or by deleting %s" % [set_name, PREFS_PATH],
				"Hide", "_do_hide", [set_name])
		CTX_RESTORE:
			_set_option.get_popup().hide()
			_do_restore()
	_ctx_index = -1


# ===== Rename (dialog) =====

func _start_rename(index: int, _from_popup: bool) -> void:
	_rename_old = _set_option.get_item_text(index)
	var popup = _set_option.get_popup()
	if popup != null and popup.visible:
		popup.hide()
	var dlg = ConfirmationDialog.new()
	dlg.window_title = "Rename prefab set"
	dlg.get_ok().text = "Rename"
	# AcceptDialog stretches any extra child Control over its content area:
	# use one VBox holding the label and the field.
	var box = VBoxContainer.new()
	box.add_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = "New name for \"%s\":" % _rename_old
	lbl.align = Label.ALIGN_CENTER
	box.add_child(lbl)
	var edit = LineEdit.new()
	edit.text = _rename_old
	edit.max_length = 64
	box.add_child(edit)
	dlg.add_child(box)
	dlg.register_text_enter(edit)
	_rename_edit = edit
	dlg.connect("confirmed", self, "_on_rename_confirmed", [edit])
	dlg.connect("popup_hide", self, "_on_rename_dialog_hidden", [dlg])
	_add_dialog(dlg)
	dlg.popup_exclusive = true
	dlg.popup_centered(Vector2(440, 150))
	_deferred_style(dlg)
	edit.grab_focus()
	edit.select_all()
	edit.caret_position = edit.text.length()


func _on_rename_confirmed(edit: LineEdit) -> void:
	var new_name = edit.text.strip_edges() if is_instance_valid(edit) else ""
	var old_name = _rename_old
	var err = _validate_new_name(old_name, new_name)
	if err != "":
		_warn("Rename prefab set", err)
		return
	_do_rename(old_name, new_name)


func _on_rename_dialog_hidden(dlg: Node) -> void:
	_rename_edit = null
	_free_dialog(dlg)


func _validate_new_name(old_name: String, new_name: String) -> String:
	if new_name == "":
		return "The set name cannot be empty."
	if new_name == old_name:
		return ""  # no-op, handled by caller
	for i in range(INVALID_NAME_CHARS.length()):
		if new_name.find(INVALID_NAME_CHARS[i]) >= 0:
			return "The set name cannot contain any of: %s" % INVALID_NAME_CHARS
	if new_name.begins_with(".") or new_name.ends_with("."):
		return "The set name cannot start or end with a dot."
	var d = Directory.new()
	if d.dir_exists(USER_ROOT + "/" + new_name) or d.dir_exists(RES_ROOT + "/" + new_name):
		return "A set named \"%s\" already exists." % new_name
	for i in range(_set_option.get_item_count()):
		if _set_option.get_item_text(i).to_lower() == new_name.to_lower():
			return "A set named \"%s\" already exists." % new_name
	if new_name.to_lower() in _lower(_hidden):
		return "\"%s\" is a hidden set." % new_name
	return ""


func _do_rename(old_name: String, new_name: String) -> void:
	if old_name == new_name:
		return
	if _is_builtin_set(old_name):
		_warn("Rename prefab set", "Built-in sets cannot be renamed.")
		return
	var d = Directory.new()
	var old_path = USER_ROOT + "/" + old_name
	var new_path = USER_ROOT + "/" + new_name
	if not d.dir_exists(old_path):
		_warn("Rename prefab set", "Folder not found on disk:\n%s" % ProjectSettings.globalize_path(old_path))
		return
	var err = d.rename(old_path, new_path)
	if err != OK:
		_warn("Rename prefab set", "Could not rename the folder (error %d)." % err)
		return
	print("[PrefabSetContext] Renamed set '%s' -> '%s'" % [old_name, new_name])
	if _prefab_tool != null and _prefab_tool.has_method("Clear"):
		_prefab_tool.Clear()
	_removed_session.append(old_name)
	var file_count = _count_prefab_files(new_path)
	var live := false
	if file_count > 0:
		live = _reload_master_prefabs(new_name)
	if live:
		_rebuild_dropdown([new_name], new_name)
	else:
		# DD's in-memory dictionary does not know the new key: keep it out of
		# the dropdown for this session, it will appear on next launch.
		_removed_session.append(new_name)
		_rebuild_dropdown([], "")
		if file_count > 0:
			_warn("Rename prefab set",
				"The set was renamed on disk, but Dungeondraft could not reload it.\nIt will appear as \"%s\" after restarting Dungeondraft." % new_name)


# Calls Master.LoadPrefabs("user://prefabs/") (private static) so the renamed
# folder gets a key in Master.Prefabs. Returns true when the key is confirmed
# present (or when the dictionary cannot be read back, in which case we trust
# the call).
func _reload_master_prefabs(expect_key: String) -> bool:
	var master = _find_master()
	if master == null or not master.has_method("LoadPrefabs"):
		print("[PrefabSetContext] Master.LoadPrefabs unavailable")
		return false
	master.call("LoadPrefabs", "user://prefabs/")
	var keys = _master_prefab_keys()
	if keys == null:
		return true
	var ok = expect_key in keys
	if not ok:
		print("[PrefabSetContext] Master.Prefabs has no key '%s' after LoadPrefabs" % expect_key)
	return ok


func _master_prefab_keys():
	var master = _find_master()
	if master == null:
		return null
	var p = master.get("Prefabs")
	if p is Dictionary:
		return p.keys()
	return null


func _find_master():
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return null
	var tree = _g.World.get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("Master")


# ===== Delete / hide / restore =====

func _do_hide(set_name: String) -> void:
	if not (set_name in _hidden):
		_hidden.append(set_name)
	_save_prefs()
	if _prefab_tool != null and _prefab_tool.has_method("Clear"):
		_prefab_tool.Clear()
	print("[PrefabSetContext] Hidden set '%s'" % set_name)
	_rebuild_dropdown([], "")


func _do_restore() -> void:
	var restored = _hidden.duplicate()
	_hidden = []
	_save_prefs()
	# Only re-add sets DD actually knows (folder still on disk, key still in
	# Master.Prefabs).
	var d = Directory.new()
	var keys = _master_prefab_keys()
	var extra = []
	for n in restored:
		if n in _removed_session:
			continue
		if not (d.dir_exists(USER_ROOT + "/" + n) or d.dir_exists(RES_ROOT + "/" + n)):
			continue
		if keys != null and not (n in keys):
			continue
		extra.append(n)
	print("[PrefabSetContext] Restored sets: %s" % str(extra))
	var current = _current_set_name()
	_rebuild_dropdown(extra, current)


# ===== Dropdown maintenance =====

func _should_hide(name: String) -> bool:
	if name in _removed_session:
		return true
	if name in _hidden:
		return true
	return false


func _dropdown_needs_filter() -> bool:
	if _removed_session.empty() and _hidden.empty():
		return false
	for i in range(_set_option.get_item_count()):
		if _should_hide(_set_option.get_item_text(i)):
			return true
	return false


func _apply_filter() -> void:
	if _set_option == null or not is_instance_valid(_set_option):
		return
	if not _dropdown_needs_filter():
		return
	_rebuild_dropdown([], _current_set_name())


func _current_set_name() -> String:
	if _set_option.selected < 0 or _set_option.selected >= _set_option.get_item_count():
		return ""
	return _set_option.get_item_text(_set_option.selected)


# Rebuilds the dropdown from its current entries + `extra`, minus the hidden
# ones, sorted like Master.Prefabs. Selects `select_name` if present, else a
# neighbour of the old selection, and emits item_selected so DD (SetSet),
# prefabs_thumbnails and prefabs_fix all refresh.
func _rebuild_dropdown(extra: Array, select_name: String) -> void:
	if _set_option == null or not is_instance_valid(_set_option):
		return
	var old_index = _set_option.selected
	var names = []
	for i in range(_set_option.get_item_count()):
		var n = _set_option.get_item_text(i)
		if not _should_hide(n) and not (n in names):
			names.append(n)
	for n in extra:
		if not _should_hide(n) and not (n in names):
			names.append(n)
	names.sort_custom(self, "_sort_nocase")
	_set_option.clear()
	for n in names:
		_set_option.add_item(n)
	if names.empty():
		var lst = _panel.get("itemList") if _panel != null else null
		if lst is ItemList:
			lst.clear()
		return
	var idx = names.find(select_name)
	if idx < 0:
		idx = int(clamp(old_index, 0, names.size() - 1))
	_set_option.select(idx)
	_set_option.emit_signal("item_selected", idx)


func _sort_nocase(a: String, b: String) -> bool:
	return a.nocasecmp_to(b) < 0


# ===== Prefs =====

func _load_prefs() -> void:
	_hidden = []
	var f = File.new()
	if not f.file_exists(PREFS_PATH):
		return
	if f.open(PREFS_PATH, File.READ) != OK:
		return
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or not (parsed.result is Dictionary):
		return
	var arr = parsed.result.get("hidden_sets", [])
	if arr is Array:
		for n in arr:
			if n is String and n != "":
				_hidden.append(n)


func _save_prefs() -> void:
	var d = Directory.new()
	d.make_dir_recursive(PREFS_PATH.get_base_dir())
	var f = File.new()
	if f.open(PREFS_PATH, File.WRITE) != OK:
		print("[PrefabSetContext] Could not write %s" % PREFS_PATH)
		return
	f.store_string(JSON.print({"hidden_sets": _hidden}, "\t"))
	f.close()


# ===== Helpers =====

func _is_builtin_set(name: String) -> bool:
	var d = Directory.new()
	return d.dir_exists(RES_ROOT + "/" + name)


func _count_prefab_files(dir_path: String) -> int:
	var d = Directory.new()
	if d.open(dir_path) != OK:
		return 0
	var n := 0
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir() and f.ends_with(PREFAB_EXT):
			n += 1
		f = d.get_next()
	d.list_dir_end()
	return n


func _lower(arr: Array) -> Array:
	var out = []
	for s in arr:
		out.append(str(s).to_lower())
	return out


# Item geometry of a PopupMenu (Godot 3 layout: panel margins, vseparation
# between items, height = max(font, icon)). Used as fallback for hit-testing
# and to place the inline rename LineEdit.
func _popup_item_rect(popup: PopupMenu, index: int) -> Rect2:
	var rects = _popup_item_rects(popup)
	if index < 0 or index >= rects.size():
		return Rect2()
	return rects[index]


func _popup_item_at(popup: PopupMenu, local: Vector2) -> int:
	var rects = _popup_item_rects(popup)
	for i in range(rects.size()):
		if rects[i].has_point(local):
			return i
	return -1


func _popup_item_rects(popup: PopupMenu) -> Array:
	var rects = []
	var style = popup.get_stylebox("panel")
	var font = popup.get_font("font")
	if style == null or font == null:
		return rects
	var vsep = popup.get_constant("vseparation")
	var x = style.get_margin(MARGIN_LEFT)
	var y = style.get_margin(MARGIN_TOP)
	var w = popup.rect_size.x - x - style.get_margin(MARGIN_RIGHT)
	for i in range(popup.get_item_count()):
		var h = font.get_height()
		var icon = popup.get_item_icon(i)
		if icon != null:
			h = max(h, icon.get_height())
		if i > 0:
			y += vsep
		rects.append(Rect2(x, y, w, h))
		y += h
	return rects


func _get_popup_layer() -> CanvasLayer:
	var tree = _set_option.get_tree()
	for child in tree.root.get_children():
		if child is CanvasLayer and child.name == "PrefabSetCtxLayer":
			return child
	var layer = CanvasLayer.new()
	layer.name = "PrefabSetCtxLayer"
	layer.layer = 128
	tree.root.add_child(layer)
	return layer


# ===== Dialogs =====

func _confirm(title: String, text: String, ok_label: String, method: String, binds: Array) -> void:
	var dlg = ConfirmationDialog.new()
	dlg.window_title = title
	dlg.dialog_text = text
	dlg.get_ok().text = ok_label
	dlg.connect("confirmed", self, method, binds)
	dlg.connect("popup_hide", self, "_free_dialog", [dlg])
	_add_dialog(dlg)
	dlg.popup_exclusive = true
	dlg.popup_centered(Vector2(460, 140))
	_deferred_style(dlg)


func _warn(title: String, text: String) -> void:
	var dlg = AcceptDialog.new()
	dlg.window_title = title
	dlg.dialog_text = text
	dlg.connect("popup_hide", self, "_free_dialog", [dlg])
	_add_dialog(dlg)
	dlg.popup_exclusive = true
	dlg.popup_centered(Vector2(440, 120))
	_deferred_style(dlg)


func _free_dialog(dlg: Node) -> void:
	if is_instance_valid(dlg):
		dlg.queue_free()


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
