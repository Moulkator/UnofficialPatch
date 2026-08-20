# terrain_paint_bucket.gd
# Square Brush pour le Terrain Brush : peint des carrés alignés sur la grille
# splat du terrain avec des bords nets.
#
# Le slider Size contrôle la taille en pixels splat :
#   0.25 → 1×1, 0.50 → 2×2, 0.75 → 3×3, 1.00 → 4×4, etc.
#
# Le carré jaune de preview montre exactement les pixels qui seront peints.

var _g
var ui_util
var input_listener: Node
const _META_KEY = "TerrainPaintBucketListener"

# UI — rangée de modes (Normal / Square / Bucket), boutons-icônes radio
const MODE_NORMAL = 0
const MODE_SQUARE = 1
const MODE_BUCKET = 2
var _mode := MODE_NORMAL
var _normal_button: Button = null
var _square_brush_button: Button = null
var _square_brush_active := false
var _suspended := false  # true quand on a quitté le terrain tool temporairement
var _painting := false
var _extra_stroke := false  # true when the current stroke targets a slot 9-24 (delegated)
var _prev_splat = null
var _prev_splat2 = null
var _size_slider: HSlider = null
var _size_spinbox: SpinBox = null
var _original_slider_min := 0.51
var _original_slider_step := 0.01
var _original_spinbox_step := 0.01
var _saved_size := -1.0  # Taille sauvegardée quand on quitte le tool
var _square_saved_value := -1.0  # Valeur propre au square brush (indépendante du circle)
var _circle_saved_value := -1.0  # Valeur propre au circle brush (indépendante du square)
# Conteneurs/labels des réglages du panneau, pour griser/locker selon le mode.
var _size_container = null
var _size_label = null
var _intensity_container = null
var _intensity_label = null
var _intensity_slider: HSlider = null
var _intensity_spinbox: SpinBox = null

# Preview
var _saved_cursor_mode := -1
var _square_preview: Line2D = null

const SQUARE_SIZE = 128.0  # Fallback si BrushRadius indisponible

# Undo record script, loaded once at init.
var _UndoRecordScript = null

# Bucket fill (région bornée par murs/paths/bords de map)
var _bucket_button: Button = null

# Options "Stopped by" (types de barrières qui bloquent le bucket)
var _opts_hbox = null
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null
var _bucket_active := false
var _region_geo = null  # instance de library/region_geometry.gd

# Barre de progression + Annuler (opérations longues)
var _progress_script = null
var _filling := false
# Fill watchdog: if the fill coroutine dies from a runtime error, _filling
# would stay true forever — every canvas click in Bucket mode would then be
# silently swallowed by _on_input (the tool looks completely dead) until the
# mods are reloaded. A Timer on the listener node (Timers keep running while
# modal windows freeze the mod update loop) re-arms the bucket after a long
# silence and force-closes any orphaned modal progress dialog.
const FILL_WATCHDOG_MS = 6000
var _fill_started := 0
var _active_progress = null

# Curseur du mode Bucket (bucket_cursor.png, comme l'outil Pattern).
var _bucket_cursor_tex: ImageTexture = null
var _bucket_cursor_active := false

# Compat ASO : grille de recherche terrain (voir _ensure_aso_grid_height).
var _aso_grid_done := false
var _aso_grid_timer := 0
const ASO_GRID_MIN_H := 700.0
# Point chaud du curseur, en fraction de la taille de l'image (0,0 = haut-gauche,
# 1,1 = bas-droite). Ajuste si la pointe du seau ne tombe pas sur le clic.
const BUCKET_CURSOR_HOTSPOT_FRAC = Vector2(0.0, 1.0)

