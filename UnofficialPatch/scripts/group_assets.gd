# group_assets.gd
# Sub-mod: Group/Ungroup assets without creating a prefab
#
# Group (Ctrl+G): Assigns a shared prefab_id + Godot group to selected items.
# Ungroup (Ctrl+G when pure group selected): Removes custom group.
# Only affects custom groups (prefab_id >= 10000), never real prefabs.
# Groups persist across save/reload via a .groups.json sidecar file.

var _g
var select_tool
var select_tool_panel
var input_listener: Node

var _group_btn: Button
var _ungroup_btn: Button
var _group_row: HBoxContainer
var _group_wrapper: VBoxContainer
var _cog_btn: Button
var _settings_panel: VBoxContainer
var _group_color_picker: ColorPickerButton
var _group_icon = null
var _ungroup_icon = null
var _icon_group = null
var _icon_ungroup = null

var _load_pending := false
var _load_delay := 0
var _force_mauve_frames := 0
var _force_normal_frames := 0
var _original_box_stylebox = null
var _original_corner_stylebox = null
var _is_mauve := false
var _color_picker_open := false
var _was_pure_group := false
var _was_pure_group_prev := false

var _group_color := Color("E0AFFF")
var _destroyed := false

# ── Copie de groupes ───────────────────────────────────────────────────────────
# Snapshot pris au Ctrl+C/X : structure de groupes de la sélection copiée, sous
# forme de positions RELATIVES au centroïde (robuste à la relocalisation du
# paste et au réordonnancement du clipboard par clipboard_fix). Les murs sont
# exclus (position de node non significative + clipboard walls géré à part).
var _copy_group_map : Array = []   # [{rel: Vector2, gid: int, type: int}]
var _regroup_frames := 0           # compte à rebours avant re-groupage post-paste
var _btn_hooked := false           # hook des boutons Copy/Paste du panel
var _btn_hook_attempts := 0

const CUSTOM_GROUP_MIN_ID = 10000

func initialize() -> void:
	select_tool = _g.Editor.Tools["SelectTool"]
	select_tool_panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	_capture_original_colors()
	_install_input_listener()
	_setup_ui()
	_load_pending = true
	_load_delay = 30
	print("[GroupAssets] Initialized")


# Hot-unload : restore world_ui (selection box / corners / select color),
# free the input/process listener (qui porte _input et _process), free le
# wrapper UI (qui contient _group_row + _settings_panel) et clear les refs.
# Note: les groupes deja crees dans la map restent intacts (stockes dans
# le sidecar .groups.json de la map et dans les prefab_id des assets) —
# ils seront re-charges si Group Assets est rallume plus tard.
func cleanup() -> void:
	_destroyed = true
	# Restore WorldUI styleboxes & color
	var world_ui = _g.WorldUI if _g != null else null
	if world_ui != null:
		if _original_box_stylebox != null:
			world_ui.transformStyleBox = _original_box_stylebox
		if _original_corner_stylebox != null:
			world_ui.transformCornerStyleBox = _original_corner_stylebox
		if _original_select_color != null:
			world_ui.selectionSelectColor = _original_select_color
	# Listener (kills _input + _process callbacks)
	if input_listener != null and is_instance_valid(input_listener):
		input_listener.handler = null
		input_listener.queue_free()
	input_listener = null
	# UI wrapper (contains group row + settings panel)
	if _group_wrapper != null and is_instance_valid(_group_wrapper):
		_group_wrapper.queue_free()
	_group_wrapper = null
	_group_row = null
	_settings_panel = null
	_group_btn = null
	_ungroup_btn = null
	_cog_btn = null
	_group_color_picker = null
	_force_mauve_frames = 0
	_force_normal_frames = 0
	_is_mauve = false
	print("[GroupAssets] Cleaned up")


func _capture_original_colors() -> void:
	var world_ui = _g.WorldUI
	if world_ui == null:
		return
	# We persist the *true* original color in user://UnofficialPatch/
	# original_select_color.json so it survives even if the user quits
	# the app while a group selection is active. Without this, on the
	# next launch we'd capture the mauve color as "original" and never
	# restore the real DD blue.
	var saved = _load_persisted_original_color()
	if saved != null:
		_original_select_color = saved
		# Restore it immediately on the live WorldUI in case it's
		# still mauve from a previous session.
		world_ui.selectionSelectColor = saved
	else:
		_original_select_color = world_ui.selectionSelectColor
		_save_persisted_original_color(_original_select_color)
	# Same idea for the styleboxes.
	_original_box_stylebox = world_ui.transformStyleBox.duplicate()
	_original_corner_stylebox = world_ui.transformCornerStyleBox.duplicate()


func _persisted_original_color_path() -> String:
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	return "user://UnofficialPatch/original_select_color.json"


func _load_persisted_original_color():
	var path = _persisted_original_color_path()
	var f = File.new()
	if not f.file_exists(path):
		return null
	if f.open(path, File.READ) != OK:
		return null
	var txt = f.get_as_text()
	f.close()
	var parsed = JSON.parse(txt)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return null
	var d = parsed.result
	if not (d.has("r") and d.has("g") and d.has("b") and d.has("a")):
		return null
	return Color(float(d["r"]), float(d["g"]), float(d["b"]), float(d["a"]))


func _save_persisted_original_color(c: Color) -> void:
	var path = _persisted_original_color_path()
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return
	var d = {"r": c.r, "g": c.g, "b": c.b, "a": c.a}
	f.store_string(JSON.print(d))
	f.close()


func _install_input_listener() -> void:
	input_listener = Node.new()
	input_listener.name = "GroupAssetsListener"
	var listener_script = GDScript.new()
	listener_script.source_code = "extends Node\nvar handler = null\nfunc _input(event) -> void:\n\tif handler != null:\n\t\thandler._on_input(event)\nfunc _process(delta) -> void:\n\tif handler != null:\n\t\thandler._on_process(delta)\n"
	listener_script.reload()
	input_listener.set_script(listener_script)
	input_listener.handler = self
	if _g.World and _g.World is Node:
		_g.World.call_deferred("add_child", input_listener)


