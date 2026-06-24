# eyedropper.gd
# Select a single asset in SelectTool, press Enter → switches to that asset's
# placement tool with all properties copied.

var _g
var scale_unlock                  # reference to scale_unlock.gd instance
var _main = null                  # reference au mod Main (acces overlay_tool au runtime)
var ui_util = null                # reference au mod ui_util (detection souris sur UI)
var _input_listener    : Node = null
var _select_tool       = null
var _suppress_enter_until := 0
var _destroyed := false

# Forçage du calque post-eyedrop : objets/chemins réappliquent leur calque par
# défaut après le chargement (différé) de la librairie, ce qui écrase un SetLayer
# immédiat. On ré-impose donc le calque cible chaque frame jusqu'à une échéance.
var _layer_tool = null
var _layer_target = null
var _layer_deadline := 0


func initialize() -> void:
	print("[Eyedropper] Initialized")
	var t = _g.World.get_tree().create_timer(0.1)
	t.connect("timeout", self, "_do_setup")


func cleanup() -> void:
	_destroyed = true
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.handler = null
		_input_listener.queue_free()
	_input_listener = null
	print("[Eyedropper] Cleaned up")


func _do_setup() -> void:
	if _destroyed:
		return
	var editor = _g.World.get_tree().root.get_node_or_null("Master/Editor")
	if editor == null:
		var t = _g.World.get_tree().create_timer(0.5)
		t.connect("timeout", self, "_do_setup")
		return
	var tools = editor.get("Tools")
	if tools and tools.has("SelectTool"):
		_select_tool = tools["SelectTool"]

	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_input(e)\n"
	script.reload()
	_input_listener = Node.new()
	_input_listener.name = "EyedropperListener"
	_input_listener.set_script(script)
	_input_listener.handler = self
	_g.World.add_child(_input_listener)
	print("[Eyedropper] Ready")


func update(_delta: float) -> void:
	if _layer_target == null:
		return
	if OS.get_ticks_msec() > _layer_deadline:
		_layer_target = null
		_layer_tool = null
		return
	if _layer_tool == null or not is_instance_valid(_layer_tool):
		return
	# Pas de garde sur l'outil actif : _enforce_layer() ne fait rien tant que le
	# LayerMenu de l'outil n'est pas prêt, donc forcer chaque frame est sûr et
	# garantit qu'on agit dès que le menu est construit (dès le 1er eyedrop).
	_enforce_layer()



func _reset_cursor() -> void:
	# Remet uniquement la texture custom de la forme Arrow à null.
	# On N'appelle PAS set_default_cursor_shape() ici : ça interfère avec
	# la gestion interne de DD et casse les raccourcis clavier (ex: X → SelectTool).
	# ClearTransformSelection() suffit pour que DD réinitialise sa propre forme.
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_select_tool.ClearTransformSelection()


func _apply_layer(t, thing) -> void:
	# Mémorise le calque (valeur z) de l'original et l'impose pendant ~0,8 s via
	# update(). SetLayer() attend l'INDEX de l'item dans le menu (pas la valeur z),
	# donc _enforce_layer() convertit valeur -> index via le metadata des items.
	# Objets et chemins réappliquent leur calque par défaut après le chargement
	# différé de la librairie : l'imposer chaque frame garantit qu'on l'emporte.
	if t == null or thing == null or not is_instance_valid(thing):
		return
	if not t.has_method("SetLayer"):
		return
	_layer_tool = t
	_layer_target = _thing_layer(thing)
	# Fenêtre large : au 1er eyedrop d'un asset, la librairie se charge de façon
	# asynchrone et réapplique son calque par défaut tardivement -> il faut tenir
	# assez longtemps pour l'emporter. (Au 2e eyedrop l'asset est en cache.)
	_layer_deadline = OS.get_ticks_msec() + 3000
	_enforce_layer()


func _thing_layer(thing):
	# PatternShape expose GetLayer() ; Prop (objets) et Pathway (chemins) non.
	# Repli : z-index effectif (somme le long de la chaîne parente tant que
	# z_as_relative est vrai) = valeur de calque, cf. prop.ZIndex = ActiveLayer.
	if thing.has_method("GetLayer"):
		return thing.GetLayer()
	var z = 0
	var n = thing
	while n != null and n is CanvasItem:
		z += n.z_index
		if not n.z_as_relative:
			break
		n = n.get_parent()
	return z


