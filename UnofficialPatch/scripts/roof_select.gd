# ============================================================================
# Roof Select - sous-script de Core - v11
# ============================================================================

var _g
var roof_tool   = null
var select_tool = null

# ── Noeuds cachés depuis le panneau RoofTool ──────────────────────────────────
var _roof_style_list      = null
var _roof_shade_btn       = null
var _roof_sun_slider      = null
var _roof_sun_spin        = null
var _roof_contrast_slider = null
var _roof_contrast_spin   = null
var _nodes_cached         := false

# _style_cache[i] = { "poly": Texture, "lines": [Texture, ...] }
# "poly"  : capturé via emit_signal à l'init (avant toute sélection)
# "lines" : capturé par scan de la map, au moment où on en a besoin
var _style_cache := []

# ── État SelectTool ───────────────────────────────────────────────────────────
var last_selected_roofs := []
var injected_panel       = null
var was_mouse_pressed   := false
var _press_pos          := Vector2.ZERO
var _press_over_ui      := false
var _drag_threshold     := 6.0
var _hovered_roof        = null

# ── Undo bookkeeping ─────────────────────────────────────────────────────────
# Drag tracking for sun/contrast sliders. We open a snapshot on
# mouse-down (from gui_input), close it on mouse-up. The snapshot is a
# Dict capturing the global Roofs sun/shade state for the level.
var _drag_snapshot = null
var _drag_slider = null
# Refs to the sliders/spinboxes we inject into the SelectTool panel,
# so we can sync them during undo. These are recreated each time the
# panel is rebuilt, so we update them on injection.
var _injected_sun_slider = null
var _injected_sun_spin = null
var _injected_contrast_slider = null
var _injected_contrast_spin = null
var _injected_shade_btn = null
# Set while applying an undo so per-roof handlers don't push their own
# records on top of ours.
var _applying_undo := false

# Cache des instance_ids des roofs presents sur la map. Utilise pour identifier
# un roof selectionne SANS appeler thing.get_parent() (cet appel mute un cache
# C# interne de DD lorsque thing est un Roof, ce qui casse la serialisation du
# clipboard au Ctrl+C). Le cache est rempli au scan initial puis maintenu via
# les signaux child_entered_tree/child_exiting_tree sur level.Roofs.
var _roof_ids_cache := {}
var _roofs_node_cached : Node = null
# Compte le nombre de roofs au dernier scan : permet de detecter quand un roof
# a ete ajoute/supprime sans recevoir de signal (les signaux Godot ne se
# declenchent pas pour les roofs crees via le code C# de DD).
var _roofs_last_count := -1


# ============================================================================
# INITIALISATION
# ============================================================================

func initialize() -> void:
	roof_tool   = _g.Editor.Tools["RoofTool"]
	select_tool = _g.Editor.Tools["SelectTool"]
	print("[RoofSel] Initialized v11")
	_cache_roof_panel_nodes()
	_try_restore_roof_textures(0)


func _try_restore_roof_textures(attempt: int) -> void:
	if attempt > 40: return  # max 4s d'attente
	var level = _g.World.GetCurrentLevel()
	if level == null or level.Roofs == null or level.Roofs.get_child_count() == 0:
		# Pas (encore) de roofs : on reessaie, mais on construit aussi un cache
		# vide avec les signaux pour ne rater aucun ajout futur de roof.
		if level != null and level.Roofs != null and _roofs_node_cached == null:
			_build_roofs_id_cache()
		_g.World.get_tree().create_timer(0.1).connect("timeout", self, "_try_restore_roof_textures", [attempt + 1])
		return
	# Build le cache des instance_ids des roofs presents AVANT toute restoration,
	# pour que la detection fonctionne meme si _restore_roof_textures court-circuite
	# (cas ou _roof_styles n'est pas sauvegarde dans ModMapData).
	if _roofs_node_cached == null:
		_build_roofs_id_cache()
	_restore_roof_textures()


func _roof_key(roof) -> String:
	# Clé stable basée sur la position du premier polygone
	for ch in roof.get_children():
		if ch is Polygon2D and ch.polygon.size() > 0:
			var p = ch.get_global_transform().xform(ch.polygon[0])
			return str(stepify(p.x, 1.0)) + "_" + str(stepify(p.y, 1.0))
	return str(roof.get_instance_id())