func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	image.load(_g.Root + icon_path)
	if scale != 1.0:
		var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
		image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _disable_color_pipette(picker_btn: ColorPickerButton):
	var picker = picker_btn.get_picker()
	if picker == null:
		return
	for child in picker.get_children():
		if child is ToolButton:
			child.visible = false
			return
	_hide_screen_picker(picker)

func _hide_screen_picker(node):
	for child in node.get_children():
		if child is ToolButton:
			child.visible = false
			return
		if child.get_child_count() > 0:
			_hide_screen_picker(child)


func _setup_ui() -> void:
	if select_tool_panel == null:
		return

	_group_btn = select_tool_panel.CreateButton("Group Selected Assets", "res://ui/icons/misc/search.png")
	_ungroup_btn = select_tool_panel.CreateButton("Ungroup Assets", "res://ui/icons/misc/search.png")

	# Remplacer les icônes placeholder par nos icônes custom
	_group_icon = _load_icon("icons/group.png", 0.85)
	_ungroup_icon = _load_icon("icons/ungroup.png", 0.85)
	if _group_icon != null:
		_group_btn.icon = _group_icon
	if _ungroup_icon != null:
		_ungroup_btn.icon = _ungroup_icon

	_group_btn.hint_tooltip = "Group selected assets (Ctrl+G)"
	_ungroup_btn.hint_tooltip = "Ungroup assets (Ctrl+G)"

	_group_btn.connect("pressed", self, "_on_group_pressed")
	_ungroup_btn.connect("pressed", self, "_on_ungroup_pressed")

	# Cog button
	_cog_btn = Button.new()
	_cog_btn.icon = _load_icon("icons/cog.png", 0.55)
	_cog_btn.hint_tooltip = "Group color settings"
	_cog_btn.toggle_mode = true
	_cog_btn.pressed = false
	_cog_btn.connect("toggled", self, "_on_cog_toggled")

	_group_row = HBoxContainer.new()
	_group_row.name = "GroupButtonRow"

	var group_parent = _group_btn.get_parent()
	var ungroup_parent = _ungroup_btn.get_parent()

	if group_parent:
		group_parent.remove_child(_group_btn)
	if ungroup_parent:
		ungroup_parent.remove_child(_ungroup_btn)

	_group_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ungroup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_group_row.add_child(_group_btn)
	_group_row.add_child(_ungroup_btn)
	_group_row.add_child(_cog_btn)

	# Settings panel (hidden by default)
	_settings_panel = VBoxContainer.new()
	_settings_panel.name = "GroupSettingsPanel"
	_settings_panel.visible = false

	# Group color row
	var group_color_hbox = HBoxContainer.new()
	var group_color_label = Label.new()
	group_color_label.text = "Group"
	group_color_label.rect_min_size.x = 60
	group_color_hbox.add_child(group_color_label)
	_group_color_picker = ColorPickerButton.new()
	_group_color_picker.color = _group_color
	_group_color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_color_picker.connect("color_changed", self, "_on_group_color_changed")
	_group_color_picker.connect("pressed", self, "_on_color_picker_opened")
	_group_color_picker.connect("popup_closed", self, "_on_color_popup_closed")
	group_color_hbox.add_child(_group_color_picker)
	var group_reset = Button.new()
	group_reset.icon = _load_icon("icons/reset.png", 0.5)
	group_reset.hint_tooltip = "Reset group color"
	group_reset.connect("pressed", self, "_on_reset_group_color")
	group_color_hbox.add_child(group_reset)
	_settings_panel.add_child(group_color_hbox)

	# Wrapper pour garder boutons + settings ensemble
	_group_wrapper = VBoxContainer.new()
	_group_wrapper.name = "GroupWrapper"
	_group_wrapper.add_child(_group_row)
	_group_wrapper.add_child(_settings_panel)

	if group_parent:
		var insert_idx = group_parent.get_child_count()
		for i in range(group_parent.get_child_count()):
			var child = group_parent.get_child(i)
			if child is VBoxContainer and not child.visible:
				insert_idx = i
				break
		group_parent.add_child(_group_wrapper)
		group_parent.move_child(_group_wrapper, insert_idx)

	_group_wrapper.visible = false


func _on_cog_toggled(pressed: bool) -> void:
	_settings_panel.visible = pressed



func _on_group_color_changed(color: Color) -> void:
	_group_color = color
	# Appliquer directement aux styleboxes (sans vérifier la sélection
	# car le color picker popup peut avoir désélectionné le groupe)
	var world_ui = _g.WorldUI
	if world_ui != null:
		_apply_color_to_stylebox(world_ui.transformStyleBox, _group_color)
		_apply_color_to_stylebox(world_ui.transformCornerStyleBox, _group_color)
		world_ui.selectionSelectColor = Color(_group_color.r, _group_color.g, _group_color.b, _original_select_color.a if _original_select_color != null else 1.0)
		_is_mauve = true


func _on_color_picker_opened() -> void:
	_color_picker_open = true
	_disable_color_pipette(_group_color_picker)


func _on_color_popup_closed() -> void:
	_color_picker_open = false
	_save_color_settings()


func _on_reset_group_color() -> void:
	_group_color = Color("E0AFFF")
	_group_color_picker.color = _group_color
	# Appliquer directement
	var world_ui = _g.WorldUI
	if world_ui != null and _is_mauve:
		_apply_color_to_stylebox(world_ui.transformStyleBox, _group_color)
		_apply_color_to_stylebox(world_ui.transformCornerStyleBox, _group_color)
		world_ui.selectionSelectColor = Color(_group_color.r, _group_color.g, _group_color.b, _original_select_color.a if _original_select_color != null else 1.0)
	_save_color_settings()