func _enforce_layer() -> void:
	var t = _layer_tool
	if t == null or not is_instance_valid(t) or not t.has_method("SetLayer"):
		return
	var lm = t.get("LayerMenu")
	if lm == null or not is_instance_valid(lm):
		return
	var count = lm.get_item_count()
	if count <= 0:
		return
	# Index de l'item dont le metadata == calque source (valeur z). Repli : l'item
	# de metadata numérique le plus proche, si aucune correspondance exacte
	# (absorbe un éventuel décalage Over/Under sur les objets).
	var target_idx := -1
	var nearest_idx := -1
	var nearest_dist = null
	for i in range(count):
		var md = lm.get_item_metadata(i)
		if md == _layer_target:
			target_idx = i
			break
		if typeof(md) == TYPE_INT or typeof(md) == TYPE_REAL:
			var d = abs(float(md) - float(_layer_target))
			if nearest_dist == null or d < nearest_dist:
				nearest_dist = d
				nearest_idx = i
	var idx = target_idx if target_idx >= 0 else nearest_idx
	if idx < 0:
		return
	var av = t.get("ActiveLayer")
	# Cohérent seulement si ActiveLayer ET la sélection du menu pointent le calque.
	# Le preview du nouvel asset (créé en différé) se base sur la SÉLECTION du
	# menu, pas sur ActiveLayer : il faut donc forcer les deux.
	if av == _layer_target and lm.get_selected() == idx:
		return
	t.call("SetLayer", idx)
	lm.select(idx)


func _do_wall_switch() -> void:
	_select_tool.ClearTransformSelection()
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_g.Editor.Toolset.Quickswitch("WallTool")
	_suppress_enter_until = OS.get_ticks_msec() + 500


func _find_focused_control(node):
	# Cherche le focus dans TOUS les viewports, pas seulement le viewport racine.
	# Certains panneaux UI de DD (ex: ObjectLibraryPanel) peuvent vivre dans un
	# sous-viewport, invisible pour root.gui_get_focus_owner().
	if node is Viewport:
		var f = node.gui_get_focus_owner()
		if f != null:
			return f
	for c in node.get_children():
		var r = _find_focused_control(c)
		if r != null:
			return r
	return null


func _is_text_focused() -> bool:
	var tree = _g.World.get_tree() if _g != null and _g.World != null else null
	if tree == null or tree.root == null:
		return false

	var editor = _g.Editor if _g != null else null
	if editor == null:
		editor = tree.root.get_node_or_null("Master/Editor")

	# Drapeau posé par Search&Select (et tout mod qui l'expose).
	if editor != null and editor.get("SearchHasFocus"):
		return true

	# Méthode canonique de DD : Global.Editor.GetFocus().
	# Plus fiable que gui_get_focus_owner() (cf. Layer Panel, ObjectLibraryPanel).
	var focused = null
	if editor != null and editor.has_method("GetFocus"):
		focused = editor.GetFocus()
	# Fallback : balayage de tous les viewports.
	if focused == null:
		focused = _find_focused_control(tree.root)
	if focused == null:
		return false

	# LineEdit / TextEdit directs, OU SpinBox.
	# Sur un SpinBox, le focus peut être sur le SpinBox lui-même (pas son
	# LineEdit interne) selon comment l'utilisateur a cliqué / tabbé dedans.
	# Les mods comme select_rotation.gd utilisent des SpinBox.
	if focused is LineEdit or focused is TextEdit or focused is SpinBox:
		return true

	# Focus à l'intérieur d'un Popup/Dialog visible (AcceptDialog de
	# Search&Select, etc.) : on considère qu'une saisie est en cours.
	var n = focused
	while n != null and n is Control:
		if n is Popup and n.visible:
			return true
		n = n.get_parent()

	return false