func _save_roof_texture(roof, style_index: int) -> void:
	if not _g.ModMapData.has("_roof_styles"):
		_g.ModMapData["_roof_styles"] = {}
	var key = _roof_key(roof)
	if key != "":
		_g.ModMapData["_roof_styles"][key] = style_index


func _restore_roof_textures() -> void:
	if not _g.ModMapData.has("_roof_styles"): return
	var store = _g.ModMapData["_roof_styles"]
	if store.empty(): return
	var level = _g.World.GetCurrentLevel()
	if level == null: return
	for roof in level.Roofs.get_children():
		if not is_instance_valid(roof): continue
		var key = _roof_key(roof)
		if not store.has(key): continue
		var idx = int(store[key])
		if idx < 0 or idx >= _style_cache.size(): continue
		var poly_tex = _style_cache[idx]["poly"]
		if poly_tex == null: continue
		_apply_style_to_roof(roof, poly_tex)
	print("[RoofSel] Roof textures restored")


func _build_roofs_id_cache() -> void:
	var level = _g.World.GetCurrentLevel()
	if level == null or level.Roofs == null: return
	_roofs_node_cached = level.Roofs
	_roof_ids_cache.clear()
	for roof in level.Roofs.get_children():
		if is_instance_valid(roof):
			_roof_ids_cache[roof.get_instance_id()] = true
	# Maintenir le cache a jour via les signaux Godot natifs
	if not level.Roofs.is_connected("child_entered_tree", self, "_on_roof_node_added"):
		level.Roofs.connect("child_entered_tree", self, "_on_roof_node_added")
	if not level.Roofs.is_connected("child_exiting_tree", self, "_on_roof_node_removed"):
		level.Roofs.connect("child_exiting_tree", self, "_on_roof_node_removed")
	print("[RoofSel] Roofs id cache built: %d entries" % _roof_ids_cache.size())


func _on_roof_node_added(node) -> void:
	if is_instance_valid(node):
		_roof_ids_cache[node.get_instance_id()] = true


func _on_roof_node_removed(node) -> void:
	if is_instance_valid(node):
		_roof_ids_cache.erase(node.get_instance_id())


func _find_align(node: Node, depth: int = 0):
	if depth > 4: return null
	for child in node.get_children():
		if child is VBoxContainer and child.name == "Align":
			return child
		var r = _find_align(child, depth + 1)
		if r != null: return r
	return null


func _cache_roof_panel_nodes() -> void:
	var tp = _g.Editor.Toolset.GetToolPanel("RoofTool")
	if tp == null: return
	var align = _find_align(tp)
	if align == null: return

	var children = align.get_children()
	for i in range(children.size()):
		var c = children[i]
		if c is Label and c.text == "STYLE":
			if i + 1 < children.size() and children[i + 1] is ItemList:
				_roof_style_list = children[i + 1]
		if c is CheckButton and c.text == "SHADE":
			_roof_shade_btn = c
			if i + 1 < children.size() and children[i + 1] is VBoxContainer:
				_parse_shade_vbox(children[i + 1])

	if _roof_style_list != null:
		_build_poly_cache()

	_nodes_cached = (_roof_style_list != null)
	print("[RoofSel] Cache: styles=", _style_cache.size(),
		" shade=", _roof_shade_btn != null,
		" sun=", _roof_sun_slider != null,
		" contrast=", _roof_contrast_slider != null)


func _parse_shade_vbox(vbox: VBoxContainer) -> void:
	var children = vbox.get_children()
	for i in range(children.size()):
		var c = children[i]
		if c is Label and c.text == "SUN_DIRECTION":
			if i + 1 < children.size() and children[i + 1] is HBoxContainer:
				for w in children[i + 1].get_children():
					if w is HSlider:   _roof_sun_slider = w
					elif w is SpinBox: _roof_sun_spin = w
		if c is Label and c.text == "SHADE_CONTRAST":
			if i + 1 < children.size() and children[i + 1] is HBoxContainer:
				for w in children[i + 1].get_children():
					if w is HSlider:   _roof_contrast_slider = w
					elif w is SpinBox: _roof_contrast_spin = w