func _on_input(event) -> void:
	if _destroyed:
		return
	if not is_instance_valid(input_listener) or input_listener.get_parent() != _g.World:
		return
	if event is InputEventKey and event.pressed and event.control:
		if event.scancode == KEY_G:
			var raw = select_tool.RawSelectables
			if _selection_is_pure_custom_group(raw):
				_on_ungroup_pressed()
			else:
				_on_group_pressed()
		elif event.scancode == KEY_C or event.scancode == KEY_X:
			if not event.echo:
				# 1) Filet de sécurité : purger les Selectables en double AVANT
				#    que DD ne sérialise (chaque doublon = un asset dupliqué au
				#    paste). 2) Snapshot de la structure de groupes copiée pour
				#    re-grouper les assets collés.
				_dedupe_selection()
				_snapshot_copy_groups()
		elif event.scancode == KEY_V:
			if not event.echo and _copy_group_map.size() > 0:
				# Le paste + la relocalisation (clipboard_fix) prennent quelques
				# frames : on re-groupe une fois la sélection collée stabilisée.
				_regroup_frames = 12


func _on_process(_delta) -> void:
	if _destroyed:
		return
	# Ne rien faire si notre World n'est plus le World actuel (reload en cours)
	if not is_instance_valid(input_listener) or not input_listener.is_inside_tree():
		return
	if input_listener.get_parent() != _g.World:
		return

	_update_visibility()
	_sync_dd_separate_button()

	if _load_pending:
		if _load_delay > 0:
			_load_delay -= 1
		else:
			_load_pending = false
			_load_groups()

	if _force_mauve_frames > 0:
		_force_mauve_frames -= 1
		_update_transform_box_color(true)
	if _force_normal_frames > 0:
		_force_normal_frames -= 1
		_update_transform_box_color(false)

	if _regroup_frames > 0:
		_regroup_frames -= 1
		if _regroup_frames == 0:
			_regroup_pasted()

	# Hook des boutons Copy/Paste du SelectTool panel (no-op une fois fait).
	if not _btn_hooked:
		_try_hook_panel_buttons()


# -- Visibility -------------------------------------------

func _update_visibility() -> void:
	if _group_wrapper == null:
		return

	# Cacher quand FreeTransform est actif
	var ft_active = _g.ModMapData.get("_free_transform_active", false) if _g.ModMapData is Dictionary else false
	if ft_active:
		_group_wrapper.visible = false
		_update_transform_box_color(false)
		return

	if select_tool_panel == null or not select_tool_panel.visible:
		_group_wrapper.visible = false
		_update_transform_box_color(false)
		return

	var raw = select_tool.RawSelectables
	var sel_count = _count_unique_selectables(raw)
	var is_pure_group = _selection_is_pure_custom_group(raw)

	# DIAG: log quand multi-selection mais pas pure group
	if sel_count >= 2 and not is_pure_group and _was_pure_group:
		print("[GroupAssets] DIAG lost pure_group: sel_count=", sel_count)
		var seen = {}
		for s in raw:
			if s == null or s.Thing == null:
				continue
			if seen.has(s.Thing):
				continue
			seen[s.Thing] = true
			var t = s.Thing
			var has_pid = t.has_meta("prefab_id")
			var pid = t.get_meta("prefab_id") if has_pid else -1
			print("[GroupAssets]   Thing=", t.get_class(), " name=", t.name,
				" has_pid=", has_pid, " pid=", pid)
	_was_pure_group = is_pure_group

	var should_show = sel_count >= 2
	_group_wrapper.visible = should_show

	if should_show:
		if is_pure_group:
			_group_btn.visible = false
			_ungroup_btn.visible = true
			_ungroup_btn.disabled = false
		else:
			_group_btn.visible = true
			_ungroup_btn.visible = false
			_group_btn.disabled = false
		_settings_panel.visible = _cog_btn.pressed
	else:
		if not _cog_btn.pressed:
			_settings_panel.visible = false

	# Couleur groupe uniquement pour les sélections de groupe pur
	# Forcer pendant quelques frames quand un groupe vient d'être sélectionné
	# (DD/PathFix peut recréer la transform box et reset la couleur)
	if is_pure_group and not _was_pure_group_prev:
		_force_mauve_frames = 10
	_was_pure_group_prev = is_pure_group
	_update_transform_box_color(is_pure_group)


# -- Copie de groupes -------------------------------------

const SELECTABLE_WALL_TYPE := 1

# Snapshot pris juste avant la sérialisation (Ctrl+C/X) : pour chaque thing
# sélectionné (hors murs), sa position relative au centroïde de la sélection,
# son gid custom (ou -1) et son type de Selectable. Vidé si aucun groupe.
func _snapshot_copy_groups() -> void:
	_copy_group_map = []
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var seen = {}
	var entries: Array = []
	var centroid = Vector2.ZERO
	var n = 0
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if int(s.Type) == SELECTABLE_WALL_TYPE:
			continue
		if not (s.Thing is Node2D):
			continue
		var id = s.Thing.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		var gid = _get_custom_gid(s.Thing)
		entries.append({"pos": s.Thing.global_position,
			"gid": gid if gid >= CUSTOM_GROUP_MIN_ID else -1,
			"type": int(s.Type)})
		centroid += s.Thing.global_position
		n += 1
	if n == 0:
		return
	centroid /= n
	var any_group = false
	for e in entries:
		e["rel"] = e["pos"] - centroid
		if e["gid"] >= CUSTOM_GROUP_MIN_ID:
			any_group = true
	if not any_group:
		return
	_copy_group_map = entries
	print("[GroupAssets] Copy snapshot: %d things (with groups)" % entries.size())