# Bucket fill — réglages des bords :
#   BUCKET_SUPERSAMPLE : qualité de l'anti-aliasing des bords (échantillons par
#       côté de texel). 2-4 suffit (le shader filtre déjà le splat en linéaire).
#   BUCKET_EDGE_SHIFT  : biais de l'échantillonnage vers le bas-droite, en texels,
#       ce qui décale le remplissage vers le HAUT-GAUCHE. 0 = centré (neutre vis-
#       à-vis de l'orientation des murs — recommandé). >0 décale en diagonale, ce
#       qui n'est correct que pour une seule orientation.
const BUCKET_SUPERSAMPLE = 4
const BUCKET_EDGE_SHIFT = 0.0
# Portée du remplissage en PIXELS MONDE (signé) : la région est dilatée de cette
# distance avant rasterisation. Comme les murs sont dessinés PAR-DESSUS le terrain,
# une valeur positive fait passer le remplissage SOUS les murs (la partie cachée
# ne se voit pas) ; trop grand → ça dépasse de l'autre côté. Négatif = recule.
# ~ demi-épaisseur d'un mur. À 0 le bord est sur l'axe du mur ; le léger
# débordement restant vient du filtrage linéaire du splat (incompressible, ~½
# texel). Passe en NÉGATIF (-4 à -8) pour faire reculer le bord et que cette bave
# retombe sous le mur. Le splat (64 px/texel) ne peut pas épouser un mur plus fin.
const BUCKET_REACH = -4.0


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize():
	# History record classes live in library/ (convention aligned with
	# DD's own built-in at library/custom_history_record.gd).
	_UndoRecordScript = ResourceLoader.load(_g.Root + "library/terrain_undo_record.gd", "GDScript", true)
	if _UndoRecordScript == null:
		print("[TerrainSquareBrush] WARNING: could not load library/terrain_undo_record.gd; undo will be disabled")
	# Moteur de géométrie partagé (calcul de la région bornée par murs/paths/bords).
	var geo_script = ResourceLoader.load(_g.Root + "library/region_geometry.gd", "GDScript", true)
	if geo_script != null:
		_region_geo = geo_script.new()
		_region_geo._g = _g
	else:
		print("[TerrainSquareBrush] WARNING: could not load library/region_geometry.gd; bucket fill disabled")
	# Barre de progression partagée (bucket fill long).
	_progress_script = ResourceLoader.load(_g.Root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		print("[TerrainSquareBrush] WARNING: library/progress_dialog.gd introuvable; pas de barre de progression")
	_inject_ui()
	_install_listener()
	print("[TerrainSquareBrush] initialized")


# ── UI Injection ─────────────────────────────────────────────────────────────

func _inject_ui():
	var tool_panel = _g.Editor.Toolset.GetToolPanel("TerrainBrush")
	if tool_panel == null: return

	var align = tool_panel.get("Align")
	if align == null: return

	# Scanner le panneau : repérer les blocs "Brush Size" et "Intensity" (label +
	# conteneur slider/spinbox), pour le réglage de plage ET le grisage/lock.
	var last_label = null
	for child in align.get_children():
		if child is Label:
			last_label = child
			continue
		if child is HBoxContainer:
			var sl = null
			var sp = null
			var inner_label = null
			for sub in child.get_children():
				if sub is HSlider: sl = sub
				elif sub is SpinBox: sp = sub
				elif sub is Label and inner_label == null: inner_label = sub
			if sl != null or sp != null:
				var lbl = last_label
				if lbl == null: lbl = inner_label
				var name = ""
				if lbl != null and lbl.text != null: name = String(lbl.text).to_upper()
				if "INTENSITY" in name:
					_intensity_container = child
					_intensity_label = last_label
					_intensity_slider = sl
					_intensity_spinbox = sp
				elif "SIZE" in name:
					_size_container = child
					_size_label = last_label
					_size_slider = sl
					_size_spinbox = sp
					if sl != null:
						_original_slider_min = sl.min_value
						_original_slider_step = sl.step
					if sp != null:
						_original_spinbox_step = sp.step
				last_label = null

	# Curseur du mode Bucket (chargé depuis les icônes DD).
	_bucket_cursor_tex = _load_icon_tex("icons/bucket_cursor.png")

	# Rangée de modes : Normal (brush_round) / Square (brush_square) / Bucket
	# (bucket). Boutons radio (groupe) → exactement un actif, Normal par défaut.
	# Icônes réduites de 20 %.
	var grp = ButtonGroup.new()
	_normal_button = _make_mode_button(_load_icon_tex("icons/brush_round.png", 0.8), "N", \
		"Round brush (default)", grp, MODE_NORMAL)
	_square_brush_button = _make_mode_button(_load_icon_tex("icons/brush_square.png", 0.8), "S", \
		"Square brush — paint squares aligned to the splat grid.\nSlider Size = splat pixels per side.", grp, MODE_SQUARE)
	_bucket_button = _make_mode_button(_load_icon_tex("icons/bucket.png", 0.8), "B", \
		"Bucket fill — fill the region (bounded by the enabled barrier types) under the click. See the Stopped by options.", grp, MODE_BUCKET)

	var row = HBoxContainer.new()
	row.name = "TerrainBrushModeRow"
	row.alignment = BoxContainer.ALIGN_BEGIN  # aligné à gauche
	row.add_child(_normal_button)
	row.add_child(_square_brush_button)
	row.add_child(_bucket_button)
	align.add_child(row)

	# Placer la rangée AU-DESSUS du bloc "Brush Size" (donc entre Enabled et Size).
	var target_idx = align.get_child_count() - 1
	var size_label_idx = -1
	for i in range(align.get_child_count()):
		var c = align.get_child(i)
		if c == row: continue
		var t = c.get("text")
		if t != null and ("SIZE" in String(t).to_upper()):
			size_label_idx = i
			break
	if size_label_idx >= 0:
		target_idx = size_label_idx
	elif _size_container != null:
		target_idx = _size_container.get_index()
	align.move_child(row, target_idx)

	# Bloc "Stopped by" juste SOUS la rangée de modes (visible en mode Bucket) :
	# label sur sa propre ligne, cases à cocher sur la ligne suivante.
	_opts_hbox = VBoxContainer.new()
	_opts_hbox.name = "TerrainBucketStoppedByBlock"
	_opts_hbox.visible = false
	var lbl_sb = Label.new()
	lbl_sb.text = "Stopped by:"
	_opts_hbox.add_child(lbl_sb)
	var cb_row = HBoxContainer.new()
	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	cb_row.add_child(_cb_walls)
	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = true
	cb_row.add_child(_cb_paths)
	_cb_patterns = CheckBox.new()
	_cb_patterns.text = "Patterns"
	_cb_patterns.pressed = false
	cb_row.add_child(_cb_patterns)
	_opts_hbox.add_child(cb_row)
	align.add_child(_opts_hbox)
	align.move_child(_opts_hbox, row.get_index() + 1)

	# Mode par défaut : brush normale.
	_normal_button.pressed = true


func _load_icon_tex(rel: String, scale: float = 1.0) -> ImageTexture:
	if _g == null or _g.Root == null: return null
	var img = Image.new()
	if img.load(_g.Root + rel) != OK:
		print("[TerrainSquareBrush] icône introuvable: %s" % rel)
		return null
	if scale != 1.0 and scale > 0.0:
		var nw = max(1, int(round(img.get_width() * scale)))
		var nh = max(1, int(round(img.get_height() * scale)))
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


func _make_mode_button(tex, fallback_text: String, tip: String, grp: ButtonGroup, mode: int) -> Button:
	var b = Button.new()
	b.toggle_mode = true
	b.group = grp
	b.hint_tooltip = tip
	b.focus_mode = Control.FOCUS_NONE
	b.rect_min_size = Vector2(30, 27)  # ~20 % plus petit
	if tex != null:
		b.icon = tex
	else:
		b.text = fallback_text
	b.connect("toggled", self, "_on_mode_toggled", [mode])
	return b


func _on_mode_toggled(pressed: bool, mode: int):
	# Boutons radio : on n'agit que sur l'activation (le désactivé est implicite).
	if not pressed:
		return
	_set_mode(mode)


func _set_mode(mode: int):
	_mode = mode
	# État Square (preview + plage du slider).
	_set_square_active(mode == MODE_SQUARE)
	# État Bucket.
	_bucket_active = (mode == MODE_BUCKET)
	if _opts_hbox != null:
		_opts_hbox.visible = _bucket_active
	# Grisage/lock des contrôles selon le mode.
	_apply_mode_locks(mode)
	# Curseur.
	if mode == MODE_BUCKET:
		_hide_dd_cursor()  # le curseur seau est posé par frame dans update()
	else:
		_clear_bucket_cursor()
		if mode == MODE_NORMAL:
			_restore_dd_cursor()
	# (le mode SQUARE a déjà caché le curseur DD via _set_square_active)


# Grise + verrouille les réglages selon le mode :
#   Square  → Intensity verrouillée (Size reste réglable).
#   Bucket  → Size ET Intensity verrouillées.
#   Normal  → tout déverrouillé.
func _apply_mode_locks(mode: int):
	_set_row_locked(_size_container, _size_label, mode == MODE_BUCKET)
	_set_row_locked(_intensity_container, _intensity_label, mode == MODE_SQUARE or mode == MODE_BUCKET)


func _set_row_locked(container, label, locked: bool):
	var col = Color(1, 1, 1, 0.35) if locked else Color(1, 1, 1, 1)
	if container != null and is_instance_valid(container):
		container.modulate = col
		for sub in container.get_children():
			if sub is Slider or sub is SpinBox:
				sub.editable = not locked
	if label != null and is_instance_valid(label):
		label.modulate = col


func _set_square_active(active: bool):
	if active == _square_brush_active:
		# Réappliquer quand même les effets si on (ré)entre en mode square.
		if active:
			_hide_dd_cursor()
			_create_square_preview()
			_apply_square_slider()
		return
	_square_brush_active = active
	if active:
		# On entre en mode square depuis le circle : mémoriser la valeur propre
		# au circle pour la restaurer plus tard (le circle ne doit pas hériter de
		# la valeur du square, ni l'inverse).
		if _size_slider != null:
			_circle_saved_value = _size_slider.value
		_hide_dd_cursor()
		_create_square_preview()
		_apply_square_slider()
	else:
		_painting = false
		_remove_square_preview()
		_restore_square_slider()
		# Retour au circle : restaurer sa dernière valeur propre.
		if _circle_saved_value > 0.0:
			if _size_slider != null:
				_size_slider.value = _circle_saved_value
			if _size_spinbox != null:
				_size_spinbox.value = _circle_saved_value


func _apply_square_slider():
	if _size_slider != null:
		_size_slider.min_value = 0.25
		_size_slider.step = 0.25
	if _size_spinbox != null:
		_size_spinbox.min_value = 0.25
		_size_spinbox.step = 0.25
		_size_spinbox.rounded = false
	# Restaurer la dernière valeur fractionnaire propre au square brush, pour
	# qu'un aller-retour square → circle → square ne fasse pas hériter le square
	# de la valeur entière laissée par le circle brush. (min/step doivent être
	# déjà réglés au-dessus avant d'écrire la valeur, sinon Godot la clampe.)
	if _square_saved_value > 0.0:
		if _size_slider != null:
			_size_slider.value = _square_saved_value
		if _size_spinbox != null:
			_size_spinbox.value = _square_saved_value


func _restore_square_slider():
	# Mémoriser la valeur du square brush AVANT de remettre la plage du circle
	# (qui clampe au step de 1), afin de pouvoir la restaurer telle quelle au
	# retour en mode square.
	if _size_slider != null:
		_square_saved_value = _size_slider.value
	if _size_slider != null:
		_size_slider.min_value = _original_slider_min
		_size_slider.step = _original_slider_step
	if _size_spinbox != null:
		_size_spinbox.min_value = _original_slider_min
		_size_spinbox.step = _original_spinbox_step


# ── Curseur seau (mode Bucket) ───────────────────────────────────────────────

func _set_bucket_cursor():
	if _bucket_cursor_active: return
	if _bucket_cursor_tex == null: return
	var sz = _bucket_cursor_tex.get_size()
	var hotspot = Vector2(sz.x * BUCKET_CURSOR_HOTSPOT_FRAC.x, sz.y * BUCKET_CURSOR_HOTSPOT_FRAC.y)
	Input.set_custom_mouse_cursor(_bucket_cursor_tex, Input.CURSOR_ARROW, hotspot)
	_bucket_cursor_active = true


func _clear_bucket_cursor():
	if not _bucket_cursor_active: return
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	_bucket_cursor_active = false


# ── Square Preview ───────────────────────────────────────────────────────────

func _create_square_preview():
	if _square_preview != null: return
	_square_preview = Line2D.new()
	_square_preview.name = "SquareBrushPreview"
	_square_preview.width = 2.0
	_square_preview.default_color = Color(1.0, 1.0, 0.0, 0.9)
	_square_preview.z_index = 4096
	_square_preview.z_as_relative = false
	_square_preview.points = PoolVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var world = _g.get("World")
	if world != null and world is Node:
		world.add_child(_square_preview)
	else:
		_g.Editor.get_tree().get_root().add_child(_square_preview)


func _remove_square_preview():
	if _square_preview != null:
		if is_instance_valid(_square_preview):
			_square_preview.queue_free()
		_square_preview = null


func _get_square_splat_rect(mouse_world: Vector2) -> Array:
	var terrain = _get_terrain()
	if terrain == null: return []

	var splat_img = terrain.get("splatImage")
	if splat_img == null: return []
	var tw = splat_img.get_width()
	var th = splat_img.get_height()

	# Compenser le décalage de WorldToTexture (bug vanilla DD)
	var origin_world = terrain.TextureToWorld(Vector2.ZERO)
	var one_px_world = terrain.TextureToWorld(Vector2(1, 1))
	var px_size = one_px_world - origin_world
	var compensated = mouse_world - px_size * 0.5

	# Centre en texture space
	var center_tex = terrain.WorldToTexture(compensated)
	var cx = int(floor(center_tex.x))
	var cy = int(floor(center_tex.y))

	# Taille : slider * 4 = pixels splat de côté
	var size_val = 1.0
	if _size_slider != null:
		size_val = _size_slider.value
	var side = int(max(1, round(size_val * 4)))

	var half_low = side / 2
	var half_high = side - half_low - 1

	var min_x = int(max(0, cx - half_low))
	var max_x = int(min(tw - 1, cx + half_high))
	var min_y = int(max(0, cy - half_low))
	var max_y = int(min(th - 1, cy + half_high))

	return [terrain, min_x, min_y, max_x, max_y]


func _update_square_preview():
	if _square_preview == null or not is_instance_valid(_square_preview): return
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var mouse = world_ui.get("MousePosition")
	if mouse == null: return

	# Vérifier si le curseur est dans la zone terrain
	var terrain = _get_terrain()
	if terrain == null:
		_square_preview.visible = false
		return
	var splat_img = terrain.get("splatImage")
	if splat_img == null:
		_square_preview.visible = false
		return
	var tw = splat_img.get_width()
	var th = splat_img.get_height()

	var origin_world = terrain.TextureToWorld(Vector2.ZERO)
	var one_px_world = terrain.TextureToWorld(Vector2(1, 1))
	var px_size = one_px_world - origin_world
	var center_tex = terrain.WorldToTexture(mouse - px_size * 0.5)

	if center_tex.x < 0 or center_tex.x >= tw or center_tex.y < 0 or center_tex.y >= th:
		_square_preview.visible = false
		return

	_square_preview.visible = true

	var rect = _get_square_splat_rect(mouse)
	if rect.size() == 0: return

	var world_tl = terrain.TextureToWorld(Vector2(rect[1], rect[2]))
	var world_br = terrain.TextureToWorld(Vector2(rect[3] + 1, rect[4] + 1))

	_square_preview.points = PoolVector2Array([
		Vector2(world_tl.x, world_tl.y),
		Vector2(world_br.x, world_tl.y),
		Vector2(world_br.x, world_br.y),
		Vector2(world_tl.x, world_br.y),
		Vector2(world_tl.x, world_tl.y)
	])

	# Largeur constante de 2 pixels écran
	var vp = world_ui.get_viewport()
	if vp != null:
		var zoom = vp.get_canvas_transform().get_scale().x
		if zoom > 0:
			_square_preview.width = 2.0 / zoom


# ── DD Cursor ────────────────────────────────────────────────────────────────

func _hide_dd_cursor():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	var cur = world_ui.get("CursorMode")
	if cur != null and cur != 0:
		_saved_cursor_mode = cur
	world_ui.set("CursorMode", 0)

func _restore_dd_cursor():
	var world_ui = _g.get("WorldUI")
	if world_ui == null: return
	if _saved_cursor_mode >= 0:
		world_ui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1
	elif _is_terrain_tool_active():
		world_ui.set("CursorMode", 5)
	# else: no tool active (e.g. fresh map at startup) — don't force the brush
	# cursor, otherwise a stray circle shows under the cursor with no tool selected.


# ── Listener ─────────────────────────────────────────────────────────────────

func _install_listener():
	if Engine.has_meta(_META_KEY):
		var old = Engine.get_meta(_META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "TerrainSquareBrushListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(_META_KEY, node)
	# Watchdog timer (child of the listener so it lives in the SceneTree and
	# keeps ticking even when DD freezes the mod update loop behind a modal).
	var wt = Timer.new()
	wt.wait_time = 2.0
	wt.autostart = true
	node.add_child(wt)
	wt.connect("timeout", self, "_watchdog_tick")
	_g.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# Failsafe: a healthy fill reports activity continuously (the progress object
# is pumped on every loop iteration, and synchronous stretches block this timer
# anyway). A long silence while _filling is set means the coroutine is dead:
# reset the flag and force the orphaned modal dialog closed.
func _watchdog_tick():
	if not _filling:
		return
	var alive = _fill_started
	if _active_progress != null:
		alive = max(alive, _active_progress.last_activity)
	if OS.get_ticks_msec() - alive < FILL_WATCHDOG_MS:
		return
	print("[TerrainBucket] WARNING: fill watchdog fired — the fill coroutine died (check the errors above). Bucket re-armed.")
	_filling = false
	if _active_progress != null:
		if _active_progress.has_method("force_close"):
			_active_progress.force_close()
		_active_progress = null


# ── Utils ────────────────────────────────────────────────────────────────────

func _is_terrain_tool_active() -> bool:
	if _g == null: return false
	var editor = _g.get("Editor")
	if editor == null: return false
	return editor.get("ActiveToolName") == "TerrainBrush"

func _get_terrain():
	if _g == null: return null
	var world = _g.get("World")
	if world == null: return null
	var level = world.call("GetCurrentLevel")
	if level == null: return null
	return level.get("Terrain")

func _get_splat_refs(terrain, terrain_id: int) -> Array:
	var use_splat2 = terrain_id >= 4
	var channel = terrain_id % 4
	var splat_img = terrain.get("splatImage2") if use_splat2 else terrain.get("splatImage")
	var splat_other = null
	if use_splat2:
		splat_other = terrain.get("splatImage")
	elif terrain.get("ExpandedSlots") == true:
		splat_other = terrain.get("splatImage2")
	return [splat_img, splat_other, channel]

func _make_color(channel: int, value: float) -> Color:
	var c = Color(0, 0, 0, 0)
	match channel:
		0: c.r = value
		1: c.g = value
		2: c.b = value
		3: c.a = value
	return c


# ── Undo ─────────────────────────────────────────────────────────────────────
#
# Why we do this ourselves instead of just setting TerrainBrush.previousSplat:
# our listener calls set_input_as_handled() on mouse events in Square Brush
# mode, so DD's native TerrainBrush never sees the mouse-down/up. Its own
# record-creation code path (which reads previousSplat) therefore never runs.
# Setting previousSplat alone creates no history entry — we have to register
# an undo action ourselves.
#
# We use the Godot UndoRedo exposed by DD's Editor, combined with
# Terrain.RestoreSplat() / RestoreSplat2() which the API docs describe as
# "Used by undo history" — i.e. this is the same restore path DD uses for
# its own terrain undos. One Ctrl+Z per paint stroke.

# terrain_slots_extended singleton, when an extended slot (9-24) is active.
func _tse():
	if Engine.has_meta("terrain_slots_extended_singleton"):
		var m = Engine.get_meta("terrain_slots_extended_singleton")
		if m != null and is_instance_valid(m) and m.has_method("paint_bucket_slot"):
			return m
	return null


func _paint_start():
	_extra_stroke = false
	var m = _tse()
	if m != null and m.is_extended_active():
		_extra_stroke = true
		m.extra_stroke_begin()
		_painting = true
		return
	var terrain = _get_terrain()
	if terrain == null: return
	_prev_splat = terrain.CloneSplatImage()
	if terrain.get("ExpandedSlots") == true:
		_prev_splat2 = terrain.CloneSplatImage2()
	_painting = true


func _paint_end():
	if not _painting: return
	_painting = false
	if _extra_stroke:
		_extra_stroke = false
		var m = _tse()
		if m != null:
			m.extra_stroke_end()
		return

	var terrain = _get_terrain()
	if terrain == null or _prev_splat == null:
		_prev_splat = null
		_prev_splat2 = null
		return

	# Snapshot the post-paint state for redo.
	var after_splat = terrain.CloneSplatImage()
	var after_splat2 = null
	var expanded = terrain.get("ExpandedSlots") == true
	if expanded:
		after_splat2 = terrain.CloneSplatImage2()

	# Create the history record. Editor.History.CreateCustomRecord() takes
	# a script instance; DD's C# code invokes Undo()/Redo() on it when the
	# user hits Ctrl+Z or Ctrl+Y. See terrain_undo_record.gd for the
	# record's method signatures.
	if _UndoRecordScript != null and _g.Editor.get("History") != null:
		var history = _g.Editor.History
		if history.has_method("CreateCustomRecord"):
			var record = _UndoRecordScript.new()
			record.terrain = terrain
			record.before_splat = _prev_splat
			record.after_splat  = after_splat
			record.before_splat2 = _prev_splat2
			record.after_splat2  = after_splat2
			history.CreateCustomRecord(record)
			print("[TerrainSquareBrush] undo record registered")
		else:
			print("[TerrainSquareBrush] History.CreateCustomRecord missing; paint is not undoable")
	else:
		print("[TerrainSquareBrush] History or record script unavailable; paint is not undoable")

	_prev_splat = null
	_prev_splat2 = null


# ── Square Brush Paint ───────────────────────────────────────────────────────

func _square_brush_paint(mouse_world: Vector2):
	var rect = _get_square_splat_rect(mouse_world)
	if rect.size() == 0: return

	var terrain = rect[0]
	var min_x = rect[1]
	var min_y = rect[2]
	var max_x = rect[3]
	var max_y = rect[4]

	var _m = _tse()
	if _m != null and _m.is_extended_active():
		var _slot = _m.paint_bucket_slot()
		if _slot < 0:
			_slot = int(_g.Editor.Tools["TerrainBrush"].TerrainID)
		var pixels = []
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				pixels.append([x, y, 1.0])
		_m.extra_paint_pixels(_slot, pixels)
		return

	var terrain_tool = _g.Editor.Tools["TerrainBrush"]
	if terrain_tool == null: return
	var terrain_id = terrain_tool.get("TerrainID")
	if terrain_id == null: terrain_id = 0

	var refs = _get_splat_refs(terrain, terrain_id)
	var splat_img = refs[0]
	var splat_other = refs[1]
	var channel = refs[2]
	if splat_img == null: return

	var new_c = _make_color(channel, 1.0)

	splat_img.lock()
	if splat_other != null:
		splat_other.lock()

	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			splat_img.set_pixel(x, y, new_c)
			if splat_other != null:
				splat_other.set_pixel(x, y, Color(0, 0, 0, 0))

	splat_img.unlock()
	if splat_other != null:
		splat_other.unlock()
	terrain.UpdateSplat()


# ── Bucket Fill ──────────────────────────────────────────────────────────────
#
# Calcule la région fermée (murs/paths/bords de map) contenant le clic via la lib
# de géométrie partagée, puis écrit dans le splat tous les texels dont le centre
# tombe dans la région. Résolution = grille splat (BlobSize), bords nets.

func _new_progress(title: String):
	if _progress_script == null:
		return null
	var pg = _progress_script.new()
	pg._g = _g
	pg.start(title)
	return pg


# Wrapper : garde de ré-entrance (ignore les clics pendant un remplissage en cours).
func _bucket_fill(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool):
	if _filling:
		return
	_filling = true
	_fill_started = OS.get_ticks_msec()
	var st = _bucket_fill_impl(mouse_world, stop_walls, stop_paths, stop_patterns)
	if st is GDScriptFunctionState:
		yield(st, "completed")
	_filling = false
	_active_progress = null


func _bucket_fill_impl(mouse_world: Vector2, stop_walls: bool, stop_paths: bool, stop_patterns: bool):
	if _region_geo == null:
		print("[TerrainBucket] region_geometry indisponible")
		return
	var terrain = _get_terrain()
	if terrain == null: return
	var splat_img = terrain.get("splatImage")
	if splat_img == null: return

	var t0 = OS.get_ticks_msec()
	var progress = _new_progress("Filling terrain…")
	_active_progress = progress
	if progress != null:
		# Yield une frame pour que le 0 % soit réellement AFFICHÉ (sinon la
		# première frame rendue arrive au premier pump(), déjà à quelques %).
		progress.set_progress(0.0, "Computing fill region\u2026")
		yield(_g.Editor.get_tree(), "idle_frame")

	# Échelle UNIQUE sur toute l'opération : région 0–60 %, rasterisation
	# 60–98 %, 100 % avant fermeture (plus de barre qui « repart de zéro »).
	var region = _region_geo.compute_region_async(mouse_world, stop_walls, stop_paths, stop_patterns, progress, 0.0, 0.6)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")
	if progress != null and region.get("cancelled") == true:
		progress.close()
		print("[TerrainBucket] Remplissage annulé par l'utilisateur")
		return

	var outer = region.outer
	if outer.size() < 3:
		if progress != null: progress.close()
		print("[TerrainBucket] aucune région trouvée (clic sur un mur ?) — %d ms" % (OS.get_ticks_msec() - t0))
		return

	# Diagnostic : bbox monde de la région vs clic. Si la région n'entoure pas
	# visuellement la pièce cliquée, le souci est la détection (coords des murs).
	var rminx = outer[0].x; var rmaxx = outer[0].x
	var rminy = outer[0].y; var rmaxy = outer[0].y
	for p in outer:
		rminx = min(rminx, p.x); rmaxx = max(rmaxx, p.x)
		rminy = min(rminy, p.y); rmaxy = max(rmaxy, p.y)
	print("[TerrainBucket] clic monde=(%.0f, %.0f) | région monde x[%.0f..%.0f] y[%.0f..%.0f] (%d pts)" % [
		mouse_world.x, mouse_world.y, rminx, rmaxx, rminy, rmaxy, outer.size()])

	# Dilatation de la région de BUCKET_REACH px (signé). L'offset d'un contour
	# ponté renvoie le contour dilaté ET les trous (en polygones séparés) : on les
	# garde TOUS et on testera l'appartenance en pair/impair (un point dans un trou
	# est compté 2 fois → exclu). Repli sur la région d'origine si l'offset échoue.
	var fill_polys = []
	if abs(BUCKET_REACH) > 0.01:
		var offres = Geometry.offset_polygon_2d(outer, BUCKET_REACH, Geometry.JOIN_MITER)
		for p in offres:
			if p.size() >= 3:
				fill_polys.append(_region_geo._to_array(p))
	if fill_polys.size() == 0:
		fill_polys = [outer]

	var terrain_tool = _g.Editor.Tools["TerrainBrush"]
	if terrain_tool == null:
		if progress != null: progress.close()
		return
	var terrain_id = terrain_tool.get("TerrainID")
	if terrain_id == null: terrain_id = 0

	var refs = _get_splat_refs(terrain, terrain_id)
	var splat_target = refs[0]
	var splat_other = refs[1]
	var channel = refs[2]
	if splat_target == null:
		if progress != null: progress.close()
		return

	var tw = splat_target.get_width()
	var th = splat_target.get_height()

	# Bbox monde de la région (dilatée) → plage de texels (avec marge de 1).
	var minw = fill_polys[0][0]
	var maxw = fill_polys[0][0]
	for poly in fill_polys:
		for p in poly:
			minw.x = min(minw.x, p.x); minw.y = min(minw.y, p.y)
			maxw.x = max(maxw.x, p.x); maxw.y = max(maxw.y, p.y)
	var t_min = terrain.WorldToTexture(minw)
	var t_max = terrain.WorldToTexture(maxw)
	var x0 = int(clamp(floor(min(t_min.x, t_max.x)) - 1, 0, tw - 1))
	var x1 = int(clamp(ceil(max(t_min.x, t_max.x)) + 1, 0, tw - 1))
	var y0 = int(clamp(floor(min(t_min.y, t_max.y)) - 1, 0, th - 1))
	var y1 = int(clamp(ceil(max(t_min.y, t_max.y)) + 1, 0, th - 1))

	var w = x1 - x0 + 1
	var h = y1 - y0 + 1

	# Taille monde d'un texel + décalage d'échantillonnage (biais haut-gauche).
	var origin_w = terrain.TextureToWorld(Vector2(0, 0))
	var px = terrain.TextureToWorld(Vector2(1, 1)) - origin_w  # ~ (BlobSize, BlobSize)
	var shift = px * BUCKET_EDGE_SHIFT  # samples décalés bas-droite → fill décalé haut-gauche

	# Couverture fractionnaire de chaque texel par la région, en UNE passe :
	# rasterisation SCANLINE suréchantillonnée (SS×SS). Par sous-ligne on calcule
	# les intersections des arêtes, on trie, on remplit en pair/impair, et on
	# accumule par texel. Coût O(sous-lignes × sommets + sous-cellules remplies),
	# au lieu de l'ancienne passe 2 qui faisait un point-in-polygon O(sommets) par
	# sous-échantillon de chaque texel de bordure (≈ region_pts × edge_texels × SS²,
	# le vrai goulot — 15 s sur une grande région à 2000+ points).
	# Aucune extension binaire vers l'extérieur : le débordement vient uniquement
	# du BUCKET_EDGE_SHIFT (réglable) et du filtrage linéaire du splat.
	var SS = BUCKET_SUPERSAMPLE
	var cov = _compute_coverage(fill_polys, x0, y0, w, h, origin_w, px, shift, terrain, SS, progress)
	if cov is GDScriptFunctionState:
		cov = yield(cov, "completed")
	if cov == null:
		if progress != null: progress.close()
		print("[TerrainBucket] Remplissage annulé par l'utilisateur")
		return
	if progress != null:
		# Deux frames pour que le 100 % soit visible avant fermeture.
		progress.set_progress(1.0, "Done")
		yield(_g.Editor.get_tree(), "idle_frame")
		yield(_g.Editor.get_tree(), "idle_frame")
		progress.close()

	# snapshot AVANT peinture (après la région + la couverture : une annulation en
	# amont ne laisse donc aucun snapshot orphelin à nettoyer).
	_paint_start()

	var _m = _tse()
	if _m != null and _m.is_extended_active():
		var _slot = _m.paint_bucket_slot()
		if _slot < 0:
			_slot = int(_g.Editor.Tools["TerrainBrush"].TerrainID)
		var pixels = []
		for yy in range(h):
			for xx in range(w):
				var wgt = cov[yy * w + xx]
				if wgt > 0.0:
					pixels.append([x0 + xx, y0 + yy, wgt])
		_m.extra_paint_pixels(_slot, pixels)
		_paint_end()
		return

	splat_target.lock()
	if splat_other != null:
		splat_other.lock()

	# Passe 2 : blend du splat vers le canal du terrain proportionnellement à la
	# couverture. Couverture 1 → terrain pur (fill net) ; partielle → mélange avec
	# le terrain existant (bord doux, comme le brush vanilla).
	var target_c = _make_color(channel, 1.0)
	var clear_c = Color(0, 0, 0, 0)
	var painted = 0
	for yy in range(h):
		for xx in range(w):
			var weight = cov[yy * w + xx]
			if weight <= 0.0:
				continue
			var x = x0 + xx
			var y = y0 + yy
			var ot = splat_target.get_pixel(x, y)
			splat_target.set_pixel(x, y, ot.linear_interpolate(target_c, weight))
			if splat_other != null:
				var oo = splat_other.get_pixel(x, y)
				splat_other.set_pixel(x, y, oo.linear_interpolate(clear_c, weight))
			painted += 1

	splat_target.unlock()
	if splat_other != null:
		splat_other.unlock()
	terrain.UpdateSplat()

	_paint_end()  # snapshot après + record undo
	var inside_count = 0
	for v in cov:
		if v >= 0.999: inside_count += 1
	print("[TerrainBucket] région=%d pts, bbox=%dx%d texels, centres intérieurs=%d, peints=%d — %d ms" % [
		outer.size(), w, h, inside_count, painted, OS.get_ticks_msec() - t0])


# Couverture fractionnaire [0..1] de chaque texel par la région (règle pair/impair
# sur fill_polys), via rasterisation SCANLINE suréchantillonnée SS×SS. Pour chaque
# sous-ligne : intersections des arêtes triées, remplissage pair/impair, et on
# incrémente le compteur du texel propriétaire de chaque sous-cellule remplie.
# Bien plus rapide que le point-in-polygon par sous-échantillon (qui était O(N) en
# sommets de région). Repli per-texel exact si l'orientation du splat est inhabituelle.
#
# Sous-échantillon (sous-colonne cc, sous-ligne r), mêmes positions que l'ancien AA :
#   centre = origin_w + (x0*px.x, y0*px.y) + shift + ((cc+0.5)*px.x/SS, (r+0.5)*px.y/SS)
# Renvoie null si l'utilisateur annule via la boîte de progression.
func _compute_coverage(polys: Array, x0: int, y0: int, w: int, h: int, origin_w: Vector2, px: Vector2, shift: Vector2, terrain, SS: int, progress = null):
	var cov = []
	cov.resize(w * h)
	var _tree = _g.Editor.get_tree()

	# Repli : orientation inhabituelle → supersampling exact par texel (lent mais rare).
	if px.x <= 0.0 or px.y == 0.0:
		for yy in range(h):
			if progress != null and progress.pump():
				progress.set_progress(0.6 + 0.38 * float(yy) / max(1, h), "Rasterizing… %d / %d" % [yy, h])
				yield(_tree, "idle_frame")
				if progress.cancelled:
					return null
			for xx in range(w):
				var tl = terrain.TextureToWorld(Vector2(x0 + xx, y0 + yy)) + shift
				var hits = 0
				for sy in range(SS):
					for sx in range(SS):
						var sp = tl + Vector2(px.x * (sx + 0.5) / SS, px.y * (sy + 0.5) / SS)
						if _in_fill(sp, polys):
							hits += 1
				cov[yy * w + xx] = float(hits) / float(SS * SS)
		return cov

	var counts = []
	counts.resize(w * h)
	for i in range(w * h):
		counts[i] = 0

	var sub_x = px.x / SS
	var sub_y = px.y / SS
	var bx0 = origin_w.x + x0 * px.x + shift.x  # bord gauche du texel col 0
	var by0 = origin_w.y + y0 * px.y + shift.y  # bord haut du texel row 0
	var max_cc = w * SS - 1
	var sub_rows = h * SS
	var xs = []
	for r in range(sub_rows):
		if progress != null and progress.pump():
			progress.set_progress(0.6 + 0.38 * float(r) / max(1, sub_rows), "Rasterizing… %d / %d" % [r, sub_rows])
			yield(_tree, "idle_frame")
			if progress.cancelled:
				return null
		var wy = by0 + (r + 0.5) * sub_y
		var trow = r / SS  # division entière → texel row
		xs.clear()
		for poly in polys:
			var n = poly.size()
			if n < 3: continue
			var j = n - 1
			for k in range(n):
				var a = poly[k]
				var b = poly[j]
				if (a.y > wy) != (b.y > wy):
					var t = (wy - a.y) / (b.y - a.y)
					xs.append(a.x + t * (b.x - a.x))
				j = k
		if xs.size() < 2:
			continue
		xs.sort()
		var base = trow * w
		var p = 0
		while p + 1 < xs.size():
			# Sous-colonnes dont le centre tombe dans [xs[p], xs[p+1]) → intérieures.
			# centre_x(cc) = bx0 + (cc+0.5)*sub_x
			var cc0 = int(ceil((xs[p] - bx0) / sub_x - 0.5))
			var cc1 = int(floor((xs[p + 1] - bx0) / sub_x - 0.5))
			if bx0 + (cc1 + 0.5) * sub_x >= xs[p + 1]:
				cc1 -= 1  # bord droit ouvert
			if cc0 < 0: cc0 = 0
			if cc1 > max_cc: cc1 = max_cc
			# Accumulation par texel : pour chaque texel recouvert par [cc0..cc1],
			# nombre de ses sous-colonnes dans l'intervalle (évite une division par
			# sous-colonne).
			var tc = cc0 / SS
			while tc * SS <= cc1:
				var lo = tc * SS
				var hi = lo + SS - 1
				if lo < cc0: lo = cc0
				if hi > cc1: hi = cc1
				counts[base + tc] += (hi - lo + 1)
				tc += 1
			p += 2

	var inv = 1.0 / float(SS * SS)
	for i in range(w * h):
		cov[i] = float(counts[i]) * inv
	return cov


# Appartenance à la zone remplie : règle pair/impair sur la liste de polygones.
# L'offset d'une région à trous renvoie le contour dilaté (CCW) + les trous (CW) ;
# un point dans un trou est contenu par 2 polygones (contour + trou) → pair → exclu.
func _in_fill(point: Vector2, polys: Array) -> bool:
	var c = 0
	for poly in polys:
		if _region_geo.point_in_region(point, poly):
			c += 1
	return (c % 2) == 1


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_input(event) -> bool:
	if not _square_brush_active and not _bucket_active: return false
	if not _is_terrain_tool_active(): return false

	# Handle the left RELEASE before the UI guard: only consume it if WE were
	# painting. Otherwise a scrollbar drag that started on the panel and drifted
	# out onto the canvas would have its release swallowed here, leaving the
	# scrollbar stuck following the mouse. Ending here (even over UI) also avoids
	# leaving _painting stuck true when a square stroke is released over a panel.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		if _painting:
			_paint_end()
			return true
		return false

	if ui_util != null and ui_util.is_mouse_over_hud(input_listener): return false

	var world_ui = _g.get("WorldUI")
	if world_ui == null: return false

	var mouse_w = _get_raw_mouse_world(world_ui, event)
	if mouse_w == null: return false

	# Bucket : remplissage one-shot au clic gauche.
	if _bucket_active:
		if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
			var sw = _cb_walls.pressed if _cb_walls != null else true
			var sp = _cb_paths.pressed if _cb_paths != null else true
			var spat = _cb_patterns.pressed if _cb_patterns != null else false
			_bucket_fill(mouse_w, sw, sp, spat)
			return true
		return false

	# Square brush (peinture continue).
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		_paint_start()
		_square_brush_paint(mouse_w)
		return true

	if event is InputEventMouseMotion and _painting:
		_square_brush_paint(mouse_w)
		return true

	return false


# ── Compat AdditionalSearchOptions ─────────────────────────────────────────────
# La grille de recherche terrain d'ASO (CreateTextureGridMenu, enregistree dans
# Controls["TerrainTextureGridID"]) n'a AUCUNE hauteur minimale : elle ne vit
# que de l'espace VBox RESTANT du panneau (size flag expand). Des que le
# contenu du panneau depasse la hauteur visible (notre rangee de modes suffit
# a faire basculer le total), l'espace restant tombe a 0 et la grille
# "disparait" (rect 0 px, items pourtant charges). On lui impose une hauteur
# minimale une fois trouvee : la grille scrolle en interne (ItemList) et le
# panneau (ScrollContainer) scrolle deja. Retente ~2 min puis abandonne
# silencieusement (ASO absent).
func _ensure_aso_grid_height() -> void:
	if _aso_grid_done:
		return
	_aso_grid_timer += 1
	if _aso_grid_timer % 30 != 0 or _aso_grid_timer > 30 * 120:
		return
	if _g == null or _g.get("Editor") == null:
		return
	var tb = _g.Editor.Tools["TerrainBrush"]
	if tb == null:
		return
	var ctrls = tb.get("Controls")
	if ctrls == null or not (ctrls is Dictionary):
		return
	if not ctrls.has("TerrainTextureGridID"):
		return
	var grid = ctrls["TerrainTextureGridID"]
	if grid == null or not is_instance_valid(grid) or not (grid is Control):
		return
	if grid.rect_min_size.y < ASO_GRID_MIN_H:
		grid.rect_min_size = Vector2(grid.rect_min_size.x, ASO_GRID_MIN_H)
	_aso_grid_done = true
	print("[TerrainSquareBrush] ASO terrain search grid: min height applied")


func _get_raw_mouse_world(world_ui, event):
	# Source de verite : WorldUI.MousePosition (position monde des outils
	# natifs DD). event.position converti a la main derive d'un offset ecran
	# sur certaines configs (Retina/DPI/UI scaling) -> terrain place a droite.
	var mp = world_ui.get("MousePosition")
	if mp != null and mp is Vector2:
		return mp
	# Fallback : calcul manuel historique.
	var vp = world_ui.get_viewport()
	if vp == null: return null
	var xform = vp.get_canvas_transform()
	return xform.affine_inverse().xform(event.position)


# ── Update ────────────────────────────────────────────────────────────────────

func update(_delta):
	_ensure_aso_grid_height()
	if not _is_terrain_tool_active():
		# Suspendre le mode une seule fois (le bouton reste coché)
		if (_square_brush_active or _bucket_active) and not _suspended:
			_suspended = true
			_painting = false
			_clear_bucket_cursor()
			# Déverrouiller les contrôles (le panneau est masqué de toute façon).
			_set_row_locked(_size_container, _size_label, false)
			_set_row_locked(_intensity_container, _intensity_label, false)
			if _square_brush_active:
				# Sauvegarder la taille UNE SEULE FOIS avant que DD la réinitialise
				if _size_slider != null:
					_saved_size = _size_slider.value
				_remove_square_preview()
				_restore_square_slider()
			# Ne pas restaurer le curseur DD — le nouveau tool gère le sien.
			# Juste forcer CursorMode à 0 pour ne pas laisser le cercle jaune.
			var world_ui = _g.get("WorldUI")
			if world_ui != null:
				world_ui.set("CursorMode", 0)
		return

	# Réactiver le mode quand on revient sur le terrain tool
	if (_square_brush_active or _bucket_active) and _suspended:
		_suspended = false
		if _square_brush_active:
			_create_square_preview()
			_apply_square_slider()
			if _saved_size > 0:
				if _size_slider != null:
					_size_slider.value = _saved_size
				if _size_spinbox != null:
					_size_spinbox.value = _saved_size

	# Réappliquer le grisage/lock chaque frame (DD peut réactiver les contrôles).
	_apply_mode_locks(_mode)

	if _square_brush_active:
		# Toujours cacher le cercle jaune DD (il se réactive chaque frame)
		_hide_dd_cursor()
		_update_square_preview()
		if _square_preview != null and is_instance_valid(_square_preview):
			if ui_util != null and ui_util.is_mouse_over_hud(input_listener):
				_square_preview.visible = false
		# Forcer l'affichage correct de la valeur (2 décimales)
		if _size_spinbox != null:
			var val = _size_spinbox.value
			var line_edit = _size_spinbox.get_line_edit()
			if line_edit != null:
				var txt = "%.2f" % val
				if line_edit.text != txt:
					line_edit.text = txt

	# Bucket : cacher le cercle jaune DD et afficher le curseur seau sur le canvas
	# (curseur normal au-dessus de l'UI).
	if _bucket_active:
		_hide_dd_cursor()
		var over_ui = (ui_util != null and ui_util.is_mouse_over_hud(input_listener))
		if over_ui:
			_clear_bucket_cursor()
		else:
			_set_bucket_cursor()