func _build_poly_cache() -> void:
	# Capture uniquement la texture Polygon2D de chaque style.
	# emit_signal ici est safe : aucun toit n'est encore sélectionné dans SelectTool.
	var count = _roof_style_list.get_item_count()
	_style_cache.resize(count)
	for i in range(count):
		_style_cache[i] = { "poly": null, "lines": [] }

	var prev = _roof_style_list.get_selected_items()
	for i in range(count):
		_roof_style_list.select(i)
		_roof_style_list.emit_signal("item_selected", i)
		_style_cache[i]["poly"] = roof_tool.Texture

	# Restaurer
	if prev.size() > 0:
		_roof_style_list.select(prev[0])
		_roof_style_list.emit_signal("item_selected", prev[0])
	else:
		_roof_style_list.unselect_all()


func _fill_line_cache_from_map() -> void:
	# Parcourir tous les roofs existants pour associer les textures Line2D à leur style.
	# Appelé juste avant d'appliquer une texture, pour couvrir les roofs créés en session.
	var level = _g.World.GetCurrentLevel()
	if level == null: return
	var roofs_node = level.Roofs
	if roofs_node == null: return

	for i in range(roofs_node.get_child_count()):
		var roof = roofs_node.get_child(i)
		if not is_instance_valid(roof): continue

		var poly_tex = null
		var line_texs := []
		for child in roof.get_children():
			if child is Polygon2D and poly_tex == null:
				poly_tex = child.texture
			elif child is Line2D:
				line_texs.append(child.texture)

		if poly_tex == null or line_texs.size() == 0: continue

		# Associer au style correspondant
		for idx in range(_style_cache.size()):
			if _style_cache[idx]["poly"] == poly_tex:
				if _style_cache[idx]["lines"].size() == 0:
					_style_cache[idx]["lines"] = line_texs
				break


# ============================================================================
# BOUCLE PRINCIPALE
# ============================================================================

func update(_delta) -> void:
	if roof_tool == null or select_tool == null:
		return
	if not _nodes_cached:
		_cache_roof_panel_nodes()

	var select_active = _is_tool_active("SELECT")

	if not select_active:
		_remove_injected_panel()
		last_selected_roofs.clear()
		_hovered_roof = null
		was_mouse_pressed = false
		return

	var mouse_pressed = Input.is_mouse_button_pressed(BUTTON_LEFT)

	if mouse_pressed and not was_mouse_pressed:
		_press_pos = _g.WorldUI.MousePosition
		# On retient si le clic a DÉMARRÉ au-dessus de l'UI du SelectTool
		# (panneau injecté = liste STYLE, sliders, checkbox SHADE). Un clic
		# qui commence sur ces réglages n'est PAS un clic "map vide" et ne
		# doit jamais déclencher la désélection, indépendamment du timing du
		# flag _just_restored (que d'autres mods peuvent perturber).
		_press_over_ui = _is_mouse_over_select_ui()

	if not mouse_pressed and was_mouse_pressed:
		if _just_restored:
			_just_restored = false
		elif not _press_over_ui:
			var pos = _g.WorldUI.MousePosition
			var dragged = pos.distance_to(_press_pos) > _drag_threshold
			if not dragged and _find_roof_at(pos) == null and last_selected_roofs.size() > 0:
				_force_deselect()

	was_mouse_pressed = mouse_pressed
	_handle_select_tool_roofs()


# ============================================================================
# DÉTECTION SOURIS SUR L'UI DU SELECTTOOL
# ============================================================================

func _is_mouse_over_select_ui() -> bool:
	# Vrai si la souris survole le panneau d'outil SelectTool (qui contient le
	# panneau injecté : liste STYLE, sliders SUN/CONTRAST, checkbox SHADE).
	# get_global_rect()/get_global_mouse_position() travaillent en coordonnées
	# écran, donc le hit-test est correct même si le panneau recouvre la map.
	var tp = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if tp != null and is_instance_valid(tp) and tp is Control and tp.is_visible_in_tree():
		if tp.get_global_rect().has_point(tp.get_global_mouse_position()):
			return true
	if injected_panel != null and is_instance_valid(injected_panel) and injected_panel is Control:
		if injected_panel.get_global_rect().has_point(injected_panel.get_global_mouse_position()):
			return true
	return false