# Re-groupe les assets collés en répliquant la partition copiée. Le matching
# copié → collé se fait par position relative au centroïde (par type de
# Selectable) : robuste au décalage uniforme du paste et à l'ordre du clipboard.
# Chaque gid copié reçoit un gid FRAIS (le collage forme de nouveaux groupes,
# indépendants des originaux). Undo/redo via _restore_group_state.
func _regroup_pasted() -> void:
	if _copy_group_map.empty():
		return
	var raw = select_tool.RawSelectables
	if raw == null:
		return
	var seen = {}
	var pasted: Array = []
	var centroid = Vector2.ZERO
	var n = 0
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		if int(s.Type) == SELECTABLE_WALL_TYPE:
			continue
		if not (s.Thing is Node2D):
			continue
		var id = s.Thing.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		pasted.append({"thing": s.Thing, "type": int(s.Type)})
		centroid += s.Thing.global_position
		n += 1
	if n == 0:
		return
	centroid /= n
	for p in pasted:
		p["rel"] = p["thing"].global_position - centroid

	# Matching glouton plus-proche-voisin, par type.
	var base_gid = _generate_group_id()
	var gid_map = {}          # gid copié → gid frais
	var assignments: Array = []
	var used = {}
	for e in _copy_group_map:
		if e["gid"] < CUSTOM_GROUP_MIN_ID:
			continue
		var best = -1
		var best_d = 1e18
		for i in range(pasted.size()):
			if used.has(i):
				continue
			if pasted[i]["type"] != e["type"]:
				continue
			var d = pasted[i]["rel"].distance_squared_to(e["rel"])
			if d < best_d:
				best_d = d
				best = i
		if best < 0:
			continue
		used[best] = true
		if not gid_map.has(e["gid"]):
			# _generate_group_id scanne la map : tant que les metas ne sont pas
			# posées, il renvoie la même valeur → allocation séquentielle.
			gid_map[e["gid"]] = base_gid + gid_map.size()
		assignments.append({"thing": pasted[best]["thing"], "gid": gid_map[e["gid"]]})
	if assignments.empty():
		return

	var pre_state: Array = []
	var post_state: Array = []
	for a in assignments:
		var thing = a["thing"]
		if _is_real_prefab(thing):
			continue
		var old_pid = -1
		if thing.has_meta("prefab_id"):
			var v = thing.get_meta("prefab_id")
			if v is int:
				old_pid = v
		pre_state.append({"ref": weakref(thing), "old_pid": old_pid})
		post_state.append({"ref": weakref(thing), "old_pid": a["gid"]})
		_remove_from_custom_group(thing)
		thing.set_meta("prefab_id", a["gid"])
		var group_name = str(a["gid"])
		if not thing.is_in_group(group_name):
			thing.add_to_group(group_name)
	_save_groups()

	# Re-sélection propre : couleur AVANT (les hoverboxes sont peintes au
	# SelectThing), une seule sélection par thing (anti-doublon).
	var all_things: Array = []
	for p in pasted:
		all_things.append(p["thing"])
	var pure = _all_share_custom_group(all_things)
	_update_transform_box_color(pure)
	if pure:
		_force_mauve_frames = 10
	select_tool.DeselectAll()
	_select_things_no_dup(all_things)
	select_tool.EnableTransformBox(true)

	var undo = _get_undo_lib()
	if undo != null:
		undo.record_callback(
			self, "_restore_group_state", [pre_state],
			self, "_restore_group_state", [post_state])
	print("[GroupAssets] Regrouped %d pasted things into %d group(s)" % [assignments.size(), gid_map.size()])


# -- Group ------------------------------------------------

func _on_group_pressed() -> void:
	var raw = select_tool.RawSelectables
	if raw == null:
		return

	var things = _get_unique_things(raw)
	if things.size() < 2:
		return

	var new_gid = _generate_group_id()
	var group_name = str(new_gid)

	# Capture pre-state for undo: which things will be modified, and
	# what their prefab_id was before (might be -1 for none, or another
	# custom-group id if they were already grouped). Build a list of
	# {"ref": WeakRef, "old_pid": int_or_minus_one} entries we can use
	# at undo time. We snapshot AFTER filtering out real prefabs since
	# those are skipped by the loop below.
	var pre_state: Array = []
	for thing in things:
		if _is_real_prefab(thing):
			continue
		var old_pid = -1
		if thing.has_meta("prefab_id"):
			var v = thing.get_meta("prefab_id")
			if v is int:
				old_pid = v
		pre_state.append({"ref": weakref(thing), "old_pid": old_pid})

	var grouped_count = 0
	for thing in things:
		if _is_real_prefab(thing):
			continue
		_remove_from_custom_group(thing)
		thing.set_meta("prefab_id", new_gid)
		if not thing.is_in_group(group_name):
			thing.add_to_group(group_name)
		grouped_count += 1

	if grouped_count >= 2:
		# IMPORTANT: apply the mauve color BEFORE re-selecting so DD
		# paints every hoverbox with the right color in one go.
		# Setting it afterwards leaves already-painted boxes blue.
		_update_transform_box_color(true)
		_force_mauve_frames = 5
		# DeselectAll + re-select EACH thing forces DD to repaint every
		# hoverbox with the current selectionSelectColor. Selecting only
		# things[0] (relying on DD's group-expansion to bring the rest
		# in) doesn't trigger a repaint on those that come in via the
		# group, so they kept the previous hover color.
		select_tool.DeselectAll()
		var to_sel: Array = []
		for thing in things:
			if _is_real_prefab(thing):
				continue
			to_sel.append(thing)
		_select_things_no_dup(to_sel)
		select_tool.EnableTransformBox(true)
		_save_groups()
		# Register undo: pre_state captures the previous prefab_ids,
		# new_gid is what we just applied. Both directions are
		# expressed via _restore_group_state which assigns a target
		# pid (or removes it when -1) for each ref.
		var undo = _get_undo_lib()
		if undo != null:
			# For redo, every ref gets pid = new_gid.
			var post_state: Array = []
			for entry in pre_state:
				post_state.append({"ref": entry["ref"], "old_pid": new_gid})
			undo.record_callback(
				self, "_restore_group_state", [pre_state],
				self, "_restore_group_state", [post_state])


# -- Ungroup ----------------------------------------------