func _on_input(event: InputEvent) -> void:
	if _destroyed:
		return
	# Ignore Enter quand on tape dans un champ texte (LineEdit / TextEdit / SpinBox)
	if event is InputEventKey and event.scancode == KEY_ENTER and _is_text_focused():
		return
	# Ignore Enter quand la souris survole un panneau/menu/popup de l'UI : on ne
	# veut eyedropper que sur la carte, pas au-dessus de l'interface.
	if event is InputEventKey and event.scancode == KEY_ENTER \
	and ui_util != null and is_instance_valid(ui_util) \
	and ui_util.is_mouse_over_ui(_input_listener):
		return
	# Suppress Enter during cooldown (press AND release)
	if event is InputEventKey and event.scancode == KEY_ENTER:
		if OS.get_ticks_msec() < _suppress_enter_until:
			_g.World.get_tree().set_input_as_handled()
			return
	# Restaure le max du slider Scale au clic (= pose de l'objet place)
	# (Desormais gere par scale_unlock.gd)

	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.scancode != KEY_ENTER:
		return
	if _select_tool == null:
		return

	# Only in SelectTool
	var editor = _g.World.get_tree().root.get_node_or_null("Master/Editor")
	if editor == null: return
	var toolset = editor.get("Toolset")
	if toolset == null: return
	if str(editor.get("ActiveToolName")) != "SelectTool": return

	# Priorite au wall/path detecte par les mods (overlay). DD.HighlightThingAtPoint()
	# pioche l'asset EN DESSOUS : IsMouseWithin() est casse pour les flat paths, et
	# un wall/path perd face a l'objet/roof situe dessous. On prend donc d'abord ce
	# qui est reellement surligne par l'overlay (uniquement si l'overlay est actif).
	var thing = null
	var ov = _main.overlay_tool if (_main != null and is_instance_valid(_main)) else null
	if ov != null and is_instance_valid(ov):
		if ov._hover_wall != null and is_instance_valid(ov._hover_wall) \
		and ov.has_method("_effective_walls") and ov._effective_walls():
			thing = ov._hover_wall
		elif ov._hover_path != null and is_instance_valid(ov._hover_path) and ov._paths_enabled:
			thing = ov._hover_path

	# Sinon, comportement DD habituel : hover natif + fallback selection unique.
	if thing == null:
		_select_tool.HighlightThingAtPoint()
		var highlighted = _select_tool.get("highlighted")
		# Fallback : HighlightThingAtPoint() utilise IsMouseWithin() en interne,
		# qui est cassé pour les flat paths (corrigé par path_fix).
		# Si highlighted est null mais qu'un seul asset est sélectionné, on l'utilise.
		if highlighted == null or not is_instance_valid(highlighted):
			var raw = _select_tool.RawSelectables
			if raw != null and raw.size() == 1:
				var candidate = raw[0]
				if candidate != null and is_instance_valid(candidate):
					highlighted = candidate
		if highlighted == null or not is_instance_valid(highlighted): return
		thing = highlighted.get("Thing")

	if thing == null or not is_instance_valid(thing): return

	var sel_type = _select_tool.GetSelectableType(thing)
	# Consume immediately
	_g.World.get_tree().set_input_as_handled()
	_suppress_enter_until = OS.get_ticks_msec() + 500
	# Schedule deferred cursor reset (DD reapplies cursor during Quickswitch)
	var t_cur = _g.World.get_tree().create_timer(0.05)
	t_cur.connect("timeout", self, "_reset_cursor")
	# Remettre la forme du curseur MAINTENANT, avant le Quickswitch.
	# C'est la seule fenêtre fiable : après le switch, le nouveau tool
	# ré-applique sa propre forme dès son premier frame.
	# Safe ici car on est en train de quitter SelectTool.
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

	var picked = false

	# ── Object (type 4) ──────────────────────────────────────────────────────
	if not picked and sel_type == 4:
		var obj_tool = _g.Editor.Tools["ObjectTool"]
		if obj_tool:
			obj_tool.set("LibraryMemory", {"selected": [thing.Texture.resource_path]})
			obj_tool.set("Texture", thing.Texture)
			if thing.get("GlobalRotation") != null:
				var rot_ctrl = obj_tool.get("Rotation")
				if rot_ctrl and rot_ctrl.has_method("set_value"):
					rot_ctrl.set_value(rad2deg(thing.GlobalRotation))
			if thing.get("GlobalScale") != null:
				var sc_val = thing.GlobalScale.x
				if scale_unlock != null:
					scale_unlock.set_value(sc_val)
				else:
					var sc_ctrl = obj_tool.get("Scale")
					if sc_ctrl != null:
						sc_ctrl.set_value(sc_val)

			if thing.get("HasShadow") != null:
				obj_tool.set("Shadow", thing.HasShadow)
				var shadow_ctrl = obj_tool.get("Controls")
				if shadow_ctrl and shadow_ctrl.has("Shadow"):
					shadow_ctrl["Shadow"].pressed = thing.HasShadow
			if thing.get("BlockLight") != null:
				obj_tool.set("BlockLight", thing.BlockLight)
				var bl_ctrl = obj_tool.get("Controls")
				if bl_ctrl and bl_ctrl.has("BlockLight"):
					bl_ctrl["BlockLight"].set_pressed_no_signal(thing.BlockLight)
			if thing.get("hasCustomColor") and thing.hasCustomColor:
				obj_tool.set("customColor", thing.customColor)
				if obj_tool.has_method("PromoteCustomColor"):
					obj_tool.call("PromoteCustomColor")
			_select_tool.ClearTransformSelection()
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_g.Editor.Toolset.Quickswitch("ObjectTool")
			_apply_layer(obj_tool, thing)
			picked = true
			print("[Eyedropper] Picked Object")

	# ── Wall (type 1) ────────────────────────────────────────────────────────
	if not picked and sel_type == 1:
		var wall_tool = _g.Editor.Tools["WallTool"]
		if wall_tool:
			var tc = wall_tool.get("Controls")
			if tc and tc.has("Texture"):
				tc["Texture"].call("SelectTexture", thing.Texture)
			wall_tool.set("Texture", thing.Texture)
			if wall_tool.has_method("SetWallColor") and thing.get("Color") != null:
				wall_tool.call("SetWallColor", thing.Color)
			if tc and tc.has("Bevel"):
				tc["Bevel"].pressed = (thing.Joint == 1)
			if tc and tc.has("Shadow") and thing.get("HasShadow") != null:
				tc["Shadow"].pressed = thing.HasShadow
			# Defer switch to next frame so Enter is fully consumed first
			_select_tool.ClearTransformSelection()
			var t_wall = _g.World.get_tree().create_timer(0.0)
			t_wall.connect("timeout", self, "_do_wall_switch")
			picked = true
			print("[Eyedropper] Picked Wall")

	# ── Portal (type 3) ──────────────────────────────────────────────────────
	if not picked and sel_type == 3:
		var portal_tool = _g.Editor.Tools["PortalTool"]
		if portal_tool:
			var tm = portal_tool.get("textureMenu")
			if tm: tm.call("SelectTexture", thing.Texture)
			portal_tool.set("Texture", thing.Texture)
			portal_tool.set("Flip", thing.Flip)
			portal_tool.set("Closed", thing.Closed)
			portal_tool.set("Freestanding", thing.IsFreestanding)
			if thing.IsFreestanding and thing.get("Direction") != null:
				var rot_ctrl = portal_tool.get("Rotation")
				if rot_ctrl and rot_ctrl.has_method("set_value"):
					rot_ctrl.set_value(rad2deg(thing.Direction.angle()))
			_select_tool.ClearTransformSelection()
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_g.Editor.Toolset.Quickswitch("PortalTool")
			_apply_layer(portal_tool, thing)
			picked = true
			print("[Eyedropper] Picked Portal")

	# ── Path (type 5) ─────────────────────────────────────────────────────
	if not picked and sel_type == 5:
		var pt = _g.Editor.Tools["PathTool"]
		var tex = thing.get("texture")
		var raw_w       = thing.get("width")
		var smoothness  = thing.get("Smoothness")
		var fade_in     = thing.get("FadeIn")
		var fade_out    = thing.get("FadeOut")
		var grow        = thing.get("Grow")
		var shrink      = thing.get("Shrink")
		var block_light = thing.get("BlockLight")
		if tex != null:
			pt.LibraryMemory["selected"] = [tex.resource_path]
			pt.Texture = tex
		_select_tool.ClearTransformSelection()
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		_g.Editor.Toolset.Quickswitch("PathTool")
		if raw_w != null and tex != null:
			var tex_h = float(tex.get_height())
			var effective_w = raw_w * thing.scale.x
			if tex_h > 0:
				pt.Width = max(0.1, effective_w / tex_h)
		if smoothness != null: pt.Smoothness = smoothness
		if fade_in != null:    pt.SetFadeIn(fade_in)
		if fade_out != null:   pt.SetFadeOut(fade_out)
		if grow != null:       pt.SetTransitionIn(2 if grow else (1 if fade_in else 0))
		if shrink != null:     pt.SetTransitionOut(2 if shrink else (1 if fade_out else 0))
		if block_light != null:
			pt.BlockLight = block_light
			pt.SetBlockLight(block_light)
		_apply_layer(pt, thing)
		picked = true
		print("[Eyedropper] Picked Path")

	# ── Light (type 6) ────────────────────────────────────────────────────────
	if not picked and sel_type == 6:
		var light_tool = _g.Editor.Tools["LightTool"]
		if light_tool:
			var tex = thing.call("get_texture") if thing.has_method("get_texture") else null
			if tex:
				light_tool.set("texture", tex)
				var tc = light_tool.get("Controls")
				if tc and tc.has("Texture"):
					tc["Texture"].call("SelectTexture", tex)
			light_tool.set("Intensity", thing.energy)
			if thing.has_method("get_texture_scale") and tex:
				var rng_ctrl = light_tool.get("Range")
				if rng_ctrl and rng_ctrl.has_method("set_value"):
					rng_ctrl.set_value((thing.get_texture_scale() * tex.get_width()) / 512.0)
			_select_tool.ClearTransformSelection()
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_g.Editor.Toolset.Quickswitch("LightTool")
			_apply_layer(light_tool, thing)
			picked = true
			print("[Eyedropper] Picked Light")

	# ── Pattern Shape (type 7) ───────────────────────────────────────────────
	if not picked and sel_type == 7:
		var pat_tool = _g.Editor.Tools["PatternShapeTool"]
		if pat_tool:
			var tm = pat_tool.get("textureMenu")
			if tm: tm.call("SelectTexture", thing._Texture)
			pat_tool.set("Texture", thing._Texture)
			var snap = _g.World.get("UI")
			var snap_pos = snap.SnappedPosition if snap else thing.global_position
			pat_tool.set("boxBegin", snap_pos)
			pat_tool.set("boxEnd", snap_pos)
			if pat_tool.has_method("ChangeColor") and thing.get("Color") != null:
				pat_tool.call("ChangeColor", thing.Color, "")
			if thing.get("_Rotation") != null:
				var rot_ctrl = pat_tool.get("Rotation")
				if rot_ctrl and rot_ctrl.has_method("set_value"):
					rot_ctrl.set_value(rad2deg(thing._Rotation))
			var tc = pat_tool.get("Controls")
			if tc and tc.has("Outline") and thing.get("HasOutline") != null:
				tc["Outline"].pressed = thing.HasOutline
			_select_tool.ClearTransformSelection()
			yield(_g.World.get_tree().create_timer(0.1), "timeout")
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_g.Editor.Toolset.Quickswitch("PatternShapeTool")
			_apply_layer(pat_tool, thing)
			picked = true
			print("[Eyedropper] Picked Pattern")

	# ── Roof (type 8) ────────────────────────────────────────────────────────
	if not picked and sel_type == 8:
		var roof_tool = _g.Editor.Tools["RoofTool"]
		if roof_tool:
			roof_tool.set("Texture", thing.TilesTexture)
			var tc = roof_tool.get("Controls")
			if tc and tc.has("Texture"):
				tc["Texture"].call("SelectTexture", thing.TilesTexture)
			var snap = _g.World.get("UI")
			var snap_pos = snap.SnappedPosition if snap else thing.global_position
			roof_tool.set("boxBegin", snap_pos)
			roof_tool.set("boxEnd", snap_pos)
			if roof_tool.has_method("SetShade") and thing.get("shade") != null:
				roof_tool.call("SetShade", thing.shade)
			if thing.get("shadeContrast") != null:
				var sc = roof_tool.get("ShadeContrast")
				if sc and sc.has_method("set_value"):
					sc.set_value(thing.shadeContrast)
			if thing.get("type") != null:
				roof_tool.set("Type", thing.type)
			if thing.get("width") != null:
				var w_ctrl = roof_tool.get("Width")
				if w_ctrl and w_ctrl.has_method("set_value"):
					w_ctrl.set_value(thing.width / _g.World.get("Instance").TileSize)
			_select_tool.ClearTransformSelection()
			yield(_g.World.get_tree().create_timer(0.1), "timeout")
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_g.Editor.Toolset.Quickswitch("RoofTool")
			_apply_layer(roof_tool, thing)
			picked = true
			print("[Eyedropper] Picked Roof")

	if not picked:
		print("[Eyedropper] Unknown asset type — GetSelectableType=", sel_type)