# ============================================================================
# DÉSELECTION FORCÉE
# ============================================================================

func _force_deselect() -> void:
	_remove_injected_panel()
	last_selected_roofs.clear()
	_hovered_roof = null
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	elif select_tool.has_method("ClearSelection"):
		select_tool.ClearSelection()
	elif select_tool.has_method("ClearTransformSelection"):
		select_tool.ClearTransformSelection()


# ============================================================================
# DÉTECTION OUTIL ACTIF
# ============================================================================

func _is_tool_active(key: String) -> bool:
	var buttons = _g.Editor.Toolset.ToolsetButtons
	if buttons == null or not buttons.has(key): return false
	return buttons[key].pressed


# ============================================================================
# HIT-TEST TOIT
# ============================================================================

func _find_roof_at(pos: Vector2):
	var level = _g.World.GetCurrentLevel()
	if level == null: return null
	var roofs_node = level.Roofs
	if roofs_node == null: return null
	for i in range(roofs_node.get_child_count() - 1, -1, -1):
		var roof = roofs_node.get_child(i)
		if not is_instance_valid(roof) or not roof.visible: continue
		if _roof_contains_point(roof, pos): return roof
	return null

func _roof_contains_point(roof, pos: Vector2) -> bool:
	for child in roof.get_children():
		if child is Polygon2D and child.polygon.size() >= 3:
			if Geometry.is_point_in_polygon(
					child.get_global_transform().affine_inverse().xform(pos),
					child.polygon):
				return true
	return false


# ============================================================================
# SELECTTOOL — DÉTECTION
# ============================================================================

func _handle_select_tool_roofs() -> void:
	# Utiliser RawSelectables au lieu de Selected pour éviter le crash
	# ToDictionary() quand des items ont un prefab_id custom (GroupAssets)
	var raw = select_tool.RawSelectables
	if raw == null or raw.size() == 0:
		_remove_injected_panel(); last_selected_roofs.clear()
		# Selection vide : moment ideal pour rafraichir le cache des roofs
		# sans risquer de muter quoi que ce soit (rien a copier de toute facon).
		# Couvre les cas de reload de map et d'ajout de nouveaux roofs entre
		# deux selections. Si _roofs_node_cached est invalide (post-reload),
		# on le re-acquiert ici.
		if _roofs_node_cached == null or not is_instance_valid(_roofs_node_cached):
			var level = _g.World.GetCurrentLevel()
			if level != null and level.Roofs != null:
				_roofs_node_cached = level.Roofs
		if _roofs_node_cached != null and is_instance_valid(_roofs_node_cached):
			_roof_ids_cache.clear()
			for roof in _roofs_node_cached.get_children():
				if is_instance_valid(roof):
					_roof_ids_cache[roof.get_instance_id()] = true
		return

	var current_roofs := []
	var has_non_roof := false
	# Detection des roofs via le cache d'instance_ids construit a l'init,
	# rafraichi quand la selection est vide (voir branche au-dessus). On evite
	# ainsi tout appel a thing.get_parent(), select_tool.GetSelectableType() ou
	# get_child_count sur le node Roofs, qui mutent un cache C# interne de DD
	# et rendent le clipboard vide au Ctrl+C sur un prefab contenant des roofs.
	for s in raw:
		if s == null or not is_instance_valid(s):
			continue
		var thing = s.get("Thing")
		if thing == null or not is_instance_valid(thing) or not (thing is Object):
			continue
		if not _roof_ids_cache.has(thing.get_instance_id()):
			has_non_roof = true
			continue
		# Ignorer les toits qui font partie d'un groupe custom
		if thing.has_meta("prefab_id"):
			var pid = thing.get_meta("prefab_id")
			if pid is int and pid >= 10000:
				continue
		current_roofs.append(thing)

	if current_roofs.size() == 0:
		_remove_injected_panel(); last_selected_roofs.clear(); return

	var changed = (current_roofs.size() != last_selected_roofs.size())
	if not changed:
		for i in range(current_roofs.size()):
			if current_roofs[i] != last_selected_roofs[i]:
				changed = true; break

	if changed:
		# Si la selection contient des choses autres que des roofs (cas d'un
		# prefab contenant un roof), on ne tracke RIEN : pas d'injection, pas de
		# last_selected_roofs. Tracker un roof dans last_selected_roofs declenche
		# _find_roof_at() au prochain mouse release, qui itere sur level.Roofs
		# et mute le cache C# de DD au mauvais moment (juste avant Ctrl+C).
		if has_non_roof:
			last_selected_roofs.clear()
			_remove_injected_panel()
		else:
			last_selected_roofs = current_roofs.duplicate()
			_inject_roof_panel(current_roofs)