func _on_ungroup_pressed() -> void:
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return

	var things = _get_unique_things(raw)
	var ungrouped_any = false

	# Capture pre-state: which custom-group things will be ungrouped,
	# and what pid they had. Used to redo the ungroup AND to undo it
	# (assigning the original pid back).
	var pre_state: Array = []
	for thing in things:
		if _is_custom_group(thing):
			var old_pid = -1
			if thing.has_meta("prefab_id"):
				var v = thing.get_meta("prefab_id")
				if v is int:
					old_pid = v
			pre_state.append({"ref": weakref(thing), "old_pid": old_pid})

	for thing in things:
		if _is_custom_group(thing):
			_remove_from_custom_group(thing)
			ungrouped_any = true

	if ungrouped_any:
		# Re-select the now-ungrouped things with the normal (non-mauve)
		# transform box so the user keeps editing context. Without this
		# the panel goes empty and you have to click again.
		# Reselectionner TOUTE la selection d'origine (pas seulement les
		# ex-groupes) : sur une selection mixte, les membres non groupes
		# doivent rester selectionnes apres l'Ungroup.
		var to_reselect: Array = []
		for t in things:
			if t != null and is_instance_valid(t):
				to_reselect.append(t)
		# IMPORTANT: restore the normal color BEFORE the re-selection.
		# DD reads selectionSelectColor at SelectThing() time to paint
		# the hoverboxes; if we change the color afterwards, the
		# already-painted boxes keep the old (mauve) color until the
		# user manually re-selects.
		_update_transform_box_color(false)
		_force_normal_frames = 10
		select_tool.DeselectAll()
		_select_things_no_dup(to_reselect)
		if to_reselect.size() > 0:
			select_tool.EnableTransformBox(true)
		else:
			select_tool.EnableTransformBox(false)
		_save_groups()
		var undo = _get_undo_lib()
		if undo != null:
			# After ungroup, all refs have no pid (pid = -1).
			var post_state: Array = []
			for entry in pre_state:
				post_state.append({"ref": entry["ref"], "old_pid": -1})
			undo.record_callback(
				self, "_restore_group_state", [pre_state],
				self, "_restore_group_state", [post_state])


# -- Undo helper ------------------------------------------

func _restore_group_state(state: Array) -> void:
	# Assigns each ref's prefab_id (and matching Godot group) to
	# whatever value is recorded as "old_pid". A value of -1 means
	# "no group" (clear the meta + group). Used for both undo and
	# redo of group/ungroup operations.
	# Also re-selects the affected things so the user keeps their
	# editing context (and sees the right transform-box color).
	var to_select: Array = []
	for entry in state:
		var thing = entry["ref"].get_ref()
		if thing == null or not is_instance_valid(thing):
			continue
		# Real prefabs are never touched by this mod and shouldn't be
		# touched here either. Safety check.
		if _is_real_prefab(thing):
			continue
		# Clean up whatever custom-group state currently exists.
		_remove_from_custom_group(thing)
		var target_pid: int = entry["old_pid"]
		if target_pid >= CUSTOM_GROUP_MIN_ID:
			thing.set_meta("prefab_id", target_pid)
			var group_name = str(target_pid)
			if not thing.is_in_group(group_name):
				thing.add_to_group(group_name)
		to_select.append(thing)
	_save_groups()
	
	# Defer re-selection. Our callback runs synchronously inside
	# Editor.History.Undo(), which then continues with its own cleanup
	# that wipes the selection. Pushing the re-select to the next
	# idle frame lets DD finish first, then we set the state we want.
	if to_select.size() > 0:
		call_deferred("_apply_restored_selection", to_select)


func _apply_restored_selection(to_select: Array) -> void:
	if select_tool == null:
		return
	# Filter once more — some refs might have been disposed between
	# the deferred call and now.
	var live: Array = []
	for thing in to_select:
		if is_instance_valid(thing):
			live.append(thing)
	if live.empty():
		return
	# Apply the right color BEFORE re-selecting so hoverboxes are
	# painted with the correct selectionSelectColor in one pass.
	var is_group := _all_share_custom_group(live)
	_update_transform_box_color(is_group)
	if is_group:
		_force_mauve_frames = 10
	else:
		_force_normal_frames = 10
	select_tool.DeselectAll()
	_select_things_no_dup(live)
	select_tool.EnableTransformBox(true)


# ── Sélection sans doublons ────────────────────────────────────────────────────
# SelectTool.SelectThing(thing, true) crée TOUJOURS un nouveau Selectable
# (aucun contrôle « déjà sélectionné » côté DD), et Select(true) étend la
# sélection aux membres du groupe Godot — l'expansion, elle, a un guard
# anti-doublon (c == null). Sélectionner chaque membre d'un groupe en boucle
# produit donc des Selectables en double pour tous les membres déjà amenés par
# l'expansion : Serialize() (Ctrl+C) les sérialise alors N fois → assets
# dupliqués au paste (×2, ×3…). On ne sélectionne que les things ABSENTS de la
# sélection courante ; l'expansion de groupe fait le reste (et repeint les
# hoverboxes via le switch de Select()).
func _select_things_no_dup(things: Array) -> void:
	for thing in things:
		if thing == null or not is_instance_valid(thing):
			continue
		if _is_thing_selected(thing):
			continue
		select_tool.SelectThing(thing, true)


func _is_thing_selected(thing) -> bool:
	var raw = select_tool.RawSelectables
	if raw == null:
		return false
	for s in raw:
		if s != null and s.Thing == thing:
			return true
	return false


# Purge les Selectables en double (même Thing présent plusieurs fois) en
# reconstruisant la sélection. NB : Select(s, false) sur un membre de groupe
# cascade la désélection à tout le groupe (expansion), donc on ne peut pas
# retirer les doublons un à un — on repart de zéro.
func _dedupe_selection() -> bool:
	var raw = select_tool.RawSelectables
	if raw == null:
		return false
	var seen = {}
	var unique: Array = []
	var has_dup = false
	for s in raw:
		if s == null or s.Thing == null or not is_instance_valid(s.Thing):
			continue
		var id = s.Thing.get_instance_id()
		if seen.has(id):
			has_dup = true
		else:
			seen[id] = true
			unique.append(s.Thing)
	if not has_dup:
		return false
	select_tool.DeselectAll()
	_select_things_no_dup(unique)
	select_tool.EnableTransformBox(true)
	print("[GroupAssets] Deduped selection: %d unique things" % unique.size())
	return true