# ============================================================================
# PANNEAU INJECTÉ
# ============================================================================

func _inject_roof_panel(roofs: Array) -> void:
	_remove_injected_panel()
	if _roof_style_list == null: return

	var tp = _g.Editor.Toolset.GetToolPanel("SelectTool")
	if tp == null: return
	var align = _find_align(tp)
	if align == null: return

	var vbox = VBoxContainer.new()
	vbox.name = "__RoofSelectPanel"
	vbox.add_constant_override("separation", 4)
	align.add_child(vbox)
	injected_panel = vbox

	vbox.add_child(HSeparator.new())
	var lbl = Label.new(); lbl.text = "STYLE"
	vbox.add_child(lbl)

	var item_list = ItemList.new()
	item_list.rect_min_size     = Vector2(0, 250)
	item_list.same_column_width = _roof_style_list.same_column_width
	item_list.max_columns       = _roof_style_list.max_columns
	item_list.icon_mode         = _roof_style_list.icon_mode
	for i in range(_roof_style_list.get_item_count()):
		item_list.add_item(
			_roof_style_list.get_item_text(i),
			_roof_style_list.get_item_icon(i))
	var match_idx = _find_style_index_for_roof(roofs[0])
	if match_idx >= 0:
		item_list.select(match_idx)
	item_list.connect("item_selected", self, "_on_style_selected", [roofs])
	vbox.add_child(item_list)

	if _roof_shade_btn != null:
		vbox.add_child(HSeparator.new())
		var chk = CheckButton.new()
		chk.text    = "SHADE"
		chk.pressed = _roof_shade_btn.pressed
		chk.connect("toggled", self, "_on_shade_toggled")
		vbox.add_child(chk)
		_injected_shade_btn = chk

		if _roof_sun_slider != null:
			var lbl_sun = Label.new(); lbl_sun.text = "SUN_DIRECTION"
			vbox.add_child(lbl_sun)
			var hbox_sun = HBoxContainer.new(); vbox.add_child(hbox_sun)
			var sl_sun = HSlider.new()
			sl_sun.min_value = _roof_sun_slider.min_value
			sl_sun.max_value = _roof_sun_slider.max_value
			sl_sun.step      = _roof_sun_slider.step
			sl_sun.value     = _roof_sun_slider.value
			sl_sun.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hbox_sun.add_child(sl_sun)
			if _roof_sun_spin != null:
				var sp_sun = SpinBox.new()
				sp_sun.min_value = _roof_sun_spin.min_value
				sp_sun.max_value = _roof_sun_spin.max_value
				sp_sun.step      = _roof_sun_spin.step
				sp_sun.value     = _roof_sun_spin.value
				hbox_sun.add_child(sp_sun)
				sl_sun.connect("value_changed", self, "_on_sun_changed", [sp_sun, true])
				sp_sun.connect("value_changed", self, "_on_sun_changed", [sl_sun, false])
				_attach_slider_undo(sp_sun)
				_injected_sun_spin = sp_sun
			else:
				sl_sun.connect("value_changed", self, "_on_sun_changed", [null, true])
				_injected_sun_spin = null
			_attach_slider_undo(sl_sun)
			_injected_sun_slider = sl_sun

		if _roof_contrast_slider != null:
			var lbl_c = Label.new(); lbl_c.text = "SHADE_CONTRAST"
			vbox.add_child(lbl_c)
			var hbox_c = HBoxContainer.new(); vbox.add_child(hbox_c)
			var sl_c = HSlider.new()
			sl_c.min_value = _roof_contrast_slider.min_value
			sl_c.max_value = _roof_contrast_slider.max_value
			sl_c.step      = _roof_contrast_slider.step
			sl_c.value     = _roof_contrast_slider.value
			sl_c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hbox_c.add_child(sl_c)
			if _roof_contrast_spin != null:
				var sp_c = SpinBox.new()
				sp_c.min_value = _roof_contrast_spin.min_value
				sp_c.max_value = _roof_contrast_spin.max_value
				sp_c.step      = _roof_contrast_spin.step
				sp_c.value     = _roof_contrast_spin.value
				hbox_c.add_child(sp_c)
				sl_c.connect("value_changed", self, "_on_contrast_changed", [sp_c, true])
				sp_c.connect("value_changed", self, "_on_contrast_changed", [sl_c, false])
				_attach_slider_undo(sp_c)
				_injected_contrast_spin = sp_c
			else:
				sl_c.connect("value_changed", self, "_on_contrast_changed", [null, true])
				_injected_contrast_spin = null
			_attach_slider_undo(sl_c)
			_injected_contrast_slider = sl_c

	print("[RoofSel] Panneau injecté (", roofs.size(), " toit(s), tex_idx=", match_idx, ")")


func _find_style_index_for_roof(roof) -> int:
	var poly_tex = null
	for child in roof.get_children():
		if child is Polygon2D and child.texture != null:
			poly_tex = child.texture; break
	if poly_tex == null: return -1
	for i in range(_style_cache.size()):
		if _style_cache[i]["poly"] == poly_tex: return i
	return -1


func _remove_injected_panel() -> void:
	if injected_panel != null and is_instance_valid(injected_panel):
		injected_panel.queue_free()
	injected_panel = null


# ============================================================================
# CALLBACKS
# ============================================================================

func _on_style_selected(index: int, roofs: Array) -> void:
	if index >= _style_cache.size(): return

	var saved_roofs = roofs.duplicate()

	# Snapshot textures BEFORE the change so undo can restore them.
	var before_styles = _snapshot_roofs_styles(saved_roofs) if not _applying_undo else []

	_roof_style_list.select(index)
	_roof_style_list.emit_signal("item_selected", index)

	var poly_tex = roof_tool.Texture
	_style_cache[index]["poly"] = poly_tex

	if poly_tex == null:
		print("[RoofSel] Pas de texture poly pour style ", index)
		return

	print("[RoofSel] Style ", index, " — poly=", poly_tex)

	for roof in saved_roofs:
		if not is_instance_valid(roof): continue
		_apply_style_to_roof(roof, poly_tex)
		_save_roof_texture(roof, index)

	call_deferred("_restore_selection", saved_roofs)

	# Record undo: the "after" state is each roof now showing poly_tex.
	if not _applying_undo and not before_styles.empty():
		var after_styles = _snapshot_roofs_styles(saved_roofs)
		_record_roof_style_undo(before_styles, after_styles)


var _just_restored := false

func _restore_selection(roofs: Array) -> void:
	if select_tool == null: return
	if select_tool.has_method("DeselectAll"):
		select_tool.DeselectAll()
	for roof in roofs:
		if is_instance_valid(roof):
			select_tool.call("SelectThing", roof, true)
	if roofs.size() > 0:
		last_selected_roofs = roofs.duplicate()
		_just_restored = true


func _apply_style_to_roof(roof, poly_tex, _unused = null) -> void:
	if poly_tex == null: return
	# SetTileTexture updates all texture references but not Line2D widths.
	# Calling roof.Set() with the same geometry forces DD to fully rebuild
	# the roof node, recalculating Line2D widths for the new texture.
	roof.call("SetTileTexture", poly_tex)
	roof.call("Set", roof.points, roof.width, roof.type)


func _on_shade_toggled(value: bool) -> void:
	var before = _snapshot_sunlight() if not _applying_undo else {}
	if _roof_shade_btn != null and is_instance_valid(_roof_shade_btn):
		_roof_shade_btn.pressed = value
		_roof_shade_btn.emit_signal("toggled", value)
	_just_restored = true
	call_deferred("_restore_selection", last_selected_roofs.duplicate())
	if not _applying_undo and not before.empty():
		var after = _snapshot_sunlight()
		_record_sunlight_undo(before, after)