# ── Boutons Copy/Paste du panel ────────────────────────────────────────────────
# Les boutons appellent Copy()/Paste() en direct (pas d'InputEventKey) : les
# chemins Ctrl+C/V ci-dessus ne les voient pas. DD a connecté ses boutons avant
# nous, donc nos handlers "pressed" tournent APRÈS l'action native.
func _try_hook_panel_buttons() -> void:
	if _btn_hooked:
		return
	_btn_hook_attempts += 1
	if _btn_hook_attempts > 600:
		_btn_hooked = true  # abandon (panel introuvable)
		return
	if select_tool_panel == null or not is_instance_valid(select_tool_panel):
		return
	var copy_btn = select_tool_panel.get("copyButton")
	if copy_btn == null or not (copy_btn is BaseButton):
		return
	if not copy_btn.is_connected("pressed", self, "_on_copy_button_pressed"):
		copy_btn.connect("pressed", self, "_on_copy_button_pressed")
	var paste_btn = select_tool_panel.get("pasteButton")
	if paste_btn != null and paste_btn is BaseButton:
		if not paste_btn.is_connected("pressed", self, "_on_paste_button_pressed"):
			paste_btn.connect("pressed", self, "_on_paste_button_pressed")
	_btn_hooked = true
	print("[GroupAssets] SelectTool copy/paste buttons hooked")


func _on_copy_button_pressed() -> void:
	if _destroyed:
		return
	# La Copy() native a déjà tourné : si la sélection contenait des Selectables
	# en double, le clipboard vient d'être sérialisé AVEC les doublons. On
	# dédoublonne puis on re-copie proprement (même contenu, sans doublons).
	var had_dups = _dedupe_selection()
	_snapshot_copy_groups()
	if had_dups:
		select_tool.Copy()


func _on_paste_button_pressed() -> void:
	if _destroyed:
		return
	if _copy_group_map.size() > 0:
		_regroup_frames = 12


# Bouton "Separate" NATIF du panneau SelectTool : DD l'affiche des que la
# selection appartient a un groupe quelconque — donc aussi pour nos groupes
# custom, qui ne sont pas des prefabs (et son Separate court-circuiterait la
# comptabilite des groupes : sidecar json, undo). On le cache quand la
# selection ne contient AUCUN vrai prefab, on le laisse quand il y en a un.
var _dd_separate_btn = null

func _sync_dd_separate_button() -> void:
	var btn = _dd_separate_btn
	if btn == null or not is_instance_valid(btn):
		btn = _find_dd_separate_button()
		_dd_separate_btn = btn
	if btn == null:
		return
	if select_tool == null or not is_instance_valid(select_tool):
		return
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		return   # selection vide : DD gere (bouton deja cache)
	var has_real = false
	var has_custom = false
	for thing in _get_unique_things(raw):
		if not is_instance_valid(thing):
			continue
		if _is_custom_group(thing):
			has_custom = true
		elif thing.has_meta("prefab_id"):
			has_real = true
	if has_real:
		btn.visible = true
	elif has_custom:
		btn.visible = false


func _find_dd_separate_button():
	if _g == null or _g.Editor == null or _g.Editor.get("Toolset") == null:
		return null
	var panel = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null or not is_instance_valid(panel):
		return null
	return _find_button_by_needle(panel, "separate", 0)


func _find_button_by_needle(node: Node, needle: String, depth: int):
	if node == null or depth > 8:
		return null
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is BaseButton:
			var haystack = ("%s %s %s" % [child.name, child.get("text"), child.hint_tooltip]).to_lower()
			if needle in haystack:
				return child
		var found = _find_button_by_needle(child, needle, depth + 1)
		if found != null:
			return found
	return null


func _all_share_custom_group(things: Array) -> bool:
	# True if every thing has the same prefab_id and that id is in the
	# custom-group range. Used to decide the transform-box color after
	# an undo/redo restores a multi-item selection.
	if things.size() < 2:
		return false
	var ref_pid = -1
	for thing in things:
		if not is_instance_valid(thing):
			return false
		if not thing.has_meta("prefab_id"):
			return false
		var pid = thing.get_meta("prefab_id")
		if not (pid is int) or pid < CUSTOM_GROUP_MIN_ID:
			return false
		if ref_pid == -1:
			ref_pid = pid
		elif pid != ref_pid:
			return false
	return true


func _get_undo_lib():
	if _g == null or _g.get("ModMapData") == null:
		return null
	return _g.ModMapData.get("_undo_lib")


# -- Right-click provider (pour right_click_util) ----------

func get_context_items(raw) -> Array:
	var items = []
	var sel_count = _count_unique_selectables(raw)
	if sel_count < 2:
		return items

	var is_pure_group = _selection_is_pure_custom_group(raw)
	if is_pure_group:
		var icon = _load_icon("icons/ungroup.png", 0.85) if _ungroup_icon == null else _ungroup_icon
		items.append({label = "Ungroup Assets", icon = icon, action_id = "ungroup"})
	else:
		var icon = _load_icon("icons/group.png", 0.85) if _group_icon == null else _group_icon
		items.append({label = "Group Selected Assets", icon = icon, action_id = "group"})
		# Selection MIXTE (groupes + non-groupes) : proposer aussi Ungroup —
		# _on_ungroup_pressed ne degroupe que les membres effectivement
		# groupes, l'action est donc bien definie sur un mix.
		if _selection_has_custom_group(raw):
			var uicon = _load_icon("icons/ungroup.png", 0.85) if _ungroup_icon == null else _ungroup_icon
			items.append({label = "Ungroup Assets", icon = uicon, action_id = "ungroup"})
	return items


func on_context_action(action_id: String, raw) -> void:
	match action_id:
		"group":
			_on_group_pressed()
		"ungroup":
			_on_ungroup_pressed()


# -- Persistence ------------------------------------------

func _get_groups_file_path() -> String:
	var dir = Directory.new()
	if not dir.dir_exists("user://UnofficialPatch"):
		dir.make_dir("user://UnofficialPatch")
	return "user://UnofficialPatch/groups.json"


func _get_map_key() -> String:
	var map_file = _g.Editor.get("CurrentMapFile") if _g.Editor else null
	if map_file != null and map_file is String and map_file != "":
		return map_file.get_file().get_basename()
	return "_unsaved"