func _on_sun_changed(value: float, other, _from_slider: bool) -> void:
	if other != null and is_instance_valid(other) and abs(other.value - value) > 0.0001:
		other.value = value
	if _roof_sun_slider != null and is_instance_valid(_roof_sun_slider):
		_roof_sun_slider.value = value
		_roof_sun_slider.emit_signal("value_changed", value)
	_just_restored = true
	call_deferred("_restore_selection", last_selected_roofs.duplicate())


func _on_contrast_changed(value: float, other, _from_slider: bool) -> void:
	if other != null and is_instance_valid(other) and abs(other.value - value) > 0.0001:
		other.value = value
	if _roof_contrast_slider != null and is_instance_valid(_roof_contrast_slider):
		_roof_contrast_slider.value = value
		_roof_contrast_slider.emit_signal("value_changed", value)
	_just_restored = true
	call_deferred("_restore_selection", last_selected_roofs.duplicate())


# ============================================================================
# UNDO HELPERS
# ============================================================================

func _get_roofs_manager():
	# The Roofs node lives on the active level. Sun/shade properties
	# are global per level (Shade, SunDirection, ShadeContrast on the
	# Roofs manager).
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return null
	var level = _g.World.get("CurrentLevel")
	if level == null or not is_instance_valid(level):
		return null
	return level.get("Roofs")


func _snapshot_sunlight() -> Dictionary:
	# Capture the per-level Roofs sun/shade settings.
	var snap := {}
	var roofs_mgr = _get_roofs_manager()
	if roofs_mgr != null and is_instance_valid(roofs_mgr):
		snap["shade"] = roofs_mgr.get("Shade")
		snap["sun_direction"] = roofs_mgr.get("SunDirection")
		snap["shade_contrast"] = roofs_mgr.get("ShadeContrast")
	return snap


func _apply_sunlight(snap: Dictionary) -> void:
	# Restore the per-level Roofs sun/shade settings via the official
	# UpdateSunlight() API, which propagates to the shader uniforms
	# and re-bakes lighting properly.
	var roofs_mgr = _get_roofs_manager()
	if roofs_mgr == null or not is_instance_valid(roofs_mgr):
		return
	if not roofs_mgr.has_method("UpdateSunlight"):
		return
	var shade = snap.get("shade", true)
	var angle = snap.get("sun_direction", 0.0)
	var contrast = snap.get("shade_contrast", 1.0)
	roofs_mgr.UpdateSunlight(shade, angle, contrast)
	# Sync the RoofTool panel controls so their displayed values match.
	if _roof_shade_btn != null and is_instance_valid(_roof_shade_btn):
		_roof_shade_btn.set_pressed_no_signal(shade)
	if _roof_sun_slider != null and is_instance_valid(_roof_sun_slider):
		_roof_sun_slider.set_block_signals(true)
		_roof_sun_slider.value = angle
		_roof_sun_slider.set_block_signals(false)
	if _roof_sun_spin != null and is_instance_valid(_roof_sun_spin):
		_roof_sun_spin.set_block_signals(true)
		_roof_sun_spin.value = angle
		_roof_sun_spin.set_block_signals(false)
	if _roof_contrast_slider != null and is_instance_valid(_roof_contrast_slider):
		_roof_contrast_slider.set_block_signals(true)
		_roof_contrast_slider.value = contrast
		_roof_contrast_slider.set_block_signals(false)
	if _roof_contrast_spin != null and is_instance_valid(_roof_contrast_spin):
		_roof_contrast_spin.set_block_signals(true)
		_roof_contrast_spin.value = contrast
		_roof_contrast_spin.set_block_signals(false)
	# Sync the SelectTool's injected panel controls too (they're a
	# different set of widgets with their own values).
	if _injected_shade_btn != null and is_instance_valid(_injected_shade_btn):
		_injected_shade_btn.set_pressed_no_signal(shade)
	if _injected_sun_slider != null and is_instance_valid(_injected_sun_slider):
		_injected_sun_slider.set_block_signals(true)
		_injected_sun_slider.value = angle
		_injected_sun_slider.set_block_signals(false)
	if _injected_sun_spin != null and is_instance_valid(_injected_sun_spin):
		_injected_sun_spin.set_block_signals(true)
		_injected_sun_spin.value = angle
		_injected_sun_spin.set_block_signals(false)
	if _injected_contrast_slider != null and is_instance_valid(_injected_contrast_slider):
		_injected_contrast_slider.set_block_signals(true)
		_injected_contrast_slider.value = contrast
		_injected_contrast_slider.set_block_signals(false)
	if _injected_contrast_spin != null and is_instance_valid(_injected_contrast_spin):
		_injected_contrast_spin.set_block_signals(true)
		_injected_contrast_spin.value = contrast
		_injected_contrast_spin.set_block_signals(false)