func _load_all_data() -> Dictionary:
	var path = _get_groups_file_path()
	var file = File.new()
	if not file.file_exists(path):
		return {}
	var err = file.open(path, File.READ)
	if err != OK:
		return {}
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or not parsed.result is Dictionary:
		return {}
	return parsed.result


func _save_all_data(all_data: Dictionary) -> void:
	var path = _get_groups_file_path()
	var file = File.new()
	var err = file.open(path, File.WRITE)
	if err != OK:
		print("[GroupAssets] Failed to save: " + path)
		return
	file.store_line(JSON.print(all_data, "\t"))
	file.close()


func _node_fingerprint(node) -> String:
	# Create a stable fingerprint from local position + class + texture path
	# (global_position shifts with Level offset between reloads)
	var parts = []
	if node is Node2D:
		parts.append("%.1f,%.1f" % [node.position.x, node.position.y])
	parts.append(node.get_class())
	# Try to get texture path for uniqueness
	if node.get("Texture") != null and node.Texture != null:
		parts.append(node.Texture.resource_path)
	elif node.has_method("get_texture"):
		var tex = node.get_texture()
		if tex != null:
			parts.append(tex.resource_path)
	elif node.get("_Texture") != null and node._Texture != null:
		parts.append(node._Texture.resource_path)
	return PoolStringArray(parts).join("|")


func _save_groups() -> void:
	var level = _g.World.Level
	if level == null:
		return

	var groups = {}
	var all_nodes = _get_all_groupable_nodes()

	for node in all_nodes:
		if _is_custom_group(node):
			var pid = node.get_meta("prefab_id")
			var fp = _node_fingerprint(node)
			var pid_str = str(pid)
			if not groups.has(pid_str):
				groups[pid_str] = []
			groups[pid_str].append(fp)

	var all_data = _load_all_data()
	var map_key = _get_map_key()
	# Groupes par map
	if not all_data.has("maps"):
		all_data["maps"] = {}
	all_data["maps"][map_key] = {
		"custom_groups": groups
	}
	# Couleur globale (partagée entre toutes les maps)
	all_data["colors"] = {
		"group": _group_color.to_html(false)
	}
	_save_all_data(all_data)
	print("[GroupAssets] Saved %d group(s) for '%s'" % [groups.size(), map_key])


func _load_groups() -> void:
	var all_data = _load_all_data()

	# Charger la couleur globale
	if all_data.has("colors") and all_data.colors is Dictionary:
		if all_data.colors.has("group"):
			_group_color = Color(all_data.colors.group)
			if _group_color_picker:
				_group_color_picker.color = _group_color

	# Charger les groupes de la map courante
	var map_key = _get_map_key()
	var maps = all_data.get("maps")
	if maps == null or not maps is Dictionary or not maps.has(map_key):
		return

	var data = maps[map_key]
	if not data is Dictionary or not data.has("custom_groups"):
		return

	var groups = data.custom_groups
	if not groups is Dictionary:
		return

	var fp_lookup = {}
	var all_nodes = _get_all_groupable_nodes()
	for node in all_nodes:
		var fp = _node_fingerprint(node)
		fp_lookup[fp] = node

	var restored_count = 0
	for gid_str in groups:
		var gid = int(gid_str)
		if gid < CUSTOM_GROUP_MIN_ID:
			continue

		var fingerprints = groups[gid_str]
		if not fingerprints is Array:
			continue

		var group_name = str(gid)
		for fp in fingerprints:
			if fp_lookup.has(fp):
				var node = fp_lookup[fp]
				node.set_meta("prefab_id", gid)
				if not node.is_in_group(group_name):
					node.add_to_group(group_name)
				restored_count += 1

	# Assainissement : chaque node ne doit appartenir qu'au groupe Godot
	# correspondant à son meta prefab_id. Les memberships croisées résiduelles
	# (autres groupes numériques >= 10000) sont purgées — elles chaînaient
	# plusieurs groupes dans la sélection au clic sur un seul membre.
	var cleaned = 0
	for node in all_nodes:
		var own_pid = -1
		if node.has_meta("prefab_id"):
			var v = node.get_meta("prefab_id")
			if v is int and v >= CUSTOM_GROUP_MIN_ID:
				own_pid = v
		for gname in node.get_groups():
			var s = str(gname)
			if s.is_valid_integer() and int(s) >= CUSTOM_GROUP_MIN_ID and int(s) != own_pid:
				node.remove_from_group(s)
				cleaned += 1
	if cleaned > 0:
		print("[GroupAssets] Sanitized %d stale group membership(s)" % cleaned)

	if restored_count > 0:
		print("[GroupAssets] Restored %d node(s) in %d group(s) for '%s'" % [restored_count, groups.size(), map_key])


func _save_color_settings() -> void:
	# Reuse the full save - it now includes colors
	_save_groups()


func _get_all_groupable_nodes() -> Array:
	# TOUS les niveaux : l'expansion de groupe Godot (GetNodesInGroup) est
	# tree-wide, un groupe peut donc s'étendre sur plusieurs niveaux. Scanner
	# seulement World.Level sous-évaluait le max de _generate_group_id ->
	# gids réalloués en collision avec un groupe existant d'un autre niveau
	# (les assets collés se retrouvaient fusionnés avec ce groupe), et la
	# persistance sidecar perdait les membres hors niveau courant.
	var result = []
	var levels = _all_levels()
	if levels.empty() and _g.World.Level != null:
		levels = [_g.World.Level]
	for level in levels:
		if level == null or not is_instance_valid(level):
			continue
		for cname in ["Objects", "Pathways", "Portals", "Lights", "Roofs"]:
			var container = level.get_node_or_null(cname)
			if container:
				for child in container.get_children():
					result.append(child)
		# PatternShapes : les enfants directs sont des LAYERS, les shapes sont
		# leurs enfants (elles peuvent porter un prefab_id de groupe custom).
		var patterns = level.get_node_or_null("PatternShapes")
		if patterns:
			for layer in patterns.get_children():
				for sh in layer.get_children():
					result.append(sh)
		var walls = level.get_node_or_null("Walls")
		if walls:
			for child in walls.get_children():
				result.append(child)
				for sub in child.get_children():
					result.append(sub)
	return result