func _apply_sunlight_undo(snap: Dictionary) -> void:
	# Wrapper used by callback_record so it doesn't recursively
	# register more history.
	_applying_undo = true
	_apply_sunlight(snap)
	_applying_undo = false


func _record_sunlight_undo(before: Dictionary, after: Dictionary) -> void:
	if before.empty() or after.empty():
		return
	# No-op skip.
	if before.get("shade") == after.get("shade") \
			and before.get("sun_direction") == after.get("sun_direction") \
			and before.get("shade_contrast") == after.get("shade_contrast"):
		return
	var undo_lib = null
	if _g != null and _g.get("ModMapData") != null:
		undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_apply_sunlight_undo", [before],
		self, "_apply_sunlight_undo", [after])


# ── Style change undo ─────────────────────────────────────────────────────────
# A style change rewrites textures on a set of selected roofs. To undo
# we need to capture each roof's original texture and re-apply it via
# _apply_style_to_roof.

func _snapshot_roofs_styles(roofs: Array) -> Array:
	# Returns [{ "key": String, "tex": Texture }, ...]
	# We use _roof_key (already keyed on geometry) to find roofs again
	# in case node refs become stale; but typically the same Node is
	# valid throughout an undo-redo cycle so we keep the ref too.
	var arr: Array = []
	for r in roofs:
		if r == null or not is_instance_valid(r):
			continue
		var poly = r.get_node_or_null("Polygon2D")
		var tex = poly.texture if poly != null else null
		arr.append({
			"ref": weakref(r),
			"key": _roof_key(r),
			"tex": tex,
		})
	return arr


func _apply_roofs_styles_undo(entries: Array) -> void:
	_applying_undo = true
	var restored: Array = []
	for entry in entries:
		var ref = entry.get("ref")
		var roof = ref.get_ref() if ref != null else null
		if roof == null or not is_instance_valid(roof):
			continue
		var tex = entry.get("tex")
		if tex == null:
			continue
		_apply_style_to_roof(roof, tex)
		# Re-save the texture index for persistence.
		var idx = -1
		for i in range(_style_cache.size()):
			if _style_cache[i].get("poly") == tex:
				idx = i
				break
		if idx >= 0:
			_save_roof_texture(roof, idx)
		restored.append(roof)
	# Re-select the affected roofs so the user sees the result and the
	# panel stays open on them.
	if not restored.empty():
		call_deferred("_restore_selection", restored)
		last_selected_roofs = restored
	_applying_undo = false


func _record_roof_style_undo(before: Array, after: Array) -> void:
	if before.empty() or after.empty():
		return
	var undo_lib = null
	if _g != null and _g.get("ModMapData") != null:
		undo_lib = _g.ModMapData.get("_undo_lib")
	if undo_lib == null:
		return
	undo_lib.record_callback(
		self, "_apply_roofs_styles_undo", [before],
		self, "_apply_roofs_styles_undo", [after])


# ── Slider drag tracking ──────────────────────────────────────────────────────

func _attach_slider_undo(slider) -> void:
	if slider == null or not is_instance_valid(slider):
		return
	if slider.is_connected("gui_input", self, "_on_slider_gui_input"):
		return
	slider.connect("gui_input", self, "_on_slider_gui_input", [slider])


func _on_slider_gui_input(event, slider) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index != BUTTON_LEFT:
		return
	if event.pressed:
		if _drag_snapshot == null:
			_drag_snapshot = _snapshot_sunlight()
			_drag_slider = slider
	else:
		if _drag_snapshot != null and _drag_slider == slider:
			var after = _snapshot_sunlight()
			_record_sunlight_undo(_drag_snapshot, after)
			_drag_snapshot = null
			_drag_slider = null