func _all_levels() -> Array:
	if _g == null:
		return []
	var w = _g.get("World")
	if w == null or not is_instance_valid(w):
		return []
	var a = w.call("get_AllLevels")
	return a if (a is Array) else []


# -- Transform box color ----------------------------------

var _original_select_color = null

func _update_transform_box_color(is_group: bool) -> void:
	var world_ui = _g.WorldUI
	if world_ui == null:
		return

	if _original_box_stylebox == null:
		_original_box_stylebox = world_ui.transformStyleBox.duplicate()
	if _original_corner_stylebox == null:
		_original_corner_stylebox = world_ui.transformCornerStyleBox.duplicate()
	if _original_select_color == null:
		_original_select_color = world_ui.selectionSelectColor

	# Ne pas restaurer pendant que le color picker est ouvert
	if _color_picker_open:
		return

	# Toujours restaurer d'abord
	if _is_mauve:
		_copy_stylebox_colors(world_ui.transformStyleBox, _original_box_stylebox)
		_copy_stylebox_colors(world_ui.transformCornerStyleBox, _original_corner_stylebox)
		world_ui.selectionSelectColor = _original_select_color
		_is_mauve = false

	# Puis appliquer le mauve seulement si c'est un groupe
	if is_group:
		_apply_color_to_stylebox(world_ui.transformStyleBox, _group_color)
		_apply_color_to_stylebox(world_ui.transformCornerStyleBox, _group_color)
		world_ui.selectionSelectColor = Color(_group_color.r, _group_color.g, _group_color.b, _original_select_color.a)
		_is_mauve = true


func _apply_color_to_stylebox(sb, color: Color) -> void:
	if sb is StyleBoxFlat:
		sb.bg_color = Color(color.r, color.g, color.b, sb.bg_color.a)
		sb.border_color = Color(color.r, color.g, color.b, sb.border_color.a)
	else:
		if sb.get("bg_color") != null:
			var orig_a = sb.bg_color.a
			sb.bg_color = Color(color.r, color.g, color.b, orig_a)
		if sb.get("border_color") != null:
			var orig_a = sb.border_color.a
			sb.border_color = Color(color.r, color.g, color.b, orig_a)


func _copy_stylebox_colors(target, source) -> void:
	if target is StyleBoxFlat and source is StyleBoxFlat:
		target.bg_color = source.bg_color
		target.border_color = source.border_color
	else:
		if target.get("bg_color") != null and source.get("bg_color") != null:
			target.bg_color = source.bg_color
		if target.get("border_color") != null and source.get("border_color") != null:
			target.border_color = source.border_color


# -- Helpers ----------------------------------------------

func _get_unique_things(raw) -> Array:
	var things = []
	var seen = {}
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if not seen.has(s.Thing):
			seen[s.Thing] = true
			things.append(s.Thing)
	return things


func _count_unique_selectables(raw) -> int:
	if raw == null:
		return 0
	var seen = {}
	for s in raw:
		if s == null or s.Thing == null:
			continue
		seen[s.Thing] = true
	return seen.size()


func _selection_has_custom_group(raw) -> bool:
	if raw == null:
		return false
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if _is_custom_group(s.Thing):
			return true
	return false


func _selection_is_pure_custom_group(raw) -> bool:
	if raw == null or raw.size() == 0:
		return false

	var custom_gid = -1
	var seen = {}
	for s in raw:
		if s == null or s.Thing == null:
			continue
		if seen.has(s.Thing):
			continue
		seen[s.Thing] = true

		if not _is_custom_group(s.Thing):
			return false

		var pid = s.Thing.get_meta("prefab_id")
		if custom_gid == -1:
			custom_gid = pid
		elif pid != custom_gid:
			return false

	return custom_gid != -1 and seen.size() >= 2


func _is_real_prefab(thing) -> bool:
	if thing.has_meta("prefab_id"):
		var pid = thing.get_meta("prefab_id")
		return pid is int and pid < CUSTOM_GROUP_MIN_ID
	return false


func _is_custom_group(thing) -> bool:
	if thing.has_meta("prefab_id"):
		var pid = thing.get_meta("prefab_id")
		return pid is int and pid >= CUSTOM_GROUP_MIN_ID
	return false


func _remove_from_custom_group(thing) -> void:
	if thing.has_meta("prefab_id"):
		var pid = thing.get_meta("prefab_id")
		if pid is int and pid >= CUSTOM_GROUP_MIN_ID:
			thing.remove_meta("prefab_id")
	# Purger TOUTES les memberships de groupes custom, pas seulement celle du
	# meta courant : des memberships croisées (héritées de vieilles sessions /
	# de l'ancien bug de doublons) laissent un asset dans DEUX groupes Godot à
	# la fois — un clic sur un membre chaîne alors les deux groupes entiers via
	# l'expansion transitive de DD (Select → GetGroups → GetNodesInGroup), et la
	# copie emporte les deux ("connected that part to the first group").
	for gname in thing.get_groups():
		var s = str(gname)
		if s.is_valid_integer() and int(s) >= CUSTOM_GROUP_MIN_ID:
			thing.remove_from_group(s)


func _generate_group_id() -> int:
	# Max sur TOUS les niveaux et TOUS les conteneurs (via
	# _get_all_groupable_nodes) : voir le commentaire de cette fonction.
	var max_gid = CUSTOM_GROUP_MIN_ID - 1
	for node in _get_all_groupable_nodes():
		var gid = _get_custom_gid(node)
		if gid > max_gid:
			max_gid = gid
	return max_gid + 1


func _get_custom_gid(node) -> int:
	if node.has_meta("prefab_id"):
		var pid = node.get_meta("prefab_id")
		if pid is int and pid >= CUSTOM_GROUP_MIN_ID:
			return pid
	return CUSTOM_GROUP_MIN_ID - 1
